// RevertEngine.swift
// Plans and applies reverts. A plan collects the changes in scope, works out
// the earliest recorded state of every path, and lists the shell commands in
// the range whose non-file effects cannot be undone. Applying a plan first
// checkpoints the current state, so a revert is itself revertible, then
// restores each path from the object store and verifies it bit for bit.
// The result is `complete` only when every path was verified.

import Foundation

/// What to revert.
struct RevertScope: Equatable {
    let since: Date
    let until: Date
    /// Restrict to these sessions, or nil for every session.
    let sessionIds: [Int64]?
    /// Whether changes no agent claimed are included. Off by default so a
    /// person's own edits are not undone alongside an agent's.
    let includeUnattributed: Bool

    /// The scope as JSON for the ledger.
    var json: JSONValue {
        .object([
            "since": .string(NotchdProtocol.string(from: since)),
            "until": .string(NotchdProtocol.string(from: until)),
            "sessions": sessionIds.map { .array($0.map { .number(Double($0)) }) } ?? .null,
            "include_unattributed": .bool(includeUnattributed),
        ])
    }
}

/// What will be done to one path.
enum RevertAction: Equatable {
    /// Write these contents and this mode.
    case restore(ManifestEntry)
    /// Remove a file that did not exist before.
    case delete
    /// Nothing can be done, and this is why.
    case impossible(String)
}

/// One path in a plan.
struct RevertTarget: Equatable {
    let path: String
    let action: RevertAction
    /// The change ids that led here, oldest first.
    let changeIds: [Int64]
}

/// The whole plan.
struct RevertPlan: Equatable {
    let scope: RevertScope
    let targets: [RevertTarget]
    /// Shell commands in the range. Their files are restored; whatever else
    /// they did is not.
    let commands: [String]

    /// Whether there is anything to do.
    var isEmpty: Bool { targets.isEmpty }

    /// The same plan restricted to some of its paths, for a sheet where the
    /// user unticked files.
    /// - Parameter paths: The paths to keep.
    /// - Returns: A plan with only those targets.
    func keeping(paths: Set<String>) -> RevertPlan {
        RevertPlan(scope: scope, targets: targets.filter { paths.contains($0.path) }, commands: commands)
    }

    /// Targets that can actually be carried out.
    var possibleTargets: [RevertTarget] {
        targets.filter { if case .impossible = $0.action { return false } else { return true } }
    }
}

/// What happened when a plan was applied.
struct RevertResult: Equatable {
    let revertId: Int64
    let eventId: Int64
    let restored: [String]
    let failed: [(path: String, reason: String)]
    let outcome: RevertOutcome

    static func == (lhs: RevertResult, rhs: RevertResult) -> Bool {
        lhs.revertId == rhs.revertId && lhs.eventId == rhs.eventId && lhs.restored == rhs.restored
            && lhs.failed.map(\.path) == rhs.failed.map(\.path) && lhs.outcome == rhs.outcome
    }
}

/// Plans and applies reverts.
final class RevertEngine {
    let ledger: Ledger
    let store: ObjectStore
    let snapshotter: Snapshotter
    /// Told which paths are about to change so a watcher does not record the
    /// revert as somebody else's work.
    var suppress: ([String]) -> Void = { _ in }

    /// Creates an engine.
    /// - Parameters:
    ///   - ledger: The ledger.
    ///   - store: The object store.
    ///   - snapshotter: Used for the pre-revert checkpoint.
    init(ledger: Ledger, store: ObjectStore, snapshotter: Snapshotter) {
        self.ledger = ledger
        self.store = store
        self.snapshotter = snapshotter
    }

    /// Works out what a scope would restore.
    /// - Parameter scope: The range and filters.
    /// - Returns: The plan.
    func plan(_ scope: RevertScope) throws -> RevertPlan {
        let changes = try ledger.changes(since: scope.since, until: scope.until, sessionIds: scope.sessionIds,
                                         includeUnattributed: scope.includeUnattributed)
        var order: [String] = []
        var grouped: [String: [ChangeRow]] = [:]
        for change in changes {
            if grouped[change.path] == nil { order.append(change.path) }
            grouped[change.path, default: []].append(change)
        }
        let targets = order.map { path -> RevertTarget in
            let history = grouped[path] ?? []
            return RevertTarget(path: path, action: action(for: history), changeIds: history.map(\.id))
        }
        let commands = try ledger.events(since: scope.since, until: scope.until)
            .filter { event in
                (scope.sessionIds?.contains(event.sessionId) ?? true) && event.kind == .toolAfter
            }
            .compactMap { $0.args?["command"]?.stringValue }
            .reversed()
        return RevertPlan(scope: scope, targets: targets, commands: Array(commands))
    }

    /// The action that returns a path to its earliest recorded state.
    private func action(for history: [ChangeRow]) -> RevertAction {
        guard let first = history.first else { return .impossible("no history") }
        guard let before = first.before else {
            return first.kind == .create ? .delete : .impossible("no earlier copy was recorded")
        }
        guard store.contains(before.hash) else { return .impossible("the earlier copy is missing from the store") }
        return .restore(before)
    }

    /// Applies a plan.
    /// - Parameters:
    ///   - plan: What to do.
    ///   - now: The time to stamp the revert with.
    /// - Returns: What was restored and what could not be.
    func apply(_ plan: RevertPlan, now: Date = Date()) throws -> RevertResult {
        let paths = plan.targets.map(\.path)
        let event = try ledger.record(NotchdEvent(
            kind: .note, vendor: "notchd", session: "revert", cwd: "/", tool: "revert",
            args: plan.scope.json, paths: paths, meta: .object(["event": .string("Revert")]), ts: now, fidelity: .official
        ))
        let before = try snapshotter.snapshot(roots: paths)
        let manifestHash = try store.put(before.manifest)
        try ledger.recordCheckpoint(eventId: event.id, sessionId: event.sessionId, toolUseId: nil, roots: paths,
                                    manifestHash: manifestHash, result: before, late: false, durationMs: 0, createdAt: now)
        suppress(paths)

        var restored: [String] = []
        var failed: [(path: String, reason: String)] = []
        var changes: [NewChange] = []
        for target in plan.targets {
            do {
                let after = try perform(target)
                restored.append(target.path)
                let previous = before.manifest.entries[target.path]
                if previous != after {
                    let kind: ChangeKind = previous == nil ? .create : (after == nil ? .delete : .modify)
                    changes.append(NewChange(eventId: event.id, sessionId: event.sessionId, path: target.path, kind: kind,
                                             before: previous, after: after, attributed: true, ts: now))
                }
            } catch {
                failed.append((target.path, String(describing: error)))
            }
        }
        try ledger.recordChanges(changes)
        let outcome: RevertOutcome = failed.isEmpty ? .complete : .partial
        let note = failed.map { "\($0.path): \($0.reason)" }.joined(separator: "\n")
        let revertId = try ledger.recordRevert(eventId: event.id, scope: plan.scope.json, result: outcome, note: note, createdAt: now)
        return RevertResult(revertId: revertId, eventId: event.id, restored: restored, failed: failed, outcome: outcome)
    }

    /// Carries out one target and verifies the outcome.
    /// - Parameter target: The path and action.
    /// - Returns: The path's entry afterwards, nil when it no longer exists.
    private func perform(_ target: RevertTarget) throws -> ManifestEntry? {
        let url = URL(fileURLWithPath: target.path)
        switch target.action {
        case .impossible(let reason):
            throw RevertError.impossible(reason)
        case .delete:
            if FileManager.default.fileExists(atPath: target.path) || FileStat.of(target.path) != nil {
                try FileManager.default.removeItem(at: url)
            }
            guard FileStat.of(target.path) == nil else { throw RevertError.verificationFailed(target.path) }
            snapshotter.cache.forget(target.path)
            return nil
        case .restore(let entry):
            guard let data = try store.get(entry.hash) else { throw RevertError.impossible("the earlier copy is missing from the store") }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileStat.of(target.path) != nil { try FileManager.default.removeItem(at: url) }
            if entry.isSymlink {
                try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: String(decoding: data, as: UTF8.self))
            } else {
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: Int(entry.mode)], ofItemAtPath: target.path)
            }
            guard let status = FileStat.of(target.path) else { throw RevertError.verificationFailed(target.path) }
            var skipped = 0
            var objects = 0
            var bytes: Int64 = 0
            let verified = try snapshotter.capture(target.path, status: status, skippedLarge: &skipped, newObjects: &objects, bytesRead: &bytes)
            guard verified?.hash == entry.hash else { throw RevertError.verificationFailed(target.path) }
            return verified
        }
    }
}

/// A failure restoring one path.
enum RevertError: Error, Equatable, CustomStringConvertible {
    case impossible(String)
    case verificationFailed(String)

    var description: String {
        switch self {
        case .impossible(let reason): return reason
        case .verificationFailed(let path): return "restored bytes did not verify at \(path)"
        }
    }
}
