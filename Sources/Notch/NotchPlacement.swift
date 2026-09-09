// NotchPlacement.swift
// The one place that knows which way round the axes are. Everything else works
// in stack space: `along` runs the length of the notch and `across` measures
// inward from the bezel, so zero is always the screen edge. This type turns a
// stack-space coordinate into a point in the panel, whose origin is top-left.
// Kept from Notchd.

import Foundation

/// Stack space to panel space for one edge and panel size.
struct NotchPlacement {
    let edge: NotchEdge
    let panelSize: CGSize

    /// A point in panel coordinates.
    /// - Parameters:
    ///   - along: Distance along the notch.
    ///   - across: Distance inward from the bezel.
    /// - Returns: The panel point.
    func point(along: CGFloat, across: CGFloat) -> CGPoint {
        switch edge {
        case .right: return CGPoint(x: panelSize.width - across, y: along)
        case .left: return CGPoint(x: across, y: along)
        case .top: return CGPoint(x: along, y: across)
        case .bottom: return CGPoint(x: along, y: panelSize.height - across)
        }
    }

    /// A rect in panel coordinates spanning `depth` inward from `across`.
    /// - Parameters:
    ///   - along: Where it starts along the notch.
    ///   - across: Where it starts inward from the bezel.
    ///   - length: Its extent along the notch.
    ///   - depth: Its extent inward.
    /// - Returns: The panel rect.
    func rect(along: CGFloat, across: CGFloat, length: CGFloat, depth: CGFloat) -> CGRect {
        switch edge {
        case .right: return CGRect(x: panelSize.width - across - depth, y: along, width: depth, height: length)
        case .left: return CGRect(x: across, y: along, width: depth, height: length)
        case .top: return CGRect(x: along, y: across, width: length, height: depth)
        case .bottom: return CGRect(x: along, y: panelSize.height - across - depth, width: length, height: depth)
        }
    }

    /// The panel needed for a given length and depth.
    /// - Parameters:
    ///   - edge: The edge.
    ///   - length: Extent along the notch.
    ///   - depth: Extent inward.
    /// - Returns: The panel size.
    static func panelSize(edge: NotchEdge, length: CGFloat, depth: CGFloat) -> CGSize {
        edge.isVertical ? CGSize(width: depth, height: length) : CGSize(width: length, height: depth)
    }

    /// How far along the notch a panel point is.
    /// - Parameter point: A panel point.
    /// - Returns: The along coordinate.
    func along(of point: CGPoint) -> CGFloat {
        edge.isVertical ? point.y : point.x
    }

    /// How far inward from the bezel a panel point is.
    /// - Parameter point: A panel point.
    /// - Returns: The across coordinate.
    func across(of point: CGPoint) -> CGFloat {
        switch edge {
        case .right: return panelSize.width - point.x
        case .left: return point.x
        case .top: return point.y
        case .bottom: return panelSize.height - point.y
        }
    }

    /// The panel's extent along the notch.
    var panelLength: CGFloat { edge.isVertical ? panelSize.height : panelSize.width }

    /// The panel's extent inward.
    var panelDepth: CGFloat { edge.isVertical ? panelSize.width : panelSize.height }
}
