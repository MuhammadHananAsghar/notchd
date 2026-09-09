// CursorHooks.swift
// Cursor's hooks live in `~/.cursor/hooks.json`: a `version` and a `hooks`
// object of event name to a list of `{command}` entries, each run with a JSON
// payload on stdin. Cursor is not installed on the machine this was written
// on, so the shape follows Cursor's documentation and the adapter says so.
// The same merge rules as the other hook vendors: existing entries are kept,
// ours appear once per event, Remove restores the file.

import Foundation

/// Notchd's entries in Cursor's hooks file.
struct CursorHooksFile: AgentIntegration {
    /// The hooks file.
    let url: URL

    /// The events Notchd listens to.
    static let events = ["beforeShellExecution", "afterShellExecution", "afterFileEdit", "beforeMCPExecution",
                         "afterMCPExecution", "beforeSubmitPrompt", "stop"]

    /// The file format version Cursor expects.
    static let version = 1

    /// The default location.
    /// - Parameter environment: The process environment.
    /// - Returns: `~/.cursor/hooks.json`.
    static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor", isDirectory: true).appendingPathComponent("hooks.json")
    }

    var displayName: String { "Cursor" }
    var targetPath: String { url.path }

    var vendorPresent: Bool {
        FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path)
    }

    var explanation: String {
        "Adds one command entry per event to Cursor's hooks file. Shell commands are checkpointed before they run; file edits arrive after the fact and are compared with the last copy Notchd has. Written to Cursor's documented format and not yet verified against a live Cursor. Fidelity: recorded by hook."
    }

    /// The command Cursor runs.
    /// - Parameter binaryPath: Absolute path to `notchd-hook`.
    /// - Returns: The command string.
    static func command(binaryPath: String) -> String {
        "\"\(binaryPath)\" cursor"
    }

    /// The `hooks` object Notchd contributes.
    /// - Parameter binaryPath: Absolute path to `notchd-hook`.
    /// - Returns: The object as it would appear in the file.
    static func contribution(binaryPath: String) -> JSONValue {
        let entry = JSONValue.object(["command": .string(command(binaryPath: binaryPath))])
        return .object(Dictionary(uniqueKeysWithValues: events.map { ($0, JSONValue.array([entry])) }))
    }

    /// Whether an entry is one of ours, from this build or an earlier one.
    /// - Parameter entry: A `{command}` object.
    /// - Returns: True when it names the hook binary.
    static func isOurs(_ entry: JSONValue) -> Bool {
        HookSettings.isOurs(entry)
    }

    /// Whether the document carries a current entry for every event.
    /// - Parameter document: The whole file.
    /// - Returns: True when nothing needs installing.
    static func isInstalled(in document: JSONValue) -> Bool {
        let hooks = document["hooks"]?.objectValue ?? [:]
        return events.allSatisfy { event in (hooks[event]?.arrayValue ?? []).contains(where: HookSettings.isCurrent) }
    }

    /// The document with Notchd's entries present exactly once per event.
    /// - Parameters:
    ///   - document: The whole file.
    ///   - binaryPath: Absolute path to `notchd-hook`.
    /// - Returns: A new document.
    static func installing(into document: JSONValue, binaryPath: String) -> JSONValue {
        var root = removing(from: document).objectValue ?? [:]
        var hooks = root["hooks"]?.objectValue ?? [:]
        let entry = JSONValue.object(["command": .string(command(binaryPath: binaryPath))])
        for event in events {
            hooks[event] = .array((hooks[event]?.arrayValue ?? []) + [entry])
        }
        root["hooks"] = .object(hooks)
        if root["version"] == nil { root["version"] = .number(Double(version)) }
        return .object(root)
    }

    /// The document with every Notchd entry removed. Events left empty and an
    /// empty `hooks` object are dropped; a `version` we added alone is too.
    /// - Parameter document: The whole file.
    /// - Returns: A new document.
    static func removing(from document: JSONValue) -> JSONValue {
        var root = document.objectValue ?? [:]
        guard let hooks = root["hooks"]?.objectValue else { return document }
        let cleaned = hooks.compactMapValues { entries -> JSONValue? in
            let kept = (entries.arrayValue ?? []).filter { !isOurs($0) }
            return kept.isEmpty ? nil : .array(kept)
        }
        if cleaned.isEmpty {
            root.removeValue(forKey: "hooks")
            if root.count == 1, root["version"] != nil { root.removeValue(forKey: "version") }
        } else {
            root["hooks"] = .object(cleaned)
        }
        return .object(root)
    }

    /// The text shown before anything is written.
    /// - Parameter binaryPath: Absolute path to `notchd-hook`.
    /// - Returns: Pretty-printed JSON.
    func snippet(binaryPath: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let document = JSONValue.object(["version": .number(Double(Self.version)), "hooks": Self.contribution(binaryPath: binaryPath)])
        guard let data = try? encoder.encode(document) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The current document, or an empty object when the file is absent.
    /// - Returns: The parsed file.
    func read() throws -> JSONValue {
        guard FileManager.default.fileExists(atPath: url.path) else { return .object([:]) }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return .object([:]) }
        let value: JSONValue
        do {
            value = try JSONValue.parse(data)
        } catch {
            throw SettingsFileError.notJSON(String(describing: error))
        }
        guard value.objectValue != nil else { throw SettingsFileError.notAnObject }
        return value
    }

    /// Replaces the document atomically.
    /// - Parameter document: The new document.
    func write(_ document: JSONValue) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    func isInstalled() throws -> Bool {
        Self.isInstalled(in: try read())
    }

    func install(binaryPath: String) throws {
        try write(Self.installing(into: try read(), binaryPath: binaryPath))
    }

    func uninstall() throws {
        try write(Self.removing(from: try read()))
    }
}
