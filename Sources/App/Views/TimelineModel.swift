// TimelineModel.swift
// State for the main window: the time range, one lane per session plus the
// unattributed lane, the drag selection and everything derived from it (files,
// the tool calls that caused them, the diff of one file), the session page,
// and the revert sheet. Reads the ledger and store; writes only through the
// revert engine.

import Foundation
import SwiftUI

/// The window's pages.
enum Page: Hashable {
    case timeline
    case session(Int64)
    case unattributed
}

/// The span the lanes cover.
enum TimeRange: String, CaseIterable, Identifiable {
    case fifteenMinutes, hour, today, week

    var id: String { rawValue }

    /// The picker label.
    var title: String {
        switch self {
        case .fifteenMinutes: return "15 min"
        case .hour: return "Hour"
        case .today: return "Today"
        case .week: return "Week"
        }
    }

    /// The span ending now.
    /// - Parameter now: The reference instant.
    /// - Returns: Start and end.
    func interval(now: Date) -> (start: Date, end: Date) {
        switch self {
        case .fifteenMinutes: return (now.addingTimeInterval(-15 * 60), now)
        case .hour: return (now.addingTimeInterval(-60 * 60), now)
        case .today: return (Calendar.current.startOfDay(for: now), now)
        case .week: return (now.addingTimeInterval(-7 * 24 * 60 * 60), now)
        }
    }
}

/// One horizontal lane.
struct TimelineLane: Identifiable, Equatable {
    /// The lane id for changes no agent claimed.
    static let unattributedId: Int64 = -1

    let id: Int64
    let title: String
    let subtitle: String
    let isActive: Bool
    let fidelity: Fidelity
    let changes: [ChangeRow]

    /// Whether this is the unattributed lane.
    var isUnattributed: Bool { id == Self.unattributedId }
}

/// A dragged span across some lanes.
struct TimelineSelection: Equatable {
    var start: Date
    var end: Date
    var laneIds: Set<Int64>
}

/// One path's net change inside a selection.
struct FileSummary: Identifiable, Equatable {
    let path: String
    let kind: ChangeKind
    let before: ManifestEntry?
    let after: ManifestEntry?
    let changeCount: Int
    let attributed: Bool

    var id: String { path }

    /// Folds a path's changes, oldest first, into one summary.
    /// - Parameter changes: The path's changes in time order.
    /// - Returns: The summary, or nil for an empty list.
    static func fold(_ changes: [ChangeRow]) -> FileSummary? {
        guard let first = changes.first, let last = changes.last else { return nil }
        let kind: ChangeKind = last.after == nil ? .delete : (first.before == nil ? .create : .modify)
        return FileSummary(path: first.path, kind: kind, before: first.before, after: last.after,
                           changeCount: changes.count, attributed: changes.allSatisfy(\.attributed))
    }

    /// Summaries for a set of changes, most changed first.
    /// - Parameter changes: Changes in any order.
    /// - Returns: One summary per path.
    static func summaries(_ changes: [ChangeRow]) -> [FileSummary] {
        let byPath = Dictionary(grouping: changes.sorted { ($0.ts, $0.id) < ($1.ts, $1.id) }, by: \.path)
        return byPath.values.compactMap(fold).sorted { ($1.changeCount, $1.path) < ($0.changeCount, $0.path) }
    }
}

/// The tick under the cursor.
struct TickInfo: Equatable {
    let change: ChangeRow
    let laneTitle: String
}

/// A plan waiting in the sheet.
struct PendingRevert: Identifiable {
    let id = UUID()
    let plan: RevertPlan
}

/// State for the main window.
@MainActor
final class TimelineModel: ObservableObject {
    @Published var page: Page = .timeline {
        didSet { loadPage() }
    }
    @Published var range: TimeRange = .hour {
        didSet { refresh() }
    }
    @Published private(set) var rangeStart = Date()
    @Published private(set) var rangeEnd = Date()
    @Published private(set) var lanes: [TimelineLane] = []
    @Published private(set) var sessions: [SessionRow] = []
    @Published private(set) var counts = LedgerCounts(activeSessions: 0, recentChanges: 0)
    @Published var selection: TimelineSelection? {
        didSet { deriveSelection() }
    }
    @Published private(set) var selectedChanges: [ChangeRow] = []
    @Published private(set) var files: [FileSummary] = []
    @Published private(set) var causes: [EventRow] = []
    @Published var selectedFile: FileSummary? {
        didSet { loadDiff() }
    }
    @Published private(set) var diff: LineDiffResult?
    @Published var hover: TickInfo?
    @Published private(set) var events: [EventRow] = []
    @Published private(set) var changesByEvent: [Int64: [ChangeRow]] = [:]
    @Published private(set) var unattributed: [ChangeRow] = []
    @Published var pendingRevert: PendingRevert?
    @Published private(set) var revertResult: RevertResult?
    @Published private(set) var revertError: String?

    /// Called on the main actor whenever the counts change.
    var onCountsChanged: ((LedgerCounts) -> Void)?
    /// Injectable clock.
    var now: () -> Date = Date.init

    let ledger: Ledger
    let store: ObjectStore
    let engine: RevertEngine

    /// Creates a model.
    /// - Parameters:
    ///   - ledger: The ledger to read.
    ///   - store: Where file contents are, for diffs.
    ///   - engine: Plans and applies reverts.
    init(ledger: Ledger, store: ObjectStore, engine: RevertEngine) {
        self.ledger = ledger
        self.store = store
        self.engine = engine
    }

    /// Whether anything has ever been recorded.
    var hasAnySessions: Bool { !sessions.isEmpty }

    /// The session shown by the session page, if that page is open.
    var selectedSession: SessionRow? {
        guard case .session(let id) = page else { return nil }
        return sessions.first { $0.id == id }
    }

    /// Every change in the range across all lanes.
    var changesInRange: [ChangeRow] { lanes.flatMap(\.changes) }

    /// Re-reads everything for the current range and page.
    func refresh() {
        do {
            let current = now()
            let interval = range.interval(now: current)
            rangeStart = interval.start
            rangeEnd = interval.end
            sessions = try ledger.sessions()
            let counts = try ledger.counts(now: current)
            if counts != self.counts {
                self.counts = counts
                onCountsChanged?(counts)
            }
            lanes = try buildLanes(since: interval.start, now: current)
            unattributed = try ledger.unattributedChanges()
            if let selection, selection.end < rangeStart { self.selection = nil } else { deriveSelection() }
            loadPage()
        } catch {
            Log.app.error("timeline refresh failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// One lane per session with changes in range, most recent first, then
    /// the unattributed lane if it has anything.
    private func buildLanes(since: Date, now: Date) throws -> [TimelineLane] {
        let changes = try ledger.changes(since: since, includeUnattributed: true)
        let bySession = Dictionary(grouping: changes, by: { $0.sessionId ?? TimelineLane.unattributedId })
        var lanes = sessions
            .filter { bySession[$0.id] != nil || $0.lastEventAt >= since }
            .map { session in
                TimelineLane(id: session.id, title: session.projectName.isEmpty ? session.cwd : session.projectName,
                             subtitle: VendorNames.display(session.vendor), isActive: session.isActive(at: now),
                             fidelity: session.fidelity, changes: bySession[session.id] ?? [])
            }
        if let loose = bySession[TimelineLane.unattributedId], !loose.isEmpty {
            lanes.append(TimelineLane(id: TimelineLane.unattributedId, title: "Not from any known agent", subtitle: "",
                                      isActive: false, fidelity: .unknown, changes: loose))
        }
        return lanes
    }

    /// Recomputes the files and causes for the selection.
    private func deriveSelection() {
        guard let selection else {
            selectedChanges = []
            files = []
            causes = []
            selectedFile = nil
            return
        }
        selectedChanges = lanes
            .filter { selection.laneIds.isEmpty || selection.laneIds.contains($0.id) }
            .flatMap(\.changes)
            .filter { $0.ts >= selection.start && $0.ts <= selection.end }
        files = FileSummary.summaries(selectedChanges)
        let eventIds = Set(selectedChanges.compactMap(\.eventId))
        causes = ((try? ledger.events(since: selection.start, until: selection.end)) ?? [])
            .filter { eventIds.contains($0.id) }
            .sorted { $0.ts < $1.ts }
        if let selectedFile, !files.contains(where: { $0.path == selectedFile.path }) { self.selectedFile = nil }
    }

    /// Loads the page's data: the session's events or the unattributed list.
    private func loadPage() {
        switch page {
        case .timeline:
            break
        case .session(let id):
            do {
                events = try ledger.events(sessionId: id)
                changesByEvent = try ledger.changesByEvent(sessionId: id)
            } catch {
                Log.app.error("session page load failed: \(String(describing: error), privacy: .public)")
            }
        case .unattributed:
            unattributed = (try? ledger.unattributedChanges()) ?? []
        }
    }

    /// Reads both versions of the selected file and diffs them off the main
    /// actor.
    private func loadDiff() {
        diff = nil
        guard let file = selectedFile else { return }
        let store = self.store
        let beforeHash = file.before?.hash
        let afterHash = file.after?.hash
        Task.detached(priority: .userInitiated) {
            let before = beforeHash.flatMap { try? store.get($0) }
            let after = afterHash.flatMap { try? store.get($0) }
            let result = LineDiff.diff(before: before, after: after)
            await MainActor.run { [weak self] in
                guard self?.selectedFile?.path == file.path else { return }
                self?.diff = result
            }
        }
    }

    /// The revert scope for the current selection.
    var selectionScope: RevertScope? {
        guard let selection else { return nil }
        let laneIds = selection.laneIds.isEmpty ? Set(lanes.map(\.id)) : selection.laneIds
        let sessionIds = laneIds.filter { $0 != TimelineLane.unattributedId }
        let allSessions = sessionIds.count == lanes.filter { !$0.isUnattributed }.count
        return RevertScope(since: selection.start, until: selection.end, sessionIds: allSessions ? nil : Array(sessionIds).sorted(),
                           includeUnattributed: laneIds.contains(TimelineLane.unattributedId))
    }

    /// Builds the plan for the selection and opens the sheet.
    func prepareRevert() {
        guard let scope = selectionScope else { return }
        revertResult = nil
        revertError = nil
        do {
            pendingRevert = PendingRevert(plan: try engine.plan(scope))
        } catch {
            revertError = String(describing: error)
        }
    }

    /// Applies a plan restricted to the ticked paths, then refreshes.
    /// - Parameters:
    ///   - plan: The plan from the sheet.
    ///   - paths: The paths left ticked.
    func applyRevert(_ plan: RevertPlan, keeping paths: Set<String>) {
        do {
            revertResult = try engine.apply(plan.keeping(paths: paths), now: now())
            revertError = nil
        } catch {
            revertError = String(describing: error)
        }
        refresh()
    }

    /// Closes the sheet.
    func dismissRevert() {
        pendingRevert = nil
    }
}
