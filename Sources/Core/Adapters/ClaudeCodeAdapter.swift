// ClaudeCodeAdapter.swift
// Normalises Claude Code hook payloads. The shapes were read from Claude Code's
// own schema (entrypoints/sdk/coreSchemas.ts, version 2.1.266): every hook
// carries session_id, transcript_path, cwd, and optionally permission_mode,
// agent_id, and agent_type; tool hooks add tool_name, tool_input, tool_use_id,
// and for PostToolUse tool_response; PostToolUseFailure adds error. Claude Code
// puts no timestamp in a hook payload, so the receipt time is the event time.

import Foundation

/// Claude Code hook payloads to protocol events.
struct ClaudeCodeAdapter: VendorAdapter {
    static let vendor = "claude"

    /// Tool results are kept to this many bytes per string.
    static let resultLimit = 64 * 1024

    /// Normalises one hook payload.
    /// - Parameters:
    ///   - raw: The JSON Claude Code wrote to the hook's stdin.
    ///   - receivedAt: When the hook read it.
    /// - Returns: Exactly one event.
    func events(from raw: JSONValue, receivedAt: Date) throws -> [NotchdEvent] {
        guard raw.objectValue != nil else { throw AdapterError.malformed("payload is not an object") }
        guard let session = raw["session_id"]?.stringValue else { throw AdapterError.missingField("session_id") }
        guard let cwd = raw["cwd"]?.stringValue else { throw AdapterError.missingField("cwd") }
        guard let hookName = raw["hook_event_name"]?.stringValue else { throw AdapterError.missingField("hook_event_name") }

        let tool = raw["tool_name"]?.stringValue
        let args = raw["tool_input"]
        let base = NotchdEvent(
            kind: Self.kind(for: hookName),
            vendor: Self.vendor,
            session: session,
            pid: nil,
            cwd: cwd,
            tool: tool,
            toolUseId: raw["tool_use_id"]?.stringValue,
            args: args,
            result: raw["tool_response"]?.truncatingStrings(to: Self.resultLimit),
            error: raw["error"]?.stringValue,
            paths: ClaudeToolPaths.paths(tool: tool, input: args, cwd: cwd),
            meta: Self.meta(from: raw, hookName: hookName),
            ts: receivedAt,
            fidelity: .official
        )
        return [base]
    }

    /// Maps a Claude Code hook name onto a protocol kind. Anything Notchd does
    /// not model as a tool or session boundary becomes a note carrying the
    /// original name in `meta.event`.
    /// - Parameter hookName: The `hook_event_name` value.
    /// - Returns: The protocol kind.
    static func kind(for hookName: String) -> NotchdEvent.Kind {
        switch hookName {
        case "SessionStart": return .sessionStart
        case "SessionEnd": return .sessionEnd
        case "PreToolUse": return .toolBefore
        case "PostToolUse": return .toolAfter
        case "PostToolUseFailure": return .toolFailed
        default: return .note
        }
    }

    /// The fields worth keeping that the protocol has no first-class slot for.
    /// - Parameters:
    ///   - raw: The payload.
    ///   - hookName: The original hook name.
    /// - Returns: A meta object, never empty because it always carries `event`.
    private static func meta(from raw: JSONValue, hookName: String) -> JSONValue {
        let carried = ["transcript_path", "permission_mode", "agent_id", "agent_type",
                       "source", "reason", "model", "prompt", "message", "is_interrupt", "stop_hook_active"]
        var object: [String: JSONValue] = ["event": .string(hookName)]
        for key in carried {
            if let value = raw[key] { object[key] = value }
        }
        return .object(object)
    }
}

/// Which paths a Claude Code tool call declares it will touch.
enum ClaudeToolPaths {
    /// Tools that name a single file in `file_path`.
    static let fileTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    /// Tools that can change anything under the working directory.
    static let shellTools: Set<String> = ["Bash", "PowerShell"]

    /// The declared paths for a tool call. Read-only tools declare nothing.
    /// - Parameters:
    ///   - tool: The tool name, if any.
    ///   - input: The tool's input.
    ///   - cwd: The session's working directory, used to resolve relative paths.
    /// - Returns: Absolute paths.
    static func paths(tool: String?, input: JSONValue?, cwd: String) -> [String] {
        guard let tool else { return [] }
        if fileTools.contains(tool) {
            guard let path = input?["file_path"]?.stringValue ?? input?["notebook_path"]?.stringValue else { return [] }
            return [absolute(path, cwd: cwd)]
        }
        if shellTools.contains(tool) {
            return [cwd]
        }
        return []
    }

    /// Resolves a path against the working directory.
    /// - Parameters:
    ///   - path: A possibly relative path.
    ///   - cwd: The working directory.
    /// - Returns: An absolute, standardised path.
    private static func absolute(_ path: String, cwd: String) -> String {
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : URL(fileURLWithPath: cwd).appendingPathComponent(path)
        return url.standardizedFileURL.path
    }
}
