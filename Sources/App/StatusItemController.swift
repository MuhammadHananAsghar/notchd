// StatusItemController.swift
// The menu bar item: a template glyph and a short count reading "agents ·
// changes in the last hour". It is the way into the app, so its menu opens the
// timeline and the set-up window and offers Quit.

import AppKit

/// The status item and its menu.
@MainActor
final class StatusItemController {
    private var item: NSStatusItem?
    private let onOpenTimeline: () -> Void
    private let onOpenSetup: () -> Void
    private let onCheckUpdates: () -> Void

    /// Creates the controller; nothing is shown until `show()`.
    /// - Parameters:
    ///   - onOpenTimeline: Opens the timeline window.
    ///   - onOpenSetup: Opens the agent set-up window.
    ///   - onCheckUpdates: Runs a manual update check.
    init(onOpenTimeline: @escaping () -> Void, onOpenSetup: @escaping () -> Void, onCheckUpdates: @escaping () -> Void) {
        self.onOpenTimeline = onOpenTimeline
        self.onOpenSetup = onOpenSetup
        self.onCheckUpdates = onCheckUpdates
    }

    /// Puts the item in the menu bar.
    func show() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.icon()
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = "Notchd"
        item.button?.title = ""

        let menu = NSMenu()
        menu.addItem(withTitle: "Open Notchd", action: #selector(openTimeline), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Set Up Agents…", action: #selector(openSetup), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Notchd", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        self.item = item
    }

    /// Updates the reading beside the glyph.
    /// - Parameter counts: Active sessions and recent events.
    func update(counts: LedgerCounts) {
        item?.button?.title = Self.title(for: counts)
        item?.button?.toolTip = "\(counts.activeSessions) active agent sessions, \(counts.recentChanges) files changed in the last hour"
    }

    /// The compact reading. Empty while nothing has happened, so an idle
    /// machine shows only the glyph.
    /// - Parameter counts: The totals.
    /// - Returns: Text such as ` 3 · 41`.
    static func title(for counts: LedgerCounts) -> String {
        if counts.activeSessions == 0 && counts.recentChanges == 0 { return "" }
        return " \(counts.activeSessions) · \(counts.recentChanges)"
    }

    /// The template glyph, tinted by the system for either menu bar appearance.
    /// - Returns: An 18-point template image.
    static func icon() -> NSImage? {
        guard let image = NSImage(systemSymbolName: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                                  accessibilityDescription: "Notchd")
            ?? NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Notchd") else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    @objc private func openTimeline() { onOpenTimeline() }
    @objc private func openSetup() { onOpenSetup() }
    @objc private func checkUpdates() { onCheckUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }
}
