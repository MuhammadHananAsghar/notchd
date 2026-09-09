// NotchRootView.swift
// What the notch draws: the glass shape welded to the edge; on the resting
// pill one breathing dot per working agent, a small hop and a short peek when
// one finishes; and when open the header, one row per live session, the last
// few files touched, and the two footer actions. Nothing here is a SwiftUI
// button: the window controller hit-tests the same rects the view model lays
// out with, because the panel is non-activating and clicks arrive at the
// window first. Every movement respects Reduce Motion.

import SwiftUI

/// The notch's content.
struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let place = model.placement(panelSize: proxy.size)
            let shape = model.notchRect(place)
            let curl = model.isPeeking ? NotchLayout.peekCurl : NotchLayout.curlRadius
            ZStack(alignment: .topLeading) {
                SideNotchShape(edge: model.edge, joining: model.joinedNotch, curlRadius: curl)
                    .fill(Surface.chrome)
                    .overlay(SideNotchShape(edge: model.edge, joining: model.joinedNotch, curlRadius: curl).stroke(Surface.edge, lineWidth: 1))
                    .shadow(color: .black.opacity(model.joinedNotch == nil ? Surface.shadowOpacity : 0), radius: Surface.shadowRadius)
                    .frame(width: shape.width, height: shape.height)
                    .position(x: shape.midX, y: shape.midY)
                    .animation(motion(NotchMotion.unfold), value: model.isExpanded)
                    .animation(motion(NotchMotion.peek), value: model.isPeeking)
                if !model.isExpanded, !model.isPeeking, model.joinedNotch == nil {
                    RestingDots(points: model.restingDotPoints(count: model.counts.activeSessions, place), hopToken: model.celebration?.id, reduceMotion: reduceMotion)
                }
                if model.isPeeking, let celebration = model.celebration {
                    let box = model.peekContentRect(place)
                    PeekView(celebration: celebration)
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                        .transition(.opacity)
                }
                if model.isExpanded {
                    let box = model.contentRect(place)
                    content
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                        .transition(.opacity)
                        .animation(motion(NotchMotion.contents), value: model.isExpanded)
                }
            }
        }
    }

    /// The animation, unless the system asks for less movement.
    private func motion(_ animation: Animation) -> Animation? {
        NotchMotion.respectingReduceMotion(animation, reduceMotion)
    }

    /// Header, rows, recent changes, footer.
    private var content: some View {
        VStack(alignment: .leading, spacing: NotchLayout.sectionGap) {
            header
            if model.shownRows.isEmpty {
                emptyRows
            } else {
                ForEach(Array(model.shownRows.enumerated()), id: \.element.id) { index, row in
                    NotchSessionRowView(row: row, now: model.now, highlighted: model.hovered == .session(row.id))
                        .animation(motion(NotchMotion.stagger(index: index)), value: model.isExpanded)
                }
            }
            if !model.shownChanges.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.shownChanges) { change in
                        NotchChangeLine(change: change)
                    }
                }
            }
            footer
        }
        .padding(NotchLayout.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The name, the counts, and the gear.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .font(.system(size: 13, weight: .semibold))
            Text("Notchd").font(Typography.heading)
            Text(NotchCopy.summary(model.counts)).font(Typography.caption).foregroundStyle(Palette.textSecondary)
            Spacer()
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(model.hovered == .gear ? Palette.textPrimary : Palette.textSecondary)
                .frame(width: NotchLayout.gearSize, height: NotchLayout.gearSize)
        }
        .frame(height: NotchLayout.headerHeight)
    }

    /// What to say when no agent is running.
    private var emptyRows: some View {
        Text(model.hasAnySessions ? "No agents running" : "No agent set up yet. Open settings from the gear.")
            .font(Typography.caption)
            .foregroundStyle(Palette.textSecondary)
            .frame(height: NotchLayout.emptyLineHeight)
    }

    /// The two actions reachable from the edge.
    private var footer: some View {
        HStack(spacing: 0) {
            NotchActionLabel(title: "Open timeline", symbol: "rectangle.split.3x1", highlighted: model.hovered == .openTimeline)
                .frame(maxWidth: .infinity, alignment: .leading)
            NotchActionLabel(title: "Revert last 10 min…", symbol: "arrow.uturn.backward", highlighted: model.hovered == .revertRecent)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: NotchLayout.footerHeight)
    }
}

/// One breathing dot per working agent. When a turn finishes the dots hop
/// once and settle, the way a small thing nods.
struct RestingDots: View {
    let points: [CGPoint]
    let hopToken: UUID?
    let reduceMotion: Bool
    @State private var breathing = false
    @State private var hopping = false

    var body: some View {
        ZStack {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                Circle()
                    .fill(Palette.create)
                    .frame(width: NotchLayout.restingDot, height: NotchLayout.restingDot)
                    .scaleEffect(breathing && !reduceMotion ? 1.35 : 1)
                    .opacity(breathing && !reduceMotion ? 1 : 0.72)
                    .animation(reduceMotion ? nil : NotchMotion.breath.delay(Double(index) * 0.25), value: breathing)
                    .offset(y: hopping && !reduceMotion ? -7 : 0)
                    .animation(reduceMotion ? nil : NotchMotion.hop, value: hopping)
                    .position(point)
            }
        }
        .onAppear { breathing = true }
        .onChange(of: hopToken) { _, token in
            guard token != nil, !reduceMotion else { return }
            hopping = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { hopping = false }
        }
    }
}

/// The short tab that announces a finished turn.
struct PeekView: View {
    let celebration: NotchCelebration
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            AgentGlyphView(glyph: AgentGlyph.forVendor(celebration.vendor), size: 22)
                .foregroundStyle(Palette.textPrimary)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Palette.create)
                        .background(Circle().fill(Palette.chrome).padding(-1))
                        .offset(x: 4, y: 3)
                        .scaleEffect(drawn || reduceMotion ? 1 : 0.2)
                }
                .scaleEffect(drawn || reduceMotion ? 1 : 0.5)
                .rotationEffect(.degrees(drawn || reduceMotion ? 0 : -30))
            Text(celebration.title).font(Typography.body).lineLimit(1).truncationMode(.middle)
            if !celebration.detail.isEmpty {
                Text(celebration.detail).font(Typography.mono).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(reduceMotion ? nil : NotchMotion.check.delay(0.12)) { drawn = true }
        }
    }
}

/// One live session.
struct NotchSessionRowView: View {
    let row: NotchSessionRow
    let now: Date
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.create).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(Typography.body).lineLimit(1)
                Text("\(row.vendor) · \(NotchCopy.ago(row.lastEventAt, now: now))").font(Typography.caption).foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            if row.hasChanges {
                HStack(spacing: 6) {
                    if row.created > 0 { Text("+\(row.created)").foregroundStyle(Palette.create) }
                    if row.modified > 0 { Text("~\(row.modified)").foregroundStyle(Palette.modify) }
                    if row.deleted > 0 { Text("-\(row.deleted)").foregroundStyle(Palette.delete) }
                }
                .font(Typography.mono)
            } else {
                Text("no changes").font(Typography.caption).foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: NotchLayout.rowHeight)
        .background(highlighted ? Palette.separator.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// One recent change.
struct NotchChangeLine: View {
    let change: ChangeRow

    var body: some View {
        HStack(spacing: 6) {
            Text(ChangeCopy.mark(for: change.kind))
                .foregroundStyle(Palette.color(for: change.kind))
                .frame(width: 10)
            Text(NotchCopy.shortPath(change.path))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(change.attributed ? Palette.textPrimary : Palette.textSecondary)
        }
        .font(Typography.mono)
        .frame(height: NotchLayout.changeLineHeight)
    }
}

/// A footer action.
struct NotchActionLabel: View {
    let title: String
    let symbol: String
    let highlighted: Bool

    var body: some View {
        Label(title, systemImage: symbol)
            .font(Typography.caption)
            .foregroundStyle(highlighted ? Palette.textPrimary : Palette.textSecondary)
            .padding(.horizontal, 6)
    }
}

/// Words for the notch.
enum NotchCopy {
    /// The header summary.
    /// - Parameter counts: The totals.
    /// - Returns: Text such as `2 agents · 41 changes / h`.
    static func summary(_ counts: LedgerCounts) -> String {
        let agents = counts.activeSessions == 1 ? "1 agent" : "\(counts.activeSessions) agents"
        return "\(agents) · \(counts.recentChanges) changes / h"
    }

    /// A short relative time.
    /// - Parameters:
    ///   - date: The instant.
    ///   - now: The reference instant.
    /// - Returns: Text such as `just now`, `3 min ago`.
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        return "\(Int(seconds / 3600)) h ago"
    }

    /// The last two path components, enough to recognise a file.
    /// - Parameter path: An absolute path.
    /// - Returns: The tail.
    static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }
}
