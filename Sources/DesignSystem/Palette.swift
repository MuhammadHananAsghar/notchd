// Palette.swift
// Every colour Notchd draws, in both appearances. Three semantic colours for
// what happened to a file (created, modified, deleted), one attention colour
// for a failed or partial revert, and system text colours. No vendor brand
// colours: agents are told apart by a glyph and a label. Each value is held to
// WCAG's 3:1 non-text floor against a nominal surface by PaletteContrastTests.

import AppKit
import SwiftUI

/// Notchd's colour tokens.
enum Palette {
    /// A file that did not exist before the change.
    static let create = dynamic(light: 0x1A7F37, dark: 0x3FB950)
    /// A file whose contents changed.
    static let modify = dynamic(light: 0x0550AE, dark: 0x58A6FF)
    /// A file that was removed.
    static let delete = dynamic(light: 0xCF222E, dark: 0xFF7B72)
    /// A failed tool call, or a revert that could only be partial.
    static let attention = dynamic(light: 0x9A6700, dark: 0xD29922)

    /// The window ground. Flat rather than a material so diffs read cleanly.
    static let surface = dynamic(light: 0xF6F6F7, dark: 0x1C1C1E)
    /// The notch chrome where a material cannot be drawn. Not pure black:
    /// under a translucent surface that reads as a hole rather than as glass.
    static let chrome = dynamic(light: 0xF2F2F2, dark: 0x1C1C1E)
    /// A raised card or the inspector.
    static let panel = dynamic(light: 0xFFFFFF, dark: 0x252528)
    /// Hairlines between regions.
    static let separator = dynamic(light: 0xD9D9DE, dark: 0x3A3A3F)

    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary

    /// The colour for an event kind in a list.
    /// - Parameter kind: The event kind.
    /// - Returns: A semantic colour, or the secondary text colour for kinds
    ///   that carry no change.
    static func color(for kind: NotchdEvent.Kind) -> Color {
        switch kind {
        case .toolAfter: return modify
        case .toolFailed: return attention
        case .toolBefore, .sessionStart, .sessionEnd, .note: return textSecondary
        }
    }

    /// A colour that resolves against whichever appearance is current when it
    /// is drawn, so it is right inside renderers and follows a system change
    /// with no state to invalidate.
    /// - Parameters:
    ///   - light: The sRGB hex for light appearance.
    ///   - dark: The sRGB hex for dark appearance.
    /// - Returns: A dynamic colour.
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    /// An opaque sRGB colour from a 24-bit hex value.
    /// - Parameter hex: `0xRRGGBB`.
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
