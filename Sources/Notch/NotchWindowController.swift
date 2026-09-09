// NotchWindowController.swift
// Puts the notch on screen and runs it: placement against the screen edge,
// the hit regions that keep the rest of the panel a hole, cursor tracking that
// opens it on contact and folds it after a pause, pinning by click, the
// targets inside it, moving between edges, and the visibility setting.
// Adapted from Notchd's controller with the dial-specific parts removed.

import AppKit
import Combine
import SwiftUI

/// The notch on screen.
@MainActor
final class NotchWindowController {
    let model = NotchViewModel()

    /// Open the timeline window.
    var onOpenTimeline: (() -> Void)?
    /// Open the set-up window.
    var onOpenSetup: (() -> Void)?
    /// Start a revert of the last ten minutes in the timeline window.
    var onRevertRecent: (() -> Void)?
    /// Open one session's page.
    var onOpenSession: ((Int64) -> Void)?

    /// The panel's frame and alpha, for tests.
    var panelFrameForTesting: CGRect? { panel?.frame }
    var isPanelVisibleForTesting: Bool { panel?.isVisible ?? false }

    private var panel: NotchPanel?
    private var hostingView: NotchHostingView<NotchRootView>?
    private var cancellables = Set<AnyCancellable>()
    private var mouseMonitors: [Any] = []
    private var cursorTimer: Timer?
    private var foldWork: DispatchWorkItem?
    private var isPointing = false
    private var lastVisibleFrame: CGRect?
    private var edgeChange = 0

    /// Folding shut waits, so the pointer straying for a moment does not
    /// snap it closed.
    private let foldGrace: TimeInterval = 0.45
    private static let edgeCrossfade: TimeInterval = 0.16
    private static let arrivalBeat: TimeInterval = 0.05

    /// Puts the notch up and starts tracking the cursor and the screen.
    func show() {
        relocate()
        startWatchingCursor()
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.relocate() } }
            .store(in: &cancellables)
    }

    /// Stops tracking and releases the cursor.
    func stop() {
        setPointing(false)
        foldWork?.cancel()
        cursorTimer?.invalidate()
        cursorTimer = nil
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors.removeAll()
    }

    /// Feeds the notch from the ledger and resizes the panel if the content
    /// grew or shrank.
    /// - Parameter ledger: The ledger.
    func refresh(from ledger: Ledger) {
        let now = Date()
        let sessions = (try? ledger.sessions(limit: 50)) ?? []
        let changes = (try? ledger.changes(since: now.addingTimeInterval(-NotchViewModel.recentWindow), includeUnattributed: true)) ?? []
        let counts = (try? ledger.counts(now: now)) ?? LedgerCounts(activeSessions: 0, recentChanges: 0)
        let before = model.panelSize
        model.update(sessions: sessions, changes: changes, counts: counts, now: now)
        if model.panelSize != before { relocate() }
        updateInteractiveRects()
    }

    /// Places or re-places the panel on the preferred screen.
    func relocate() {
        guard let screen = NotchGeometry.preferredScreen(from: NSScreen.screens) else { return }
        model.adopt(screen: screen)
        let frame = NotchGeometry.panelFrame(for: screen, panelSize: model.panelSize, edge: model.edge)
        lastVisibleFrame = screen.visibleFrame
        if let panel {
            panel.setFrame(frame, display: true)
        } else {
            let panel = NotchPanel(contentRect: frame)
            let hosting = NotchHostingView(rootView: NotchRootView(model: model))
            panel.contextMenuProvider = { [weak self] in self?.contextMenu() }
            panel.onClick = { [weak self] in self?.handleClick() }
            let container = NotchContainerView(frame: CGRect(origin: .zero, size: frame.size))
            container.autoresizingMask = [.width, .height]
            hosting.frame = container.bounds
            hosting.autoresizingMask = [.width, .height]
            container.addSubview(hosting)
            panel.contentView = container
            panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
            self.panel = panel
            self.hostingView = hosting
        }
        updateInteractiveRects()
    }

    /// The placement for the panel's real size.
    private var placement: NotchPlacement {
        model.placement(panelSize: panel?.frame.size)
    }

    /// The only region that takes the mouse: the pill and its hot zone when
    /// folded, the whole open shape when open.
    private var liveRect: CGRect {
        model.isExpanded ? model.expandedRect(placement) : model.pillHotRect(placement)
    }

    /// Tells the hosting view and the panel where events are taken.
    private func updateInteractiveRects() {
        hostingView?.interactiveRects = [liveRect]
        if let panel {
            panel.ignoresMouseEvents = !liveRect.contains(localCursor(in: panel.frame))
        }
    }

    /// A global monitor catches the outside-to-inside crossing while the panel
    /// is still ignoring events; a local one the way back out; a slow poll
    /// backs both up for a pointer that never moves.
    private func startWatchingCursor() {
        let poll = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.followUsableAreaIfItMoved()
                self?.cursorMoved()
            }
        }
        RunLoop.main.add(poll, forMode: .common)
        cursorTimer = poll
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        let handler: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.cursorMoved() } }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: handler) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in
            handler(event)
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    /// The cursor in panel coordinates with a top-left origin.
    private func localCursor(in frame: CGRect) -> CGPoint {
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
    }

    /// Re-places the panel when the Dock has come or gone, which nothing
    /// announces.
    private func followUsableAreaIfItMoved() {
        guard let screen = NotchGeometry.preferredScreen(from: NSScreen.screens), screen.visibleFrame != lastVisibleFrame else { return }
        relocate()
    }

    /// Opens on contact, tracks the target under the pointer, folds after a
    /// pause once the pointer has left.
    private func cursorMoved() {
        guard let panel, panel.isVisible else { return }
        let local = localCursor(in: panel.frame)
        setExpanded(liveRect.contains(local))
        let target = model.target(at: local, placement)
        if model.hovered != target {
            withAnimation(NotchMotion.crossfade) { model.hovered = target }
        }
        setPointing(target != nil)
        updateInteractiveRects()
    }

    /// Opens now, or schedules a fold unless something holds it open.
    private func setExpanded(_ wanted: Bool) {
        if wanted {
            foldWork?.cancel()
            foldWork = nil
            guard !model.isExpanded else { return }
            withAnimation(NotchMotion.unfold) { model.isExpanded = true }
            return
        }
        guard model.isExpanded, !model.staysOpen, foldWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.foldWork = nil
                guard !self.model.staysOpen else { return }
                withAnimation(NotchMotion.unfold) {
                    self.model.isExpanded = false
                    self.model.hovered = nil
                }
                self.setPointing(false)
                self.updateInteractiveRects()
            }
        }
        foldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + foldGrace, execute: work)
    }

    /// Pushed and popped so leaving restores whatever cursor the app
    /// underneath had.
    private func setPointing(_ wanted: Bool) {
        guard wanted != isPointing else { return }
        isPointing = wanted
        if wanted { NSCursor.pointingHand.push() } else { NSCursor.pop() }
    }

    /// A click on a target does that thing; a click elsewhere on the open
    /// notch pins it; a click on the pill opens it.
    func handleClick() {
        guard let panel, model.isExpanded else {
            setExpanded(true)
            return
        }
        switch model.target(at: localCursor(in: panel.frame), placement) {
        case .gear: onOpenSetup?()
        case .openTimeline: onOpenTimeline?()
        case .revertRecent: onRevertRecent?()
        case .session(let id): onOpenSession?(id)
        case nil: togglePinned()
        }
    }

    /// Clicking the open notch pins it. A no-op under Always show.
    func togglePinned() {
        guard !model.isAlwaysOn else { return }
        model.isPinned.toggle()
        if model.isPinned {
            foldWork?.cancel()
            foldWork = nil
            withAnimation(NotchMotion.unfold) { model.isExpanded = true }
        }
        updateInteractiveRects()
    }

    /// Moves to another edge: fades out where it was, crosses while there is
    /// nothing to see, and opens where it now is if it was open.
    /// - Parameter edge: The new edge.
    func apply(edge: NotchEdge) {
        guard model.edge != edge else { return }
        guard let panel else {
            model.edge = edge
            relocate()
            return
        }
        let wasOpen = model.isExpanded
        model.hovered = nil
        setPointing(false)
        edgeChange += 1
        let change = edgeChange
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.edgeCrossfade
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, change == self.edgeChange else { return }
                self.model.edge = edge
                self.model.isExpanded = false
                self.relocate()
                panel.alphaValue = 1
                guard wasOpen else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.arrivalBeat) {
                    MainActor.assumeIsolated {
                        guard change == self.edgeChange else { return }
                        withAnimation(NotchMotion.unfold) { self.model.isExpanded = true }
                        self.updateInteractiveRects()
                    }
                }
            }
        }
    }

    /// Applies the visibility setting.
    /// - Parameter visibility: The setting.
    func apply(_ visibility: NotchVisibility) {
        switch visibility {
        case .alwaysShow:
            panel?.orderFrontRegardless()
            model.isAlwaysOn = true
            model.isPinned = false
            foldWork?.cancel()
            foldWork = nil
            withAnimation(NotchMotion.unfold) { model.isExpanded = true }
        case .onHover:
            panel?.orderFrontRegardless()
            model.isAlwaysOn = false
            model.isPinned = false
            withAnimation(NotchMotion.unfold) {
                model.isExpanded = false
                model.hovered = nil
            }
        case .hidden:
            model.isAlwaysOn = false
            model.isPinned = false
            model.isExpanded = false
            model.hovered = nil
            panel?.orderOut(nil)
        }
        setPointing(false)
        updateInteractiveRects()
    }

    /// The right-click menu.
    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let keepOpen = NSMenuItem(title: "Keep open", action: #selector(NotchMenuActions.togglePinned(_:)), keyEquivalent: "")
        keepOpen.target = menuActions
        keepOpen.state = model.staysOpen ? .on : .off
        keepOpen.isEnabled = !model.isAlwaysOn
        menu.addItem(keepOpen)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Notchd", action: #selector(NotchMenuActions.openTimeline(_:)), keyEquivalent: "")
        open.target = menuActions
        open.isEnabled = true
        menu.addItem(open)
        let setup = NSMenuItem(title: "Set Up Agents…", action: #selector(NotchMenuActions.openSetup(_:)), keyEquivalent: "")
        setup.target = menuActions
        setup.isEnabled = true
        menu.addItem(setup)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Notchd", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").isEnabled = true
        return menu
    }

    private lazy var menuActions = NotchMenuActions(
        togglePinned: { [weak self] in self?.togglePinned() },
        openTimeline: { [weak self] in self?.onOpenTimeline?() },
        openSetup: { [weak self] in self?.onOpenSetup?() }
    )
}

/// An Objective-C target for the menu items.
final class NotchMenuActions: NSObject {
    private let pin: () -> Void
    private let timeline: () -> Void
    private let setup: () -> Void

    /// Creates the target.
    /// - Parameters:
    ///   - togglePinned: Keep open.
    ///   - openTimeline: Open Notchd.
    ///   - openSetup: Set up agents.
    init(togglePinned: @escaping () -> Void, openTimeline: @escaping () -> Void, openSetup: @escaping () -> Void) {
        pin = togglePinned
        timeline = openTimeline
        setup = openSetup
    }

    @objc func togglePinned(_ sender: Any?) { pin() }
    @objc func openTimeline(_ sender: Any?) { timeline() }
    @objc func openSetup(_ sender: Any?) { setup() }
}
