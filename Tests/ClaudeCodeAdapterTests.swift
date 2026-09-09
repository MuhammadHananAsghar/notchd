// ClaudeCodeAdapterTests.swift
// Fixtures shaped exactly like Claude Code 2.1.266's hook payloads, checked
// against what the adapter must produce: the right kind, the session and cwd
// carried through, the declared paths for file and shell tools, bounded
// results, and the extra fields kept in meta.

import XCTest
@testable import Notchd

final class ClaudeCodeAdapterTests: XCTestCase {
    private let adapter = ClaudeCodeAdapter()
    private let received = Date(timeIntervalSince1970: 1_757_400_000)

    /// Builds a payload with the base fields every hook carries.
    private func payload(_ extra: [String: JSONValue]) -> JSONValue {
        var object: [String: JSONValue] = [
            "session_id": .string("abc-123"),
            "transcript_path": .string("/Users/me/.claude/projects/-Users-me-proj/abc-123.jsonl"),
            "cwd": .string("/Users/me/proj"),
            "permission_mode": .string("default"),
        ]
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }

    /// PreToolUse on Edit becomes tool.before with the file path declared.
    func testEditBeforeDeclaresTheFile() throws {
        let raw = payload([
            "hook_event_name": .string("PreToolUse"), "tool_name": .string("Edit"), "tool_use_id": .string("toolu_1"),
            "tool_input": .object(["file_path": .string("Sources/A.swift"), "old_string": .string("a"), "new_string": .string("b")]),
        ])
        let event = try XCTUnwrap(adapter.events(from: raw, receivedAt: received).first)
        XCTAssertEqual(event.kind, .toolBefore)
        XCTAssertEqual(event.vendor, "claude")
        XCTAssertEqual(event.session, "abc-123")
        XCTAssertEqual(event.cwd, "/Users/me/proj")
        XCTAssertEqual(event.tool, "Edit")
        XCTAssertEqual(event.toolUseId, "toolu_1")
        XCTAssertEqual(event.paths, ["/Users/me/proj/Sources/A.swift"])
        XCTAssertEqual(event.ts, received)
        XCTAssertEqual(event.fidelity, .official)
        XCTAssertEqual(event.meta?["transcript_path"]?.stringValue, "/Users/me/.claude/projects/-Users-me-proj/abc-123.jsonl")
    }

    /// PostToolUse on Bash becomes tool.after, declares the cwd, and keeps a
    /// bounded result.
    func testBashAfterDeclaresTheWorkingDirectoryAndBoundsTheResult() throws {
        let raw = payload([
            "hook_event_name": .string("PostToolUse"), "tool_name": .string("Bash"), "tool_use_id": .string("toolu_2"),
            "tool_input": .object(["command": .string("rm -rf build")]),
            "tool_response": .object(["stdout": .string(String(repeating: "y", count: 200_000)), "stderr": .string("")]),
        ])
        let event = try XCTUnwrap(adapter.events(from: raw, receivedAt: received).first)
        XCTAssertEqual(event.kind, .toolAfter)
        XCTAssertEqual(event.paths, ["/Users/me/proj"])
        XCTAssertEqual(event.args?["command"]?.stringValue, "rm -rf build")
        XCTAssertEqual(event.result?["stdout"]?["truncated"]?.boolValue, true)
        XCTAssertEqual(event.result?["stdout"]?["bytes"]?.numberValue, 200_000)
    }

    /// A read-only tool declares no paths.
    func testReadDeclaresNothing() throws {
        let raw = payload([
            "hook_event_name": .string("PreToolUse"), "tool_name": .string("Read"), "tool_use_id": .string("toolu_3"),
            "tool_input": .object(["file_path": .string("/etc/hosts")]),
        ])
        let event = try XCTUnwrap(adapter.events(from: raw, receivedAt: received).first)
        XCTAssertEqual(event.paths, [])
    }

    /// PostToolUseFailure carries the error.
    func testFailureCarriesTheError() throws {
        let raw = payload([
            "hook_event_name": .string("PostToolUseFailure"), "tool_name": .string("Write"), "tool_use_id": .string("toolu_4"),
            "tool_input": .object(["file_path": .string("/Users/me/proj/out.txt"), "content": .string("hi")]),
            "error": .string("permission denied"), "is_interrupt": .bool(false),
        ])
        let event = try XCTUnwrap(adapter.events(from: raw, receivedAt: received).first)
        XCTAssertEqual(event.kind, .toolFailed)
        XCTAssertEqual(event.error, "permission denied")
        XCTAssertEqual(event.paths, ["/Users/me/proj/out.txt"])
        XCTAssertEqual(event.meta?["is_interrupt"]?.boolValue, false)
    }

    /// Session boundaries map to session events and keep source and reason.
    func testSessionBoundaries() throws {
        let start = try XCTUnwrap(adapter.events(from: payload([
            "hook_event_name": .string("SessionStart"), "source": .string("startup"), "model": .string("claude-fable-5-1"),
        ]), receivedAt: received).first)
        XCTAssertEqual(start.kind, .sessionStart)
        XCTAssertEqual(start.meta?["source"]?.stringValue, "startup")
        XCTAssertEqual(start.meta?["model"]?.stringValue, "claude-fable-5-1")

        let end = try XCTUnwrap(adapter.events(from: payload([
            "hook_event_name": .string("SessionEnd"), "reason": .string("prompt_input_exit"),
        ]), receivedAt: received).first)
        XCTAssertEqual(end.kind, .sessionEnd)
        XCTAssertEqual(end.meta?["reason"]?.stringValue, "prompt_input_exit")
    }

    /// Hooks Notchd does not model become notes that still name the event.
    func testUnmodelledHooksBecomeNotes() throws {
        let event = try XCTUnwrap(adapter.events(from: payload([
            "hook_event_name": .string("UserPromptSubmit"), "prompt": .string("fix the build"),
        ]), receivedAt: received).first)
        XCTAssertEqual(event.kind, .note)
        XCTAssertEqual(event.meta?["event"]?.stringValue, "UserPromptSubmit")
        XCTAssertEqual(event.meta?["prompt"]?.stringValue, "fix the build")
    }

    /// Missing required fields are named in the error.
    func testMissingFieldsAreNamed() {
        XCTAssertThrowsError(try adapter.events(from: .object(["cwd": .string("/")]), receivedAt: received)) { error in
            XCTAssertEqual(error as? AdapterError, .missingField("session_id"))
        }
        XCTAssertThrowsError(try adapter.events(from: .string("nope"), receivedAt: received)) { error in
            guard case AdapterError.malformed = error else { return XCTFail("unexpected \(error)") }
        }
    }

    /// Absolute file paths are kept as given, relative ones resolved.
    func testPathResolution() {
        XCTAssertEqual(ClaudeToolPaths.paths(tool: "Write", input: .object(["file_path": .string("/abs/x")]), cwd: "/cwd"), ["/abs/x"])
        XCTAssertEqual(ClaudeToolPaths.paths(tool: "MultiEdit", input: .object(["file_path": .string("./a/../b")]), cwd: "/cwd"), ["/cwd/b"])
        XCTAssertEqual(ClaudeToolPaths.paths(tool: "NotebookEdit", input: .object(["notebook_path": .string("n.ipynb")]), cwd: "/cwd"), ["/cwd/n.ipynb"])
        XCTAssertEqual(ClaudeToolPaths.paths(tool: "Grep", input: .object([:]), cwd: "/cwd"), [])
        XCTAssertEqual(ClaudeToolPaths.paths(tool: nil, input: nil, cwd: "/cwd"), [])
    }
}
