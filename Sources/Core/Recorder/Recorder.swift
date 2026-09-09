// Recorder.swift
// Turns events into checkpoints and changes. Before a mutating tool call it
// snapshots the paths the call declared; after the call it snapshots again and
// records the difference. A session start warms the cache with a baseline of
// the working directory. Filesystem activity the watcher reports outside any
// open tool call is recorded as unattributed. Everything runs on one serial
// queue, and the before-checkpoint is taken synchronously so the hook's
// acknowledgement waits for it.

import Foundation
import os

/// Something that wants to see every recorded event.
protocol EventObserver: AnyObject {
    /// Called after an event is in the ledger, before the hook is acknowledged.
    /// - Parameters:
    ///   - row: The stored event.
    ///   - event: The normalised event.
    func observe(_ row: EventRow, event: NotchdEvent) throws
}

/// Checkpoints and diffs around tool calls.
final class Recorder: EventObserver {
    /// A tool call that has a checkpoint and no matching after-event yet.
    private struct OpenCall {
        let checkpointId: Int64
        let eventId: Int64
        let roots: [String]
        let manifest: Manifest
        /// When the vendor says the call started.
        let startedAt: Date
        /// True when Notchd learned of the call from a transcript, so the
        /// checkpoint may have been taken after the call had already run.
        let derived: Bool
    }

    /// How far before a derived call's own start time the watcher's reports
    /// are still taken to belong to it. Transcript clocks and the watcher's
    /// coalescing both introduce a little skew.
    static let derivedClaimSlack: TimeInterval = 5

    let ledger: Ledger
    let store: ObjectStore
    let snapshotter: Snapshotter
    /// How long the hook waits for the acknowledgement. A checkpoint slower
    /// than this is recorded as late.
    let hookBudget: TimeInterval

    private let queue = DispatchQueue(label: "com.muhammad.notchd.recorder")
    private var openCalls: [String: OpenCall] = [:]
    private var openCallOrder: [Int64: [String]] = [:]
    private var suppressedUntil: [String: Date] = [:]
    private let log = Logger(subsystem: "com.muhammad.notchd", category: "recorder")

    /// Called on the recorder queue after the set of open roots changes, so a
    /// watcher can be kept in step.
    var onRootsChanged: (() -> Void)?

    /// Creates a recorder.
    /// - Parameters:
    ///   - ledger: Where checkpoints and changes are written.
    ///   - store: Where contents are kept.
    ///   - snapshotter: Captures trees.
    ///   - hookBudget: The hook's acknowledgement wait, in seconds.
    init(ledger: Ledger, store: ObjectStore, snapshotter: Snapshotter, hookBudget: TimeInterval = 3.5) {
        self.ledger = ledger
        self.store = store
        self.snapshotter = snapshotter
        self.hookBudget = hookBudget
    }

    /// Routes an event to the right step. Runs synchronously so the caller's
    /// acknowledgement covers the checkpoint.
    /// - Parameters:
    ///   - row: The stored event.
    ///   - event: The normalised event.
    func observe(_ row: EventRow, event: NotchdEvent) throws {
        try queue.sync {
            switch event.kind {
            case .sessionStart:
                queue.async { [weak self] in self?.baseline(event.cwd) }
            case .toolBefore:
                try checkpoint(row, event: event)
            case .toolAfter, .toolFailed:
                try diff(row, event: event)
            case .sessionEnd:
                closeSession(row.sessionId)
            case .note:
                break
            }
        }
    }

    /// Roots of every open tool call. Changes inside them belong to the diff,
    /// not to the watcher.
    var openRoots: [String] {
        queue.sync { openCalls.values.flatMap(\.roots) }
    }

    /// Ignores watcher reports for paths Notchd itself is about to change.
    /// - Parameters:
    ///   - paths: The paths.
    ///   - seconds: How long to ignore them.
    func suppress(_ paths: [String], for seconds: TimeInterval = 3) {
        queue.sync {
            let until = Date().addingTimeInterval(seconds)
            for path in paths { suppressedUntil[path] = until }
        }
    }

    /// Records filesystem activity no tool call claimed. Paths under an open
    /// call's roots are left for that call's diff; suppressed and excluded
    /// paths are dropped.
    /// - Parameter paths: Absolute paths the watcher reported.
    func observeExternal(_ paths: [String]) {
        queue.async { [weak self] in self?.recordExternal(paths) }
    }

    /// Warms the cache with the working directory so the first tool call's
    /// checkpoint is fast and unattributed changes have an earlier copy.
    private func baseline(_ cwd: String) {
        guard snapshotter.limits.isReasonableRoot(cwd) else { return }
        do {
            let result = try snapshotter.snapshot(roots: [cwd])
            log.notice("baseline of \(cwd, privacy: .public): \(result.manifest.entries.count) files")
        } catch {
            log.error("baseline of \(cwd, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Snapshots the declared paths and remembers the call as open.
    private func checkpoint(_ row: EventRow, event: NotchdEvent) throws {
        let roots = Snapshotter.normalized(event.paths).filter { snapshotter.limits.isReasonableRoot($0) || FileStat.of($0)?.kind == .regular }
        guard !roots.isEmpty else { return }
        let started = Date()
        let result = try snapshotter.snapshot(roots: roots)
        let manifestHash = try store.put(result.manifest)
        let duration = Date().timeIntervalSince(started)
        let checkpointId = try ledger.recordCheckpoint(
            eventId: row.id, sessionId: row.sessionId, toolUseId: event.toolUseId, roots: roots, manifestHash: manifestHash,
            result: result, late: duration > hookBudget, durationMs: Int(duration * 1000), createdAt: started
        )
        let key = Self.key(sessionId: row.sessionId, toolUseId: event.toolUseId)
        openCalls[key] = OpenCall(checkpointId: checkpointId, eventId: row.id, roots: roots, manifest: result.manifest,
                                  startedAt: event.ts, derived: event.fidelity == .derived)
        openCallOrder[row.sessionId, default: []].append(key)
        onRootsChanged?()
    }

    /// Snapshots the same roots again and records what differs. For a call
    /// learned from a transcript, changes the watcher already filed as
    /// nobody's inside the call's span are claimed for it instead, because
    /// the checkpoint may have been taken after they happened.
    private func diff(_ row: EventRow, event: NotchdEvent) throws {
        guard let open = takeOpenCall(sessionId: row.sessionId, toolUseId: event.toolUseId) else {
            try recordAfterOnly(row, event: event)
            return
        }
        let result = try snapshotter.snapshot(roots: open.roots)
        var claimedPaths = Set<String>()
        if open.derived {
            let candidates = try ledger.unattributedChanges(since: open.startedAt.addingTimeInterval(-Self.derivedClaimSlack),
                                                             until: max(event.ts, Date()).addingTimeInterval(1))
                .filter { change in open.roots.contains { change.path == $0 || change.path.hasPrefix($0 + "/") } }
            try ledger.attribute(changeIds: candidates.map(\.id), to: row.id, sessionId: row.sessionId)
            claimedPaths = Set(candidates.map(\.path))
        }
        let changes = ManifestDiff.changes(from: open.manifest, to: result.manifest)
            .filter { !claimedPaths.contains($0.path) }
            .map { change in
                NewChange(eventId: row.id, sessionId: row.sessionId, path: change.path, kind: change.kind,
                          before: change.before, after: change.after, attributed: true, ts: event.ts)
            }
        try ledger.recordChanges(changes)
        onRootsChanged?()
    }

    /// Finds the open call for an after-event, falling back to the session's
    /// most recent open call when the vendor gave no tool call id, and to the
    /// ledger when the before-event was recorded by a previous run.
    private func takeOpenCall(sessionId: Int64, toolUseId: String?) -> OpenCall? {
        let key = Self.key(sessionId: sessionId, toolUseId: toolUseId)
        if let open = openCalls.removeValue(forKey: key) {
            openCallOrder[sessionId]?.removeAll { $0 == key }
            return open
        }
        if toolUseId == nil, let last = openCallOrder[sessionId]?.popLast(), let open = openCalls.removeValue(forKey: last) {
            return open
        }
        guard let toolUseId, let stored = try? ledger.checkpoint(sessionId: sessionId, toolUseId: toolUseId),
              let manifest = try? store.manifest(stored.manifestHash) else { return nil }
        let derived = (try? ledger.session(id: sessionId))?.fidelity == .derived
        return OpenCall(checkpointId: stored.id, eventId: stored.eventId ?? 0, roots: stored.roots, manifest: manifest,
                        startedAt: stored.createdAt, derived: derived)
    }

    /// Drops any calls a finished session left open.
    private func closeSession(_ sessionId: Int64) {
        for key in openCallOrder[sessionId] ?? [] { openCalls.removeValue(forKey: key) }
        openCallOrder.removeValue(forKey: sessionId)
        onRootsChanged?()
    }

    /// A tool call that only ever reports after it ran, such as Cursor's file
    /// edits, declares the files it touched with no checkpoint to diff
    /// against. Each declared file is compared with the last copy the cache
    /// holds and recorded as the call's change, attributed to it. A file
    /// never seen before has no earlier copy, and a revert says so.
    private func recordAfterOnly(_ row: EventRow, event: NotchdEvent) throws {
        guard event.kind == .toolAfter, !event.paths.isEmpty else { return }
        let changes = event.paths
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { FileStat.of($0)?.kind != .directory }
            .compactMap { classify($0, at: event.ts, eventId: row.id, sessionId: row.sessionId) }
        try ledger.recordChanges(changes)
    }

    /// Records watcher reports as unattributed changes. Paths inside an open
    /// hook-recorded call are left to that call's diff; paths inside an open
    /// transcript-derived call are recorded anyway, because its checkpoint
    /// may already be too late to see them, and its after-event claims them.
    private func recordExternal(_ paths: [String]) {
        let now = Date()
        let roots = openCalls.values.filter { !$0.derived }.flatMap(\.roots)
        let candidates = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }).filter { path in
            !roots.contains { path == $0 || path.hasPrefix($0 + "/") }
                && !snapshotter.limits.isExcluded(path)
                && (suppressedUntil[path] ?? .distantPast) < now
        }
        suppressedUntil = suppressedUntil.filter { $0.value >= now }
        var changes: [NewChange] = []
        for path in candidates.sorted() {
            if let change = classify(path, at: now, eventId: nil, sessionId: nil) { changes.append(change) }
        }
        do {
            try ledger.recordChanges(changes)
        } catch {
            log.error("could not record unattributed changes: \(String(describing: error), privacy: .public)")
        }
    }

    /// Compares a path's current state with the last one seen, as a change
    /// belonging to a tool call or to nobody.
    private func classify(_ path: String, at now: Date, eventId: Int64?, sessionId: Int64?) -> NewChange? {
        let attributed = eventId != nil
        let before = snapshotter.cache.lastKnown(path)
        guard let status = FileStat.of(path), status.kind == .regular || status.kind == .symlink else {
            guard before != nil else { return nil }
            snapshotter.cache.forget(path)
            return NewChange(eventId: eventId, sessionId: sessionId, path: path, kind: .delete, before: before, after: nil, attributed: attributed, ts: now)
        }
        var skipped = 0
        var objects = 0
        var bytes: Int64 = 0
        guard let after = try? snapshotter.capture(path, status: status, skippedLarge: &skipped, newObjects: &objects, bytesRead: &bytes) else { return nil }
        if let before, before == after { return nil }
        return NewChange(eventId: eventId, sessionId: sessionId, path: path, kind: before == nil ? .create : .modify,
                         before: before, after: after, attributed: attributed, ts: now)
    }

    /// The map key for a tool call.
    private static func key(sessionId: Int64, toolUseId: String?) -> String {
        "\(sessionId)|\(toolUseId ?? "")"
    }
}
