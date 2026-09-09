// NotchHostingView.swift
// The panel's content view and the hosting view inside it. The hosting view is
// not the content view on purpose: as the content view an NSHostingView
// reports its ideal size to the window, and a GeometryReader root reports
// 10 by 10, which had AppKit walking the window down to nothing. The panel's
// size is NotchGeometry's to decide. Everything outside the visible chrome
// passes clicks through to whatever is underneath. Kept from Notchd.

import AppKit
import SwiftUI

/// The content view: holds the hosting view and answers hit tests with
/// whatever its subview says, never with itself.
final class NotchContainerView: NSView {
    /// Defers to subviews so empty panel space stays a hole.
    /// - Parameter point: A point in the superview's coordinates.
    /// - Returns: The subview hit, or nil.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for subview in subviews.reversed() {
            if let hit = subview.hitTest(local) { return hit }
        }
        return nil
    }
}

/// The hosting view, which takes events only inside its interactive rects.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    /// Regions that receive events, in view coordinates with a top-left origin.
    var interactiveRects: [CGRect] = []

    /// Answers only inside an interactive rect.
    /// - Parameter point: A point in the superview's coordinates.
    /// - Returns: The view hit, or nil.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard interactiveRects.contains(where: { $0.contains(local) }) else { return nil }
        return super.hitTest(point)
    }

    /// The menu, only inside an interactive rect; subviews do not inherit it.
    /// - Parameter event: The event.
    /// - Returns: The menu, or nil.
    override func menu(for event: NSEvent) -> NSMenu? {
        let local = convert(event.locationInWindow, from: nil)
        guard interactiveRects.contains(where: { $0.contains(local) }) else { return nil }
        return menu
    }
}
