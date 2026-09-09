// NotchVisibility.swift
// How much of itself the notch shows when you are not using it. Three states,
// because the default is neither always nor never: a pill that opens on
// contact. Kept from Notchd.

import Foundation

/// The notch's resting behaviour.
enum NotchVisibility: String, CaseIterable, Identifiable {
    /// Pinned open.
    case alwaysShow
    /// A pill at the edge that unfolds when the pointer reaches it.
    case onHover
    /// Nothing on screen.
    case hidden

    var id: String { rawValue }

    /// The picker label.
    var title: String {
        switch self {
        case .alwaysShow: return "Always show"
        case .onHover: return "Show on hover"
        case .hidden: return "Hide"
        }
    }

    /// One sentence for the settings window.
    var explanation: String {
        switch self {
        case .alwaysShow: return "The notch stays open."
        case .onHover: return "A small pill at the screen edge that opens when you reach it."
        case .hidden: return "Nothing on screen. The menu bar item is the way back to these settings."
        }
    }
}
