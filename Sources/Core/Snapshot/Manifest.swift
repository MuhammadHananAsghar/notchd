// Manifest.swift
// The shape of a set of files at one instant: for every path, the hash of its
// contents, its mode, its size, and whether it is a symlink. Two manifests
// diffed give the list of changes between them, which is what the ledger
// records and what a revert restores from.

import Foundation

/// One file inside a manifest.
struct ManifestEntry: Codable, Equatable {
    /// Hash of the contents, or of the link target for a symlink.
    let hash: String
    /// POSIX permission bits.
    let mode: UInt16
    let size: Int64
    let isSymlink: Bool
}

/// Every file under a set of roots at one instant, keyed by absolute path.
struct Manifest: Codable, Equatable {
    var entries: [String: ManifestEntry]

    /// An empty manifest.
    static let empty = Manifest(entries: [:])
}

/// What happened to one path between two manifests.
enum ChangeKind: String, Codable, CaseIterable {
    case create
    case modify
    case delete
}

/// One path's difference between two manifests.
struct PathChange: Equatable {
    let path: String
    let kind: ChangeKind
    let before: ManifestEntry?
    let after: ManifestEntry?
}

/// Diffing manifests.
enum ManifestDiff {
    /// The changes that turn one manifest into another, sorted by path.
    /// - Parameters:
    ///   - before: The earlier manifest.
    ///   - after: The later manifest.
    /// - Returns: Creates, modifies, and deletes. Unchanged paths are omitted.
    static func changes(from before: Manifest, to after: Manifest) -> [PathChange] {
        let paths = Set(before.entries.keys).union(after.entries.keys)
        return paths.sorted().compactMap { path in
            switch (before.entries[path], after.entries[path]) {
            case (nil, nil):
                return nil
            case (nil, let new?):
                return PathChange(path: path, kind: .create, before: nil, after: new)
            case (let old?, nil):
                return PathChange(path: path, kind: .delete, before: old, after: nil)
            case (let old?, let new?):
                return old == new ? nil : PathChange(path: path, kind: .modify, before: old, after: new)
            }
        }
    }
}
