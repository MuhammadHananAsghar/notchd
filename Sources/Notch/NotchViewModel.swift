// NotchViewModel.swift
// State and geometry for the notch. The content is what a person with agents
// running wants at a glance: which sessions are live, how much each changed in
// the last hour, the last few files touched, and two actions, open the
// timeline and revert the last ten minutes. The geometry works in stack space
// and hands the view and the window controller the same rects, so what is
// drawn and what takes clicks never disagree.

import Foundation
import SwiftUI

/// One live session in the notch.
struct NotchSessionRow: Identifiable, Equatable {
    let id: Int64
    let title: String
    let vendor: String
    let isActive: Bool
    let lastEventAt: Date
    let created: Int
    let modified: Int
    let deleted: Int

    /// Whether anything changed in the window.
    var hasChanges: Bool { created + modified + deleted > 0 }
}

/// A finished turn, shown for a moment on the closed notch.
struct NotchCelebration: Equatable, Identifiable {
    /// Fresh for every celebration, so two turns finishing with the same
    /// words still trigger two hops.
    let id = UUID()
    /// The session that finished, for a click that wants its page.
    let sessionId: Int64
    /// The vendor slug, which picks the mark drawn on the peek.
    let vendor: String
    /// The project name followed by "done".
    let title: String
    /// The change marks, such as `+1 ~2`, or empty when nothing changed.
    let detail: String
}

/// Something in the open notch that takes a click.
enum NotchTarget: Equatable {
    case gear
    case openTimeline
    case revertRecent
    case session(Int64)
}

/// The notch's state.
@MainActor
final class NotchViewModel: ObservableObject {
    @Published var isExpanded = false
    @Published var isPinned = false
    @Published var isAlwaysOn = false
    @Published var edge: NotchEdge = .right
    @Published var hardwareNotch: HardwareNotch?
    @Published var now = Date()
    @Published var hovered: NotchTarget?
    @Published private(set) var rows: [NotchSessionRow] = []
    @Published private(set) var recentChanges: [ChangeRow] = []
    @Published private(set) var counts = LedgerCounts(activeSessions: 0, recentChanges: 0)
    @Published private(set) var hasAnySessions = false
    @Published private(set) var celebration: NotchCelebration?
    private var celebrationClear: Task<Void, Never>?

    /// Shows a finished turn on the closed notch for a moment. A new one
    /// replaces the last.
    /// - Parameter celebration: What finished.
    func celebrate(_ celebration: NotchCelebration) {
        celebrationClear?.cancel()
        self.celebration = celebration
        celebrationClear = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(NotchLayout.peekDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.celebration = nil
        }
    }

    /// Whether the closed notch is showing a finished turn.
    var isPeeking: Bool { celebration != nil && !isExpanded }

    /// The peek's extent along the edge and inward from it.
    var peekLength: CGFloat {
        let wanted = edge.isVertical ? NotchLayout.peekSideLength : NotchLayout.peekLength
        return joinedNotch == nil ? min(wanted, expandedLength) : max(restingLength, min(wanted, expandedLength))
    }

    var peekDepth: CGFloat {
        let wanted = edge.isVertical ? NotchLayout.peekSideDepth : NotchLayout.peekDepth + contentInset
        return min(wanted, expandedDepth)
    }

    /// How far back the row counts and recent changes look.
    static let recentWindow: TimeInterval = 60 * 60

    /// Whether something other than the pointer is holding it open.
    var staysOpen: Bool { isPinned || isAlwaysOn }

    /// Reads the hardware notch from a screen.
    /// - Parameter screen: The screen the panel is on.
    func adopt(screen: ScreenDescribing) {
        hardwareNotch = screen.hardwareNotch
    }

    /// The hardware notch this one is drawn as, only on the top edge.
    var joinedNotch: HardwareNotch? { edge == .top ? hardwareNotch : nil }

    /// The band behind the hardware notch the content has to clear.
    var contentInset: CGFloat { joinedNotch?.height ?? 0 }

    /// The resting shape: the hardware notch when joined, else the pill.
    var restingLength: CGFloat { joinedNotch?.width ?? NotchLayout.pillLength }
    var restingDepth: CGFloat { joinedNotch?.height ?? NotchLayout.pillDepth }

    /// Rows and change lines actually shown.
    var shownRows: [NotchSessionRow] { Array(rows.prefix(NotchLayout.maximumRows)) }
    var shownChanges: [ChangeRow] { Array(recentChanges.prefix(NotchLayout.maximumChanges)) }

    /// The content box, in ordinary top-left coordinates.
    var contentSize: CGSize {
        CGSize(width: NotchLayout.contentWidth(for: edge),
               height: NotchLayout.contentHeight(rows: shownRows.count, changes: shownChanges.count))
    }

    /// The content's extent along the edge and inward from it.
    var contentAlong: CGFloat { edge.isVertical ? contentSize.height : contentSize.width }
    var contentAcross: CGFloat { edge.isVertical ? contentSize.width : contentSize.height }

    /// The open shape.
    var expandedLength: CGFloat { contentAlong + 2 * NotchLayout.curlRadius }
    var expandedDepth: CGFloat { contentAcross + 2 * NotchLayout.edgePadding + contentInset }

    /// The shape as currently drawn: open, peeking, or at rest.
    var shapeLength: CGFloat { isExpanded ? expandedLength : (isPeeking ? peekLength : restingLength) }
    var shapeDepth: CGFloat { isExpanded ? expandedDepth : (isPeeking ? peekDepth : restingDepth) }

    /// Where the peek's text goes: inside the peeking shape, clear of the
    /// hardware band on a joined top edge.
    /// - Parameter place: The placement.
    /// - Returns: The rect in panel coordinates.
    func peekContentRect(_ place: NotchPlacement) -> CGRect {
        let along = slack + (max(expandedLength, restingLength) - peekLength) / 2
        return place.rect(along: along, across: contentInset + 4, length: peekLength, depth: max(0, peekDepth - contentInset - 8))
    }

    /// Where the resting dots sit, centred on the pill and spread along it.
    /// - Parameters:
    ///   - count: How many agents are working.
    ///   - place: The placement.
    /// - Returns: One point per dot, in panel coordinates.
    func restingDotPoints(count: Int, _ place: NotchPlacement) -> [CGPoint] {
        let shown = min(max(count, 0), NotchLayout.maximumRestingDots)
        guard shown > 0 else { return [] }
        let centre = slack + max(expandedLength, restingLength) / 2
        let span = CGFloat(shown - 1) * NotchLayout.restingDotGap
        return (0..<shown).map { index in
            place.point(along: centre - span / 2 + CGFloat(index) * NotchLayout.restingDotGap, across: restingDepth / 2)
        }
    }

    /// The panel: the open shape plus room for its shadow.
    var panelSize: CGSize {
        NotchPlacement.panelSize(edge: edge, length: max(expandedLength, restingLength) + 2 * NotchLayout.shadowMargin,
                                 depth: max(expandedDepth, restingDepth) + NotchLayout.shadowMargin)
    }

    /// Where the open shape starts along the panel.
    var slack: CGFloat { NotchLayout.shadowMargin }

    /// The panel's placement for a real panel size.
    /// - Parameter size: The panel's actual size, which AppKit may have rounded.
    /// - Returns: The placement.
    func placement(panelSize size: CGSize? = nil) -> NotchPlacement {
        NotchPlacement(edge: edge, panelSize: size ?? panelSize)
    }

    /// The shape as drawn, centred where the open shape would be.
    /// - Parameter place: The placement.
    /// - Returns: The rect in panel coordinates.
    func notchRect(_ place: NotchPlacement) -> CGRect {
        let along = slack + (max(expandedLength, restingLength) - shapeLength) / 2
        return place.rect(along: along, across: 0, length: shapeLength, depth: shapeDepth)
    }

    /// The open shape's rect whether or not it is open, for the hit region.
    /// - Parameter place: The placement.
    /// - Returns: The rect in panel coordinates.
    func expandedRect(_ place: NotchPlacement) -> CGRect {
        let along = slack + (max(expandedLength, restingLength) - expandedLength) / 2
        return place.rect(along: along, across: 0, length: expandedLength, depth: expandedDepth)
    }

    /// The resting pill plus its hot zone.
    /// - Parameter place: The placement.
    /// - Returns: The rect in panel coordinates.
    func pillHotRect(_ place: NotchPlacement) -> CGRect {
        let length = restingLength + NotchLayout.pillHotZone
        let along = slack + (max(expandedLength, restingLength) - length) / 2
        return place.rect(along: along, across: 0, length: length, depth: restingDepth + NotchLayout.pillHotZone)
    }

    /// The content box in panel coordinates. Content is never rotated: only
    /// the shape is, so this box is laid out with ordinary top-left axes.
    /// - Parameter place: The placement.
    /// - Returns: The rect.
    func contentRect(_ place: NotchPlacement) -> CGRect {
        let along = slack + (max(expandedLength, restingLength) - expandedLength) / 2 + NotchLayout.curlRadius
        return place.rect(along: along, across: NotchLayout.edgePadding + contentInset, length: contentAlong, depth: contentAcross)
    }

    /// Where a target sits inside the content box.
    /// - Parameters:
    ///   - target: The target.
    ///   - place: The placement.
    /// - Returns: The rect in panel coordinates, or nil when not shown.
    func rect(for target: NotchTarget, _ place: NotchPlacement) -> CGRect? {
        let box = contentRect(place)
        let inner = box.insetBy(dx: NotchLayout.contentPadding, dy: NotchLayout.contentPadding)
        switch target {
        case .gear:
            return CGRect(x: inner.maxX - NotchLayout.gearSize, y: inner.minY, width: NotchLayout.gearSize, height: NotchLayout.headerHeight)
        case .openTimeline:
            return CGRect(x: inner.minX, y: inner.maxY - NotchLayout.footerHeight, width: inner.width / 2, height: NotchLayout.footerHeight)
        case .revertRecent:
            return CGRect(x: inner.midX, y: inner.maxY - NotchLayout.footerHeight, width: inner.width / 2, height: NotchLayout.footerHeight)
        case .session(let id):
            guard let index = shownRows.firstIndex(where: { $0.id == id }) else { return nil }
            let top = inner.minY + NotchLayout.headerHeight + NotchLayout.sectionGap + CGFloat(index) * NotchLayout.rowHeight
            return CGRect(x: inner.minX, y: top, width: inner.width, height: NotchLayout.rowHeight)
        }
    }

    /// Every target currently shown.
    var targets: [NotchTarget] {
        [.gear, .openTimeline, .revertRecent] + shownRows.map { .session($0.id) }
    }

    /// The target under a panel point, if the notch is open.
    /// - Parameters:
    ///   - point: A panel point.
    ///   - place: The placement.
    /// - Returns: The target, or nil.
    func target(at point: CGPoint, _ place: NotchPlacement) -> NotchTarget? {
        guard isExpanded else { return nil }
        return targets.first { rect(for: $0, place)?.contains(point) ?? false }
    }

    /// Rebuilds the rows and recent changes from the ledger's view of now.
    /// - Parameters:
    ///   - sessions: Sessions, most recent first.
    ///   - changes: Changes within the recent window, any order.
    ///   - counts: The menu bar counts.
    ///   - now: The reference instant.
    func update(sessions: [SessionRow], changes: [ChangeRow], counts: LedgerCounts, now: Date) {
        self.now = now
        self.counts = counts
        hasAnySessions = !sessions.isEmpty
        let bySession = Dictionary(grouping: changes.filter { $0.attributed }, by: { $0.sessionId ?? -1 })
        rows = sessions
            .filter { $0.vendor != "notchd" && $0.isActive(at: now) }
            .sorted { $0.lastEventAt > $1.lastEventAt }
            .map { session in
                let own = bySession[session.id] ?? []
                return NotchSessionRow(id: session.id, title: session.projectName.isEmpty ? session.cwd : session.projectName,
                                       vendor: VendorNames.display(session.vendor), isActive: true, lastEventAt: session.lastEventAt,
                                       created: own.filter { $0.kind == .create }.count,
                                       modified: own.filter { $0.kind == .modify }.count,
                                       deleted: own.filter { $0.kind == .delete }.count)
            }
        recentChanges = changes.sorted { ($0.ts, $0.id) > ($1.ts, $1.id) }
    }
}
