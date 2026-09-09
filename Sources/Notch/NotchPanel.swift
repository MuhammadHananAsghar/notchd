// NotchPanel.swift
// A borderless, non-activating panel that floats over everything, including
// the menu bar and full-screen apps. Non-activating matters: glancing at the
// notch must never take focus off what you were doing. Clicks and the context
// menu are handled here because the window sees every event first, while the
// hit test lands on a SwiftUI-owned subview that may consume it. Kept from
// Notchd.

import AppKit

/// The floating panel.
final class NotchPanel: NSPanel {
    /// Supplies the right-click menu.
    var contextMenuProvider: (() -> NSMenu?)?
    /// A left click on the visible chrome.
    var onClick: (() -> Void)?

    /// Routes a right click over the chrome to the context menu.
    /// - Parameter event: The event.
    override func sendEvent(_ event: NSEvent) {
        guard event.type == .rightMouseDown, let menu = contextMenuProvider?(), let view = contentView,
              view.hitTest(event.locationInWindow) != nil else { return super.sendEvent(event) }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    /// Routes a left click over the chrome to the click handler.
    /// - Parameter event: The event.
    override func mouseDown(with event: NSEvent) {
        guard let view = contentView, view.hitTest(event.locationInWindow) != nil else {
            return super.mouseDown(with: event)
        }
        onClick?()
    }

    /// Creates the panel at a frame.
    /// - Parameter contentRect: The initial frame.
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
