// HookSettings.swift
// The vendors whose settings files take command hooks in the same shape, and
// the pure functions that merge Notchd's entries in and out of such a file.
// Claude Code and Gemini CLI both keep `hooks` as an object of event name to
// matcher groups, each group holding `{type, command, timeout}` definitions.
// Nothing here touches disk; HookSettingsFile does that after the user has
// seen the exact text. Every function returns a new value.

import Foundation

/// A vendor whose settings file takes command hooks.
enum HookVendor: String, CaseIterable, Identifiable {
    case claude
    case gemini

    var id: String { rawValue }

    /// The name shown in the settings window.
    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .gemini: return "Gemini CLI"
        }
    }

    /// The events Notchd listens to.
    var events: [String] {
        switch self {
        case .claude: return ["SessionStart", "SessionEnd", "PreToolUse", "PostToolUse", "PostToolUseFailure", "UserPromptSubmit", "Stop"]
        case .gemini: return ["SessionStart", "SessionEnd", "BeforeAgent", "AfterAgent", "BeforeTool", "AfterTool"]
        }
    }

    /// The configuration directory, honouring the vendor's own override.
    /// - Parameter environment: The process environment.
    /// - Returns: The directory.
    func configurationDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude:
            if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
            return home.appendingPathComponent(".claude", isDirectory: true)
        case .gemini:
            if let dir = environment["GEMINI_CLI_HOME"], !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(".gemini", isDirectory: true) }
            return home.appendingPathComponent(".gemini", isDirectory: true)
        }
    }

    /// The settings file.
    /// - Parameter environment: The process environment.
    /// - Returns: The file location.
    func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        configurationDirectory(environment: environment).appendingPathComponent("settings.json")
    }

    /// The shell command the vendor runs.
    /// - Parameter binaryPath: Absolute path to `notchd-hook`.
    /// - Returns: The command string.
    func command(binaryPath: String) -> String {
        "\"\(binaryPath)\" \(rawValue)"
    }
}

/// Merging Notchd's hook entries into a vendor's settings document.
enum HookSettings {
    /// The marker every Notchd hook command contains.
    static let marker = "notchd-hook"

    /// Seconds the vendor waits for the hook. The hook exits in
    /// milliseconds, or after its four-second acknowledgement cap; this only
    /// bounds a wedged machine.
    static let timeoutSeconds = 6

    /// One hook definition object.
    /// - Parameters:
    ///   - vendor: The vendor.
    ///   - binaryPath: Absolute path to `notchd-hook`.
    /// - Returns: `{type, command, timeout}`.
    static func hookDefinition(vendor: HookVendor, binaryPath: String) -> JSONValue {
        .object(["type": .string("command"), "command": .string(vendor.command(binaryPath: binaryPath)), "timeout": .number(Double(timeoutSeconds))])
    }

    /// The `hooks` object Notchd contributes, keyed by event.
    /// - Parameters:
    ///   - vendor: The vendor.
    ///   - binaryPath: Absolute path to `notchd-hook`.
    /// - Returns: The object as it would appear in settings.
    static func contribution(vendor: HookVendor, binaryPath: String) -> JSONValue {
        let group = JSONValue.object(["hooks": .array([hookDefinition(vendor: vendor, binaryPath: binaryPath)])])
        return .object(Dictionary(uniqueKeysWithValues: vendor.events.map { ($0, JSONValue.array([group])) }))
    }

    /// The text shown before anything is written.
    /// - Parameters:
    ///   - vendor: The vendor.
    ///   - binaryPath: Absolute path to `notchd-hook`.
    /// - Returns: Pretty-printed JSON of the `hooks` object.
    static func renderedSnippet(vendor: HookVendor, binaryPath: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(JSONValue.object(["hooks": contribution(vendor: vendor, binaryPath: binaryPath)])) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Markers earlier builds used. Recognised so Remove and Install clean
    /// them up, never counted as installed.
    static let legacyMarkers = ["rewind-hook"]

    /// Whether a hook definition is one of ours, from this build or an
    /// earlier one.
    /// - Parameter definition: A `{type, command, ...}` object.
    /// - Returns: True when its command names the hook binary.
    static func isOurs(_ definition: JSONValue) -> Bool {
        guard let command = definition["command"]?.stringValue else { return false }
        return command.contains(marker) || legacyMarkers.contains { command.contains($0) }
    }

    /// Whether a hook definition is one of this build's.
    /// - Parameter definition: A `{type, command, ...}` object.
    /// - Returns: True when its command names the current hook binary.
    static func isCurrent(_ definition: JSONValue) -> Bool {
        definition["command"]?.stringValue?.contains(marker) ?? false
    }

    /// Whether settings already carry a current Notchd hook for every event.
    /// - Parameters:
    ///   - settings: The whole settings document.
    ///   - vendor: The vendor.
    /// - Returns: True when nothing needs installing.
    static func isInstalled(in settings: JSONValue, vendor: HookVendor) -> Bool {
        let hooks = settings["hooks"]?.objectValue ?? [:]
        return vendor.events.allSatisfy { event in
            (hooks[event]?.arrayValue ?? []).contains { group in (group["hooks"]?.arrayValue ?? []).contains(where: isCurrent) }
        }
    }

    /// Settings with Notchd's hooks present exactly once per event. Existing
    /// hooks, including other people's, are kept in place.
    /// - Parameters:
    ///   - settings: The whole settings document.
    ///   - vendor: The vendor.
    ///   - binaryPath: Absolute path to `notchd-hook`.
    /// - Returns: A new settings document.
    static func installing(into settings: JSONValue, vendor: HookVendor, binaryPath: String) -> JSONValue {
        var root = removing(from: settings).objectValue ?? [:]
        var hooks = root["hooks"]?.objectValue ?? [:]
        let group = JSONValue.object(["hooks": .array([hookDefinition(vendor: vendor, binaryPath: binaryPath)])])
        for event in vendor.events {
            hooks[event] = .array((hooks[event]?.arrayValue ?? []) + [group])
        }
        root["hooks"] = .object(hooks)
        return .object(root)
    }

    /// Settings with every Notchd hook removed and nothing else changed.
    /// Groups left empty and an empty `hooks` object are dropped.
    /// - Parameter settings: The whole settings document.
    /// - Returns: A new settings document.
    static func removing(from settings: JSONValue) -> JSONValue {
        var root = settings.objectValue ?? [:]
        guard let hooks = root["hooks"]?.objectValue else { return settings }
        let cleaned = hooks.compactMapValues { groups -> JSONValue? in
            let kept = (groups.arrayValue ?? []).compactMap(strippingOurs)
            return kept.isEmpty ? nil : .array(kept)
        }
        if cleaned.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = .object(cleaned)
        }
        return .object(root)
    }

    /// A matcher group without our definitions, or nil if nothing remains.
    private static func strippingOurs(_ group: JSONValue) -> JSONValue? {
        var object = group.objectValue ?? [:]
        let remaining = (object["hooks"]?.arrayValue ?? []).filter { !isOurs($0) }
        if remaining.isEmpty { return nil }
        object["hooks"] = .array(remaining)
        return .object(object)
    }
}

/// Claude Code's entries, as a named view over the shared functions.
enum ClaudeHookConfig {
    static let marker = HookSettings.marker
    static let timeoutSeconds = HookSettings.timeoutSeconds
    static let events = HookVendor.claude.events

    /// The shell command Claude Code runs.
    /// - Parameter binaryPath: Absolute path to `notchd-hook`.
    /// - Returns: The command string.
    static func command(binaryPath: String) -> String { HookVendor.claude.command(binaryPath: binaryPath) }

    /// One hook definition object.
    /// - Parameter binaryPath: Absolute path to `notchd-hook`.
    /// - Returns: `{type, command, timeout}`.
    static func hookDefinition(binaryPath: String) -> JSONValue { HookSettings.hookDefinition(vendor: .claude, binaryPath: binaryPath) }

    /// The `hooks` object Notchd contributes.
    /// - Parameter binaryPath: Absolute path to `notchd-hook`.
    /// - Returns: The object.
    static func contribution(binaryPath: String) -> JSONValue { HookSettings.contribution(vendor: .claude, binaryPath: binaryPath) }

    /// The text shown before anything is written.
    /// - Parameter binaryPath: Absolute path to `notchd-hook`.
    /// - Returns: Pretty-printed JSON.
    static func renderedSnippet(binaryPath: String) -> String { HookSettings.renderedSnippet(vendor: .claude, binaryPath: binaryPath) }

    /// Whether a definition is ours.
    /// - Parameter definition: A hook definition.
    /// - Returns: True when it names the hook binary.
    static func isOurs(_ definition: JSONValue) -> Bool { HookSettings.isOurs(definition) }

    /// Whether every event has a Notchd hook.
    /// - Parameter settings: The settings document.
    /// - Returns: True when installed.
    static func isInstalled(in settings: JSONValue) -> Bool { HookSettings.isInstalled(in: settings, vendor: .claude) }

    /// Settings with Notchd's hooks added.
    /// - Parameters:
    ///   - settings: The settings document.
    ///   - binaryPath: Absolute path to `notchd-hook`.
    /// - Returns: A new document.
    static func installing(into settings: JSONValue, binaryPath: String) -> JSONValue {
        HookSettings.installing(into: settings, vendor: .claude, binaryPath: binaryPath)
    }

    /// Settings with Notchd's hooks removed.
    /// - Parameter settings: The settings document.
    /// - Returns: A new document.
    static func removing(from settings: JSONValue) -> JSONValue { HookSettings.removing(from: settings) }
}
