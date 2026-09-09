// CodexRolloutParser.swift
// Turns the lines of a Codex rollout transcript into protocol events. Codex
// on this machine is the desktop app with no hooks, so its transcripts under
// ~/.codex/sessions are the only source, and everything here is `derived`.
// Shapes measured from Codex 0.145: `session_meta` carries the session id and
// cwd; `turn_context` the cwd per turn; `response_item` lines carry
// `function_call` (name, arguments as a JSON string, call_id),
// `custom_tool_call` (name exec or apply_patch, input as text, call_id), and
// their `_output` counterparts paired by call_id. Every line has a timestamp.

import Foundation

/// A stateful parser for one rollout file.
struct CodexRolloutParser {
    static let vendor = "codex"

    /// Tool results are kept to this many bytes per string.
    static let resultLimit = 64 * 1024

    /// The session id, from `session_meta` or the file name.
    private(set) var sessionId: String
    /// The working directory, from `session_meta` and then each `turn_context`.
    private(set) var cwd: String?
    /// Tool names for calls whose output has not arrived, by call id.
    private var openCalls: [String: String] = [:]

    /// Creates a parser for a file.
    /// - Parameter fallbackSession: The session id to use until `session_meta`
    ///   is seen, usually taken from the file name.
    init(fallbackSession: String) {
        sessionId = fallbackSession
    }

    /// The session id inside a rollout file name, or the whole stem.
    /// - Parameter fileName: A name like `rollout-2026-07-28T08-37-41-<uuid>.jsonl`.
    /// - Returns: The uuid, or the stem when the name is not in that form.
    static func sessionId(fromFileName fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        let parts = stem.split(separator: "-")
        guard parts.count >= 5 else { return stem }
        return parts.suffix(5).joined(separator: "-")
    }

    /// Parses one line.
    /// - Parameter line: One JSON object.
    /// - Returns: The events it describes, usually none or one.
    mutating func events(from line: Data) -> [NotchdEvent] {
        guard let root = try? JSONValue.parse(line), let type = root["type"]?.stringValue,
              let payload = root["payload"] else { return [] }
        let ts = root["timestamp"]?.stringValue.flatMap(NotchdProtocol.date(from:)) ?? Date()
        switch type {
        case "session_meta":
            return sessionMeta(payload, ts: ts)
        case "turn_context":
            if let dir = payload["cwd"]?.stringValue { cwd = dir }
            return []
        case "response_item":
            return responseItem(payload, ts: ts)
        case "event_msg":
            guard payload["type"]?.stringValue == "task_complete" else { return [] }
            return [event(kind: .note, ts: ts, meta: .object(["event": .string("task_complete")]))]
        default:
            return []
        }
    }

    /// The session start.
    private mutating func sessionMeta(_ payload: JSONValue, ts: Date) -> [NotchdEvent] {
        if let id = payload["session_id"]?.stringValue ?? payload["id"]?.stringValue { sessionId = id }
        if let dir = payload["cwd"]?.stringValue { cwd = dir }
        let started = payload["timestamp"]?.stringValue.flatMap(NotchdProtocol.date(from:)) ?? ts
        var meta: [String: JSONValue] = ["event": .string("session_meta")]
        for key in ["originator", "source", "cli_version", "model_provider"] {
            if let value = payload[key] { meta[key] = value }
        }
        return [event(kind: .sessionStart, ts: started, meta: .object(meta))]
    }

    /// A tool call, its output, or a prompt the user typed.
    private mutating func responseItem(_ payload: JSONValue, ts: Date) -> [NotchdEvent] {
        guard let itemType = payload["type"]?.stringValue else { return [] }
        switch itemType {
        case "message":
            guard payload["role"]?.stringValue == "user", let prompt = Self.promptText(payload) else { return [] }
            return [event(kind: .note, ts: ts, meta: .object(["event": .string("UserPromptSubmit"), "prompt": .string(prompt)]))]
        case "function_call":
            guard let name = payload["name"]?.stringValue else { return [] }
            let args = payload["arguments"]?.stringValue.flatMap { try? JSONValue.parse(Data($0.utf8)) } ?? .object([:])
            return [toolBefore(name: name, callId: payload["call_id"]?.stringValue, args: args, ts: ts)]
        case "custom_tool_call":
            guard let name = payload["name"]?.stringValue else { return [] }
            let input = payload["input"]?.stringValue ?? ""
            let args = name == "exec" ? CodexExecScript.arguments(input) : JSONValue.object(["input": .string(input)])
            return [toolBefore(name: name, callId: payload["call_id"]?.stringValue, args: args, ts: ts)]
        case "function_call_output", "custom_tool_call_output":
            let callId = payload["call_id"]?.stringValue
            let name = callId.flatMap { openCalls.removeValue(forKey: $0) } ?? "tool"
            let output = payload["output"]?.truncatingStrings(to: Self.resultLimit) ?? .null
            return [event(kind: .toolAfter, ts: ts, tool: name, toolUseId: callId, result: .object(["output": output]),
                          meta: .object(["event": .string(itemType)]))]
        default:
            return []
        }
    }

    /// The text of a user message, or nil for the instruction blocks the
    /// Codex app injects under the user role, which begin with a tag.
    /// - Parameter payload: A `message` item.
    /// - Returns: The prompt, trimmed.
    static func promptText(_ payload: JSONValue) -> String? {
        let parts = payload["content"]?.arrayValue ?? []
        let text = parts.compactMap { part -> String? in
            guard part["type"]?.stringValue == "input_text" else { return nil }
            return part["text"]?.stringValue
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("<") else { return nil }
        return text
    }

    /// A tool call about to run, with the paths it declares.
    private mutating func toolBefore(name: String, callId: String?, args: JSONValue, ts: Date) -> NotchdEvent {
        if let callId { openCalls[callId] = name }
        return event(kind: .toolBefore, ts: ts, tool: name, toolUseId: callId, args: args,
                     paths: CodexToolPaths.paths(tool: name, args: args, cwd: cwd ?? "/"),
                     meta: .object(["event": .string("function_call")]))
    }

    /// An event for this session.
    private func event(kind: NotchdEvent.Kind, ts: Date, tool: String? = nil, toolUseId: String? = nil, args: JSONValue? = nil,
                       result: JSONValue? = nil, paths: [String] = [], meta: JSONValue? = nil) -> NotchdEvent {
        NotchdEvent(kind: kind, vendor: Self.vendor, session: sessionId, cwd: cwd ?? "/", tool: tool, toolUseId: toolUseId,
                    args: args, result: result, paths: paths, meta: meta, ts: ts, fidelity: .derived)
    }
}

/// Which paths a Codex tool call declares it will touch.
enum CodexToolPaths {
    /// The declared paths for a tool call.
    /// - Parameters:
    ///   - tool: The tool name.
    ///   - args: The parsed arguments, or `{input}` for a custom tool.
    ///   - cwd: The current working directory.
    /// - Returns: Absolute paths. Shell tools declare their working
    ///   directory; apply_patch declares every file its headers name.
    static func paths(tool: String, args: JSONValue, cwd: String) -> [String] {
        switch tool {
        case "exec_command", "shell", "write_stdin":
            return [absolute(args["workdir"]?.stringValue ?? cwd, cwd: cwd)]
        case "exec":
            let workdir = absolute(args["workdir"]?.stringValue ?? cwd, cwd: cwd)
            let patched = (args["patch_files"]?.arrayValue ?? []).compactMap(\.stringValue).map { absolute($0, cwd: cwd) }
            return args["commands"]?.arrayValue?.isEmpty == false || patched.isEmpty ? [workdir] + patched : patched
        case "apply_patch":
            let patch = args["input"]?.stringValue ?? args["patch"]?.stringValue ?? ""
            return patchPaths(patch).map { absolute($0, cwd: cwd) }
        default:
            return []
        }
    }

    /// File names from apply_patch headers: `*** Update File:`, `*** Add
    /// File:`, `*** Delete File:`, and the target of `*** Move to:`.
    /// - Parameter patch: The patch text.
    /// - Returns: The paths in order of first mention, without duplicates.
    static func patchPaths(_ patch: String) -> [String] {
        let markers = ["*** Update File: ", "*** Add File: ", "*** Delete File: ", "*** Move to: "]
        var seen: [String] = []
        for line in patch.split(separator: "\n") {
            for marker in markers where line.hasPrefix(marker) {
                let path = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                if !path.isEmpty, !seen.contains(path) { seen.append(path) }
            }
        }
        return seen
    }

    /// Resolves a path against the working directory.
    private static func absolute(_ path: String, cwd: String) -> String {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: cwd).appendingPathComponent(path)
        return url.standardizedFileURL.path
    }
}

/// What can be read out of the JavaScript Codex's `exec` tool runs: the shell
/// commands it passes to `tools.exec_command`, the working directory, and any
/// apply_patch text it carries as a string literal.
enum CodexExecScript {
    /// The arguments Notchd records for an `exec` call: the script itself, the
    /// commands and workdir found in it, the files a patch names, and a
    /// one-line `command` for the timeline.
    /// - Parameter script: The JavaScript.
    /// - Returns: An arguments object.
    static func arguments(_ script: String) -> JSONValue {
        let commands = stringLiterals(after: "\"cmd\"", in: script)
        let workdir = stringLiterals(after: "\"workdir\"", in: script).first
        let patchFiles = patches(in: script).flatMap(CodexToolPaths.patchPaths)
        var object: [String: JSONValue] = ["input": .string(script)]
        if !commands.isEmpty { object["commands"] = .array(commands.map(JSONValue.string)) }
        if let workdir { object["workdir"] = .string(workdir) }
        if !patchFiles.isEmpty { object["patch_files"] = .array(patchFiles.map(JSONValue.string)) }
        if let summary = summary(commands: commands, patchFiles: patchFiles) { object["command"] = .string(summary) }
        return .object(object)
    }

    /// The one line the timeline shows for the call.
    private static func summary(commands: [String], patchFiles: [String]) -> String? {
        if !commands.isEmpty { return commands.joined(separator: " && ") }
        if !patchFiles.isEmpty {
            let names = patchFiles.map { ($0 as NSString).lastPathComponent }
            return "apply_patch " + names.joined(separator: ", ")
        }
        return nil
    }

    /// Every JSON string literal that follows a key, such as `"cmd":`.
    /// - Parameters:
    ///   - key: The quoted key.
    ///   - script: The JavaScript.
    /// - Returns: The decoded strings in order.
    static func stringLiterals(after key: String, in script: String) -> [String] {
        var result: [String] = []
        var search = script.startIndex
        while let keyRange = script.range(of: key, range: search..<script.endIndex) {
            search = keyRange.upperBound
            var index = keyRange.upperBound
            while index < script.endIndex, script[index] == " " || script[index] == ":" { index = script.index(after: index) }
            guard index < script.endIndex, script[index] == "\"", let literal = literal(from: index, in: script) else { continue }
            result.append(literal.value)
            search = literal.end
        }
        return result
    }

    /// Every string literal in the script that holds an apply_patch document.
    /// - Parameter script: The JavaScript.
    /// - Returns: The decoded patch texts.
    static func patches(in script: String) -> [String] {
        var result: [String] = []
        var search = script.startIndex
        while let marker = script.range(of: "*** Begin Patch", range: search..<script.endIndex) {
            search = marker.upperBound
            guard let open = script[..<marker.lowerBound].lastIndex(of: "\""), let literal = literal(from: open, in: script) else { continue }
            result.append(literal.value)
            search = literal.end
        }
        return result
    }

    /// Decodes a double-quoted JavaScript string literal with JSON escapes.
    /// - Parameters:
    ///   - start: The index of the opening quote.
    ///   - script: The JavaScript.
    /// - Returns: The value and the index after the closing quote, or nil
    ///   when the literal is unterminated or not decodable.
    private static func literal(from start: String.Index, in script: String) -> (value: String, end: String.Index)? {
        var index = script.index(after: start)
        var escaped = false
        while index < script.endIndex {
            let character = script[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                let raw = String(script[start...index])
                guard let value = try? JSONDecoder().decode(String.self, from: Data(raw.utf8)) else { return nil }
                return (value, script.index(after: index))
            }
            index = script.index(after: index)
        }
        return nil
    }
}
