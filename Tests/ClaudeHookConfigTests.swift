// ClaudeHookConfigTests.swift
// Installing into Claude Code's settings must add exactly our hooks, keep
// everyone else's, be idempotent, and be fully reversible, leaving the file as
// it was. The file wrapper is checked against a temporary directory.

import XCTest
@testable import Notchd

final class ClaudeHookConfigTests: XCTestCase {
    private let binary = "/Applications/Notchd.app/Contents/MacOS/notchd-hook"

    /// Someone else's settings, with a hook of their own on one event.
    private var existing: JSONValue {
        .object([
            "permissions": .object(["allow": .array([.string("Bash(ls:*)")])]),
            "hooks": .object([
                "PreToolUse": .array([
                    .object(["matcher": .string("Bash"), "hooks": .array([
                        .object(["type": .string("command"), "command": .string("/usr/local/bin/guard")]),
                    ])]),
                ]),
            ]),
        ])
    }

    /// Installing into empty settings yields one Notchd group per event.
    func testInstallIntoEmptySettings() {
        let result = ClaudeHookConfig.installing(into: .object([:]), binaryPath: binary)
        XCTAssertTrue(ClaudeHookConfig.isInstalled(in: result))
        let hooks = result["hooks"]?.objectValue ?? [:]
        XCTAssertEqual(Set(hooks.keys), Set(ClaudeHookConfig.events))
        let definition = hooks["PreToolUse"]?.arrayValue?.first?["hooks"]?.arrayValue?.first
        XCTAssertEqual(definition?["command"]?.stringValue, "\"\(binary)\" claude")
        XCTAssertEqual(definition?["type"]?.stringValue, "command")
        XCTAssertEqual(definition?["timeout"]?.numberValue, Double(HookSettings.timeoutSeconds))
    }

    /// Existing keys and existing hooks survive an install.
    func testInstallKeepsOtherPeoplesSettings() {
        let result = ClaudeHookConfig.installing(into: existing, binaryPath: binary)
        XCTAssertEqual(result["permissions"], existing["permissions"])
        let pre = result["hooks"]?["PreToolUse"]?.arrayValue ?? []
        XCTAssertEqual(pre.count, 2)
        XCTAssertEqual(pre[0]["matcher"]?.stringValue, "Bash")
        XCTAssertEqual(pre[0]["hooks"]?.arrayValue?.first?["command"]?.stringValue, "/usr/local/bin/guard")
    }

    /// Installing twice adds nothing the second time, even with a new path.
    func testInstallIsIdempotent() {
        let once = ClaudeHookConfig.installing(into: existing, binaryPath: binary)
        let twice = ClaudeHookConfig.installing(into: once, binaryPath: "/elsewhere/notchd-hook")
        for event in ClaudeHookConfig.events {
            let ours = (twice["hooks"]?[event]?.arrayValue ?? []).filter { group in
                (group["hooks"]?.arrayValue ?? []).contains(where: ClaudeHookConfig.isOurs)
            }
            XCTAssertEqual(ours.count, 1, event)
        }
        XCTAssertTrue(twice.serializedString.contains("/elsewhere/notchd-hook"))
        XCTAssertFalse(twice.serializedString.contains(binary))
    }

    /// Removing after installing restores the original document exactly.
    func testRemoveRestoresTheOriginal() {
        let installed = ClaudeHookConfig.installing(into: existing, binaryPath: binary)
        XCTAssertEqual(ClaudeHookConfig.removing(from: installed), existing)
    }

    /// Removing from settings that were empty before leaves no `hooks` key.
    func testRemoveFromEmptyLeavesNoHooksKey() {
        let installed = ClaudeHookConfig.installing(into: .object([:]), binaryPath: binary)
        XCTAssertEqual(ClaudeHookConfig.removing(from: installed), .object([:]))
    }

    /// Settings with our hook on only some events do not count as installed.
    func testPartialInstallIsNotInstalled() {
        let partial = JSONValue.object(["hooks": .object([
            "Stop": .array([.object(["hooks": .array([ClaudeHookConfig.hookDefinition(binaryPath: binary)])])]),
        ])])
        XCTAssertFalse(ClaudeHookConfig.isInstalled(in: partial))
    }

    /// The snippet the user sees is the same object that gets written.
    func testSnippetMatchesContribution() throws {
        let snippet = ClaudeHookConfig.renderedSnippet(binaryPath: binary)
        let parsed = try JSONValue.parse(Data(snippet.utf8))
        XCTAssertEqual(parsed["hooks"], ClaudeHookConfig.contribution(binaryPath: binary))
        XCTAssertTrue(snippet.contains("\n"), "snippet should be pretty-printed")
    }

    /// The file wrapper reads an absent file as empty, writes atomically, and
    /// round-trips install and uninstall on disk.
    func testSettingsFileRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notchd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = ClaudeSettingsFile.at(dir.appendingPathComponent("settings.json"))
        XCTAssertTrue(file.vendorPresent)
        XCTAssertEqual(try file.read(), .object([:]))
        XCTAssertFalse(try file.isInstalled())

        try file.write(existing)
        try file.install(binaryPath: binary)
        XCTAssertTrue(try file.isInstalled())
        try file.uninstall()
        XCTAssertEqual(try file.read(), existing)
    }

    /// A settings file that is not JSON is reported, never overwritten.
    func testUnparseableSettingsAreReported() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notchd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        try Data("{ not json".utf8).write(to: url)
        let file = ClaudeSettingsFile.at(url)
        XCTAssertThrowsError(try file.install(binaryPath: binary))
        XCTAssertEqual(try Data(contentsOf: url), Data("{ not json".utf8))
    }

    /// CLAUDE_CONFIG_DIR relocates the file the way Claude Code does, and
    /// GEMINI_CLI_HOME the way Gemini CLI does.
    func testDefaultLocationHonoursConfigDir() {
        XCTAssertEqual(ClaudeSettingsFile.defaultURL(environment: ["CLAUDE_CONFIG_DIR": "/tmp/work"]).path, "/tmp/work/settings.json")
        XCTAssertTrue(ClaudeSettingsFile.defaultURL(environment: [:]).path.hasSuffix("/.claude/settings.json"))
        XCTAssertEqual(HookVendor.gemini.defaultURL(environment: ["GEMINI_CLI_HOME": "/tmp/g"]).path, "/tmp/g/.gemini/settings.json")
        XCTAssertTrue(HookVendor.gemini.defaultURL(environment: [:]).path.hasSuffix("/.gemini/settings.json"))
    }

    /// An entry left by an earlier build's hook binary is recognised as ours
    /// for removal and replaced on install, but never counts as installed.
    func testLegacyEntriesAreReplacedNotCounted() {
        let legacy = JSONValue.object(["hooks": .object([
            "PreToolUse": .array([.object(["hooks": .array([
                .object(["type": .string("command"), "command": .string("\"/old/Rewind.app/Contents/MacOS/rewind-hook\" claude")]),
            ])])]),
        ])])
        XCTAssertFalse(ClaudeHookConfig.isInstalled(in: legacy))
        XCTAssertEqual(ClaudeHookConfig.removing(from: legacy), .object([:]))
        let replaced = ClaudeHookConfig.installing(into: legacy, binaryPath: binary)
        XCTAssertTrue(ClaudeHookConfig.isInstalled(in: replaced))
        XCTAssertFalse(replaced.serializedString.contains("rewind-hook"))
    }

    /// Gemini's entries use Gemini's event names and slug, and install and
    /// remove the same way, without disturbing a Claude-style hook that
    /// happens to live in the same document.
    func testGeminiEntries() throws {
        let installed = HookSettings.installing(into: existing, vendor: .gemini, binaryPath: binary)
        XCTAssertTrue(HookSettings.isInstalled(in: installed, vendor: .gemini))
        XCTAssertFalse(HookSettings.isInstalled(in: installed, vendor: .claude))
        let hooks = installed["hooks"]?.objectValue ?? [:]
        XCTAssertEqual(Set(hooks.keys), Set(HookVendor.gemini.events + ["PreToolUse"]))
        let definition = hooks["BeforeTool"]?.arrayValue?.first?["hooks"]?.arrayValue?.first
        XCTAssertEqual(definition?["command"]?.stringValue, "\"\(binary)\" gemini")
        XCTAssertEqual(HookSettings.removing(from: installed), existing)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notchd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = HookSettingsFile(url: dir.appendingPathComponent("settings.json"), vendor: .gemini)
        try file.install(binaryPath: binary)
        XCTAssertTrue(try file.isInstalled())
        try file.uninstall()
        XCTAssertEqual(try file.read(), .object([:]))
    }
}
