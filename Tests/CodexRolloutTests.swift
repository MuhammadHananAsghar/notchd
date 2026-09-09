// CodexRolloutTests.swift
// The Codex parser is checked against lines in the exact shape Codex 0.145
// writes on this machine, and the tailer against a directory it appends to:
// a file seen for the first time is adopted at its end, new lines become
// events, partial lines wait for their newline, and old files are ignored.

import XCTest
@testable import Notchd

final class CodexRolloutParserTests: XCTestCase {
    private let meta = """
    {"timestamp":"2026-07-28T03:37:41.062Z","ordinal":0,"type":"session_meta","payload":{"session_id":"019fa6cc-b3bb-7aa0-b00b-c3eeb9f72b6c","id":"019fa6cc-b3bb-7aa0-b00b-c3eeb9f72b6c","timestamp":"2026-07-28T03:37:41.062Z","cwd":"/Users/me/tevta-chat","originator":"Codex Desktop","cli_version":"0.145.0-alpha.30","source":"vscode","model_provider":"openai"}}
    """
    private let turn = """
    {"timestamp":"2026-07-28T03:37:49.175Z","ordinal":7,"type":"turn_context","payload":{"turn_id":"t1","cwd":"/Users/me/other","workspace_roots":["/Users/me/other"]}}
    """
    private let execCall = """
    {"timestamp":"2026-07-28T03:37:58.429Z","ordinal":16,"type":"response_item","payload":{"type":"function_call","id":"fc_1","name":"exec_command","arguments":"{\\"cmd\\":\\"rm -rf build\\",\\"workdir\\":\\"/Users/me/tevta-chat\\",\\"yield_time_ms\\":10000}","call_id":"call_A"}}
    """
    private let execOutput = """
    {"timestamp":"2026-07-28T03:38:01.003Z","ordinal":17,"type":"response_item","payload":{"type":"function_call_output","id":"fco_1","call_id":"call_A","output":"done"}}
    """
    private let patchCall = """
    {"timestamp":"2026-07-28T03:41:49.673Z","ordinal":160,"type":"response_item","payload":{"type":"custom_tool_call","id":"ctc_1","status":"completed","call_id":"call_B","name":"apply_patch","input":"*** Begin Patch\\n*** Update File: docs/plan.md\\n@@\\n-old\\n+new\\n*** Add File: /Users/me/tevta-chat/src/new.py\\n+print(1)\\n*** Delete File: gone.txt\\n*** End Patch"}}
    """
    private let patchOutput = """
    {"timestamp":"2026-07-28T03:41:49.704Z","ordinal":162,"type":"response_item","payload":{"type":"custom_tool_call_output","id":"ctco_1","call_id":"call_B","output":"Exit code: 0\\nSuccess."}}
    """

    private func parse(_ lines: [String]) -> [NotchdEvent] {
        var parser = CodexRolloutParser(fallbackSession: "fallback")
        return lines.flatMap { parser.events(from: Data($0.utf8)) }
    }

    /// session_meta is the session start and sets the id and cwd.
    func testSessionMeta() throws {
        let event = try XCTUnwrap(parse([meta]).first)
        XCTAssertEqual(event.kind, .sessionStart)
        XCTAssertEqual(event.vendor, "codex")
        XCTAssertEqual(event.session, "019fa6cc-b3bb-7aa0-b00b-c3eeb9f72b6c")
        XCTAssertEqual(event.cwd, "/Users/me/tevta-chat")
        XCTAssertEqual(event.fidelity, .derived)
        XCTAssertEqual(event.meta?["originator"]?.stringValue, "Codex Desktop")
        XCTAssertEqual(NotchdProtocol.string(from: event.ts), "2026-07-28T03:37:41.062Z")
    }

    /// A shell call and its output pair by call id, with the workdir declared
    /// and the arguments parsed out of their JSON string.
    func testShellCallAndOutput() {
        let events = parse([meta, execCall, execOutput])
        XCTAssertEqual(events.map(\.kind), [.sessionStart, .toolBefore, .toolAfter])
        XCTAssertEqual(events[1].tool, "exec_command")
        XCTAssertEqual(events[1].toolUseId, "call_A")
        XCTAssertEqual(events[1].args?["cmd"]?.stringValue, "rm -rf build")
        XCTAssertEqual(events[1].paths, ["/Users/me/tevta-chat"])
        XCTAssertEqual(events[2].tool, "exec_command")
        XCTAssertEqual(events[2].toolUseId, "call_A")
        XCTAssertEqual(events[2].result?["output"]?.stringValue, "done")
    }

    /// apply_patch declares every file its headers name, relative ones
    /// resolved against the cwd.
    func testPatchDeclaresItsFiles() {
        let events = parse([meta, patchCall, patchOutput])
        XCTAssertEqual(events[1].tool, "apply_patch")
        XCTAssertEqual(events[1].paths, ["/Users/me/tevta-chat/docs/plan.md", "/Users/me/tevta-chat/src/new.py", "/Users/me/tevta-chat/gone.txt"])
        XCTAssertEqual(events[2].kind, .toolAfter)
        XCTAssertEqual(events[2].tool, "apply_patch")
    }

    /// An exec call's JavaScript yields the commands it runs, its workdir,
    /// and a one-line command for the timeline.
    func testExecScriptCommands() {
        let script = """
        const r = await tools.exec_command({"cmd":"git status --short && sed -n '1,20p' a.py","workdir":"/Users/me/tevta-chat","yield_time_ms":10000});\\ntext(r.output);\\n
        """
        let line = """
        {"timestamp":"2026-09-09T05:57:15.000Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"call_x","name":"exec","input":\(String(decoding: try! JSONEncoder().encode(script), as: UTF8.self))}}
        """
        let events = parse([meta, line])
        XCTAssertEqual(events[1].tool, "exec")
        XCTAssertEqual(events[1].args?["command"]?.stringValue, "git status --short && sed -n '1,20p' a.py")
        XCTAssertEqual(events[1].args?["workdir"]?.stringValue, "/Users/me/tevta-chat")
        XCTAssertEqual(events[1].paths, ["/Users/me/tevta-chat"])
    }

    /// An exec call carrying a patch as a string literal declares the files
    /// the patch names, and the timeline line names them too.
    func testExecScriptPatch() {
        let patch = "*** Begin Patch\n*** Update File: /Users/me/tevta-chat/backend/app/api/chat.py\n@@\n+    # note\n*** Update File: backend/app/services/retrieval.py\n@@\n+    # note\n*** End Patch"
        let literal = String(decoding: try! JSONEncoder().encode(patch), as: UTF8.self)
        let script = "const patch = \(literal);\nconst r = await tools.apply_patch({patch});\ntext(r.output);\n"
        let line = """
        {"timestamp":"2026-09-09T05:57:15.000Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"call_p","name":"exec","input":\(String(decoding: try! JSONEncoder().encode(script), as: UTF8.self))}}
        """
        let events = parse([meta, line])
        XCTAssertEqual(events[1].paths, ["/Users/me/tevta-chat/backend/app/api/chat.py", "/Users/me/tevta-chat/backend/app/services/retrieval.py"])
        XCTAssertEqual(events[1].args?["command"]?.stringValue, "apply_patch chat.py, retrieval.py")
        XCTAssertEqual(CodexExecScript.patches(in: script).count, 1)
    }

    /// turn_context moves the cwd for later calls.
    func testTurnContextMovesTheCwd() {
        let events = parse([meta, turn, execCall.replacingOccurrences(of: ",\\\"workdir\\\":\\\"/Users/me/tevta-chat\\\"", with: "")])
        XCTAssertEqual(events[1].cwd, "/Users/me/other")
        XCTAssertEqual(events[1].paths, ["/Users/me/other"])
    }

    /// Without session_meta the file name supplies the session id.
    func testFileNameSessionId() {
        XCTAssertEqual(CodexRolloutParser.sessionId(fromFileName: "rollout-2026-07-28T08-37-41-019fa6cc-b3bb-7aa0-b00b-c3eeb9f72b6c.jsonl"),
                       "019fa6cc-b3bb-7aa0-b00b-c3eeb9f72b6c")
        XCTAssertEqual(CodexRolloutParser.sessionId(fromFileName: "odd.jsonl"), "odd")
        let events = parse([execCall])
        XCTAssertEqual(events.first?.session, "fallback")
        XCTAssertEqual(events.first?.cwd, "/")
    }

    /// A user message becomes a prompt note; the instruction blocks the app
    /// injects under the user role, which begin with a tag, do not.
    func testUserMessagesBecomePromptNotes() {
        let prompt = """
        {"timestamp":"2026-09-09T05:50:29.015Z","ordinal":8,"type":"response_item","payload":{"type":"message","id":"msg_1","role":"user","content":[{"type":"input_text","text":"hi\\n"}]}}
        """
        let injected = """
        {"timestamp":"2026-09-09T05:50:28.000Z","ordinal":7,"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<recommended_plugins>\\nHere is a list"}]}}
        """
        let assistant = """
        {"timestamp":"2026-09-09T05:50:30.000Z","ordinal":9,"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hi!"}]}}
        """
        let events = parse([meta, injected, prompt, assistant])
        XCTAssertEqual(events.map(\.kind), [.sessionStart, .note])
        XCTAssertEqual(events[1].meta?["event"]?.stringValue, "UserPromptSubmit")
        XCTAssertEqual(events[1].meta?["prompt"]?.stringValue, "hi")
    }

    /// Lines that are not JSON, or not modelled, produce nothing.
    func testNoiseIsIgnored() {
        XCTAssertTrue(parse(["not json", "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\"}}"]).isEmpty)
    }
}

final class CodexRolloutTailerTests: XCTestCase {
    private var root: URL!
    private var dayDir: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notchd-codex-\(UUID().uuidString)")
        let day = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        dayDir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", day.year!, day.month!, day.day!), isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private let meta = """
    {"timestamp":"2026-07-28T03:37:41.062Z","type":"session_meta","payload":{"session_id":"s-tail","cwd":"/Users/me/proj"}}
    """
    private let call = """
    {"timestamp":"2026-07-28T03:37:58.429Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"ls\\"}","call_id":"c1"}}
    """

    /// Makes a file look created long ago, so the tailer treats it as an
    /// existing session rather than a new one.
    private func age(_ file: URL) throws {
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: file.path)
    }

    /// A file created while Notchd is watching is read from the start, so a
    /// thread that is only chat so far still appears with its prompt.
    func testNewFilesAreReadFromTheStart() throws {
        let file = dayDir.appendingPathComponent("rollout-2026-09-09T10-50-24-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl")
        let prompt = """
        {"timestamp":"2026-09-09T05:50:29.015Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi\\n"}]}}
        """
        try Data((meta + "\n" + prompt + "\n").utf8).write(to: file)
        var received: [NotchdEvent] = []
        let tailer = CodexRolloutTailer(root: root, interval: 60, recentWindow: 3600) { received += $0 }
        tailer.poll()
        XCTAssertEqual(received.map(\.kind), [.sessionStart, .note])
        XCTAssertEqual(received.first?.session, "s-tail")
        XCTAssertEqual(received.last?.meta?["prompt"]?.stringValue, "hi")
        tailer.poll()
        XCTAssertEqual(received.count, 2, "nothing is read twice")
    }

    /// An existing file is adopted at its end and yields nothing old; lines
    /// appended after that become events; a partial line waits for its
    /// newline.
    func testFollowsAppendedLines() throws {
        let file = dayDir.appendingPathComponent("rollout-2026-07-28T08-37-41-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl")
        try Data((meta + "\n" + call + "\n").utf8).write(to: file)
        try age(file)
        var received: [NotchdEvent] = []
        let lock = NSLock()
        let tailer = CodexRolloutTailer(root: root, interval: 60, recentWindow: 3600) { events in
            lock.lock()
            received += events
            lock.unlock()
        }
        tailer.poll()
        XCTAssertTrue(received.isEmpty, "history before adoption is not replayed")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((call.replacingOccurrences(of: "c1", with: "c2") + "\n{\"timestamp\":\"2026-07-28T03:38:00.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"c2\",\"out").utf8))
        try handle.close()
        tailer.poll()
        XCTAssertEqual(received.map(\.kind), [.toolBefore])
        XCTAssertEqual(received.first?.session, "s-tail", "the session came from the first line read at adoption")
        XCTAssertEqual(received.first?.cwd, "/Users/me/proj")
        XCTAssertEqual(received.first?.toolUseId, "c2")
        let more = try FileHandle(forWritingTo: file)
        try more.seekToEnd()
        try more.write(contentsOf: Data("put\":\"ok\"}}\n".utf8))
        try more.close()
        tailer.poll()
        XCTAssertEqual(received.map(\.kind), [.toolBefore, .toolAfter])
        XCTAssertEqual(received.last?.result?["output"]?.stringValue, "ok")
    }

    /// Files outside the recent window are not followed.
    func testIgnoresStaleFiles() throws {
        let file = dayDir.appendingPathComponent("rollout-old-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl")
        try Data((meta + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: file.path)
        var count = 0
        let tailer = CodexRolloutTailer(root: root, interval: 60, recentWindow: 3600) { count += $0.count }
        tailer.poll()
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((call + "\n").utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: file.path)
        tailer.poll()
        XCTAssertEqual(count, 0)
    }

    /// A missing directory is reported as unavailable, not an error.
    func testAvailability() {
        XCTAssertTrue(CodexRolloutTailer(root: root) { _ in }.isAvailable)
        XCTAssertFalse(CodexRolloutTailer(root: root.appendingPathComponent("nope")) { _ in }.isAvailable)
    }
}
