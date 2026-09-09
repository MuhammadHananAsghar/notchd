// GuardTests.swift
// Guard mode: globs match the way the card says, the policy judges only
// hook-recorded tool.before events with deny beating ask, the ingest keeps
// the decision on the event and skips the checkpoint for a denied call, the
// server answers the hook with the decision, and the real hook binary turns
// each decision into each vendor's own refusal.

import XCTest
@testable import Notchd

final class GuardRuleTests: XCTestCase {
    /// Path globs: one segment for `*`, any depth for `**`, the directory
    /// itself for a trailing `/**`, and `~` as home.
    func testPathGlobs() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let ssh = GuardRule(subject: .path, pattern: "~/.ssh/**", action: .deny)
        XCTAssertTrue(ssh.matches(paths: [home + "/.ssh/id_ed25519"], command: nil))
        XCTAssertTrue(ssh.matches(paths: [home + "/.ssh"], command: nil))
        XCTAssertFalse(ssh.matches(paths: [home + "/.sshx"], command: nil))
        XCTAssertFalse(ssh.matches(paths: ["/etc/ssh/config"], command: nil))
        let env = GuardRule(subject: .path, pattern: "**/.env", action: .deny)
        XCTAssertTrue(env.matches(paths: ["/Users/me/proj/.env"], command: nil))
        XCTAssertFalse(env.matches(paths: ["/Users/me/proj/.env.example"], command: nil))
        let segment = GuardRule(subject: .path, pattern: "/Users/me/*/secrets.txt", action: .deny)
        XCTAssertTrue(segment.matches(paths: ["/Users/me/proj/secrets.txt"], command: nil))
        XCTAssertFalse(segment.matches(paths: ["/Users/me/a/b/secrets.txt"], command: nil))
    }

    /// Command globs match anywhere in the command line.
    func testCommandGlobs() {
        let rm = GuardRule(subject: .command, pattern: "rm -rf *", action: .ask)
        XCTAssertTrue(rm.matches(paths: [], command: "cd build && rm -rf dist"))
        XCTAssertFalse(rm.matches(paths: [], command: "rm build/x"))
        XCTAssertFalse(rm.matches(paths: [], command: nil))
        let force = GuardRule(subject: .command, pattern: "git push*--force*", action: .ask)
        XCTAssertTrue(force.matches(paths: [], command: "git push origin main --force-with-lease"))
        XCTAssertFalse(force.matches(paths: [], command: "git push origin main"))
        let dot = GuardRule(subject: .command, pattern: "rm -rf /*", action: .deny)
        XCTAssertTrue(dot.matches(paths: [], command: "rm -rf /"))
        XCTAssertFalse(dot.matches(paths: [], command: "rm -rf ./build"))
    }

    /// The reason names the rule and carries the note.
    func testReason() {
        let rule = GuardRule(subject: .path, pattern: "~/.ssh/**", action: .deny, note: "Keys stay put.")
        XCTAssertEqual(rule.reason, "Notchd guard rule: path matches \"~/.ssh/**\". Keys stay put.")
    }

    /// Rules round trip through JSON with their ids.
    func testDocumentRoundTrip() throws {
        let document = GuardDocument(enabled: true, rules: GuardRule.suggested)
        let data = try JSONEncoder().encode(document)
        XCTAssertEqual(try JSONDecoder().decode(GuardDocument.self, from: data), document)
    }
}

final class GuardPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_757_400_000)

    private func before(tool: String, command: String? = nil, paths: [String], fidelity: Fidelity = .official, kind: NotchdEvent.Kind = .toolBefore) -> NotchdEvent {
        NotchdEvent(kind: kind, vendor: "claude", session: "s", cwd: "/p", tool: tool, toolUseId: "t",
                    args: command.map { .object(["command": .string($0)]) }, paths: paths, ts: t0, fidelity: fidelity)
    }

    /// Off means allow; on, deny beats ask, and only tool.before is judged.
    func testEvaluation() {
        let rules = [
            GuardRule(subject: .command, pattern: "rm -rf *", action: .ask),
            GuardRule(subject: .path, pattern: "/secret/**", action: .deny, note: "No."),
        ]
        let off = GuardPolicy(enabled: false, rules: rules)
        XCTAssertEqual(off.evaluate(before(tool: "Bash", command: "rm -rf x", paths: ["/secret"])).decision, .allow)
        let on = GuardPolicy(enabled: true, rules: rules)
        XCTAssertEqual(on.evaluate(before(tool: "Bash", command: "rm -rf x", paths: ["/p"])).decision, .ask(rules[0].reason))
        XCTAssertEqual(on.evaluate(before(tool: "Bash", command: "rm -rf x", paths: ["/secret/k"])).decision, .deny(rules[1].reason))
        XCTAssertEqual(on.evaluate(before(tool: "Bash", command: "ls", paths: ["/p"])).decision, .allow)
        XCTAssertEqual(on.evaluate(before(tool: "Bash", command: "rm -rf x", paths: ["/p"], kind: .toolAfter)).decision, .allow)
        XCTAssertEqual(on.evaluate(before(tool: "exec", command: "rm -rf x", paths: ["/p"], fidelity: .derived)).decision, .allow, "a derived call has already run")
    }

    /// The policy persists to its file and loads back.
    func testPersistence() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notchd-guard-\(UUID().uuidString)/guard.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let policy = GuardPolicy(url: url)
        XCTAssertFalse(policy.isEnabled)
        try policy.update(GuardDocument(enabled: true, rules: [GuardRule(subject: .command, pattern: "sudo *", action: .deny)]))
        let reloaded = GuardPolicy(url: url)
        XCTAssertTrue(reloaded.isEnabled)
        XCTAssertEqual(reloaded.rules.map(\.pattern), ["sudo *"])
    }

    /// The decision's wire line and ledger form.
    func testDecisionForms() {
        XCTAssertEqual(HookDecision.allow.line, "ok\n")
        XCTAssertEqual(HookDecision.deny("a\nb").line, "deny a b\n")
        XCTAssertEqual(HookDecision.ask("why").meta?["decision"]?.stringValue, "ask")
        XCTAssertNil(HookDecision.allow.meta)
    }
}

final class GuardIngestTests: XCTestCase {
    /// A denied call is recorded with the decision, the observers are not
    /// run, and the hook is told to deny; an allowed call runs as before.
    func testDeniedCallIsRecordedButNotCheckpointed() throws {
        let ledger = try Ledger(path: ":memory:")
        final class Counting: EventObserver {
            var seen = 0
            func observe(_ row: EventRow, event: NotchdEvent) throws { seen += 1 }
        }
        let observer = Counting()
        let policy = GuardPolicy(enabled: true, rules: [GuardRule(subject: .command, pattern: "rm -rf *", action: .deny, note: "No.")])
        let ingest = EventIngest(ledger: ledger, observers: [observer], guardPolicy: policy)
        let line = { (command: String) in
            Data("""
            {"v":1,"vendor":"claude","received_at":1757400000,"raw":{"session_id":"g1","transcript_path":"/t","cwd":"/p","hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"\(command)"}}}
            """.utf8)
        }
        let denied = ingest.handle(line("rm -rf build"))
        guard case .deny(let reason) = denied else { return XCTFail("expected deny, got \(denied)") }
        XCTAssertTrue(reason.contains("rm -rf *"))
        XCTAssertEqual(observer.seen, 0)
        let session = try XCTUnwrap(ledger.sessions().first)
        let event = try XCTUnwrap(ledger.events(sessionId: session.id).first)
        XCTAssertEqual(event.meta?["guard"]?["decision"]?.stringValue, "deny")
        XCTAssertEqual(ingest.handle(line("ls")), .allow)
        XCTAssertEqual(observer.seen, 1)
    }
}

final class GuardServerAndHookTests: XCTestCase {
    /// The server writes the decider's answer back.
    func testServerAnswersWithTheDecision() throws {
        let path = NSTemporaryDirectory() + "notchd-guard-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path) }
        let server = EventSocketServer.deciding(path: path) { _ in HookDecision.deny("nope") }
        try server.start()
        defer { server.stop() }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = EventSocketServer.address(for: path)
        XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }, 0)
        let bytes = Array("{\"v\":1}\n".utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        shutdown(fd, SHUT_WR)
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(fd, &buffer, buffer.count)
        XCTAssertEqual(String(decoding: buffer[0..<max(0, Int(count))], as: UTF8.self), "deny nope\n")
    }

    /// The real hook turns a deny into each vendor's refusal: Claude Code
    /// gets a JSON decision on stdout, Gemini a blocking status with the
    /// reason on stderr, Cursor a permission object, a native emitter a plain
    /// decision; an ask reaches Claude Code as ask.
    func testHookTranslatesDecisions() throws {
        let hook = try XCTUnwrap(Bundle(for: Updater.self).url(forAuxiliaryExecutable: "notchd-hook"))
        let home = "/tmp/notchd-guard-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        var next = HookDecision.deny("keys stay put")
        let lock = NSLock()
        let server = EventSocketServer.deciding(path: home + "/" + URL(fileURLWithPath: NotchdPaths.socketPath).lastPathComponent) { _ in
            lock.lock()
            defer { lock.unlock() }
            return next
        }
        try server.start()
        defer { server.stop() }
        func run(_ vendor: String) throws -> (status: Int32, out: String, err: String) {
            let process = Process()
            process.executableURL = hook
            process.arguments = [vendor]
            process.environment = ["NOTCHD_HOME": home]
            let input = Pipe(), out = Pipe(), err = Pipe()
            process.standardInput = input
            process.standardOutput = out
            process.standardError = err
            try process.run()
            input.fileHandleForWriting.write(Data("{\"session_id\":\"s\",\"hook_event_name\":\"PreToolUse\",\"cwd\":\"/\"}".utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                    String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        let claude = try run("claude")
        XCTAssertEqual(claude.status, 0)
        let claudeJSON = try JSONValue.parse(Data(claude.out.utf8))
        XCTAssertEqual(claudeJSON["hookSpecificOutput"]?["permissionDecision"]?.stringValue, "deny")
        XCTAssertEqual(claudeJSON["hookSpecificOutput"]?["permissionDecisionReason"]?.stringValue, "keys stay put")
        let gemini = try run("gemini")
        XCTAssertEqual(gemini.status, 2)
        XCTAssertEqual(gemini.err.trimmingCharacters(in: .whitespacesAndNewlines), "keys stay put")
        let cursor = try run("cursor")
        XCTAssertEqual(try JSONValue.parse(Data(cursor.out.utf8))["permission"]?.stringValue, "deny")
        let native = try run("emit")
        XCTAssertEqual(try JSONValue.parse(Data(native.out.utf8))["decision"]?.stringValue, "deny")
        lock.lock()
        next = .ask("sure?")
        lock.unlock()
        let asked = try run("claude")
        XCTAssertEqual(try JSONValue.parse(Data(asked.out.utf8))["hookSpecificOutput"]?["permissionDecision"]?.stringValue, "ask")
        lock.lock()
        next = .allow
        lock.unlock()
        let allowed = try run("claude")
        XCTAssertEqual(allowed.status, 0)
        XCTAssertEqual(allowed.out, "")
    }
}
