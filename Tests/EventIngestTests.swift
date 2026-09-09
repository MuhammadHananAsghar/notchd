// EventIngestTests.swift
// The pipeline from socket line to ledger must never throw at the caller:
// garbage, unknown vendors, and adapter rejections all become outcomes, and a
// good line lands in the ledger and notifies the app.

import XCTest
@testable import Notchd

final class EventIngestTests: XCTestCase {
    private var ledger: Ledger!

    override func setUpWithError() throws {
        ledger = try Ledger(path: ":memory:")
    }

    /// A Claude Code envelope is normalised, recorded, and reported.
    func testValidClaudeLineIsRecorded() throws {
        var notified: [EventRow] = []
        let ingest = EventIngest(ledger: ledger) { notified = $0 }
        let line = Data("""
        {"v":1,"vendor":"claude","received_at":1757400000,"raw":{"session_id":"s1","transcript_path":"/t","cwd":"/p","hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"ls"}}}
        """.utf8)
        let outcome = ingest.ingest(line)
        guard case .recorded(let ids) = outcome else { return XCTFail("unexpected \(outcome)") }
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(notified.count, 1)
        XCTAssertEqual(notified[0].tool, "Bash")
        XCTAssertEqual(try ledger.sessions().first?.vendorSessionId, "s1")
    }

    /// A native protocol line from a third-party agent is recorded as-is.
    func testNativeLineIsRecorded() throws {
        let ingest = EventIngest(ledger: ledger)
        let line = Data("""
        {"v":1,"vendor":"notchd","received_at":1757400000,"raw":{"kind":"tool.after","vendor":"my-agent","session":"z","cwd":"/w","tool":"write","paths":["/w/a"]}}
        """.utf8)
        guard case .recorded = ingest.ingest(line) else { return XCTFail("not recorded") }
        XCTAssertEqual(try ledger.sessions().first?.vendor, "my-agent")
    }

    /// Already-normalised events are recorded once, and replaying the same
    /// events, as a transcript tailer does after a relaunch, adds nothing.
    func testReplayedEventsAreRecordedOnce() throws {
        let ingest = EventIngest(ledger: ledger)
        let ts = Date(timeIntervalSince1970: 1_757_400_000)
        let events = [
            NotchdEvent(kind: .sessionStart, vendor: "codex", session: "r1", cwd: "/p", ts: ts, fidelity: .derived),
            NotchdEvent(kind: .toolBefore, vendor: "codex", session: "r1", cwd: "/p", tool: "exec_command", toolUseId: "c1", ts: ts.addingTimeInterval(1), fidelity: .derived),
            NotchdEvent(kind: .note, vendor: "codex", session: "r1", cwd: "/p", meta: .object(["prompt": .string("hi")]), ts: ts.addingTimeInterval(2), fidelity: .derived),
        ]
        XCTAssertEqual(ingest.ingest(events: events).count, 3)
        XCTAssertEqual(ingest.ingest(events: events).count, 0)
        let session = try XCTUnwrap(ledger.sessions().first)
        XCTAssertEqual(try ledger.events(sessionId: session.id).count, 3)
        let later = NotchdEvent(kind: .toolAfter, vendor: "codex", session: "r1", cwd: "/p", tool: "exec_command", toolUseId: "c1", ts: ts.addingTimeInterval(3), fidelity: .derived)
        XCTAssertEqual(ingest.ingest(events: [later]).count, 1)
    }

    /// Bytes that are not an envelope are dropped without touching the ledger.
    func testGarbageIsDropped() throws {
        let ingest = EventIngest(ledger: ledger)
        guard case .malformedEnvelope = ingest.ingest(Data("not json".utf8)) else { return XCTFail("accepted garbage") }
        guard case .malformedEnvelope = ingest.ingest(Data()) else { return XCTFail("accepted empty") }
        XCTAssertEqual(try ledger.sessions().count, 0)
    }

    /// An unknown vendor is rejected by name.
    func testUnknownVendorIsRejected() throws {
        let ingest = EventIngest(ledger: ledger)
        let line = Data("""
        {"v":1,"vendor":"codex","received_at":1757400000,"raw":{}}
        """.utf8)
        guard case .rejected(let why) = ingest.ingest(line) else { return XCTFail("accepted unknown vendor") }
        XCTAssertTrue(why.contains("codex"), why)
        XCTAssertEqual(try ledger.sessions().count, 0)
    }

    /// The hook sends `null` when it read nothing; that is rejected, not stored.
    func testEmptyPayloadIsRejected() throws {
        let ingest = EventIngest(ledger: ledger)
        let line = Data("""
        {"v":1,"vendor":"claude","received_at":1757400000,"raw":null}
        """.utf8)
        guard case .rejected = ingest.ingest(line) else { return XCTFail("accepted null payload") }
    }
}
