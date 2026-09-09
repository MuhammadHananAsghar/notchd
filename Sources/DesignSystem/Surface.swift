// Surface.swift
// How the notch body is filled. The notch floats over whatever is on screen,
// so its chrome has no guaranteed backdrop. A material samples what is behind
// and keeps a legibility floor, which is what lets one chrome work in both
// appearances. Render tests switch to a solid fill because a material paints
// nothing offscreen. Kept from Notchd.

import SwiftUI

/// The chrome fill.
enum Surface {
    /// Whether chrome draws as a material or as a flat colour.
    enum Mode {
        case glass
        case solid
    }

    /// Not a preference: the app always runs glass; only render tests set
    /// solid, and they set it back.
    @MainActor static var mode: Mode = .glass

    /// The fill for the notch body.
    @MainActor static var chrome: AnyShapeStyle {
        switch mode {
        case .glass: return AnyShapeStyle(.regularMaterial)
        case .solid: return AnyShapeStyle(Palette.chrome)
        }
    }

    /// The hairline along the chrome's edge, which is what reads as glass.
    static let edge = Color.primary.opacity(0.14)

    /// How far the chrome lifts off what is behind it.
    static let shadowRadius: CGFloat = 12
    static let shadowOpacity: Double = 0.18
}
