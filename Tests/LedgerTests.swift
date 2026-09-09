// LedgerTests.swift
// The ledger is append-only: recording never rewrites an existing event, a
// session is created on first sight and only gains an end time, and the counts
// the menu bar shows come from what was recorded.

import XCTest
@testable import Notchd

final class LedgerTests: XCTestCase {
    private var ledger: Ledger!
    private let t0 = Date(timeIntervalSince1970: 1_757_400_000)

    override func setUpWithError() throws {
        ledger = try Ledger(path: ":memory:")
    }

    /// A tool event for the fixture session at an offset from t0.
    private func event(_ kind: NotchdEvent.Kind, at offset: TimeInterval, tool: String? = "Bash",
                       session: String = "s1", vendor: String = "claude", pid: Int32? = nil) -> NotchdEvent {
        NotchdEvent(kind: kind, vendor: vendor, session: session, pid: pid, cwd: "/Users/me/proj", tool: tool,
                    toolUseId: "t\(Int(offset))", args: .object(["command": .string("ls")]), result: nil, error: nil,
                    paths: ["/Users/me/proj"], meta: nil, ts: t0.addingTimeInterval(offset), fidelity: .official)
    }

    /// The first event creates the session with the event's time and cwd.
    func testFirstEventCreatesTheSession() throws {
        let row = try ledger.record(event(.sessionStart, at: 0, tool: nil))
        let sessions = try ledger.sessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, row.sessionId)
        XCTAssertEqual(sessions[0].vendor, "claude")
        XCTAssertEqual(sessions[0].vendorSessionId, "s1")
        XCTAssertEqual(sessions[0].cwd, "/Users/me/proj")
        XCTAssertEqual(sessions[0].startedAt, t0)
        XCTAssertNil(sessions[0].endedAt)
        XCTAssertEqual(sessions[0].projectName, "proj")
    }

    /// Later events join the same session and advance its activity time.
    func testLaterEventsJoinTheSession() throws {
        try ledger.record(event(.sessionStart, at: 0, tool: nil))
        try ledger.record(event(.toolBefore, at: 5))
        try ledger.record(event(.toolAfter, at: 6))
        let sessions = try ledger.sessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].lastEventAt, t0.addingTimeInterval(6))
        let events = try ledger.events(sessionId: sessions[0].id)
        XCTAssertEqual(events.map(\.kind), [.sessionStart, .toolBefore, .toolAfter])
        XCTAssertEqual(events[1].args?["command"]?.stringValue, "ls")
        XCTAssertEqual(events[1].paths, ["/Users/me/proj"])
    }

    /// Recording more events leaves earlier rows exactly as they were.
    func testEarlierRowsNeverChange() throws {
        let first = try ledger.record(event(.toolBefore, at: 1))
        let before = try ledger.events(sessionId: first.sessionId)
        try ledger.record(event(.toolAfter, at: 2))
        try ledger.record(event(.sessionEnd, at: 3, tool: nil))
        let after = try ledger.events(sessionId: first.sessionId)
        XCTAssertEqual(Array(after.prefix(before.count)), before)
        XCTAssertTrue(zip(after, after.dropFirst()).allSatisfy { $0.id < $1.id })
    }

    /// A session end sets the end time and makes the session inactive.
    func testSessionEndClosesTheSession() throws {
        try ledger.record(event(.sessionStart, at: 0, tool: nil))
        try ledger.record(event(.sessionEnd, at: 60, tool: nil))
        let session = try XCTUnwrap(ledger.sessions().first)
        XCTAssertEqual(session.endedAt, t0.addingTimeInterval(60))
        XCTAssertFalse(session.isActive(at: t0.addingTimeInterval(61)))
    }

    /// Activity is a function of silence, not just of an end event.
    func testActivityWindow() throws {
        try ledger.record(event(.toolAfter, at: 0))
        let session = try XCTUnwrap(ledger.sessions().first)
        XCTAssertTrue(session.isActive(at: t0.addingTimeInterval(10 * 60)))
        XCTAssertFalse(session.isActive(at: t0.addingTimeInterval(31 * 60)))
    }

    /// Different vendors with the same session id are different sessions.
    func testSessionsAreScopedByVendor() throws {
        try ledger.record(event(.toolAfter, at: 0, vendor: "claude"))
        try ledger.record(event(.toolAfter, at: 1, vendor: "notchd"))
        XCTAssertEqual(try ledger.sessions().count, 2)
    }

    /// The pid is kept when a vendor reports one, and not overwritten.
    func testPidIsRecordedOnce() throws {
        try ledger.record(event(.toolAfter, at: 0))
        try ledger.record(event(.toolAfter, at: 1, pid: 4242))
        try ledger.record(event(.toolAfter, at: 2, pid: 9999))
        XCTAssertEqual(try ledger.sessions().first?.pid, 4242)
    }

    /// Counts: active sessions within thirty minutes, attributed changes
    /// within the hour.
    func testCounts() throws {
        let row = try ledger.record(event(.toolAfter, at: 1))
        try ledger.record(event(.toolAfter, at: -2 * 60 * 60, session: "old"))
        let entry = ManifestEntry(hash: "h", mode: 0o644, size: 1, isSymlink: false)
        try ledger.recordChanges([
            NewChange(eventId: row.id, sessionId: row.sessionId, path: "/p/a", kind: .modify, before: entry, after: entry, attributed: true, ts: t0.addingTimeInterval(1)),
            NewChange(eventId: row.id, sessionId: row.sessionId, path: "/p/b", kind: .create, before: nil, after: entry, attributed: true, ts: t0.addingTimeInterval(1)),
            NewChange(eventId: nil, sessionId: nil, path: "/p/c", kind: .modify, before: nil, after: entry, attributed: false, ts: t0.addingTimeInterval(2)),
            NewChange(eventId: row.id, sessionId: row.sessionId, path: "/p/d", kind: .delete, before: entry, after: nil, attributed: true, ts: t0.addingTimeInterval(-3 * 60 * 60)),
        ])
        let counts = try ledger.counts(now: t0.addingTimeInterval(10))
        XCTAssertEqual(counts, LedgerCounts(activeSessions: 1, recentChanges: 2))
    }

    /// Checkpoints, changes, and reverts round trip with their fields intact,
    /// and change queries honour range, session, and attribution filters.
    func testCheckpointsChangesAndReverts() throws {
        let before = try ledger.record(event(.toolBefore, at: 0))
        let after = try ledger.record(event(.toolAfter, at: 1))
        let entry = ManifestEntry(hash: "abc", mode: 0o755, size: 12, isSymlink: true)
        let result = SnapshotResult(manifest: Manifest(entries: ["/p/x": entry]), truncated: true, skippedLarge: 1, newObjects: 1, bytesRead: 12)
        let checkpointId = try ledger.recordCheckpoint(eventId: before.id, sessionId: before.sessionId, toolUseId: "t0", roots: ["/p"],
                                                       manifestHash: "m1", result: result, late: true, durationMs: 42, createdAt: t0)
        let stored = try XCTUnwrap(ledger.checkpoint(sessionId: before.sessionId, toolUseId: "t0"))
        XCTAssertEqual(stored.id, checkpointId)
        XCTAssertEqual(stored.roots, ["/p"])
        XCTAssertEqual(stored.manifestHash, "m1")
        XCTAssertTrue(stored.truncated)
        XCTAssertTrue(stored.late)
        XCTAssertEqual(stored.durationMs, 42)
        XCTAssertEqual(stored.objectCount, 1)
        XCTAssertEqual(try ledger.checkpoint(eventId: before.id)?.id, checkpointId)

        let ids = try ledger.recordChanges([
            NewChange(eventId: after.id, sessionId: after.sessionId, path: "/p/x", kind: .modify, before: entry, after: nil, attributed: true, ts: t0.addingTimeInterval(1)),
            NewChange(eventId: nil, sessionId: nil, path: "/p/y", kind: .create, before: nil, after: entry, attributed: false, ts: t0.addingTimeInterval(2)),
        ])
        XCTAssertEqual(ids.count, 2)
        let byEvent = try ledger.changes(eventId: after.id)
        XCTAssertEqual(byEvent.count, 1)
        XCTAssertEqual(byEvent[0].before, entry)
        XCTAssertNil(byEvent[0].after)
        XCTAssertEqual(try ledger.changes(since: t0).map(\.path), ["/p/x"])
        XCTAssertEqual(try ledger.changes(since: t0, includeUnattributed: true).map(\.path), ["/p/x", "/p/y"])
        XCTAssertEqual(try ledger.changes(since: t0, sessionIds: [after.sessionId + 99]).count, 0)
        XCTAssertEqual(try ledger.changes(since: t0.addingTimeInterval(1.5), includeUnattributed: true).map(\.path), ["/p/y"])
        XCTAssertEqual(try ledger.changesByEvent(sessionId: after.sessionId)[after.id]?.count, 1)
        XCTAssertEqual(try ledger.unattributedChanges().map(\.path), ["/p/y"])

        let revertId = try ledger.recordRevert(eventId: after.id, scope: .object(["since": .string("x")]), result: .partial, note: "/p/x: missing", createdAt: t0)
        let revert = try XCTUnwrap(ledger.reverts().first)
        XCTAssertEqual(revert.id, revertId)
        XCTAssertEqual(revert.result, .partial)
        XCTAssertEqual(revert.note, "/p/x: missing")
        XCTAssertEqual(revert.scope["since"]?.stringValue, "x")
    }

    /// Events across sessions since an instant, newest first.
    func testRecentEventsAcrossSessions() throws {
        try ledger.record(event(.toolAfter, at: 0, session: "a"))
        try ledger.record(event(.toolAfter, at: 10, session: "b"))
        try ledger.record(event(.toolAfter, at: -100, session: "c"))
        let recent = try ledger.events(since: t0)
        XCTAssertEqual(recent.map(\.ts), [t0.addingTimeInterval(10), t0])
    }
}
