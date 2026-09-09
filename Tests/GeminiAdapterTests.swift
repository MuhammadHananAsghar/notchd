// GeminiAdapterTests.swift
// Gemini CLI's hook payloads, in the documented shape, must map to the same
// kinds and paths Claude Code's do, accept Gemini's own tool names, and use
// the payload's timestamp when it has one.

import XCTest
@testable import Notchd

final class GeminiAdapterTests: XCTestCase {
    private let adapter = GeminiAdapter()
    private let received = Date(timeIntervalSince1970: 1_757_400_000)

    private func payload(_ extra: [String: JSONValue]) -> JSONValue {
        var object: [String: JSONValue] = [
            "session_id": .string("g-1"),
            "transcript_path": .string("/Users/me/.gemini/tmp/x/chats/session.json"),
            "cwd": .string("/Users/me/proj"),
        ]
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }

    /// BeforeTool on write_file becomes tool.before with the file declared.
    func testWriteFileBefore() throws {
        let raw = payload([
            "hook_event_name": .string("BeforeTool"), "tool_name": .string("write_file"),
            "tool_input": .object(["file_path": .string("src/a.py"), "content": .string("x")]),
            "timestamp": .string("2025-09-09T06:40:10.000Z"),
        ])
        let event = try XCTUnwrap(adapter.events(from: raw, receivedAt: received).first)
        XCTAssertEqual(event.kind, .toolBefore)
        XCTAssertEqual(event.vendor, "gemini")
        XCTAssertEqual(event.session, "g-1")
        XCTAssertEqual(event.paths, ["/Users/me/proj/src/a.py"])
        XCTAssertEqual(event.ts, Date(timeIntervalSince1970: 1_757_400_010))
        XCTAssertEqual(event.fidelity, .official)
    }

    /// AfterTool on run_shell_command declares the directory it ran in and
    /// keeps a bounded response.
    func testShellAfter() throws {
        let raw = payload([
            "hook_event_name": .string("AfterTool"), "tool_name": .string("run_shell_command"),
            "tool_input": .object(["command": .string("rm -rf build"), "directory": .string("sub")]),
            "tool_response": .object(["output": .string(String(repeating: "z", count: 100_000))]),
        ])
        let event = try XCTUnwrap(adapter.events(from: raw, receivedAt: received).first)
        XCTAssertEqual(event.kind, .toolAfter)
        XCTAssertEqual(event.paths, ["/Users/me/proj/sub"])
        XCTAssertEqual(event.args?["command"]?.stringValue, "rm -rf build")
        XCTAssertEqual(event.result?["output"]?["truncated"]?.boolValue, true)
        XCTAssertEqual(event.ts, received, "no timestamp in the payload falls back to the receipt time")
    }

    /// Claude-style tool names are accepted too, and read-only tools declare
    /// nothing.
    func testToolNameVariantsAndReadOnly() {
        XCTAssertEqual(GeminiToolPaths.paths(tool: "replace", input: .object(["file_path": .string("/abs/x")]), cwd: "/p"), ["/abs/x"])
        XCTAssertEqual(GeminiToolPaths.paths(tool: "Edit", input: .object(["file_path": .string("y")]), cwd: "/p"), ["/p/y"])
        XCTAssertEqual(GeminiToolPaths.paths(tool: "Bash", input: .object([:]), cwd: "/p"), ["/p"])
        XCTAssertEqual(GeminiToolPaths.paths(tool: "read_file", input: .object(["absolute_path": .string("/p/z")]), cwd: "/p"), [])
        XCTAssertEqual(GeminiToolPaths.paths(tool: "glob", input: nil, cwd: "/p"), [])
    }

    /// Session boundaries and unmodelled hooks.
    func testSessionAndNotes() throws {
        let start = try XCTUnwrap(adapter.events(from: payload(["hook_event_name": .string("SessionStart"), "source": .string("startup")]), receivedAt: received).first)
        XCTAssertEqual(start.kind, .sessionStart)
        XCTAssertEqual(start.meta?["source"]?.stringValue, "startup")
        let end = try XCTUnwrap(adapter.events(from: payload(["hook_event_name": .string("SessionEnd")]), receivedAt: received).first)
        XCTAssertEqual(end.kind, .sessionEnd)
        let agent = try XCTUnwrap(adapter.events(from: payload(["hook_event_name": .string("BeforeAgent"), "prompt": .string("hi")]), receivedAt: received).first)
        XCTAssertEqual(agent.kind, .note)
        XCTAssertEqual(agent.meta?["event"]?.stringValue, "BeforeAgent")
    }

    /// Missing fields are named.
    func testMissingFields() {
        XCTAssertThrowsError(try adapter.events(from: .object(["cwd": .string("/")]), receivedAt: received)) { error in
            XCTAssertEqual(error as? AdapterError, .missingField("session_id"))
        }
    }
}
