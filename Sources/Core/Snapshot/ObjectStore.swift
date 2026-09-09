// ObjectStore.swift
// A content-addressed store of file contents and manifests: SHA-256 names,
// LZFSE compressed, one file per blob under objects/ab/cdef... Writing the same
// bytes twice costs one hash. This is the git object model without git, so it
// works on directories that are not repositories and on files git ignores.

import CryptoKit
import Foundation

/// A failure reading or writing the store.
enum ObjectStoreError: Error, Equatable {
    case corrupt(String)
}

/// Content-addressed blob storage.
final class ObjectStore {
    /// The directory holding `objects/`.
    let root: URL

    /// Opens or creates a store.
    /// - Parameter root: The store directory.
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root.appendingPathComponent("objects"), withIntermediateDirectories: true)
    }

    /// The hex SHA-256 of some bytes.
    /// - Parameter data: The bytes.
    /// - Returns: 64 hex characters.
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Where a blob lives.
    /// - Parameter hash: The blob's hash.
    /// - Returns: The file URL.
    func url(for hash: String) -> URL {
        root.appendingPathComponent("objects").appendingPathComponent(String(hash.prefix(2))).appendingPathComponent(String(hash.dropFirst(2)))
    }

    /// Whether a blob is present.
    /// - Parameter hash: The blob's hash.
    /// - Returns: True when the file exists.
    func contains(_ hash: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: hash).path)
    }

    /// Stores bytes, returning their hash. Existing blobs are not rewritten.
    /// - Parameter data: The bytes.
    /// - Returns: The hash.
    @discardableResult
    func put(_ data: Data) throws -> String {
        let hash = Self.hash(data)
        let destination = url(for: hash)
        if FileManager.default.fileExists(atPath: destination.path) { return hash }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stored = data.isEmpty ? Data() : try (data as NSData).compressed(using: .lzfse) as Data
        try stored.write(to: destination, options: .atomic)
        return hash
    }

    /// Reads a blob back, verifying its hash.
    /// - Parameter hash: The blob's hash.
    /// - Returns: The bytes, or nil when the blob is absent.
    func get(_ hash: String) throws -> Data? {
        let source = url(for: hash)
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let stored = try Data(contentsOf: source)
        let data = stored.isEmpty ? Data() : try (stored as NSData).decompressed(using: .lzfse) as Data
        guard Self.hash(data) == hash else { throw ObjectStoreError.corrupt(hash) }
        return data
    }

    /// Stores a manifest as JSON.
    /// - Parameter manifest: The manifest.
    /// - Returns: Its hash.
    func put(_ manifest: Manifest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try put(encoder.encode(manifest))
    }

    /// Reads a manifest back.
    /// - Parameter hash: The manifest's hash.
    /// - Returns: The manifest, or nil when absent.
    func manifest(_ hash: String) throws -> Manifest? {
        guard let data = try get(hash) else { return nil }
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Bytes on disk across every blob.
    /// - Returns: The total size of the objects directory.
    func totalBytes() -> Int64 {
        let objects = root.appendingPathComponent("objects")
        guard let enumerator = FileManager.default.enumerator(at: objects, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
