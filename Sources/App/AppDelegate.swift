// AppDelegate.swift
// Owns the long-lived objects: the ledger, the object store, the recorder that
// checkpoints and diffs, the FSEvents watcher over active working directories,
// the socket server hooks write to, the notch on the screen edge, the menu bar
// item, the updater, the preferences, and the two windows. The app process is
// the recorder in this phase; a separate launchd daemon is deferred until the
// recorder needs to outlive the app.

import AppKit
import Combine
import SwiftUI

/// The application delegate.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var ledger: Ledger?
    private var store: ObjectStore?
    private var recorder: Recorder?
    private var watcher: FileActivityWatcher?
    private var ingest: EventIngest?
    private var server: EventSocketServer?
    private var statusItem: StatusItemController?
    private var model: TimelineModel?
    private let notch = NotchWindowController()
    private let preferences = Preferences()
    private var codexTailer: CodexRolloutTailer?
    private var guardPolicy: GuardPolicy?
    private var completion: CompletionNotifier?
    private let updater = Updater()
    private var timelineWindow: NSWindow?
    private var setupWindow: NSWindow?
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// Whether this process is the test host. The unit tests run inside the
    /// app, and a test host that started recording would write to the real
    /// ledger and take over the real socket while a real copy is running.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }

    /// Brings everything up. A failure to open storage or the socket is shown
    /// once and the app keeps running so the user can reach Quit.
    /// - Parameter notification: Unused.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        do {
            try NotchdPaths.ensureDirectories()
            let ledger = try Ledger(path: NotchdPaths.ledgerURL.path)
            let store = try ObjectStore(root: NotchdPaths.supportDirectory.appendingPathComponent("store"))
            let snapshotter = Snapshotter(store: store)
            let recorder = Recorder(ledger: ledger, store: store, snapshotter: snapshotter)
            let watcher = FileActivityWatcher { [weak recorder] paths in recorder?.observeExternal(paths) }
            let engine = RevertEngine(ledger: ledger, store: store, snapshotter: snapshotter)
            engine.suppress = { [weak recorder] paths in recorder?.suppress(paths) }
            let model = TimelineModel(ledger: ledger, store: store, engine: engine)
            let guardPolicy = GuardPolicy(url: NotchdPaths.guardURL)
            let ingest = EventIngest(ledger: ledger, observers: [recorder], guardPolicy: guardPolicy) { [weak self] rows in
                Task { @MainActor in
                    self?.refreshEverything()
                    self?.completion?.handle(rows)
                }
            }
            let server = EventSocketServer.deciding(path: NotchdPaths.socketPath) { [weak ingest] line in
                ingest?.handle(line) ?? .allow
            }
            self.guardPolicy = guardPolicy
            try server.start()
            self.ledger = ledger
            self.store = store
            self.recorder = recorder
            self.watcher = watcher
            self.model = model
            self.ingest = ingest
            self.server = server
            Log.server.notice("listening at \(NotchdPaths.socketPath, privacy: .public)")
        } catch {
            Log.app.error("start-up failed: \(String(describing: error), privacy: .public)")
            presentStartupFailure(error)
        }
        installStatusItem()
        installNotch()
        installCodexTailer()
        installCompletion()
        updater.start()
        scheduleRefresh()
        refreshEverything()
        schedulePrune()
        if !(model?.hasAnySessions ?? false) { openSetup() }
    }

    /// Stops the notch, the tailer, the watcher, and the server so the socket
    /// file is removed.
    /// - Parameter notification: Unused.
    func applicationWillTerminate(_ notification: Notification) {
        notch.stop()
        codexTailer?.stop()
        watcher?.stop()
        server?.stop()
    }

    /// Wires finished turns to notifications and the notch.
    private func installCompletion() {
        guard let ledger else { return }
        let notifier = CompletionNotifier(ledger: ledger, preferences: preferences, notch: notch.model) { [weak self] id in
            self?.model?.page = .session(id)
            self?.openTimeline()
        }
        notifier.prepare()
        completion = notifier
    }

    /// Follows Codex's transcripts while the preference is on and the
    /// directory exists, and follows the preference from then on.
    private func installCodexTailer() {
        guard let ingest else { return }
        let tailer = CodexRolloutTailer { [weak ingest] events in ingest?.ingest(events: events) }
        codexTailer = tailer
        let apply: (Bool) -> Void = { [weak tailer] on in
            guard let tailer else { return }
            if on, tailer.isAvailable { tailer.start() } else { tailer.stop() }
        }
        apply(preferences.codexTranscripts)
        preferences.$codexTranscripts
            .dropFirst()
            .sink { on in apply(on) }
            .store(in: &cancellables)
    }

    /// Puts the status item up and wires its menu.
    private func installStatusItem() {
        let item = StatusItemController(
            onOpenTimeline: { [weak self] in self?.openTimeline() },
            onOpenSetup: { [weak self] in self?.openSetup() },
            onCheckUpdates: { [weak self] in self?.updater.checkNow() }
        )
        item.show()
        statusItem = item
        model?.onCountsChanged = { [weak item] counts in item?.update(counts: counts) }
    }

    /// Puts the notch on the edge, wires its actions, and follows the
    /// preferences.
    private func installNotch() {
        notch.onOpenTimeline = { [weak self] in self?.openTimeline() }
        notch.onOpenSetup = { [weak self] in self?.openSetup() }
        notch.onRevertRecent = { [weak self] in self?.revertRecent() }
        notch.onOpenSession = { [weak self] id in
            self?.model?.page = .session(id)
            self?.openTimeline()
        }
        notch.model.edge = preferences.notchEdge
        notch.show()
        notch.apply(preferences.notchVisibility)
        preferences.$notchEdge
            .dropFirst()
            .sink { [weak self] edge in self?.notch.apply(edge: edge) }
            .store(in: &cancellables)
        preferences.$notchVisibility
            .dropFirst()
            .sink { [weak self] visibility in self?.notch.apply(visibility) }
            .store(in: &cancellables)
    }

    /// Re-reads the ledger periodically so session liveness, the watcher's
    /// roots, the notch, and the menu bar counts stay current even when no
    /// event arrives.
    private func scheduleRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshEverything() }
        }
    }

    /// One refresh for every surface.
    private func refreshEverything() {
        model?.refresh()
        refreshWatcher()
        if let ledger { notch.refresh(from: ledger) }
    }

    /// Points the watcher at the working directories of active sessions.
    private func refreshWatcher() {
        guard let ledger, let watcher, let recorder else { return }
        let limits = recorder.snapshotter.limits
        let roots = ((try? ledger.sessions(limit: 50)) ?? [])
            .filter { $0.isActive() && $0.vendor != "notchd" }
            .map(\.cwd)
            .filter { limits.isReasonableRoot($0) }
        watcher.update(roots: roots)
    }

    /// Prunes the object store shortly after launch and once a day after
    /// that, off the main thread.
    private func schedulePrune() {
        guard let ledger, let store else { return }
        let pruner = StorePruner(ledger: ledger, store: store)
        let run = {
            DispatchQueue.global(qos: .utility).async {
                do {
                    let result = try pruner.prune()
                    Log.app.notice("pruned store: kept \(result.kept), removed \(result.removed), freed \(result.bytesFreed) bytes")
                } catch {
                    Log.app.error("prune failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: run)
        Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { _ in run() }
    }

    /// The notch's quick action: select the last ten minutes across every
    /// lane and open the revert sheet in the timeline window. Still two
    /// steps; the notch never reverts on its own.
    private func revertRecent() {
        guard let model else { return }
        let now = Date()
        model.page = .timeline
        if model.range == .fifteenMinutes { model.refresh() } else { model.range = .fifteenMinutes }
        model.selection = TimelineSelection(start: now.addingTimeInterval(-10 * 60), end: now, laneIds: [])
        openTimeline()
        model.prepareRevert()
    }

    /// Shows the timeline window, creating it on first use.
    func openTimeline() {
        guard let model else { return }
        if timelineWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: TimelineView(model: model)))
            window.title = "Notchd"
            window.setContentSize(NSSize(width: 980, height: 620))
            window.minSize = NSSize(width: 720, height: 420)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            timelineWindow = window
        }
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        timelineWindow?.makeKeyAndOrderFront(nil)
    }

    /// Shows the set-up window, creating it on first use.
    func openSetup() {
        if setupWindow == nil {
            let guardModel = GuardModel(policy: guardPolicy ?? GuardPolicy(url: NotchdPaths.guardURL))
            let view = SetupView(models: SetupModel.standard(), preferences: preferences, guardModel: guardModel)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Notchd Settings"
            window.setContentSize(NSSize(width: 640, height: 760))
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            setupWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    /// A single alert for a start-up failure, in words that say what to do.
    /// - Parameter error: The failure.
    private func presentStartupFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Notchd could not start recording"
        alert.informativeText = "It could not open its ledger, its object store, or its socket in Application Support. "
            + "Nothing has been changed on your Mac. Details: \(error)"
        alert.alertStyle = .warning
        alert.runModal()
    }
}
