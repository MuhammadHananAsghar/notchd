// ClaudeSettingsFile.swift
// Reads and writes a vendor's settings file for the purpose of adding or
// removing Notchd's hooks. Writes go through a temporary file and an atomic
// replace, and the document is parsed and re-serialised as JSON, so unrelated
// keys survive. One type serves Claude Code and Gemini CLI; the name keeps
// the file where the first vendor's version lived.

import Foundation

/// A failure reading or writing the settings file.
enum SettingsFileError: Error, Equatable {
    case notJSON(String)
    case notAnObject
}

/// A vendor's `settings.json`.
struct HookSettingsFile {
    /// The file this instance reads and writes.
    let url: URL
    /// Whose file it is.
    let vendor: HookVendor

    /// Whether the vendor appears to be installed for this user, judged by its
    /// configuration directory existing.
    var vendorPresent: Bool {
        FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path)
    }

    /// The current document, or an empty object when the file is absent.
    /// - Returns: The parsed settings.
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
    /// - Parameter settings: The new document.
    func write(_ settings: JSONValue) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(settings)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Whether Notchd's hooks are present in the file.
    /// - Returns: True when every event has a Notchd hook.
    func isInstalled() throws -> Bool {
        HookSettings.isInstalled(in: try read(), vendor: vendor)
    }

    /// Adds Notchd's hooks.
    /// - Parameter binaryPath: Absolute path to `notchd-hook`.
    func install(binaryPath: String) throws {
        try write(HookSettings.installing(into: try read(), vendor: vendor, binaryPath: binaryPath))
    }

    /// Removes Notchd's hooks.
    func uninstall() throws {
        try write(HookSettings.removing(from: try read()))
    }
}

/// Claude Code's settings file, as a named constructor over the shared type.
enum ClaudeSettingsFile {
    /// The default location: `$CLAUDE_CONFIG_DIR/settings.json` or
    /// `~/.claude/settings.json`.
    /// - Parameter environment: The process environment.
    /// - Returns: The file location.
    static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        HookVendor.claude.defaultURL(environment: environment)
    }

    /// A settings file at a location.
    /// - Parameter url: The file.
    /// - Returns: The file wrapper.
    static func at(_ url: URL) -> HookSettingsFile {
        HookSettingsFile(url: url, vendor: .claude)
    }
}
