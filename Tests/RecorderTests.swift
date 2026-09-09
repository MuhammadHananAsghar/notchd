// RecorderTests.swift
// The recorder must checkpoint before a mutating call, diff after it, pair the
// two by tool call id or by order, survive a missing before-event, drop open
// calls at session end, and record watcher reports as unattributed only when
// no tool call could explain them.

import XCTest
@testable import Notchd

final class RecorderTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var ledger: Ledger!
    private var store: ObjectStore!
    private var snapshotter: Snapshotter!
    private var recorder: Recorder!
    private var ingest: EventIngest!
    private let t0 = Date(timeIntervalSince1970: 1_757_400_000)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notchd-rec-\(UUID().uuidString)")
        project = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        ledger = try Ledger(path: ":memory:")
        store = try ObjectStore(root: root.appendingPathComponent("store"))
        snapshotter = Snapshotter(store: store)
        recorder = Recorder(ledger: ledger, store: store, snapshotter: snapshotter)
        ingest = EventIngest(ledger: ledger, observers: [recorder])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes a file under the project and returns its absolute path.
    @discardableResult
    private func write(_ relative: String, _ text: String) throws -> String {
        let url = project.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url.standardizedFileURL.path
    }

    /// Sends one event straight to the recorder via the ledger.
    @discardableResult
    private func send(_ kind: NotchdEvent.Kind, tool: String? = nil, toolUseId: String? = nil, paths: [String] = [],
                      session: String = "s1", at offset: TimeInterval = 0) throws -> EventRow {
        let event = NotchdEvent(kind: kind, vendor: "claude", session: session, cwd: project.path, tool: tool, toolUseId: toolUseId,
                                args: nil, paths: paths, ts: t0.addingTimeInterval(offset), fidelity: .official)
        let row = try ledger.record(event)
        try recorder.observe(row, event: event)
        return row
    }

    /// An Edit that changes a file yields one modify change on the after-event.
    func testEditIsRecordedAsAModify() throws {
        let file = try write("src/a.swift", "one")
        let before = try send(.toolBefore, tool: "Edit", toolUseId: "t1", paths: [file])
        XCTAssertNotNil(try ledger.checkpoint(eventId: before.id))
        Thread.sleep(forTimeInterval: 0.02)
        try write("src/a.swift", "two")
        let after = try send(.toolAfter, tool: "Edit", toolUseId: "t1", paths: [file], at: 1)
        let changes = try ledger.changes(eventId: after.id)
        XCTAssertEqual(changes.map(\.kind), [.modify])
        XCTAssertEqual(changes.first?.path, file)
        XCTAssertEqual(changes.first?.before?.hash, ObjectStore.hash(Data("one".utf8)))
        XCTAssertEqual(changes.first?.after?.hash, ObjectStore.hash(Data("two".utf8)))
        XCTAssertTrue(changes.first?.attributed ?? false)
        XCTAssertTrue(store.contains(changes.first!.before!.hash))
    }

    /// A Write to a path that did not exist is a create; a shell call that
    /// removes a directory yields deletes for every file in it.
    func testCreatesAndDeletesUnderAShellRoot() throws {
        try write("src/a.swift", "a")
        try write("src/b.swift", "b")
        try send(.toolBefore, tool: "Bash", toolUseId: "t2", paths: [project.path])
        try FileManager.default.removeItem(at: project.appendingPathComponent("src"))
        let created = try write("new.txt", "n")
        let after = try send(.toolAfter, tool: "Bash", toolUseId: "t2", paths: [project.path], at: 1)
        let changes = try ledger.changes(eventId: after.id)
        XCTAssertEqual(changes.map(\.kind), [.create, .delete, .delete])
        XCTAssertEqual(changes.first?.path, created)
    }

    /// An after-event with no before-event and no declared files records
    /// nothing rather than guessing.
    func testAfterWithoutBeforeOrPathsRecordsNothing() throws {
        let after = try send(.toolAfter, tool: "Edit", toolUseId: "orphan", paths: [])
        XCTAssertEqual(try ledger.changes(eventId: after.id), [])
    }

    /// A tool that only reports after it ran, such as Cursor's file edits,
    /// has its declared files compared with the last copy in the cache and
    /// recorded as its own attributed changes. A never-seen file has no
    /// earlier copy; a directory root declares nothing on its own.
    func testAfterOnlyToolRecordsFromTheCache() throws {
        let known = try write("known.txt", "before")
        _ = try snapshotter.snapshot(roots: [project.path])
        Thread.sleep(forTimeInterval: 0.02)
        try write("known.txt", "after")
        let fresh = try write("fresh.txt", "new")
        let after = try send(.toolAfter, tool: "edit", toolUseId: nil, paths: [known, fresh, project.path])
        let changes = try ledger.changes(eventId: after.id)
        XCTAssertEqual(changes.map(\.path), [fresh, known])
        XCTAssertEqual(changes.map(\.kind), [.create, .modify])
        XCTAssertEqual(changes[1].before?.hash, ObjectStore.hash(Data("before".utf8)))
        XCTAssertTrue(changes.allSatisfy(\.attributed))
        XCTAssertEqual(try ledger.unattributedChanges(), [])
    }

    /// Without tool call ids, the most recent open call is paired.
    func testPairsByOrderWhenNoToolUseId() throws {
        let file = try write("y.txt", "1")
        try send(.toolBefore, tool: "write", paths: [file])
        Thread.sleep(forTimeInterval: 0.02)
        try write("y.txt", "22")
        let after = try send(.toolAfter, tool: "write", paths: [file], at: 1)
        XCTAssertEqual(try ledger.changes(eventId: after.id).map(\.kind), [.modify])
    }

    /// A before-event recorded by an earlier run is found through the ledger.
    func testPairsThroughTheLedgerAfterARestart() throws {
        let file = try write("z.txt", "z")
        try send(.toolBefore, tool: "Edit", toolUseId: "t3", paths: [file])
        let fresh = Recorder(ledger: ledger, store: store, snapshotter: snapshotter)
        try write("z.txt", "zz")
        let event = NotchdEvent(kind: .toolAfter, vendor: "claude", session: "s1", cwd: project.path, tool: "Edit", toolUseId: "t3",
                                paths: [file], ts: t0.addingTimeInterval(1), fidelity: .official)
        let row = try ledger.record(event)
        try fresh.observe(row, event: event)
        XCTAssertEqual(try ledger.changes(eventId: row.id).map(\.kind), [.modify])
    }

    /// Open roots are reported while a call is open and cleared afterwards.
    func testOpenRootsFollowCalls() throws {
        try send(.toolBefore, tool: "Bash", toolUseId: "t4", paths: [project.path])
        XCTAssertEqual(recorder.openRoots, [project.standardizedFileURL.path])
        try send(.toolAfter, tool: "Bash", toolUseId: "t4", paths: [project.path], at: 1)
        XCTAssertEqual(recorder.openRoots, [])
    }

    /// Session end drops calls that never finished.
    func testSessionEndClosesOpenCalls() throws {
        try send(.toolBefore, tool: "Bash", toolUseId: "t5", paths: [project.path])
        try send(.sessionEnd, at: 1)
        XCTAssertEqual(recorder.openRoots, [])
    }

    /// The ingest pipeline runs the recorder before it answers.
    func testIngestRunsTheRecorder() throws {
        let file = try write("via-ingest.txt", "a")
        let line = { (event: String, extra: String) in
            Data("""
            {"v":1,"vendor":"claude","received_at":1757400000,"raw":{"session_id":"i1","transcript_path":"/t","cwd":"\(self.project.path)","hook_event_name":"\(event)","tool_name":"Edit","tool_use_id":"t6","tool_input":{"file_path":"\(file)"}\(extra)}}
            """.utf8)
        }
        ingest.ingest(line("PreToolUse", ""))
        try write("via-ingest.txt", "b")
        guard case .recorded(let ids) = ingest.ingest(line("PostToolUse", ",\"tool_response\":{}")) else { return XCTFail("not recorded") }
        XCTAssertEqual(try ledger.changes(eventId: ids[0]).map(\.kind), [.modify])
    }

    /// Watcher reports outside any open call become unattributed changes,
    /// compared against the last copy the cache knows.
    func testExternalChangesAreUnattributed() throws {
        let known = try write("known.txt", "before")
        _ = try snapshotter.snapshot(roots: [project.path])
        Thread.sleep(forTimeInterval: 0.02)
        try write("known.txt", "after")
        let fresh = try write("fresh.txt", "new")
        recorder.observeExternal([known, fresh])
        let settled = expectation(description: "recorded")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        let rows = try ledger.unattributedChanges()
        XCTAssertEqual(Set(rows.map(\.path)), [known, fresh])
        XCTAssertEqual(rows.first { $0.path == known }?.kind, .modify)
        XCTAssertEqual(rows.first { $0.path == known }?.before?.hash, ObjectStore.hash(Data("before".utf8)))
        XCTAssertEqual(rows.first { $0.path == fresh }?.kind, .create)
        XCTAssertFalse(rows[0].attributed)
    }

    /// A transcript-derived call whose checkpoint arrives after the edit
    /// claims the changes the watcher filed as nobody's, and records nothing
    /// twice.
    func testDerivedCallClaimsLateChanges() throws {
        let file = try write("late.py", "before")
        _ = try snapshotter.snapshot(roots: [project.path])
        Thread.sleep(forTimeInterval: 0.02)
        try write("late.py", "after, edited before Notchd heard of the call")
        recorder.observeExternal([file])
        let settled = expectation(description: "recorded")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(try ledger.unattributedChanges().count, 1)

        let callStart = Date().addingTimeInterval(-1)
        let before = NotchdEvent(kind: .toolBefore, vendor: "codex", session: "d1", cwd: project.path, tool: "exec", toolUseId: "c1",
                                 paths: [project.path], ts: callStart, fidelity: .derived)
        try recorder.observe(try ledger.record(before), event: before)
        let after = NotchdEvent(kind: .toolAfter, vendor: "codex", session: "d1", cwd: project.path, tool: "exec", toolUseId: "c1",
                                ts: callStart.addingTimeInterval(1), fidelity: .derived)
        let row = try ledger.record(after)
        try recorder.observe(row, event: after)

        let claimed = try ledger.changes(eventId: row.id)
        XCTAssertEqual(claimed.map(\.path), [file])
        XCTAssertEqual(claimed.first?.kind, .modify)
        XCTAssertEqual(claimed.first?.before?.hash, ObjectStore.hash(Data("before".utf8)))
        XCTAssertTrue(claimed.first?.attributed ?? false)
        XCTAssertEqual(try ledger.unattributedChanges(), [])
        XCTAssertEqual(try ledger.changes(since: .distantPast, includeUnattributed: true).count, 1, "not recorded twice")
    }

    /// While a derived call is open, watcher reports inside its roots are
    /// still recorded, so a late checkpoint cannot lose them.
    func testDerivedOpenCallDoesNotSwallowReports() throws {
        let file = try write("during.py", "1")
        _ = try snapshotter.snapshot(roots: [project.path])
        let before = NotchdEvent(kind: .toolBefore, vendor: "codex", session: "d2", cwd: project.path, tool: "exec", toolUseId: "c2",
                                 paths: [project.path], ts: Date(), fidelity: .derived)
        try recorder.observe(try ledger.record(before), event: before)
        Thread.sleep(forTimeInterval: 0.02)
        try write("during.py", "22")
        recorder.observeExternal([file])
        let settled = expectation(description: "recorded")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(try ledger.unattributedChanges().map(\.path), [file])
        let after = NotchdEvent(kind: .toolAfter, vendor: "codex", session: "d2", cwd: project.path, tool: "exec", toolUseId: "c2",
                                ts: Date(), fidelity: .derived)
        let row = try ledger.record(after)
        try recorder.observe(row, event: after)
        XCTAssertEqual(try ledger.changes(eventId: row.id).map(\.path), [file])
        XCTAssertEqual(try ledger.unattributedChanges(), [])
    }

    /// Reports inside an open call's roots, and suppressed paths, are ignored.
    func testExternalReportsInsideOpenCallsAndSuppressedPathsAreIgnored() throws {
        let inside = try write("inside.txt", "1")
        try send(.toolBefore, tool: "Bash", toolUseId: "t7", paths: [project.path])
        try write("inside.txt", "2")
        recorder.observeExternal([inside])
        try send(.toolAfter, tool: "Bash", toolUseId: "t7", paths: [project.path], at: 1)
        let other = try write("other.txt", "x")
        recorder.suppress([other])
        try write("other.txt", "y")
        recorder.observeExternal([other])
        let settled = expectation(description: "recorded")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(try ledger.unattributedChanges(), [])
    }
}
