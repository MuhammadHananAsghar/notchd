// TimelineModelTests.swift
// The window's model must build one lane per session plus the unattributed
// lane, fold a selection into per-file summaries with the right net kind,
// find the tool calls that caused them, turn a selection into a revert scope,
// and run a revert through the sheet's path.

import XCTest
@testable import Notchd

@MainActor
final class TimelineModelTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var ledger: Ledger!
    private var store: ObjectStore!
    private var model: TimelineModel!
    private let t0 = Date(timeIntervalSince1970: 1_757_400_000)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notchd-model-\(UUID().uuidString)")
        project = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        ledger = try Ledger(path: ":memory:")
        store = try ObjectStore(root: root.appendingPathComponent("store"))
        let snapshotter = Snapshotter(store: store)
        model = TimelineModel(ledger: ledger, store: store, engine: RevertEngine(ledger: ledger, store: store, snapshotter: snapshotter))
        model.now = { self.t0.addingTimeInterval(600) }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func entry(_ text: String) throws -> ManifestEntry {
        ManifestEntry(hash: try store.put(Data(text.utf8)), mode: 0o644, size: Int64(text.utf8.count), isSymlink: false)
    }

    /// Records a tool call with changes for a session.
    @discardableResult
    private func call(_ session: String, at offset: TimeInterval, changes: [(String, ChangeKind, ManifestEntry?, ManifestEntry?)]) throws -> EventRow {
        let event = try ledger.record(NotchdEvent(kind: .toolAfter, vendor: "claude", session: session, cwd: project.path, tool: "Bash",
                                                  toolUseId: "t\(Int(offset))", args: .object(["command": .string("cmd \(Int(offset))")]),
                                                  ts: t0.addingTimeInterval(offset), fidelity: .official))
        try ledger.recordChanges(changes.map { path, kind, before, after in
            NewChange(eventId: event.id, sessionId: event.sessionId, path: path, kind: kind, before: before, after: after, attributed: true, ts: event.ts)
        })
        return event
    }

    /// Lanes: one per session with activity in range, plus unattributed.
    func testBuildsLanes() throws {
        let a = try entry("a")
        try call("one", at: 10, changes: [("/p/x", .modify, a, a)])
        try call("two", at: 20, changes: [("/p/y", .create, nil, a)])
        try ledger.recordChanges([NewChange(eventId: nil, sessionId: nil, path: "/p/z", kind: .modify, before: nil, after: a, attributed: false, ts: t0.addingTimeInterval(30))])
        model.range = .hour
        XCTAssertEqual(model.lanes.map(\.subtitle), ["Claude Code", "Claude Code", ""])
        XCTAssertEqual(model.lanes.last?.isUnattributed, true)
        XCTAssertEqual(model.lanes.map { $0.changes.count }, [1, 1, 1])
        XCTAssertEqual(model.lanes.first?.title, "proj")
    }

    /// A selection folds changes by path with the net kind and finds causes.
    func testSelectionSummariesAndCauses() throws {
        let v1 = try entry("v1")
        let v2 = try entry("v2")
        let first = try call("one", at: 10, changes: [("/p/a", .modify, v1, v2), ("/p/new", .create, nil, v1)])
        let second = try call("one", at: 20, changes: [("/p/a", .modify, v2, v1), ("/p/new", .delete, v1, nil)])
        try call("one", at: 500, changes: [("/p/late", .create, nil, v1)])
        model.refresh()
        model.selection = TimelineSelection(start: t0, end: t0.addingTimeInterval(100), laneIds: [])
        XCTAssertEqual(model.selectedChanges.count, 4)
        let byPath = Dictionary(uniqueKeysWithValues: model.files.map { ($0.path, $0) })
        XCTAssertEqual(byPath["/p/a"]?.kind, .modify)
        XCTAssertEqual(byPath["/p/a"]?.before, v1)
        XCTAssertEqual(byPath["/p/a"]?.after, v1)
        XCTAssertEqual(byPath["/p/a"]?.changeCount, 2)
        XCTAssertEqual(byPath["/p/new"]?.kind, .delete)
        XCTAssertNil(byPath["/p/late"])
        XCTAssertEqual(model.causes.map(\.id), [first.id, second.id])
        model.selection = nil
        XCTAssertTrue(model.files.isEmpty)
        XCTAssertTrue(model.causes.isEmpty)
    }

    /// A selection across every lane restricts nothing; a selection on some
    /// lanes restricts to those sessions; the unattributed lane opts in.
    func testSelectionScope() throws {
        let a = try entry("a")
        let one = try call("one", at: 10, changes: [("/p/x", .modify, a, a)])
        try call("two", at: 20, changes: [("/p/y", .modify, a, a)])
        try ledger.recordChanges([NewChange(eventId: nil, sessionId: nil, path: "/p/z", kind: .modify, before: a, after: a, attributed: false, ts: t0.addingTimeInterval(30))])
        model.refresh()
        model.selection = TimelineSelection(start: t0, end: t0.addingTimeInterval(100), laneIds: [])
        let whole = try XCTUnwrap(model.selectionScope)
        XCTAssertNil(whole.sessionIds)
        XCTAssertTrue(whole.includeUnattributed)
        model.selection = TimelineSelection(start: t0, end: t0.addingTimeInterval(100), laneIds: [one.sessionId])
        let some = try XCTUnwrap(model.selectionScope)
        XCTAssertEqual(some.sessionIds, [one.sessionId])
        XCTAssertFalse(some.includeUnattributed)
    }

    /// The sheet's path: prepare a plan, apply it with one file unticked.
    func testRevertThroughTheSheet() throws {
        let original = try entry("original")
        let edited = try entry("edited")
        let keepPath = project.appendingPathComponent("keep.txt").path
        let restorePath = project.appendingPathComponent("restore.txt").path
        try Data("edited".utf8).write(to: URL(fileURLWithPath: keepPath))
        try Data("edited".utf8).write(to: URL(fileURLWithPath: restorePath))
        try call("one", at: 10, changes: [(keepPath, .modify, original, edited), (restorePath, .modify, original, edited)])
        model.refresh()
        model.selection = TimelineSelection(start: t0, end: t0.addingTimeInterval(100), laneIds: [])
        model.prepareRevert()
        let plan = try XCTUnwrap(model.pendingRevert?.plan)
        XCTAssertEqual(plan.targets.count, 2)
        XCTAssertEqual(plan.commands, ["cmd 10"])
        model.applyRevert(plan, keeping: [restorePath])
        XCTAssertEqual(model.revertResult?.outcome, .complete)
        XCTAssertEqual(try String(contentsOfFile: restorePath, encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOfFile: keepPath, encoding: .utf8), "edited")
        model.dismissRevert()
        XCTAssertNil(model.pendingRevert)
    }

    /// Opening a session page loads its events and changes.
    func testSessionPage() throws {
        let a = try entry("a")
        let event = try call("one", at: 10, changes: [("/p/x", .modify, a, a)])
        model.refresh()
        model.page = .session(event.sessionId)
        XCTAssertEqual(model.selectedSession?.id, event.sessionId)
        XCTAssertEqual(model.events.map(\.id), [event.id])
        XCTAssertEqual(model.changesByEvent[event.id]?.count, 1)
    }

    /// Time ranges end now and start where they say.
    func testTimeRanges() {
        let now = t0
        XCTAssertEqual(TimeRange.fifteenMinutes.interval(now: now).start, now.addingTimeInterval(-900))
        XCTAssertEqual(TimeRange.hour.interval(now: now).start, now.addingTimeInterval(-3600))
        XCTAssertEqual(TimeRange.week.interval(now: now).start, now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(TimeRange.today.interval(now: now).start, Calendar.current.startOfDay(for: now))
    }

    /// Ticks within a few points merge into one cluster in the most serious
    /// kind; ticks further apart stay separate.
    func testTickClusters() throws {
        let a = try entry("a")
        let rows = [
            ChangeRow(id: 1, eventId: nil, sessionId: nil, path: "/1", kind: .create, before: nil, after: a, attributed: true, ts: t0),
            ChangeRow(id: 2, eventId: nil, sessionId: nil, path: "/2", kind: .delete, before: a, after: nil, attributed: true, ts: t0.addingTimeInterval(1)),
            ChangeRow(id: 3, eventId: nil, sessionId: nil, path: "/3", kind: .modify, before: a, after: a, attributed: false, ts: t0.addingTimeInterval(100)),
        ]
        let clusters = TickCluster.clusters(rows, x: { CGFloat($0.ts.timeIntervalSince(self.t0)) })
        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(clusters[0].changes.count, 2)
        XCTAssertEqual(clusters[0].kind, .delete)
        XCTAssertTrue(clusters[0].attributed)
        XCTAssertEqual(clusters[1].kind, .modify)
        XCTAssertFalse(clusters[1].attributed)
    }

    /// Lane geometry maps time to x and back, and y to lane index.
    func testLaneGeometry() {
        let geometry = LaneGeometry(size: CGSize(width: 1000, height: 300), start: t0, end: t0.addingTimeInterval(1000))
        XCTAssertEqual(geometry.x(for: t0), LaneLayout.labelWidth)
        XCTAssertEqual(geometry.x(for: t0.addingTimeInterval(1000)), LaneLayout.labelWidth + geometry.trackWidth)
        let middle = geometry.date(at: LaneLayout.labelWidth + geometry.trackWidth / 2)
        XCTAssertEqual(middle.timeIntervalSince(t0), 500, accuracy: 0.001)
        XCTAssertNil(geometry.laneIndex(at: 5))
        XCTAssertEqual(geometry.laneIndex(at: LaneLayout.axisHeight + LaneLayout.laneHeight * 1.5), 1)
        XCTAssertEqual(geometry.date(at: -50), t0, "x before the track clamps to the start")
    }
}
