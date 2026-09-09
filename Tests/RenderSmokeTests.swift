// RenderSmokeTests.swift
// Every surface renders in both appearances without crashing and produces a
// non-empty image. Not a pixel comparison: the point is that a view with real
// data does not throw, hang, or draw nothing in one of the two modes.

import SwiftUI
import XCTest
@testable import Notchd

@MainActor
final class RenderSmokeTests: XCTestCase {
    private var root: URL!
    private var ledger: Ledger!
    private var store: ObjectStore!
    private var model: TimelineModel!
    private let t0 = Date(timeIntervalSince1970: 1_757_400_000)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notchd-render-\(UUID().uuidString)")
        ledger = try Ledger(path: ":memory:")
        store = try ObjectStore(root: root)
        model = TimelineModel(ledger: ledger, store: store, engine: RevertEngine(ledger: ledger, store: store, snapshotter: Snapshotter(store: store)))
        model.now = { self.t0.addingTimeInterval(300) }
        try seed()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A session with a prompt, a shell call, three changes, and an
    /// unattributed change.
    private func seed() throws {
        let before = ManifestEntry(hash: try store.put(Data("let a = 1\n".utf8)), mode: 0o644, size: 10, isSymlink: false)
        let after = ManifestEntry(hash: try store.put(Data("let a = 2\n".utf8)), mode: 0o644, size: 10, isSymlink: false)
        try ledger.record(NotchdEvent(kind: .sessionStart, vendor: "claude", session: "s", cwd: "/Users/me/proj", ts: t0, fidelity: .official))
        try ledger.record(NotchdEvent(kind: .note, vendor: "claude", session: "s", cwd: "/Users/me/proj",
                                      meta: .object(["event": .string("UserPromptSubmit"), "prompt": .string("fix the build")]), ts: t0.addingTimeInterval(1), fidelity: .official))
        let call = try ledger.record(NotchdEvent(kind: .toolAfter, vendor: "claude", session: "s", cwd: "/Users/me/proj", tool: "Bash", toolUseId: "t1",
                                                 args: .object(["command": .string("rm -rf build")]), paths: ["/Users/me/proj"], ts: t0.addingTimeInterval(10), fidelity: .official))
        try ledger.recordChanges([
            NewChange(eventId: call.id, sessionId: call.sessionId, path: "/Users/me/proj/a.swift", kind: .modify, before: before, after: after, attributed: true, ts: call.ts),
            NewChange(eventId: call.id, sessionId: call.sessionId, path: "/Users/me/proj/new.swift", kind: .create, before: nil, after: after, attributed: true, ts: call.ts),
            NewChange(eventId: call.id, sessionId: call.sessionId, path: "/Users/me/proj/gone.swift", kind: .delete, before: before, after: nil, attributed: true, ts: call.ts),
            NewChange(eventId: nil, sessionId: nil, path: "/Users/me/proj/mine.txt", kind: .modify, before: nil, after: after, attributed: false, ts: t0.addingTimeInterval(20)),
        ])
        model.refresh()
        model.selection = TimelineSelection(start: t0, end: t0.addingTimeInterval(100), laneIds: [])
        model.selectedFile = model.files.first { $0.path == "/Users/me/proj/a.swift" }
    }

    /// Renders a view at a size in both appearances through a real window,
    /// so AppKit-backed controls such as lists and pickers draw too, and
    /// checks the images. With `NOTCHD_RENDER_DIR` set, also writes each as a
    /// PNG for a person to look at.
    private func assertRenders<V: View>(_ view: V, size: CGSize = CGSize(width: 900, height: 600), name: String = #function,
                                        file: StaticString = #filePath, line: UInt = #line) {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let image = render(view, size: size, appearance: appearance)
            XCTAssertNotNil(image, "no image in \(appearance.rawValue)", file: file, line: line)
            XCTAssertGreaterThan(image?.size.width ?? 0, 0, file: file, line: line)
            XCTAssertGreaterThan(image?.size.height ?? 0, 0, file: file, line: line)
            save(image, name: "\(name.replacingOccurrences(of: "()", with: ""))-\(appearance == .darkAqua ? "dark" : "light")")
        }
    }

    /// Hosts the view in an offscreen window and caches its display.
    private func render<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name) -> NSImage? {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        window.contentView = nil
        return image
    }

    /// Writes a PNG into the directory named by `NOTCHD_RENDER_DIR`, if set.
    private func save(_ image: NSImage?, name: String) {
        guard let dir = ProcessInfo.processInfo.environment["NOTCHD_RENDER_DIR"], !dir.isEmpty, let image,
              let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    func testTimelinePageRenders() {
        assertRenders(TimelinePage(model: model))
    }

    func testLaneViewRenders() {
        assertRenders(LaneView(model: model), size: CGSize(width: 900, height: 120))
    }

    func testInspectorRenders() {
        assertRenders(InspectorView(model: model), size: CGSize(width: 900, height: 320))
    }

    func testSessionPageRenders() throws {
        let session = try XCTUnwrap(ledger.sessions().first)
        model.page = .session(session.id)
        assertRenders(SessionDetailView(session: session, events: model.events, changesByEvent: model.changesByEvent))
    }

    func testUnattributedPageRenders() {
        assertRenders(UnattributedView(changes: model.unattributed))
    }

    func testRevertSheetRenders() throws {
        model.prepareRevert()
        let plan = try XCTUnwrap(model.pendingRevert?.plan)
        assertRenders(RevertSheet(model: model, plan: plan), size: CGSize(width: 620, height: 480))
    }

    func testDiffViewRenders() throws {
        let file = try XCTUnwrap(model.selectedFile)
        let before = try store.get(file.before!.hash)
        let after = try store.get(file.after!.hash)
        assertRenders(DiffView(file: file, diff: LineDiff.diff(before: before, after: after)), size: CGSize(width: 600, height: 300))
    }

    func testSetupViewRenders() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notchd-setup-\(UUID().uuidString)")
        let binary = "/Applications/Notchd.app/Contents/MacOS/notchd-hook"
        let models = [
            SetupModel(integration: HookSettingsFile(url: dir.appendingPathComponent("claude.json"), vendor: .claude), binaryPath: binary),
            SetupModel(integration: HookSettingsFile(url: dir.appendingPathComponent("gemini.json"), vendor: .gemini), binaryPath: binary),
            SetupModel(integration: OpenCodePlugin(url: dir.appendingPathComponent("opencode/plugin/notchd.js")), binaryPath: binary),
            SetupModel(integration: CursorHooksFile(url: dir.appendingPathComponent("cursor/hooks.json")), binaryPath: binary),
        ]
        let preferences = Preferences(defaults: UserDefaults(suiteName: "notchd-render-\(UUID().uuidString)")!)
        let guardModel = GuardModel(policy: GuardPolicy(enabled: true, rules: GuardRule.suggested))
        assertRenders(SetupView(models: models, preferences: preferences, guardModel: guardModel, codexPresent: true), size: CGSize(width: 640, height: 1800))
    }

    /// The notch on every edge, open and at rest, with a solid chrome because
    /// a material has nothing to sample offscreen.
    func testNotchRenders() throws {
        Surface.mode = .solid
        defer { Surface.mode = .glass }
        let sessions = try ledger.sessions()
        let changes = try ledger.changes(since: .distantPast, includeUnattributed: true)
        for edge in NotchEdge.allCases {
            let notch = NotchViewModel()
            notch.edge = edge
            notch.update(sessions: sessions, changes: changes, counts: LedgerCounts(activeSessions: 1, recentChanges: 4), now: t0.addingTimeInterval(300))
            notch.isExpanded = true
            assertRenders(NotchRootView(model: notch), size: notch.panelSize, name: "testNotchRenders-\(edge.rawValue)-open")
            notch.isExpanded = false
            assertRenders(NotchRootView(model: notch), size: notch.panelSize, name: "testNotchRenders-\(edge.rawValue)-rest")
        }
        let peeking = NotchViewModel()
        peeking.update(sessions: sessions, changes: changes, counts: LedgerCounts(activeSessions: 2, recentChanges: 4), now: t0.addingTimeInterval(300))
        assertRenders(NotchRootView(model: peeking), size: peeking.panelSize, name: "testNotchRenders-right-working")
        peeking.celebrate(NotchCelebration(sessionId: 1, vendor: "claude", title: "proj done", detail: "+1 ~1 -1"))
        assertRenders(NotchRootView(model: peeking), size: peeking.panelSize, name: "testNotchRenders-right-peek")
        let topPeek = NotchViewModel()
        topPeek.edge = .top
        topPeek.celebrate(NotchCelebration(sessionId: 1, vendor: "opencode", title: "tevta-chat done", detail: "+1 ~2"))
        assertRenders(NotchRootView(model: topPeek), size: topPeek.panelSize, name: "testNotchRenders-top-peek")
        let joined = NotchViewModel()
        joined.edge = .top
        joined.hardwareNotch = HardwareNotch(width: 220, height: 38)
        joined.update(sessions: sessions, changes: changes, counts: LedgerCounts(activeSessions: 1, recentChanges: 4), now: t0.addingTimeInterval(300))
        joined.isExpanded = true
        assertRenders(NotchRootView(model: joined), size: joined.panelSize, name: "testNotchRenders-joined-open")
    }
}
