// TurnCompletionTests.swift
// A finished turn is recognised from each vendor's own marker, summarised
// from the last prompt to the marker, and judged worth noticing only when it
// ran tools or changed files. The notch's peek geometry fits inside the panel
// and clears itself.

import XCTest
@testable import Notchd

final class TurnCompletionTests: XCTestCase {
    private var ledger: Ledger!
    private let t0 = Date(timeIntervalSince1970: 1_757_400_000)

    override func setUpWithError() throws {
        ledger = try Ledger(path: ":memory:")
    }

    @discardableResult
    private func record(_ kind: NotchdEvent.Kind, at offset: TimeInterval, tool: String? = nil, event marker: String? = nil,
                        session: String = "s", vendor: String = "claude") throws -> EventRow {
        try ledger.record(NotchdEvent(kind: kind, vendor: vendor, session: session, cwd: "/Users/me/proj", tool: tool,
                                      toolUseId: tool == nil ? nil : "t\(Int(offset))", meta: marker.map { .object(["event": .string($0)]) },
                                      ts: t0.addingTimeInterval(offset), fidelity: .official))
    }

    /// Every vendor's done marker, and a session end, count; prompts and
    /// tool calls do not.
    func testDoneMarkers() throws {
        for marker in ["Stop", "task_complete", "session.idle", "AfterAgent", "stop"] {
            XCTAssertTrue(TurnCompletion.isDone(try record(.note, at: 1, event: marker)), marker)
        }
        XCTAssertTrue(TurnCompletion.isDone(try record(.sessionEnd, at: 2)))
        XCTAssertFalse(TurnCompletion.isDone(try record(.note, at: 3, event: "UserPromptSubmit")))
        XCTAssertFalse(TurnCompletion.isDone(try record(.toolAfter, at: 4, tool: "Bash")))
    }

    /// The summary spans from the last prompt to the marker: its tool calls,
    /// its changes, its duration. An earlier turn's work is not counted.
    func testSummaryCoversOnlyTheTurn() throws {
        try record(.sessionStart, at: 0)
        try record(.note, at: 1, event: "UserPromptSubmit")
        let earlier = try record(.toolAfter, at: 5, tool: "Edit")
        let entry = ManifestEntry(hash: "h", mode: 0o644, size: 1, isSymlink: false)
        try ledger.recordChanges([NewChange(eventId: earlier.id, sessionId: earlier.sessionId, path: "/Users/me/proj/old.txt", kind: .modify,
                                            before: entry, after: entry, attributed: true, ts: earlier.ts)])
        try record(.note, at: 6, event: "Stop")
        try record(.note, at: 60, event: "UserPromptSubmit")
        let call = try record(.toolAfter, at: 90, tool: "Bash")
        try ledger.recordChanges([
            NewChange(eventId: call.id, sessionId: call.sessionId, path: "/Users/me/proj/a.txt", kind: .create, before: nil, after: entry, attributed: true, ts: call.ts),
            NewChange(eventId: call.id, sessionId: call.sessionId, path: "/Users/me/proj/b.txt", kind: .delete, before: entry, after: nil, attributed: true, ts: call.ts),
        ])
        try record(.toolAfter, at: 95, tool: "Read")
        let done = try record(.note, at: 99, event: "Stop")
        let summary = try XCTUnwrap(TurnCompletion.summary(for: done, in: ledger))
        XCTAssertEqual(summary.project, "proj")
        XCTAssertEqual(summary.vendor, "claude")
        XCTAssertEqual(summary.created, 1)
        XCTAssertEqual(summary.modified, 0)
        XCTAssertEqual(summary.deleted, 1)
        XCTAssertEqual(summary.toolCalls, 2)
        XCTAssertEqual(summary.duration, 39, accuracy: 0.001)
        XCTAssertTrue(summary.isWorthNoticing)
        XCTAssertEqual(summary.title, "proj done")
        XCTAssertEqual(summary.marks, "+1 -1")
        XCTAssertEqual(summary.sentence, "1 created, 1 deleted, 2 tool calls, 39 s")
    }

    /// A reply with no tools and no changes is not worth noticing.
    func testChatOnlyTurnIsQuiet() throws {
        try record(.sessionStart, at: 0)
        try record(.note, at: 1, event: "UserPromptSubmit")
        let done = try record(.note, at: 4, event: "Stop")
        let summary = try XCTUnwrap(TurnCompletion.summary(for: done, in: ledger))
        XCTAssertFalse(summary.isWorthNoticing)
        XCTAssertTrue(summary.isChatOnly)
        XCTAssertEqual(summary.title, "proj replied")
        XCTAssertEqual(summary.sentence, "Replied in 3 s")
        XCTAssertEqual(summary.marks, "")
    }

    /// The switch for plain replies defaults to on and persists.
    @MainActor
    func testChatReplyPreference() {
        let suite = "notchd-chat-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let first = Preferences(defaults: defaults)
        XCTAssertTrue(first.noticeChatReplies)
        first.noticeChatReplies = false
        XCTAssertFalse(Preferences(defaults: defaults).noticeChatReplies)
        defaults.removePersistentDomain(forName: suite)
    }

    /// The trackpad tap defaults to on and persists.
    @MainActor
    func testHapticPreference() {
        let suite = "notchd-haptic-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let first = Preferences(defaults: defaults)
        XCTAssertTrue(first.hapticOnDone)
        first.hapticOnDone = false
        XCTAssertFalse(Preferences(defaults: defaults).hapticOnDone)
        defaults.removePersistentDomain(forName: suite)
    }

    /// Each wire vendor maps to its own mark, Codex to OpenAI's, and a third
    /// party to the generic dot. Every mark has at least one loop and every
    /// point sits near the unit box so the shape scales into any frame.
    func testAgentGlyphs() {
        XCTAssertEqual(AgentGlyph.forVendor("claude"), .claude)
        XCTAssertEqual(AgentGlyph.forVendor("codex"), .openai)
        XCTAssertEqual(AgentGlyph.forVendor("gemini"), .gemini)
        XCTAssertEqual(AgentGlyph.forVendor("opencode"), .opencode)
        XCTAssertEqual(AgentGlyph.forVendor("cursor"), .cursor)
        XCTAssertEqual(AgentGlyph.forVendor("my-agent"), .generic)
        for glyph in AgentGlyph.allCases {
            XCTAssertFalse(glyph.outline.isEmpty, glyph.rawValue)
            for loop in glyph.outline {
                XCTAssertGreaterThanOrEqual(loop.count, 3, glyph.rawValue)
                for point in loop {
                    XCTAssertTrue((-0.05...1.05).contains(point.x) && (-0.05...1.05).contains(point.y), "\(glyph.rawValue) \(point)")
                }
            }
            let path = AgentGlyphShape(outline: glyph.outline).path(in: CGRect(x: 0, y: 0, width: 16, height: 16))
            XCTAssertFalse(path.isEmpty, glyph.rawValue)
        }
    }

    /// Codex's task_complete line becomes a done marker.
    func testCodexTaskCompleteIsADoneMarker() {
        var parser = CodexRolloutParser(fallbackSession: "s")
        let line = """
        {"timestamp":"2026-09-09T05:57:30.000Z","type":"event_msg","payload":{"type":"task_complete","thread_id":"s","turn_id":"t"}}
        """
        let events = parser.events(from: Data(line.utf8))
        XCTAssertEqual(events.map(\.kind), [.note])
        XCTAssertEqual(events.first?.meta?["event"]?.stringValue, "task_complete")
        XCTAssertTrue(parser.events(from: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\"}}".utf8)).isEmpty)
    }
}

@MainActor
final class NotchPeekTests: XCTestCase {
    /// A peek is smaller than the open shape on every edge, fits the panel,
    /// gives its text a rect inside the shape, and clears itself.
    func testPeekGeometryAndClearing() async {
        for edge in NotchEdge.allCases {
            let model = NotchViewModel()
            model.edge = edge
            let place = model.placement()
            let resting = model.notchRect(place)
            model.celebrate(NotchCelebration(sessionId: 1, vendor: "claude", title: "proj done", detail: "+1"))
            XCTAssertTrue(model.isPeeking, edge.rawValue)
            let peek = model.notchRect(place)
            XCTAssertLessThanOrEqual(model.peekLength, model.expandedLength, edge.rawValue)
            XCTAssertLessThanOrEqual(model.peekDepth, model.expandedDepth, edge.rawValue)
            XCTAssertGreaterThan(peek.width * peek.height, resting.width * resting.height, edge.rawValue)
            XCTAssertTrue(CGRect(origin: .zero, size: model.panelSize).contains(peek), edge.rawValue)
            XCTAssertTrue(peek.insetBy(dx: -0.5, dy: -0.5).contains(model.peekContentRect(place)), edge.rawValue)
            model.isExpanded = true
            XCTAssertFalse(model.isPeeking, "opening the notch takes precedence")
        }
        let model = NotchViewModel()
        model.celebrate(NotchCelebration(sessionId: 1, vendor: "codex", title: "proj done", detail: ""))
        try? await Task.sleep(nanoseconds: UInt64((NotchLayout.peekDuration + 0.5) * 1_000_000_000))
        XCTAssertNil(model.celebration)
    }

    /// Dots spread along the pill, centred, capped at three.
    func testRestingDots() {
        let model = NotchViewModel()
        let place = model.placement()
        XCTAssertEqual(model.restingDotPoints(count: 0, place), [])
        let one = model.restingDotPoints(count: 1, place)
        let pill = model.notchRect(place)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one[0].x, pill.midX, accuracy: 0.5)
        XCTAssertEqual(one[0].y, pill.midY, accuracy: 0.5)
        let many = model.restingDotPoints(count: 7, place)
        XCTAssertEqual(many.count, NotchLayout.maximumRestingDots)
        XCTAssertEqual(many[1].y, pill.midY, accuracy: 0.5)
        XCTAssertEqual(many[2].y - many[0].y, 2 * NotchLayout.restingDotGap, accuracy: 0.001)
    }
}
