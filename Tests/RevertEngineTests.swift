// RevertEngineTests.swift
// A revert must return every path in scope to its earliest recorded state and
// verify it, delete what was created, recreate what was deleted, checkpoint
// the current state first so the revert can itself be reverted, leave
// unattributed changes alone unless asked, and report partial when a copy is
// missing rather than claim success.

import XCTest
@testable import Notchd

final class RevertEngineTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var ledger: Ledger!
    private var store: ObjectStore!
    private var snapshotter: Snapshotter!
    private var recorder: Recorder!
    private var engine: RevertEngine!
    private let t0 = Date(timeIntervalSince1970: 1_757_400_000)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notchd-rev-\(UUID().uuidString)")
        project = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        ledger = try Ledger(path: ":memory:")
        store = try ObjectStore(root: root.appendingPathComponent("store"))
        snapshotter = Snapshotter(store: store)
        recorder = Recorder(ledger: ledger, store: store, snapshotter: snapshotter)
        engine = RevertEngine(ledger: ledger, store: store, snapshotter: snapshotter)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ relative: String, _ text: String) throws -> String {
        let url = project.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url.standardizedFileURL.path
    }

    private func read(_ relative: String) -> String? {
        (try? Data(contentsOf: project.appendingPathComponent(relative))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Records a tool call around a closure that mutates the project.
    private func agentRuns(_ toolUseId: String, at offset: TimeInterval, _ mutate: () throws -> Void) throws {
        let before = NotchdEvent(kind: .toolBefore, vendor: "claude", session: "s1", cwd: project.path, tool: "Bash", toolUseId: toolUseId,
                                 args: .object(["command": .string("cmd \(toolUseId)")]), paths: [project.path],
                                 ts: t0.addingTimeInterval(offset), fidelity: .official)
        try recorder.observe(try ledger.record(before), event: before)
        Thread.sleep(forTimeInterval: 0.02)
        try mutate()
        let after = NotchdEvent(kind: .toolAfter, vendor: "claude", session: "s1", cwd: project.path, tool: "Bash", toolUseId: toolUseId,
                                args: .object(["command": .string("cmd \(toolUseId)")]), paths: [project.path],
                                ts: t0.addingTimeInterval(offset + 1), fidelity: .official)
        try recorder.observe(try ledger.record(after), event: after)
    }

    private var wholeRange: RevertScope {
        RevertScope(since: t0.addingTimeInterval(-1), until: t0.addingTimeInterval(1000), sessionIds: nil, includeUnattributed: false)
    }

    /// The headline scenario: an agent deletes src, and the revert brings every
    /// file back bit for bit.
    func testRecoversADeletedDirectory() throws {
        try write("src/a.swift", "let a = 1\n")
        try write("src/b.swift", "let b = 2\n")
        try agentRuns("rm", at: 0) {
            try FileManager.default.removeItem(at: self.project.appendingPathComponent("src"))
        }
        XCTAssertNil(read("src/a.swift"))

        let plan = try engine.plan(wholeRange)
        XCTAssertEqual(plan.targets.count, 2)
        XCTAssertEqual(plan.commands, ["cmd rm"])
        let result = try engine.apply(plan, now: t0.addingTimeInterval(10))
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertEqual(result.restored.count, 2)
        XCTAssertEqual(read("src/a.swift"), "let a = 1\n")
        XCTAssertEqual(read("src/b.swift"), "let b = 2\n")
        XCTAssertEqual(try ledger.reverts().first?.result, .complete)
    }

    /// Several changes to one path revert to the earliest state, and files
    /// the agent created are removed.
    func testRevertsToEarliestStateAndRemovesCreatedFiles() throws {
        try write("a.txt", "original")
        try agentRuns("one", at: 0) { try self.write("a.txt", "edit one") }
        try agentRuns("two", at: 10) {
            try self.write("a.txt", "edit two")
            try self.write("made.txt", "new")
        }
        let result = try engine.apply(try engine.plan(wholeRange), now: t0.addingTimeInterval(20))
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertEqual(read("a.txt"), "original")
        XCTAssertNil(read("made.txt"))
    }

    /// A narrower range only undoes what is inside it.
    func testRangeLimitsWhatIsUndone() throws {
        try write("a.txt", "original")
        try agentRuns("one", at: 0) { try self.write("a.txt", "edit one") }
        try agentRuns("two", at: 10) { try self.write("a.txt", "edit two") }
        let scope = RevertScope(since: t0.addingTimeInterval(9), until: t0.addingTimeInterval(20), sessionIds: nil, includeUnattributed: false)
        let result = try engine.apply(try engine.plan(scope), now: t0.addingTimeInterval(30))
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertEqual(read("a.txt"), "edit one")
    }

    /// A revert is recorded as changes of its own, so reverting the revert
    /// puts the agent's work back.
    func testARevertCanBeReverted() throws {
        try write("a.txt", "original")
        try agentRuns("one", at: 0) { try self.write("a.txt", "agent") }
        try engine.apply(try engine.plan(wholeRange), now: t0.addingTimeInterval(20))
        XCTAssertEqual(read("a.txt"), "original")
        let undoScope = RevertScope(since: t0.addingTimeInterval(15), until: t0.addingTimeInterval(25), sessionIds: nil, includeUnattributed: false)
        let redo = try engine.apply(try engine.plan(undoScope), now: t0.addingTimeInterval(30))
        XCTAssertEqual(redo.outcome, .complete)
        XCTAssertEqual(read("a.txt"), "agent")
    }

    /// The current state is checkpointed before anything is touched.
    func testPreRevertCheckpointIsTaken() throws {
        try write("a.txt", "original")
        try agentRuns("one", at: 0) { try self.write("a.txt", "agent") }
        let result = try engine.apply(try engine.plan(wholeRange), now: t0.addingTimeInterval(20))
        let checkpoint = try XCTUnwrap(ledger.checkpoint(eventId: result.eventId))
        let manifest = try XCTUnwrap(store.manifest(checkpoint.manifestHash))
        XCTAssertEqual(manifest.entries[project.appendingPathComponent("a.txt").standardizedFileURL.path]?.hash, ObjectStore.hash(Data("agent".utf8)))
    }

    /// Unattributed changes are excluded unless asked for.
    func testUnattributedChangesAreLeftAloneByDefault() throws {
        let path = try write("mine.txt", "mine")
        _ = try snapshotter.snapshot(roots: [project.path])
        Thread.sleep(forTimeInterval: 0.02)
        try write("mine.txt", "mine, edited by hand")
        recorder.observeExternal([path])
        let settled = expectation(description: "recorded")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        let now = Date()
        let excluding = RevertScope(since: now.addingTimeInterval(-60), until: now.addingTimeInterval(60), sessionIds: nil, includeUnattributed: false)
        XCTAssertTrue(try engine.plan(excluding).isEmpty)
        let including = RevertScope(since: now.addingTimeInterval(-60), until: now.addingTimeInterval(60), sessionIds: nil, includeUnattributed: true)
        let result = try engine.apply(try engine.plan(including))
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertEqual(read("mine.txt"), "mine")
    }

    /// A missing earlier copy is reported, and the result is partial.
    func testMissingCopyMakesTheRevertPartial() throws {
        try write("a.txt", "original")
        try write("b.txt", "b-original")
        try agentRuns("one", at: 0) {
            try self.write("a.txt", "agent a")
            try self.write("b.txt", "agent b")
        }
        try FileManager.default.removeItem(at: store.url(for: ObjectStore.hash(Data("original".utf8))))
        let plan = try engine.plan(wholeRange)
        let impossible = plan.targets.filter { if case .impossible = $0.action { return true } else { return false } }
        XCTAssertEqual(impossible.count, 1)
        let result = try engine.apply(plan, now: t0.addingTimeInterval(20))
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertEqual(result.failed.map(\.path), [project.appendingPathComponent("a.txt").standardizedFileURL.path])
        XCTAssertEqual(read("b.txt"), "b-original")
        XCTAssertEqual(read("a.txt"), "agent a")
        XCTAssertTrue(try ledger.reverts().first?.note.contains("missing") ?? false)
    }

    /// Restoring keeps the file's mode.
    func testModeIsRestored() throws {
        let path = try write("run.sh", "#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        try agentRuns("one", at: 0) {
            try FileManager.default.removeItem(atPath: path)
        }
        try engine.apply(try engine.plan(wholeRange), now: t0.addingTimeInterval(20))
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)
    }

    /// The scope is recorded on the revert.
    func testScopeIsRecorded() throws {
        try write("a.txt", "o")
        try agentRuns("one", at: 0) { try self.write("a.txt", "x") }
        try engine.apply(try engine.plan(wholeRange), now: t0.addingTimeInterval(20))
        let revert = try XCTUnwrap(ledger.reverts().first)
        XCTAssertEqual(revert.scope["include_unattributed"]?.boolValue, false)
        XCTAssertNotNil(revert.scope["since"]?.stringValue)
    }
}
