// StorePrunerTests.swift
// Pruning must keep every blob a change or checkpoint inside the retention
// window refers to, including the files inside a kept manifest, remove the
// rest, and never touch ledger rows.

import XCTest
@testable import Notchd

final class StorePrunerTests: XCTestCase {
    private var root: URL!
    private var ledger: Ledger!
    private var store: ObjectStore!
    private let now = Date(timeIntervalSince1970: 1_757_400_000)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notchd-prune-\(UUID().uuidString)")
        ledger = try Ledger(path: ":memory:")
        store = try ObjectStore(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func entry(_ text: String) throws -> ManifestEntry {
        let data = Data(text.utf8)
        return ManifestEntry(hash: try store.put(data), mode: 0o644, size: Int64(data.count), isSymlink: false)
    }

    private func event(at offset: TimeInterval) throws -> EventRow {
        try ledger.record(NotchdEvent(kind: .toolAfter, vendor: "claude", session: "s", cwd: "/p", ts: now.addingTimeInterval(offset), fidelity: .official))
    }

    /// Recent references survive, stale and orphaned blobs go.
    func testKeepsRecentReferencesAndRemovesTheRest() throws {
        let recent = try entry("recent")
        let stale = try entry("stale")
        let orphan = try store.put(Data("orphan".utf8))
        let inManifest = try entry("inside a recent manifest")
        let manifestHash = try store.put(Manifest(entries: ["/m": inManifest]))
        let recentEvent = try event(at: 0)
        let staleEvent = try event(at: -40 * 24 * 60 * 60)
        try ledger.recordChanges([
            NewChange(eventId: recentEvent.id, sessionId: recentEvent.sessionId, path: "/a", kind: .modify, before: recent, after: nil, attributed: true, ts: now),
            NewChange(eventId: staleEvent.id, sessionId: staleEvent.sessionId, path: "/b", kind: .modify, before: stale, after: nil, attributed: true, ts: now.addingTimeInterval(-40 * 24 * 60 * 60)),
        ])
        let snapshot = SnapshotResult(manifest: Manifest(entries: ["/m": inManifest]), truncated: false, skippedLarge: 0, newObjects: 1, bytesRead: 1)
        try ledger.recordCheckpoint(eventId: recentEvent.id, sessionId: recentEvent.sessionId, toolUseId: nil, roots: ["/m"],
                                    manifestHash: manifestHash, result: snapshot, late: false, durationMs: 0, createdAt: now)

        let result = try StorePruner(ledger: ledger, store: store).prune(now: now)
        XCTAssertEqual(result.removed, 2)
        XCTAssertGreaterThan(result.bytesFreed, 0)
        XCTAssertTrue(store.contains(recent.hash))
        XCTAssertTrue(store.contains(inManifest.hash))
        XCTAssertTrue(store.contains(manifestHash))
        XCTAssertFalse(store.contains(stale.hash))
        XCTAssertFalse(store.contains(orphan))
        XCTAssertEqual(try ledger.changes(since: .distantPast).count, 2, "ledger rows are never pruned")
    }

    /// An empty store prunes to nothing without error.
    func testEmptyStore() throws {
        XCTAssertEqual(try StorePruner(ledger: ledger, store: store).prune(now: now), PruneResult(kept: 0, removed: 0, bytesFreed: 0))
    }
}
