// NotchTests.swift
// The notch's geometry: the panel hugs the chosen edge and is centred along
// it, stack space maps onto every edge the same way, the resting shape is the
// pill or the hardware notch, the open shape wraps the content, the hit
// targets sit where the view draws them, and the rows summarise the ledger.

import SwiftUI
import XCTest
@testable import Notchd

private struct FakeScreen: ScreenDescribing {
    var frameValue: CGRect
    var visibleFrameValue: CGRect
    var hardwareNotch: HardwareNotch?
}

private let plain = FakeScreen(
    frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1169),
    visibleFrameValue: CGRect(x: 0, y: 0, width: 1800, height: 1132),
    hardwareNotch: nil
)

private let notched = FakeScreen(
    frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1169),
    visibleFrameValue: CGRect(x: 0, y: 59, width: 1800, height: 1071),
    hardwareNotch: HardwareNotch(width: 220, height: 38)
)

final class NotchGeometryTests: XCTestCase {
    /// The panel hugs the right edge and is centred vertically, to within the
    /// half point that rounding to whole points allows.
    func testPanelHugsTheRightEdgeAndIsCentred() {
        let frame = NotchGeometry.panelFrame(for: plain, panelSize: CGSize(width: 334, height: 484))
        XCTAssertEqual(frame.maxX, 1800, accuracy: 0.001)
        XCTAssertEqual(frame.midY, plain.frameValue.midY, accuracy: 0.5)
    }

    /// A fractional size still lands flush, integral, and never smaller.
    func testAFractionalSizeIsRoundedOutAndFlush() {
        let requested = CGSize(width: 334.32, height: 205.18)
        let frame = NotchGeometry.panelFrame(for: plain, panelSize: requested)
        XCTAssertEqual(frame.maxX, 1800, accuracy: 0.0001)
        for value in [frame.minX, frame.minY, frame.width, frame.height] {
            XCTAssertEqual(value, value.rounded(), "\(value) is not a whole point")
        }
        XCTAssertGreaterThanOrEqual(frame.width, requested.width)
        XCTAssertGreaterThanOrEqual(frame.height, requested.height)
    }

    /// A screen with a non-zero origin is handled.
    func testFollowsASecondaryScreen() {
        let secondary = FakeScreen(frameValue: CGRect(x: -2560, y: 200, width: 2560, height: 1440),
                                   visibleFrameValue: CGRect(x: -2560, y: 200, width: 2560, height: 1415), hardwareNotch: nil)
        let frame = NotchGeometry.panelFrame(for: secondary, panelSize: CGSize(width: 334, height: 484))
        XCTAssertEqual(frame.maxX, 0, accuracy: 0.001)
        XCTAssertEqual(frame.midY, 920, accuracy: 0.5)
    }

    /// A top notch runs up to meet a hardware notch, and stays below the menu
    /// bar where there is none. The bottom edge rests on the Dock either way.
    func testTopEdgeMeetsTheHardwareNotch() {
        let size = CGSize(width: 700, height: 200)
        XCTAssertEqual(NotchGeometry.panelFrame(for: notched, panelSize: size, edge: .top).maxY, notched.frameValue.maxY, accuracy: 0.001)
        XCTAssertEqual(NotchGeometry.panelFrame(for: plain, panelSize: size, edge: .top).maxY, plain.visibleFrameValue.maxY, accuracy: 0.001)
        XCTAssertEqual(NotchGeometry.panelFrame(for: notched, panelSize: size, edge: .bottom).minY, notched.visibleFrameValue.minY, accuracy: 0.001)
    }
}

final class NotchPlacementTests: XCTestCase {
    private func placement(_ edge: NotchEdge) -> NotchPlacement {
        NotchPlacement(edge: edge, panelSize: CGSize(width: 400, height: 900))
    }

    /// Zero across is the bezel on every edge, and across grows inward.
    func testAcrossIsMeasuredInwardFromEveryEdge() {
        XCTAssertEqual(placement(.right).point(along: 0, across: 30).x, 370, accuracy: 0.001)
        XCTAssertEqual(placement(.left).point(along: 0, across: 30).x, 30, accuracy: 0.001)
        XCTAssertEqual(placement(.top).point(along: 0, across: 30).y, 30, accuracy: 0.001)
        XCTAssertEqual(placement(.bottom).point(along: 0, across: 30).y, 870, accuracy: 0.001)
    }

    /// A rect spans inward, never off the screen side of its edge.
    func testARectSpansInward() {
        XCTAssertEqual(placement(.right).rect(along: 10, across: 0, length: 200, depth: 70), CGRect(x: 330, y: 10, width: 70, height: 200))
        XCTAssertEqual(placement(.bottom).rect(along: 10, across: 0, length: 200, depth: 70), CGRect(x: 10, y: 830, width: 200, height: 70))
    }

    /// Point to stack space and back agree.
    func testRoundTrip() {
        for edge in NotchEdge.allCases {
            let place = placement(edge)
            let point = place.point(along: 123, across: 45)
            XCTAssertEqual(place.along(of: point), 123, accuracy: 0.001, edge.rawValue)
            XCTAssertEqual(place.across(of: point), 45, accuracy: 0.001, edge.rawValue)
        }
    }

    /// The panel is tall for the sides and wide for the rest.
    func testPanelOrientation() {
        XCTAssertEqual(NotchPlacement.panelSize(edge: .right, length: 500, depth: 300), CGSize(width: 300, height: 500))
        XCTAssertEqual(NotchPlacement.panelSize(edge: .top, length: 500, depth: 300), CGSize(width: 500, height: 300))
    }
}

@MainActor
final class NotchViewModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_757_400_000)

    private func session(_ id: Int64, cwd: String, ago: TimeInterval, ended: Bool = false) -> SessionRow {
        SessionRow(id: id, vendor: "claude", vendorSessionId: "s\(id)", pid: nil, cwd: cwd, startedAt: t0.addingTimeInterval(-3600),
                   endedAt: ended ? t0.addingTimeInterval(-ago) : nil, lastEventAt: t0.addingTimeInterval(-ago), fidelity: .official)
    }

    private func change(_ id: Int64, session: Int64?, kind: ChangeKind, ago: TimeInterval) -> ChangeRow {
        ChangeRow(id: id, eventId: nil, sessionId: session, path: "/p/\(id).txt", kind: kind, before: nil, after: nil,
                  attributed: session != nil, ts: t0.addingTimeInterval(-ago))
    }

    /// At rest on a plain screen the shape is the pill; joined to a hardware
    /// notch on the top edge it is exactly that notch, so nothing shows.
    func testRestingShape() {
        let model = NotchViewModel()
        XCTAssertEqual(model.shapeLength, NotchLayout.pillLength)
        XCTAssertEqual(model.shapeDepth, NotchLayout.pillDepth)
        model.edge = .top
        model.adopt(screen: notched)
        XCTAssertEqual(model.shapeLength, 220)
        XCTAssertEqual(model.shapeDepth, 38)
        XCTAssertEqual(model.contentInset, 38)
        model.edge = .right
        XCTAssertNil(model.joinedNotch, "only the top edge joins the hardware")
        XCTAssertEqual(model.contentInset, 0)
    }

    /// Open, the shape wraps the content plus the flares, and grows by the
    /// hardware band when joined.
    func testOpenShapeWrapsTheContent() {
        let model = NotchViewModel()
        model.isExpanded = true
        XCTAssertEqual(model.shapeLength, model.contentSize.height + 2 * NotchLayout.curlRadius)
        XCTAssertEqual(model.shapeDepth, model.contentSize.width + 2 * NotchLayout.edgePadding)
        let joined = NotchViewModel()
        joined.edge = .top
        joined.adopt(screen: notched)
        joined.isExpanded = true
        XCTAssertEqual(joined.shapeLength, joined.contentSize.width + 2 * NotchLayout.curlRadius)
        XCTAssertEqual(joined.shapeDepth, joined.contentSize.height + 2 * NotchLayout.edgePadding + 38)
    }

    /// The content grows with rows and change lines, and is capped.
    func testContentGrowsWithRows() {
        let model = NotchViewModel()
        let empty = model.contentSize.height
        let sessions = (1...6).map { session(Int64($0), cwd: "/p\($0)", ago: 60) }
        let changes = (1...8).map { change(Int64($0), session: 1, kind: .modify, ago: 30) }
        model.update(sessions: sessions, changes: changes, counts: LedgerCounts(activeSessions: 6, recentChanges: 8), now: t0)
        XCTAssertEqual(model.shownRows.count, NotchLayout.maximumRows)
        XCTAssertEqual(model.shownChanges.count, NotchLayout.maximumChanges)
        XCTAssertEqual(model.contentSize.height, NotchLayout.contentHeight(rows: 4, changes: 4))
        XCTAssertGreaterThan(model.contentSize.height, empty)
    }

    /// Rows are the live sessions, most recent first, with per-kind counts
    /// from the window; ended and silent sessions are left out; the recent
    /// list is newest first and includes unattributed changes.
    func testUpdateBuildsRows() {
        let model = NotchViewModel()
        let sessions = [
            session(1, cwd: "/Users/me/alpha", ago: 600),
            session(2, cwd: "/Users/me/beta", ago: 10),
            session(3, cwd: "/Users/me/old", ago: 40 * 60),
            session(4, cwd: "/Users/me/done", ago: 5, ended: true),
        ]
        let changes = [
            change(1, session: 1, kind: .create, ago: 500),
            change(2, session: 1, kind: .delete, ago: 400),
            change(3, session: 2, kind: .modify, ago: 5),
            change(4, session: nil, kind: .modify, ago: 2),
        ]
        model.update(sessions: sessions, changes: changes, counts: LedgerCounts(activeSessions: 2, recentChanges: 3), now: t0)
        XCTAssertEqual(model.rows.map(\.id), [2, 1])
        XCTAssertEqual(model.rows.map(\.title), ["beta", "alpha"])
        XCTAssertEqual(model.rows[1].created, 1)
        XCTAssertEqual(model.rows[1].deleted, 1)
        XCTAssertEqual(model.rows[1].modified, 0)
        XCTAssertEqual(model.rows[0].modified, 1)
        XCTAssertEqual(model.recentChanges.map(\.id), [4, 3, 2, 1])
        XCTAssertTrue(model.hasAnySessions)
    }

    /// Targets are inside the content box, do not overlap, and are found by
    /// hit test only while open.
    func testTargetsLieInsideTheContentAndAreFound() {
        for edge in NotchEdge.allCases {
            let model = NotchViewModel()
            model.edge = edge
            model.update(sessions: [session(1, cwd: "/p", ago: 1), session(2, cwd: "/q", ago: 2)], changes: [],
                         counts: LedgerCounts(activeSessions: 2, recentChanges: 0), now: t0)
            model.isExpanded = true
            let place = model.placement()
            let box = model.contentRect(place)
            XCTAssertTrue(model.expandedRect(place).contains(box), "\(edge): content is outside the shape")
            let rects = model.targets.compactMap { model.rect(for: $0, place) }
            XCTAssertEqual(rects.count, 5, edge.rawValue)
            for rect in rects { XCTAssertTrue(box.contains(rect), "\(edge): \(rect) outside \(box)") }
            for (i, a) in rects.enumerated() {
                for b in rects.dropFirst(i + 1) { XCTAssertFalse(a.intersects(b), "\(edge): targets overlap") }
            }
            let gear = model.rect(for: .gear, place)!
            XCTAssertEqual(model.target(at: CGPoint(x: gear.midX, y: gear.midY), place), .gear, edge.rawValue)
            let row = model.rect(for: .session(2), place)!
            XCTAssertEqual(model.target(at: CGPoint(x: row.midX, y: row.midY), place), .session(2), edge.rawValue)
            model.isExpanded = false
            XCTAssertNil(model.target(at: CGPoint(x: gear.midX, y: gear.midY), place))
        }
    }

    /// The hot zone around the pill contains the pill and is inside the panel.
    func testPillHotZoneContainsThePill() {
        let model = NotchViewModel()
        let place = model.placement()
        let pill = model.notchRect(place)
        let hot = model.pillHotRect(place)
        XCTAssertTrue(hot.contains(pill))
        XCTAssertTrue(CGRect(origin: .zero, size: model.panelSize).contains(hot))
    }
}

final class SideNotchShapeTests: XCTestCase {
    /// The path stays inside its rect on every edge, open and folded, and a
    /// tiny rect does not produce a degenerate path.
    func testPathStaysInsideItsRect() {
        for edge in NotchEdge.allCases {
            for size in [CGSize(width: 14, height: 124), CGSize(width: 320, height: 300), CGSize(width: 600, height: 60)] {
                let rect = CGRect(origin: CGPoint(x: 10, y: 20), size: size)
                let path = SideNotchShape(edge: edge).path(in: rect)
                XCTAssertFalse(path.isEmpty, "\(edge) \(size)")
                let bounds = path.boundingRect
                XCTAssertTrue(rect.insetBy(dx: -0.5, dy: -0.5).contains(bounds), "\(edge) \(size): \(bounds) outside \(rect)")
            }
        }
    }

    /// Joined to a hardware notch the shape has no flares, only the small
    /// bezel fillet: it fills the rect to within that fillet of both top
    /// corners, where a flared shape would have curled inward by far more.
    func testJoinedShapeMeetsTheBezelWithOnlyTheFillet() {
        let rect = CGRect(x: 0, y: 0, width: 220, height: 38)
        let joined = SideNotchShape(edge: .top, joining: HardwareNotch(width: 220, height: 38)).path(in: rect)
        let fillet = NotchLayout.bezelFillet
        XCTAssertTrue(joined.contains(CGPoint(x: fillet + 1, y: 1)))
        XCTAssertTrue(joined.contains(CGPoint(x: rect.width - fillet - 1, y: 1)))
        XCTAssertTrue(joined.contains(CGPoint(x: 110, y: 36)))
        let side = CGPoint(x: fillet + 6, y: 30)
        XCTAssertTrue(joined.contains(side), "the joined body's side sits at the fillet")
        let flared = SideNotchShape(edge: .top).path(in: rect)
        XCTAssertFalse(flared.contains(side), "a flared body's side sits a whole flare in from the corner")
    }
}

@MainActor
final class NotchCopyTests: XCTestCase {
    func testSummaryAndAgo() {
        XCTAssertEqual(NotchCopy.summary(LedgerCounts(activeSessions: 1, recentChanges: 3)), "1 agent · 3 changes / h")
        XCTAssertEqual(NotchCopy.summary(LedgerCounts(activeSessions: 0, recentChanges: 0)), "0 agents · 0 changes / h")
        let now = Date()
        XCTAssertEqual(NotchCopy.ago(now.addingTimeInterval(-5), now: now), "just now")
        XCTAssertEqual(NotchCopy.ago(now.addingTimeInterval(-180), now: now), "3 min ago")
        XCTAssertEqual(NotchCopy.ago(now.addingTimeInterval(-7200), now: now), "2 h ago")
        XCTAssertEqual(NotchCopy.shortPath("/Users/me/proj/src/a.swift"), "src/a.swift")
    }

    /// Preferences persist and default sensibly.
    func testPreferencesPersist() {
        let suite = "notchd-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let first = Preferences(defaults: defaults)
        XCTAssertEqual(first.notchEdge, .right)
        XCTAssertEqual(first.notchVisibility, .onHover)
        first.notchEdge = .top
        first.notchVisibility = .alwaysShow
        let second = Preferences(defaults: defaults)
        XCTAssertEqual(second.notchEdge, .top)
        XCTAssertEqual(second.notchVisibility, .alwaysShow)
        defaults.removePersistentDomain(forName: suite)
    }
}
