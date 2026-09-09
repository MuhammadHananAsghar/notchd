// IntegrationTests.swift
// The OpenCode plugin and Cursor's hooks file: what Install writes, that it
// carries the hook path, that Remove restores the file, and that the Cursor
// adapter maps the documented payloads onto events. The plugin's JavaScript
// is syntax-checked with whichever of bun or node the machine has.

import XCTest
@testable import Notchd

final class OpenCodePluginTests: XCTestCase {
    private var dir: URL!
    private let binary = "/Applications/Notchd.app/Contents/MacOS/notchd-hook"

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notchd-opencode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("opencode"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private var plugin: OpenCodePlugin {
        OpenCodePlugin(url: dir.appendingPathComponent("opencode/plugin/notchd.js"))
    }

    /// Install writes the plugin with the hook path; Remove deletes it.
    func testInstallAndRemove() throws {
        XCTAssertTrue(plugin.vendorPresent)
        XCTAssertFalse(try plugin.isInstalled())
        try plugin.install(binaryPath: binary)
        XCTAssertTrue(try plugin.isInstalled())
        let text = try String(contentsOf: plugin.url, encoding: .utf8)
        XCTAssertTrue(text.contains("const HOOK = \"\(binary)\""))
        XCTAssertTrue(text.contains("export const NotchdPlugin"))
        XCTAssertTrue(text.contains("\"tool.execute.before\""))
        XCTAssertTrue(text.contains("\"tool.execute.after\""))
        XCTAssertEqual(plugin.snippet(binaryPath: binary), text)
        try plugin.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: plugin.url.path))
        XCTAssertFalse(try plugin.isInstalled())
    }

    /// A plugin written by an earlier build reads as needing Install again,
    /// and Install replaces it.
    func testStalePluginIsNotInstalled() throws {
        try plugin.install(binaryPath: binary)
        let current = try String(contentsOf: plugin.url, encoding: .utf8)
        let stale = current.replacingOccurrences(of: OpenCodePlugin.versionLine, with: "const NOTCHD_PLUGIN_VERSION = 1;")
        try Data(stale.utf8).write(to: plugin.url)
        XCTAssertFalse(try plugin.isInstalled())
        try plugin.install(binaryPath: binary)
        XCTAssertTrue(try plugin.isInstalled())
        XCTAssertTrue(try String(contentsOf: plugin.url, encoding: .utf8).contains("session.idle"))
    }

    /// The plugin directory's absence means OpenCode is absent.
    func testVendorPresence() {
        XCTAssertFalse(OpenCodePlugin(url: dir.appendingPathComponent("nope/plugin/notchd.js")).vendorPresent)
        XCTAssertEqual(OpenCodePlugin.defaultURL(environment: ["XDG_CONFIG_HOME": "/tmp/xdg"]).path, "/tmp/xdg/opencode/plugin/notchd.js")
        XCTAssertTrue(OpenCodePlugin.defaultURL(environment: [:]).path.hasSuffix("/.config/opencode/plugin/notchd.js"))
    }

    /// The generated JavaScript parses, checked with a runtime when one is
    /// available on the machine.
    func testGeneratedJavaScriptParses() throws {
        try plugin.install(binaryPath: binary)
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", NSHomeDirectory() + "/.bun/bin/bun"]
        guard let runtime = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("no JavaScript runtime on this machine")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: runtime)
        process.arguments = runtime.hasSuffix("bun") ? ["build", "--no-bundle", plugin.url.path] : ["--check", plugin.url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(runtime) rejected the generated plugin")
    }
}

final class CursorHooksTests: XCTestCase {
    private let binary = "/Applications/Notchd.app/Contents/MacOS/notchd-hook"

    private var existing: JSONValue {
        .object(["version": .number(1), "hooks": .object([
            "beforeShellExecution": .array([.object(["command": .string("/usr/local/bin/guard")])]),
        ])])
    }

    /// Install adds one entry per event and keeps other people's; Remove
    /// restores the document exactly.
    func testInstallKeepsOthersAndRemoveRestores() {
        let installed = CursorHooksFile.installing(into: existing, binaryPath: binary)
        XCTAssertTrue(CursorHooksFile.isInstalled(in: installed))
        let shell = installed["hooks"]?["beforeShellExecution"]?.arrayValue ?? []
        XCTAssertEqual(shell.count, 2)
        XCTAssertEqual(shell[0]["command"]?.stringValue, "/usr/local/bin/guard")
        XCTAssertEqual(shell[1]["command"]?.stringValue, "\"\(binary)\" cursor")
        XCTAssertEqual(installed["hooks"]?["afterFileEdit"]?.arrayValue?.count, 1)
        XCTAssertEqual(CursorHooksFile.removing(from: installed), existing)
    }

    /// From nothing, Install writes a version and Remove leaves nothing.
    func testFromEmpty() {
        let installed = CursorHooksFile.installing(into: .object([:]), binaryPath: binary)
        XCTAssertEqual(installed["version"]?.numberValue, 1)
        XCTAssertEqual(CursorHooksFile.removing(from: installed), .object([:]))
        XCTAssertTrue(CursorHooksFile.installing(into: installed, binaryPath: "/elsewhere/notchd-hook").serializedString.contains("/elsewhere/"))
    }

    /// The file wrapper round trips on disk.
    func testFileRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notchd-cursor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = CursorHooksFile(url: dir.appendingPathComponent("hooks.json"))
        XCTAssertTrue(file.vendorPresent)
        XCTAssertFalse(try file.isInstalled())
        try file.install(binaryPath: binary)
        XCTAssertTrue(try file.isInstalled())
        let parsed = try JSONValue.parse(Data(file.snippet(binaryPath: binary).utf8))
        XCTAssertEqual(parsed["hooks"], CursorHooksFile.contribution(binaryPath: binary))
        try file.uninstall()
        XCTAssertEqual(try file.read(), .object([:]))
    }
}

final class CursorAdapterTests: XCTestCase {
    private let adapter = CursorAdapter()
    private let received = Date(timeIntervalSince1970: 1_757_400_000)

    private func payload(_ extra: [String: JSONValue]) -> JSONValue {
        var object: [String: JSONValue] = [
            "conversation_id": .string("conv-1"), "generation_id": .string("gen-1"),
            "workspace_roots": .array([.string("/Users/me/proj")]),
        ]
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }

    /// A shell command before and after, with the cwd declared.
    func testShellHooks() throws {
        let before = try XCTUnwrap(adapter.events(from: payload([
            "hook_event_name": .string("beforeShellExecution"), "command": .string("rm -rf build"), "cwd": .string("/Users/me/proj/sub"),
        ]), receivedAt: received).first)
        XCTAssertEqual(before.kind, .toolBefore)
        XCTAssertEqual(before.vendor, "cursor")
        XCTAssertEqual(before.session, "conv-1")
        XCTAssertEqual(before.tool, "shell")
        XCTAssertEqual(before.cwd, "/Users/me/proj/sub")
        XCTAssertEqual(before.paths, ["/Users/me/proj/sub"])
        XCTAssertEqual(before.args?["command"]?.stringValue, "rm -rf build")
        let after = try XCTUnwrap(adapter.events(from: payload([
            "hook_event_name": .string("afterShellExecution"), "command": .string("rm -rf build"), "output": .string("ok"),
        ]), receivedAt: received).first)
        XCTAssertEqual(after.kind, .toolAfter)
        XCTAssertEqual(after.cwd, "/Users/me/proj", "without cwd the first workspace root stands in")
        XCTAssertEqual(after.result?["output"]?.stringValue, "ok")
    }

    /// A file edit is an after-only tool call declaring the file.
    func testFileEdit() throws {
        let event = try XCTUnwrap(adapter.events(from: payload([
            "hook_event_name": .string("afterFileEdit"), "file_path": .string("src/a.ts"),
            "edits": .array([.object(["old_string": .string("a"), "new_string": .string("b")])]),
        ]), receivedAt: received).first)
        XCTAssertEqual(event.kind, .toolAfter)
        XCTAssertEqual(event.tool, "edit")
        XCTAssertEqual(event.paths, ["/Users/me/proj/src/a.ts"])
        XCTAssertNil(event.toolUseId)
    }

    /// Prompts and stops are notes; MCP calls are tool calls with no paths.
    func testNotesAndMCP() throws {
        let prompt = try XCTUnwrap(adapter.events(from: payload(["hook_event_name": .string("beforeSubmitPrompt"), "prompt": .string("fix it")]), receivedAt: received).first)
        XCTAssertEqual(prompt.kind, .note)
        XCTAssertEqual(prompt.meta?["prompt"]?.stringValue, "fix it")
        let stop = try XCTUnwrap(adapter.events(from: payload(["hook_event_name": .string("stop"), "status": .string("completed")]), receivedAt: received).first)
        XCTAssertEqual(stop.meta?["status"]?.stringValue, "completed")
        let mcp = try XCTUnwrap(adapter.events(from: payload(["hook_event_name": .string("beforeMCPExecution"), "tool_name": .string("search"), "tool_input": .object(["q": .string("x")])]), receivedAt: received).first)
        XCTAssertEqual(mcp.tool, "mcp:search")
        XCTAssertEqual(mcp.paths, [])
    }

    /// Missing fields are named.
    func testMissingFields() {
        XCTAssertThrowsError(try adapter.events(from: .object(["hook_event_name": .string("stop")]), receivedAt: received)) { error in
            XCTAssertEqual(error as? AdapterError, .missingField("conversation_id"))
        }
    }
}

final class HookBinaryTests: XCTestCase {
    /// The hook inside this bundle and the app agree on where the socket is:
    /// with NOTCHD_HOME pointing at a directory where a server listens at the
    /// app's socket name, an envelope arrives and is acknowledged.
    func testHookReachesTheAppsSocket() throws {
        let hook = try XCTUnwrap(Bundle(for: Updater.self).url(forAuxiliaryExecutable: "notchd-hook"))
        let home = "/tmp/notchd-hook-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let socketName = URL(fileURLWithPath: NotchdPaths.socketPath).lastPathComponent
        let received = expectation(description: "envelope")
        var line = Data()
        let server = EventSocketServer(path: home + "/" + socketName) { data in
            line = data
            received.fulfill()
        }
        try server.start()
        defer { server.stop() }
        let process = Process()
        process.executableURL = hook
        process.arguments = ["claude"]
        process.environment = ["NOTCHD_HOME": home]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        let started = Date()
        try process.run()
        input.fileHandleForWriting.write(Data("{\"session_id\":\"s\",\"hook_event_name\":\"Stop\",\"cwd\":\"/\"}".utf8))
        try input.fileHandleForWriting.close()
        wait(for: [received], timeout: 5)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the hook should return as soon as it is acknowledged")
        let envelope = try Envelope.parse(line)
        XCTAssertEqual(envelope.vendor, "claude")
        XCTAssertEqual(envelope.raw["session_id"]?.stringValue, "s")
    }

    /// The hook inside this bundle answers Cursor's before-hooks with an
    /// allow, says nothing to anyone else, and exits 0 with no server.
    func testCursorGetsAnAllowAndOthersGetSilence() throws {
        let hook = try XCTUnwrap(Bundle(for: Updater.self).url(forAuxiliaryExecutable: "notchd-hook"))
        func run(_ vendor: String) throws -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = hook
            process.arguments = [vendor]
            process.environment = ["NOTCHD_HOME": "/tmp/notchd-no-server-\(UUID().uuidString)"]
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            input.fileHandleForWriting.write(Data("{\"conversation_id\":\"c\",\"hook_event_name\":\"beforeShellExecution\"}".utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        let cursor = try run("cursor")
        XCTAssertEqual(cursor.status, 0)
        XCTAssertEqual(cursor.output.trimmingCharacters(in: .whitespacesAndNewlines), "{\"permission\":\"allow\"}")
        let claude = try run("claude")
        XCTAssertEqual(claude.status, 0)
        XCTAssertEqual(claude.output, "")
    }
}
