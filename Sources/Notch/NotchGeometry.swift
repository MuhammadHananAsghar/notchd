// NotchGeometry.swift
// Where the panel goes on the screen, and what the display's own notch looks
// like. The panel hugs the chosen edge of the visible frame, so it rests on
// the Dock rather than under it, and is centred on the full frame so a Dock
// hiding does not slide a side notch up and down. Kept from Notchd.

import AppKit

/// The display's own notch: the camera housing on a MacBook.
struct HardwareNotch: Equatable {
    let width: CGFloat
    let height: CGFloat
}

/// What the geometry needs from a screen, so tests can fake one.
protocol ScreenDescribing {
    var frameValue: CGRect { get }
    var visibleFrameValue: CGRect { get }
    var hardwareNotch: HardwareNotch? { get }
}

extension ScreenDescribing {
    /// Most displays have none.
    var hardwareNotch: HardwareNotch? { nil }
}

extension NSScreen: ScreenDescribing {
    var frameValue: CGRect { frame }
    var visibleFrameValue: CGRect { visibleFrame }

    /// Measured from the two menu bar strips either side of the notch, which
    /// is the only thing AppKit describes directly; the height is the top
    /// safe-area inset. A display without a notch reports no auxiliary areas.
    var hardwareNotch: HardwareNotch? {
        guard let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return nil }
        let width = frame.width - left.width - right.width
        let height = safeAreaInsets.top
        guard width > 0, height > 0 else { return nil }
        return HardwareNotch(width: width, height: height)
    }
}

/// Panel placement.
enum NotchGeometry {
    /// The panel frame for an edge, centred along it, hugging the visible
    /// frame's edge, rounded out to whole points so the content reaches the
    /// bezel with no hairline of wallpaper.
    ///
    /// On the top edge of a Mac with a hardware notch the panel goes all the
    /// way up to meet it, past the menu bar, so the two read as one shape.
    /// - Parameters:
    ///   - screen: The screen.
    ///   - panelSize: The size wanted.
    ///   - edge: The edge.
    /// - Returns: The frame in screen coordinates.
    static func panelFrame(for screen: ScreenDescribing, panelSize: CGSize, edge: NotchEdge = .right) -> CGRect {
        let full = screen.frameValue
        let usable = screen.visibleFrameValue
        let width = panelSize.width.rounded(.up)
        let height = panelSize.height.rounded(.up)
        let origin: CGPoint
        switch edge {
        case .right:
            origin = CGPoint(x: usable.maxX - width, y: full.midY - height / 2)
        case .left:
            origin = CGPoint(x: usable.minX, y: full.midY - height / 2)
        case .top:
            let top = screen.hardwareNotch == nil ? usable.maxY : full.maxY
            origin = CGPoint(x: full.midX - width / 2, y: top - height)
        case .bottom:
            origin = CGPoint(x: full.midX - width / 2, y: usable.minY)
        }
        return CGRect(x: origin.x.rounded(), y: origin.y.rounded(), width: width, height: height)
    }

    /// The notch follows the screen with the menu bar.
    /// - Parameter screens: The connected screens.
    /// - Returns: The screen to use.
    static func preferredScreen(from screens: [NSScreen]) -> NSScreen? {
        NSScreen.main ?? screens.first
    }
}
