// GeminiAdapter.swift
// Normalises Gemini CLI hook payloads. Gemini CLI's hooks follow Claude Code's
// shape: session_id, cwd, hook_event_name, and for BeforeTool and AfterTool a
// tool_name, tool_input, and tool_response, plus a timestamp. This machine has
// Gemini CLI configured but not installed, so the shape comes from Gemini's
// documentation rather than a recorded payload; the adapter accepts either
// Gemini's own tool names or Claude-style ones, and falls back to the receipt
// time when no timestamp is present.

import Foundation

/// Gemini CLI hook payloads to protocol events.
struct GeminiAdapter: VendorAdapter {
    static let vendor = "gemini"

    /// Tool results are kept to this many bytes per string.
    static let resultLimit = 64 * 1024

    /// Normalises one hook payload.
    /// - Parameters:
    ///   - raw: The JSON Gemini CLI wrote to the hook's stdin.
    ///   - receivedAt: When the hook read it.
    /// - Returns: Exactly one event.
    func events(from raw: JSONValue, receivedAt: Date) throws -> [NotchdEvent] {
        guard raw.objectValue != nil else { throw AdapterError.malformed("payload is not an object") }
        guard let session = raw["session_id"]?.stringValue else { throw AdapterError.missingField("session_id") }
        guard let cwd = raw["cwd"]?.stringValue else { throw AdapterError.missingField("cwd") }
        guard let hookName = raw["hook_event_name"]?.stringValue else { throw AdapterError.missingField("hook_event_name") }
        let tool = raw["tool_name"]?.stringValue
        let args = raw["tool_input"]
        let ts = raw["timestamp"]?.stringValue.flatMap(NotchdProtocol.date(from:)) ?? receivedAt
        return [NotchdEvent(
            kind: Self.kind(for: hookName), vendor: Self.vendor, session: session, cwd: cwd, tool: tool,
            toolUseId: raw["tool_use_id"]?.stringValue ?? raw["call_id"]?.stringValue, args: args,
            result: raw["tool_response"]?.truncatingStrings(to: Self.resultLimit), error: raw["error"]?.stringValue,
            paths: GeminiToolPaths.paths(tool: tool, input: args, cwd: cwd), meta: Self.meta(from: raw, hookName: hookName),
            ts: ts, fidelity: .official
        )]
    }

    /// Maps a Gemini hook name onto a protocol kind.
    /// - Parameter hookName: The `hook_event_name` value.
    /// - Returns: The protocol kind.
    static func kind(for hookName: String) -> NotchdEvent.Kind {
        switch hookName {
        case "SessionStart": return .sessionStart
        case "SessionEnd": return .sessionEnd
        case "BeforeTool": return .toolBefore
        case "AfterTool": return .toolAfter
        default: return .note
        }
    }

    /// The fields worth keeping that the protocol has no slot for.
    private static func meta(from raw: JSONValue, hookName: String) -> JSONValue {
        let carried = ["transcript_path", "source", "reason", "model", "prompt", "message"]
        var object: [String: JSONValue] = ["event": .string(hookName)]
        for key in carried {
            if let value = raw[key] { object[key] = value }
        }
        return .object(object)
    }
}

/// Which paths a Gemini CLI tool call declares it will touch.
enum GeminiToolPaths {
    /// Tools that name a single file.
    static let fileTools: Set<String> = ["write_file", "replace", "edit", "Edit", "Write", "MultiEdit", "NotebookEdit"]

    /// Tools that can change anything under a directory.
    static let shellTools: Set<String> = ["run_shell_command", "shell", "Bash"]

    /// The declared paths for a tool call. Read-only tools declare nothing.
    /// - Parameters:
    ///   - tool: The tool name, if any.
    ///   - input: The tool's input.
    ///   - cwd: The session's working directory.
    /// - Returns: Absolute paths.
    static func paths(tool: String?, input: JSONValue?, cwd: String) -> [String] {
        guard let tool else { return [] }
        if fileTools.contains(tool) {
            guard let path = input?["file_path"]?.stringValue ?? input?["path"]?.stringValue ?? input?["absolute_path"]?.stringValue else { return [] }
            return [absolute(path, cwd: cwd)]
        }
        if shellTools.contains(tool) {
            return [absolute(input?["directory"]?.stringValue ?? input?["dir"]?.stringValue ?? cwd, cwd: cwd)]
        }
        return []
    }

    /// Resolves a path against the working directory.
    private static func absolute(_ path: String, cwd: String) -> String {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: cwd).appendingPathComponent(path)
        return url.standardizedFileURL.path
    }
}
