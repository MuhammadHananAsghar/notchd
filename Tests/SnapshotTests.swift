// SnapshotTests.swift
// The snapshotter must capture exactly the files under its roots, skip what
// the limits say, stop at the file cap and say so, use the cache for unchanged
// files, and produce manifests whose diff names every create, modify, and
// delete and nothing else.

import XCTest
@testable import Notchd

final class SnapshotTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var store: ObjectStore!
    private var snapshotter: Snapshotter!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notchd-snap-\(UUID().uuidString)")
        project = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        store = try ObjectStore(root: root.appendingPathComponent("store"))
        snapshotter = Snapshotter(store: store)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes a file under the project.
    @discardableResult
    private func write(_ relative: String, _ text: String) throws -> String {
        let url = project.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url.standardizedFileURL.path
    }

    /// Every regular file under the root is captured with its hash and mode.
    func testCapturesFilesUnderRoot() throws {
        let a = try write("src/a.swift", "let a = 1\n")
        let b = try write("README.md", "# hi\n")
        let result = try snapshotter.snapshot(roots: [project.path])
        XCTAssertEqual(Set(result.manifest.entries.keys), [a, b])
        XCTAssertEqual(result.manifest.entries[a]?.hash, ObjectStore.hash(Data("let a = 1\n".utf8)))
        XCTAssertEqual(result.manifest.entries[a]?.size, 10)
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.newObjects, 2)
        XCTAssertTrue(store.contains(result.manifest.entries[b]!.hash))
    }

    /// Excluded directory names are not descended into.
    func testSkipsExcludedDirectories() throws {
        try write("node_modules/x/index.js", "x")
        try write(".git/HEAD", "ref")
        let kept = try write("src/a.swift", "a")
        let result = try snapshotter.snapshot(roots: [project.path])
        XCTAssertEqual(Array(result.manifest.entries.keys), [kept])
    }

    /// Files over the size limit are skipped and counted.
    func testSkipsLargeFiles() throws {
        let small = Snapshotter(store: store, limits: SnapshotLimits(maxFileBytes: 4))
        let kept = try write("ok.txt", "abc")
        try write("big.txt", "abcdefgh")
        let result = try small.snapshot(roots: [project.path])
        XCTAssertEqual(Array(result.manifest.entries.keys), [kept])
        XCTAssertEqual(result.skippedLarge, 1)
    }

    /// The file cap stops the walk and marks the result.
    func testFileCapTruncates() throws {
        let capped = Snapshotter(store: store, limits: SnapshotLimits(maxFiles: 2))
        for index in 0..<5 { try write("f\(index).txt", "\(index)") }
        let result = try capped.snapshot(roots: [project.path])
        XCTAssertEqual(result.manifest.entries.count, 2)
        XCTAssertTrue(result.truncated)
    }

    /// A single file root and a missing root both work.
    func testFileAndMissingRoots() throws {
        let a = try write("a.txt", "a")
        let result = try snapshotter.snapshot(roots: [a, project.appendingPathComponent("missing.txt").path])
        XCTAssertEqual(Array(result.manifest.entries.keys), [a])
    }

    /// Symlinks are captured by their target, not followed.
    func testSymlinksAreCapturedAsLinks() throws {
        try write("target.txt", "t")
        let link = project.appendingPathComponent("link.txt").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "target.txt")
        let result = try snapshotter.snapshot(roots: [project.path])
        XCTAssertEqual(result.manifest.entries[link]?.isSymlink, true)
        XCTAssertEqual(try store.get(result.manifest.entries[link]!.hash), Data("target.txt".utf8))
    }

    /// An unchanged file is not re-read; a changed one is.
    func testCacheSkipsUnchangedFiles() throws {
        let a = try write("a.txt", "one")
        let first = try snapshotter.snapshot(roots: [project.path])
        XCTAssertEqual(first.bytesRead, 3)
        let second = try snapshotter.snapshot(roots: [project.path])
        XCTAssertEqual(second.bytesRead, 0)
        XCTAssertEqual(second.manifest, first.manifest)
        Thread.sleep(forTimeInterval: 0.02)
        try write("a.txt", "two!")
        let third = try snapshotter.snapshot(roots: [project.path])
        XCTAssertEqual(third.bytesRead, 4)
        XCTAssertNotEqual(third.manifest.entries[a], first.manifest.entries[a])
    }

    /// Nested roots collapse into their parent.
    func testNormalizedRootsCollapseNesting() {
        XCTAssertEqual(Snapshotter.normalized(["/a/b", "/a", "/c/", "/a/b/c"]), ["/a", "/c"])
    }

    /// Home, root, and system trees are not reasonable roots.
    func testReasonableRoots() {
        let limits = SnapshotLimits.standard
        XCTAssertFalse(limits.isReasonableRoot("/"))
        XCTAssertFalse(limits.isReasonableRoot(FileManager.default.homeDirectoryForCurrentUser.path))
        XCTAssertFalse(limits.isReasonableRoot("/System/Library"))
        XCTAssertTrue(limits.isReasonableRoot(project.path))
    }

    /// The diff names creates, modifies, and deletes, and nothing unchanged.
    func testManifestDiff() {
        let same = ManifestEntry(hash: "s", mode: 0o644, size: 1, isSymlink: false)
        let before = Manifest(entries: [
            "/keep": same,
            "/edit": ManifestEntry(hash: "old", mode: 0o644, size: 3, isSymlink: false),
            "/gone": ManifestEntry(hash: "g", mode: 0o644, size: 1, isSymlink: false),
        ])
        let after = Manifest(entries: [
            "/keep": same,
            "/edit": ManifestEntry(hash: "new", mode: 0o644, size: 3, isSymlink: false),
            "/new": ManifestEntry(hash: "n", mode: 0o755, size: 2, isSymlink: false),
        ])
        let changes = ManifestDiff.changes(from: before, to: after)
        XCTAssertEqual(changes.map(\.path), ["/edit", "/gone", "/new"])
        XCTAssertEqual(changes.map(\.kind), [.modify, .delete, .create])
        XCTAssertEqual(changes[0].before?.hash, "old")
        XCTAssertEqual(changes[0].after?.hash, "new")
        XCTAssertNil(changes[1].after)
        XCTAssertNil(changes[2].before)
    }

    /// A mode change alone is a modify.
    func testModeChangeIsAModify() {
        let before = Manifest(entries: ["/x": ManifestEntry(hash: "h", mode: 0o644, size: 1, isSymlink: false)])
        let after = Manifest(entries: ["/x": ManifestEntry(hash: "h", mode: 0o755, size: 1, isSymlink: false)])
        XCTAssertEqual(ManifestDiff.changes(from: before, to: after).map(\.kind), [.modify])
    }
}
