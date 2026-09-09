// CursorAdapter.swift
// Normalises Cursor hook payloads. Per Cursor's documentation every payload
// carries `conversation_id`, `generation_id`, `hook_event_name`, and
// `workspace_roots`; shell hooks add `command` and `cwd`; `afterFileEdit`
// adds `file_path` and `edits`; MCP hooks add `tool_name` and `tool_input`;
// `beforeSubmitPrompt` adds `prompt`; `stop` adds `status`. Cursor has no
// before-edit hook, so a file edit arrives after the fact and the recorder
// compares it with the last copy it has. Not verified against a live Cursor
// on the machine this was written on.

import Foundation

/// Cursor hook payloads to protocol events.
struct CursorAdapter: VendorAdapter {
    static let vendor = "cursor"

    /// Normalises one hook payload.
    /// - Parameters:
    ///   - raw: The JSON Cursor wrote to the hook's stdin.
    ///   - receivedAt: When the hook read it.
    /// - Returns: Exactly one event.
    func events(from raw: JSONValue, receivedAt: Date) throws -> [NotchdEvent] {
        guard raw.objectValue != nil else { throw AdapterError.malformed("payload is not an object") }
        guard let session = raw["conversation_id"]?.stringValue else { throw AdapterError.missingField("conversation_id") }
        guard let hookName = raw["hook_event_name"]?.stringValue else { throw AdapterError.missingField("hook_event_name") }
        let cwd = raw["cwd"]?.stringValue ?? raw["workspace_roots"]?.arrayValue?.first?.stringValue ?? "/"
        let shape = Self.shape(for: hookName, raw: raw, cwd: cwd)
        return [NotchdEvent(
            kind: shape.kind, vendor: Self.vendor, session: session, cwd: cwd, tool: shape.tool,
            toolUseId: nil, args: shape.args, result: shape.result, paths: shape.paths,
            meta: Self.meta(from: raw, hookName: hookName), ts: receivedAt, fidelity: .official
        )]
    }

    /// The parts of an event that depend on the hook.
    private struct Shape {
        let kind: NotchdEvent.Kind
        let tool: String?
        let args: JSONValue?
        let result: JSONValue?
        let paths: [String]
    }

    /// Maps a hook onto an event shape.
    private static func shape(for hookName: String, raw: JSONValue, cwd: String) -> Shape {
        switch hookName {
        case "beforeShellExecution":
            return Shape(kind: .toolBefore, tool: "shell", args: .object(["command": raw["command"] ?? .null]), result: nil, paths: [cwd])
        case "afterShellExecution":
            return Shape(kind: .toolAfter, tool: "shell", args: .object(["command": raw["command"] ?? .null]),
                         result: pick(raw, ["output", "exit_code", "status", "duration"]), paths: [cwd])
        case "afterFileEdit":
            let path = raw["file_path"]?.stringValue.map { absolute($0, cwd: cwd) }
            return Shape(kind: .toolAfter, tool: "edit", args: .object(["file_path": raw["file_path"] ?? .null, "edits": raw["edits"] ?? .null]),
                         result: nil, paths: path.map { [$0] } ?? [])
        case "beforeMCPExecution":
            return Shape(kind: .toolBefore, tool: "mcp:" + (raw["tool_name"]?.stringValue ?? "tool"), args: raw["tool_input"], result: nil, paths: [])
        case "afterMCPExecution":
            return Shape(kind: .toolAfter, tool: "mcp:" + (raw["tool_name"]?.stringValue ?? "tool"), args: raw["tool_input"],
                         result: pick(raw, ["tool_output", "output", "status"]), paths: [])
        default:
            return Shape(kind: .note, tool: nil, args: nil, result: nil, paths: [])
        }
    }

    /// The listed keys that are present, as an object, or nil when none are.
    private static func pick(_ raw: JSONValue, _ keys: [String]) -> JSONValue? {
        var object: [String: JSONValue] = [:]
        for key in keys {
            if let value = raw[key] { object[key] = value.truncatingStrings(to: 64 * 1024) }
        }
        return object.isEmpty ? nil : .object(object)
    }

    /// The fields worth keeping that the protocol has no slot for.
    private static func meta(from raw: JSONValue, hookName: String) -> JSONValue {
        var object: [String: JSONValue] = ["event": .string(hookName)]
        for key in ["generation_id", "workspace_roots", "prompt", "status", "user_message", "agent_message"] {
            if let value = raw[key] { object[key] = value }
        }
        return .object(object)
    }

    /// Resolves a path against the working directory.
    private static func absolute(_ path: String, cwd: String) -> String {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: cwd).appendingPathComponent(path)
        return url.standardizedFileURL.path
    }
}
