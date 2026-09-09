// ObjectStoreTests.swift
// The store must return exactly the bytes it was given, name them by content
// so duplicates cost nothing, handle empty data, and refuse a blob whose bytes
// no longer match its name.

import XCTest
@testable import Notchd

final class ObjectStoreTests: XCTestCase {
    private var root: URL!
    private var store: ObjectStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notchd-store-\(UUID().uuidString)")
        store = try ObjectStore(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Bytes round trip and are named by their SHA-256.
    func testPutAndGetRoundTrip() throws {
        let data = Data("hello, agent\n".utf8)
        let hash = try store.put(data)
        XCTAssertEqual(hash.count, 64)
        XCTAssertEqual(hash, ObjectStore.hash(data))
        XCTAssertTrue(store.contains(hash))
        XCTAssertEqual(try store.get(hash), data)
    }

    /// The same bytes are stored once.
    func testDuplicatesAreStoredOnce() throws {
        let data = Data(repeating: 7, count: 10_000)
        let first = try store.put(data)
        let modified = try FileManager.default.attributesOfItem(atPath: store.url(for: first).path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.02)
        let second = try store.put(data)
        XCTAssertEqual(first, second)
        let again = try FileManager.default.attributesOfItem(atPath: store.url(for: first).path)[.modificationDate] as? Date
        XCTAssertEqual(modified, again)
    }

    /// Empty files are legal content.
    func testEmptyDataRoundTrips() throws {
        let hash = try store.put(Data())
        XCTAssertEqual(try store.get(hash), Data())
    }

    /// An unknown hash is nil, not an error.
    func testMissingBlobIsNil() throws {
        XCTAssertNil(try store.get(String(repeating: "0", count: 64)))
        XCTAssertFalse(store.contains(String(repeating: "0", count: 64)))
    }

    /// Manifests are stored and read back whole.
    func testManifestRoundTrip() throws {
        let manifest = Manifest(entries: ["/a": ManifestEntry(hash: "x", mode: 0o644, size: 1, isSymlink: false)])
        let hash = try store.put(manifest)
        XCTAssertEqual(try store.manifest(hash), manifest)
    }

    /// A blob whose contents were tampered with is refused.
    func testCorruptBlobIsRefused() throws {
        let hash = try store.put(Data("original".utf8))
        let other = try store.put(Data("other".utf8))
        try FileManager.default.removeItem(at: store.url(for: hash))
        try FileManager.default.copyItem(at: store.url(for: other), to: store.url(for: hash))
        XCTAssertThrowsError(try store.get(hash)) { error in
            XCTAssertEqual(error as? ObjectStoreError, .corrupt(hash))
        }
    }
}
