// LaneView.swift
// The lanes: time runs left to right, one row per session, every change a
// tick coloured by kind. Hook-recorded ticks draw solid, transcript-derived
// ones hatched, unattributed ones faded. Drag across one or more lanes to
// select a span; hover a tick to read its path in the header.

import SwiftUI

/// Fixed measurements of the lane view.
enum LaneLayout {
    static let labelWidth: CGFloat = 200
    static let laneHeight: CGFloat = 34
    static let axisHeight: CGFloat = 22
    static let tickWidth: CGFloat = 2
    static let tickHeight: CGFloat = 18
    static let hoverRadius: CGFloat = 6
    /// The most height the lanes take before they scroll.
    static let maximumHeight: CGFloat = 320

    /// The height that fits a number of lanes without scrolling.
    /// - Parameter count: The number of lanes.
    /// - Returns: Points.
    static func height(forLanes count: Int) -> CGFloat {
        axisHeight + CGFloat(max(count, 1)) * laneHeight + 8
    }
}

/// Converts between time and x, and between lane index and y.
struct LaneGeometry {
    let size: CGSize
    let start: Date
    let end: Date

    /// The width of the track region.
    var trackWidth: CGFloat { max(1, size.width - LaneLayout.labelWidth - 12) }

    /// The x of an instant.
    /// - Parameter date: The instant.
    /// - Returns: Points from the left edge.
    func x(for date: Date) -> CGFloat {
        let fraction = date.timeIntervalSince(start) / max(1, end.timeIntervalSince(start))
        return LaneLayout.labelWidth + CGFloat(min(max(fraction, 0), 1)) * trackWidth
    }

    /// The instant at an x.
    /// - Parameter x: Points from the left edge.
    /// - Returns: The instant, clamped to the range.
    func date(at x: CGFloat) -> Date {
        let fraction = Double((x - LaneLayout.labelWidth) / trackWidth)
        return start.addingTimeInterval(min(max(fraction, 0), 1) * end.timeIntervalSince(start))
    }

    /// The vertical centre of a lane.
    /// - Parameter index: The lane's index.
    /// - Returns: Points from the top.
    func y(forLane index: Int) -> CGFloat {
        LaneLayout.axisHeight + CGFloat(index) * LaneLayout.laneHeight + LaneLayout.laneHeight / 2
    }

    /// The lane index at a y, or nil above the lanes.
    /// - Parameter y: Points from the top.
    /// - Returns: The index.
    func laneIndex(at y: CGFloat) -> Int? {
        guard y >= LaneLayout.axisHeight else { return nil }
        return Int((y - LaneLayout.axisHeight) / LaneLayout.laneHeight)
    }
}

/// Changes that fall on the same pixel column of a lane.
struct TickCluster: Equatable {
    let x: CGFloat
    let changes: [ChangeRow]

    /// Distance in points within which ticks merge.
    static let mergeDistance: CGFloat = 3

    /// The most serious kind in the cluster: delete over modify over create.
    var kind: ChangeKind {
        if changes.contains(where: { $0.kind == .delete }) { return .delete }
        if changes.contains(where: { $0.kind == .modify }) { return .modify }
        return .create
    }

    /// Whether every change in the cluster was claimed by an agent.
    var attributed: Bool { changes.allSatisfy(\.attributed) }

    /// Groups changes whose ticks would overlap.
    /// - Parameters:
    ///   - changes: The lane's changes in any order.
    ///   - x: The tick position of a change.
    /// - Returns: Clusters ordered left to right.
    static func clusters(_ changes: [ChangeRow], x: (ChangeRow) -> CGFloat) -> [TickCluster] {
        let sorted = changes.map { ($0, x($0)) }.sorted { $0.1 < $1.1 }
        var result: [TickCluster] = []
        for (change, position) in sorted {
            if let last = result.last, position - last.x <= mergeDistance {
                result[result.count - 1] = TickCluster(x: last.x, changes: last.changes + [change])
            } else {
                result.append(TickCluster(x: position, changes: [change]))
            }
        }
        return result
    }
}

/// The lanes.
struct LaneView: View {
    @ObservedObject var model: TimelineModel
    @State private var drag: (from: CGPoint, to: CGPoint)?

    var body: some View {
        GeometryReader { proxy in
            let geometry = LaneGeometry(size: proxy.size, start: model.rangeStart, end: model.rangeEnd)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    draw(in: &context, size: size, geometry: geometry)
                }
                labels
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(geometry))
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): model.hover = nearestTick(to: point, geometry: geometry)
                case .ended: model.hover = nil
                }
            }
        }
        .background(Palette.panel)
    }

    /// Lane titles down the left edge.
    private var labels: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: LaneLayout.axisHeight)
            ForEach(model.lanes) { lane in
                HStack(spacing: 6) {
                    Circle()
                        .fill(lane.isActive ? Palette.create : Palette.separator)
                        .frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(lane.title).font(Typography.body).lineLimit(1)
                        if !lane.subtitle.isEmpty {
                            Text(lane.subtitle).font(Typography.caption).foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
                .padding(.leading, 12)
                .frame(width: LaneLayout.labelWidth, height: LaneLayout.laneHeight, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { model.page = lane.isUnattributed ? .unattributed : .session(lane.id) }
            }
        }
    }

    /// Draws the axis, the lane tracks, the ticks, and the selection.
    private func draw(in context: inout GraphicsContext, size: CGSize, geometry: LaneGeometry) {
        drawAxis(in: &context, geometry: geometry)
        for (index, lane) in model.lanes.enumerated() {
            let y = geometry.y(forLane: index)
            context.fill(Path(CGRect(x: LaneLayout.labelWidth, y: y - 0.5, width: geometry.trackWidth, height: 1)),
                         with: .color(Palette.separator))
            for cluster in TickCluster.clusters(lane.changes, x: { geometry.x(for: $0.ts) }) {
                drawTick(cluster, lane: lane, at: CGPoint(x: cluster.x, y: y), in: &context)
            }
        }
        if let rect = selectionRect(geometry: geometry) {
            context.fill(Path(rect), with: .color(Palette.modify.opacity(0.12)))
            context.stroke(Path(rect), with: .color(Palette.modify.opacity(0.6)), lineWidth: 1)
        }
    }

    /// Five time labels along the top.
    private func drawAxis(in context: inout GraphicsContext, geometry: LaneGeometry) {
        let formatter = DateFormatter()
        formatter.dateFormat = geometry.end.timeIntervalSince(geometry.start) > 86_400 ? "EEE HH:mm" : "HH:mm"
        for step in 0...4 {
            let date = geometry.start.addingTimeInterval(geometry.end.timeIntervalSince(geometry.start) * Double(step) / 4)
            let x = geometry.x(for: date)
            let text = Text(formatter.string(from: date)).font(Typography.caption).foregroundColor(Palette.textSecondary)
            let anchor: UnitPoint = step == 0 ? .topLeading : (step == 4 ? .topTrailing : .top)
            context.draw(text, at: CGPoint(x: x, y: 4), anchor: anchor)
            context.fill(Path(CGRect(x: x - 0.5, y: LaneLayout.axisHeight - 4, width: 1, height: 4)), with: .color(Palette.separator))
        }
    }

    /// One tick, or one cluster of ticks too close to tell apart, styled by
    /// kind and fidelity. A cluster is wider, in the colour of its most
    /// serious kind, so several changes at one instant do not read as one.
    private func drawTick(_ cluster: TickCluster, lane: TimelineLane, at point: CGPoint, in context: inout GraphicsContext) {
        let width = LaneLayout.tickWidth + CGFloat(min(cluster.changes.count - 1, 4))
        let rect = CGRect(x: point.x - width / 2, y: point.y - LaneLayout.tickHeight / 2, width: width, height: LaneLayout.tickHeight)
        let color = Palette.color(for: cluster.kind)
        if lane.isUnattributed || !cluster.attributed {
            context.fill(Path(rect), with: .color(color.opacity(0.45)))
        } else if lane.fidelity == .derived {
            context.stroke(Path(rect), with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        } else {
            context.fill(Path(rect), with: .color(color))
        }
    }

    /// The rectangle of the live drag or the committed selection.
    private func selectionRect(geometry: LaneGeometry) -> CGRect? {
        if let drag {
            return rect(from: drag.from, to: drag.to, geometry: geometry)
        }
        guard let selection = model.selection else { return nil }
        let indices = model.lanes.enumerated().filter { selection.laneIds.isEmpty || selection.laneIds.contains($1.id) }.map(\.offset)
        guard let first = indices.min(), let last = indices.max() else { return nil }
        let top = geometry.y(forLane: first) - LaneLayout.laneHeight / 2
        let bottom = geometry.y(forLane: last) + LaneLayout.laneHeight / 2
        return CGRect(x: geometry.x(for: selection.start), y: top,
                      width: geometry.x(for: selection.end) - geometry.x(for: selection.start), height: bottom - top)
    }

    /// The rectangle between two drag points, snapped to whole lanes.
    private func rect(from: CGPoint, to: CGPoint, geometry: LaneGeometry) -> CGRect {
        let x0 = max(LaneLayout.labelWidth, min(from.x, to.x))
        let x1 = min(geometry.size.width, max(from.x, to.x))
        let lanes = laneRange(from: from, to: to, geometry: geometry)
        let top = geometry.y(forLane: lanes.lowerBound) - LaneLayout.laneHeight / 2
        let bottom = geometry.y(forLane: lanes.upperBound) + LaneLayout.laneHeight / 2
        return CGRect(x: x0, y: top, width: x1 - x0, height: bottom - top)
    }

    /// The lane indices a drag covers, clamped to real lanes.
    private func laneRange(from: CGPoint, to: CGPoint, geometry: LaneGeometry) -> ClosedRange<Int> {
        let count = max(model.lanes.count, 1)
        let a = min(max(geometry.laneIndex(at: from.y) ?? 0, 0), count - 1)
        let b = min(max(geometry.laneIndex(at: to.y) ?? 0, 0), count - 1)
        return min(a, b)...max(a, b)
    }

    /// Dragging selects a span across the lanes under it.
    private func dragGesture(_ geometry: LaneGeometry) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in drag = (value.startLocation, value.location) }
            .onEnded { value in
                drag = nil
                let lanes = laneRange(from: value.startLocation, to: value.location, geometry: geometry)
                let ids = Set(model.lanes.enumerated().filter { lanes.contains($0.offset) }.map(\.element.id))
                let allLanes = ids.count == model.lanes.count
                model.selection = TimelineSelection(
                    start: geometry.date(at: min(value.startLocation.x, value.location.x)),
                    end: geometry.date(at: max(value.startLocation.x, value.location.x)),
                    laneIds: allLanes ? [] : ids
                )
            }
    }

    /// The tick within reach of a point, if any.
    private func nearestTick(to point: CGPoint, geometry: LaneGeometry) -> TickInfo? {
        guard let index = geometry.laneIndex(at: point.y), index < model.lanes.count else { return nil }
        let lane = model.lanes[index]
        let nearest = lane.changes.min { abs(geometry.x(for: $0.ts) - point.x) < abs(geometry.x(for: $1.ts) - point.x) }
        guard let nearest, abs(geometry.x(for: nearest.ts) - point.x) <= LaneLayout.hoverRadius else { return nil }
        return TickInfo(change: nearest, laneTitle: lane.title)
    }
}
