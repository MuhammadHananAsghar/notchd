// PaletteContrastTests.swift
// Every semantic colour has to be legible in both appearances. These hold each
// one to WCAG's 3:1 floor for non-text contrast against the window surface in
// that appearance, so nobody can tune a hex for one mode and silently ruin the
// other.

import AppKit
import SwiftUI
import XCTest
@testable import Notchd

final class PaletteContrastTests: XCTestCase {
    /// WCAG 2.1 non-text contrast minimum.
    private let floor = 3.0

    /// Relative luminance of an sRGB colour.
    private func luminance(_ color: NSColor) -> Double {
        guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ raw: CGFloat) -> Double {
            let c = Double(raw)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(srgb.redComponent) + 0.7152 * channel(srgb.greenComponent) + 0.0722 * channel(srgb.blueComponent)
    }

    /// WCAG contrast ratio between two colours.
    private func ratio(_ a: NSColor, _ b: NSColor) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Resolves a dynamic colour under a pinned appearance, so the answer does
    /// not depend on the machine's System Settings.
    private func resolve(_ color: Color, _ name: NSAppearance.Name) -> NSColor {
        var resolved = NSColor.black
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        }
        return resolved
    }

    /// Asserts a colour clears the floor against the surface in both modes.
    private func check(_ color: Color, _ label: String) {
        let onLight = ratio(resolve(color, .aqua), resolve(Palette.surface, .aqua))
        let onDark = ratio(resolve(color, .darkAqua), resolve(Palette.surface, .darkAqua))
        XCTAssertGreaterThanOrEqual(onLight, floor, "\(label) scores \(String(format: "%.2f", onLight)) on the light surface")
        XCTAssertGreaterThanOrEqual(onDark, floor, "\(label) scores \(String(format: "%.2f", onDark)) on the dark surface")
    }

    func testCreateIsLegibleInBothAppearances() { check(Palette.create, "create") }
    func testModifyIsLegibleInBothAppearances() { check(Palette.modify, "modify") }
    func testDeleteIsLegibleInBothAppearances() { check(Palette.delete, "delete") }
    func testAttentionIsLegibleInBothAppearances() { check(Palette.attention, "attention") }

    /// The three change colours must be told apart from each other too.
    func testChangeColoursAreDistinct() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let create = resolve(Palette.create, name)
            let modify = resolve(Palette.modify, name)
            let delete = resolve(Palette.delete, name)
            XCTAssertNotEqual(create, modify)
            XCTAssertNotEqual(modify, delete)
            XCTAssertNotEqual(create, delete)
        }
    }

    /// Kinds that carry no change draw in the secondary text colour.
    func testKindColours() {
        XCTAssertEqual(Palette.color(for: .toolAfter), Palette.modify)
        XCTAssertEqual(Palette.color(for: .toolFailed), Palette.attention)
        XCTAssertEqual(Palette.color(for: .sessionStart), Palette.textSecondary)
    }
}
