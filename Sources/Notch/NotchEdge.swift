// NotchEdge.swift
// Which screen edge the notch is welded to. The edge decides which way the
// content runs and which way the shape folds away. Kept from Notchd.

import Foundation

/// A screen edge.
enum NotchEdge: String, CaseIterable, Identifiable {
    case right
    case left
    case top
    case bottom

    var id: String { rawValue }

    /// True when the notch runs down the screen rather than across it.
    var isVertical: Bool { self == .right || self == .left }

    /// A unit vector pointing at the bezel, in panel coordinates with y
    /// growing down. The way the contents slide as the notch folds away.
    var outward: CGPoint {
        switch self {
        case .right: return CGPoint(x: 1, y: 0)
        case .left: return CGPoint(x: -1, y: 0)
        case .top: return CGPoint(x: 0, y: -1)
        case .bottom: return CGPoint(x: 0, y: 1)
        }
    }

    /// The picker label.
    var title: String {
        switch self {
        case .right: return "Right"
        case .left: return "Left"
        case .top: return "Top"
        case .bottom: return "Bottom"
        }
    }

    /// One sentence for the settings window.
    var explanation: String {
        switch self {
        case .right: return "Down the right-hand edge, clear of a Dock on that side."
        case .left: return "Down the left-hand edge, clear of a Dock on that side."
        case .top: return "A bar across the top. On a Mac with a notch of its own it runs up to meet it, so the two read as one shape."
        case .bottom: return "A bar resting on top of the Dock."
        }
    }
}
