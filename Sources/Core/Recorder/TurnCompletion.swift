// TurnCompletion.swift
// When an agent has finished a turn, and what it did in it. Each vendor marks
// the end of a turn its own way: Claude Code's Stop hook, Codex's
// task_complete line, OpenCode's session.idle event, Gemini's AfterAgent
// hook, Cursor's stop hook, and any session end. The summary looks back to
// the start of the turn, the last prompt or the session's start, and counts
// the tool calls and the files changed in between.

import Foundation

/// What one finished turn amounted to.
struct TurnSummary: Equatable {
    let sessionId: Int64
    let vendor: String
    let project: String
    let created: Int
    let modified: Int
    let deleted: Int
    let toolCalls: Int
    let duration: TimeInterval

    /// Whether the turn ran tools or changed files.
    var isWorthNoticing: Bool { toolCalls > 0 || changeCount > 0 }

    /// Whether the turn only replied.
    var isChatOnly: Bool { !isWorthNoticing }

    /// Every changed file.
    var changeCount: Int { created + modified + deleted }

    /// The short title for the notch: "proj done" after work, "proj replied"
    /// after a plain reply.
    var title: String {
        isChatOnly ? "\(project) replied" : "\(project) done"
    }

    /// The counts as marks: `+1 ~2 -0` without the zeros.
    var marks: String {
        var parts: [String] = []
        if created > 0 { parts.append("+\(created)") }
        if modified > 0 { parts.append("~\(modified)") }
        if deleted > 0 { parts.append("-\(deleted)") }
        return parts.joined(separator: " ")
    }

    /// The counts in words, for a notification body.
    var sentence: String {
        if isChatOnly { return "Replied in \(DurationText.format(duration))" }
        var parts: [String] = []
        if created > 0 { parts.append("\(created) created") }
        if modified > 0 { parts.append("\(modified) modified") }
        if deleted > 0 { parts.append("\(deleted) deleted") }
        let files = parts.isEmpty ? "no file changes" : parts.joined(separator: ", ")
        let calls = toolCalls == 1 ? "1 tool call" : "\(toolCalls) tool calls"
        return "\(files), \(calls), \(DurationText.format(duration))"
    }
}

/// Recognising and summarising finished turns.
enum TurnCompletion {
    /// The note events that mark the end of a turn, by vendor spelling.
    static let doneMarkers: Set<String> = ["Stop", "task_complete", "session.idle", "AfterAgent", "stop"]

    /// The note events that mark the start of a turn.
    static let promptMarkers: Set<String> = ["UserPromptSubmit", "BeforeAgent", "beforeSubmitPrompt", "user_message"]

    /// Whether an event ends a turn.
    /// - Parameter event: A stored event.
    /// - Returns: True for a done marker or a session end.
    static func isDone(_ event: EventRow) -> Bool {
        if event.kind == .sessionEnd { return true }
        guard event.kind == .note, let marker = event.meta?["event"]?.stringValue else { return false }
        return doneMarkers.contains(marker)
    }

    /// Whether an event starts a turn.
    /// - Parameter event: A stored event.
    /// - Returns: True for a prompt note or a session start.
    static func isTurnStart(_ event: EventRow) -> Bool {
        if event.kind == .sessionStart { return true }
        guard event.kind == .note, let marker = event.meta?["event"]?.stringValue else { return false }
        return promptMarkers.contains(marker)
    }

    /// Summarises the turn a done event closes.
    /// - Parameters:
    ///   - done: The event that ended the turn.
    ///   - ledger: The ledger.
    /// - Returns: The summary, or nil when the session is unknown.
    static func summary(for done: EventRow, in ledger: Ledger) throws -> TurnSummary? {
        guard let session = try ledger.session(id: done.sessionId) else { return nil }
        let events = try ledger.events(sessionId: done.sessionId).filter { $0.ts <= done.ts && $0.id != done.id }
        let previousDone = events.last(where: isDone)
        let start = events.last { isTurnStart($0) && ($0.ts >= (previousDone?.ts ?? .distantPast)) }
        let since = start?.ts ?? previousDone?.ts ?? session.startedAt
        let turnEvents = events.filter { $0.ts >= since }
        let changes = try ledger.changes(since: since, until: done.ts, sessionIds: [done.sessionId])
        return TurnSummary(
            sessionId: done.sessionId, vendor: session.vendor,
            project: session.projectName.isEmpty ? session.cwd : session.projectName,
            created: changes.filter { $0.kind == .create }.count,
            modified: changes.filter { $0.kind == .modify }.count,
            deleted: changes.filter { $0.kind == .delete }.count,
            toolCalls: turnEvents.filter { $0.kind == .toolAfter || $0.kind == .toolFailed }.count,
            duration: max(0, done.ts.timeIntervalSince(since))
        )
    }
}
