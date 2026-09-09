// SideNotchShape.swift
// The notch body: a pill welded to one edge of the screen, with inverse
// rounded corners at each end that flare back out to the edge so it reads as
// part of the bezel rather than a floating panel. The path is written once,
// for the right edge, and transformed onto whichever edge it is on. When it
// joins a MacBook's own notch on the top edge the flares go and the corner is
// capped, so the resting shape is the hardware's and opening it grows that
// shape rather than hanging a tab below it. Kept from Notchd.

import SwiftUI

/// The notch outline.
struct SideNotchShape: Shape {
    var edge: NotchEdge = .right
    /// The display's own notch, when this one is drawn as it.
    var joining: HardwareNotch?
    var curlRadius: CGFloat = NotchLayout.curlRadius
    var cornerRadius: CGFloat = NotchLayout.cornerRadius

    /// The outline in a rect whose bezel side is decided by `edge`.
    /// - Parameter rect: The whole shape including the flares.
    /// - Returns: The path.
    func path(in rect: CGRect) -> Path {
        let depth = edge.isVertical ? rect.width : rect.height
        let length = edge.isVertical ? rect.height : rect.width
        let canonical = canonicalPath(
            in: CGRect(x: 0, y: 0, width: depth, height: length),
            flare: joining == nil ? curlRadius : NotchLayout.bezelFillet,
            cornerCap: joining.map { $0.height / 2 } ?? .greatestFiniteMagnitude
        )
        return canonical
            .applying(Self.transform(for: edge, depth: depth))
            .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    /// Canonical space, with the bezel at the right, onto the rect's own axes.
    /// - Parameters:
    ///   - edge: The edge.
    ///   - depth: The shape's extent inward from the bezel.
    /// - Returns: The transform.
    static func transform(for edge: NotchEdge, depth: CGFloat) -> CGAffineTransform {
        switch edge {
        case .right: return .identity
        case .left: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: depth, ty: 0)
        case .top: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: depth)
        case .bottom: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        }
    }

    /// The right-edge path. The corner is claimed first out of half the
    /// width and the flare takes what is left; the other order collapsed the
    /// corner to zero as the shape folded to its pill.
    private func canonicalPath(in rect: CGRect, flare: CGFloat, cornerCap: CGFloat) -> Path {
        let wanted = max(0, min(cornerRadius, cornerCap, rect.width / 2))
        let curl = max(0, min(flare, rect.height / 2, rect.width - wanted))
        let corner = max(0, min(wanted, (rect.height - 2 * curl) / 2))
        let bodyTop = rect.minY + curl
        let bodyBottom = rect.maxY - curl

        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        if curl > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - curl, y: rect.minY), radius: curl,
                        startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.minX + corner, y: bodyTop))
        path.addArc(center: CGPoint(x: rect.minX + corner, y: bodyTop + corner), radius: corner,
                    startAngle: .degrees(270), endAngle: .degrees(180), clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX, y: bodyBottom - corner))
        path.addArc(center: CGPoint(x: rect.minX + corner, y: bodyBottom - corner), radius: corner,
                    startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX - curl, y: bodyBottom))
        if curl > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - curl, y: rect.maxY), radius: curl,
                        startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
        }
        path.closeSubpath()
        return path
    }
}
