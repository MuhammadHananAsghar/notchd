// GuardPolicy.swift
// The rules of guard mode, kept in one JSON file beside the ledger and
// evaluated on every tool.before that arrives through a hook. Off by default:
// a fresh install records and never refuses. A transcript-derived call cannot
// be refused, because the call has already run by the time Notchd hears of
// it, so derived events are never evaluated.

import Foundation

/// The outcome of evaluating a call.
enum HookDecision: Equatable {
    case allow
    case ask(String)
    case deny(String)

    /// The line the server answers the hook with.
    var line: String {
        switch self {
        case .allow: return "ok\n"
        case .ask(let reason): return "ask " + Self.oneLine(reason) + "\n"
        case .deny(let reason): return "deny " + Self.oneLine(reason) + "\n"
        }
    }

    /// The decision as the ledger keeps it.
    var meta: JSONValue? {
        switch self {
        case .allow: return nil
        case .ask(let reason): return .object(["decision": .string("ask"), "reason": .string(reason)])
        case .deny(let reason): return .object(["decision": .string("deny"), "reason": .string(reason)])
        }
    }

    /// A reason with its line breaks folded, since the answer is one line.
    private static func oneLine(_ reason: String) -> String {
        reason.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }
}

/// The stored form.
struct GuardDocument: Codable, Equatable {
    var enabled = false
    var rules: [GuardRule] = []
}

/// The rules, with the file they live in. Safe to read from any thread.
final class GuardPolicy {
    /// The file.
    let url: URL
    private var document: GuardDocument
    private let lock = NSLock()

    /// Loads the policy, or starts empty and off when there is no file.
    /// - Parameter url: The JSON file.
    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(GuardDocument.self, from: data) {
            document = stored
        } else {
            document = GuardDocument()
        }
    }

    /// An in-memory policy for tests.
    /// - Parameters:
    ///   - enabled: Whether it is on.
    ///   - rules: The rules.
    convenience init(enabled: Bool, rules: [GuardRule]) {
        self.init(url: URL(fileURLWithPath: "/dev/null"))
        document = GuardDocument(enabled: enabled, rules: rules)
    }

    /// Whether guard mode is on.
    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return document.enabled
    }

    /// The rules.
    var rules: [GuardRule] {
        lock.lock()
        defer { lock.unlock() }
        return document.rules
    }

    /// Replaces the document and writes it.
    /// - Parameter updated: The new document.
    func update(_ updated: GuardDocument) throws {
        lock.lock()
        document = updated
        lock.unlock()
        guard url.path != "/dev/null" else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(updated).write(to: url, options: .atomic)
    }

    /// The current document.
    var current: GuardDocument {
        lock.lock()
        defer { lock.unlock() }
        return document
    }

    /// Evaluates a call. Only hook-recorded `tool.before` events are judged;
    /// deny beats ask when several rules match.
    /// - Parameter event: The event.
    /// - Returns: The decision and the rule behind it.
    func evaluate(_ event: NotchdEvent) -> (decision: HookDecision, rule: GuardRule?) {
        guard event.kind == .toolBefore, event.fidelity == .official else { return (.allow, nil) }
        lock.lock()
        let active = document.enabled ? document.rules : []
        lock.unlock()
        guard !active.isEmpty else { return (.allow, nil) }
        let command = Self.command(of: event)
        let hits = active.filter { $0.matches(paths: event.paths, command: command) }
        if let deny = hits.first(where: { $0.action == .deny }) { return (.deny(deny.reason), deny) }
        if let ask = hits.first(where: { $0.action == .ask }) { return (.ask(ask.reason), ask) }
        return (.allow, nil)
    }

    /// The command line of a shell call, from whichever field the vendor
    /// used.
    /// - Parameter event: The event.
    /// - Returns: The command, or nil for a call without one.
    static func command(of event: NotchdEvent) -> String? {
        for key in ["command", "cmd", "input"] {
            if let value = event.args?[key]?.stringValue { return value }
        }
        return nil
    }
}
