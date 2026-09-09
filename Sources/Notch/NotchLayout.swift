// NotchLayout.swift
// Every measurement of the notch, in points. The resting pill, the flares that
// weld the open shape to the bezel, and the content box the open notch wraps:
// a header, a row per live session, a few recent changes, and a footer with
// the two things you reach for from the edge.

import Foundation

/// Notch measurements.
enum NotchLayout {
    /// The flare radius where the open shape meets the bezel.
    static let curlRadius: CGFloat = 38
    /// The flare when joining a hardware notch, which does not taper.
    static let bezelFillet: CGFloat = 10
    /// The inward corners of the body.
    static let cornerRadius: CGFloat = 26

    /// The resting pill along the edge.
    static let pillLength: CGFloat = 124
    /// The resting pill's extent inward from the edge.
    static let pillDepth: CGFloat = 14
    /// The extra band around the pill that wakes it.
    static let pillHotZone: CGFloat = 40
    /// The activity dot on the resting pill.
    static let restingDot: CGFloat = 6
    /// Spacing between dots when several agents are working.
    static let restingDotGap: CGFloat = 10
    /// Dots shown at most on the resting pill.
    static let maximumRestingDots = 3

    /// The peek that announces a finished turn: a short tab along a top or
    /// bottom edge, a tab growing inward from a side edge.
    static let peekLength: CGFloat = 250
    static let peekDepth: CGFloat = 38
    static let peekSideLength: CGFloat = 62
    static let peekSideDepth: CGFloat = 230
    /// The flare while peeking. The open notch's flare would eat a tab this
    /// small whole.
    static let peekCurl: CGFloat = 14
    /// How long the peek stays out.
    static let peekDuration: TimeInterval = 3.2

    /// From the bezel to the content, and from the content to the inward face.
    static let edgePadding: CGFloat = 14
    /// Inside the content box.
    static let contentPadding: CGFloat = 14
    static let headerHeight: CGFloat = 26
    static let rowHeight: CGFloat = 38
    static let changeLineHeight: CGFloat = 20
    static let footerHeight: CGFloat = 30
    static let sectionGap: CGFloat = 8
    static let emptyLineHeight: CGFloat = 22
    /// The gear at the end of the header.
    static let gearSize: CGFloat = 22

    /// Rows and change lines shown at most.
    static let maximumRows = 4
    static let maximumChanges = 4

    /// Room around the shape inside the panel so the shadow is not clipped.
    static let shadowMargin: CGFloat = 24

    /// The content box's width for an edge: narrow down a side, wide across
    /// the top or bottom.
    /// - Parameter edge: The edge.
    /// - Returns: Points.
    static func contentWidth(for edge: NotchEdge) -> CGFloat {
        edge.isVertical ? 300 : 520
    }

    /// The content box's height for a number of rows and change lines.
    /// - Parameters:
    ///   - rows: Session rows shown.
    ///   - changes: Change lines shown.
    /// - Returns: Points.
    static func contentHeight(rows: Int, changes: Int) -> CGFloat {
        let rowsBlock = rows > 0 ? CGFloat(rows) * rowHeight : emptyLineHeight
        let changesBlock = changes > 0 ? sectionGap + CGFloat(changes) * changeLineHeight : 0
        return contentPadding + headerHeight + sectionGap + rowsBlock + changesBlock + sectionGap + footerHeight + contentPadding
    }
}
