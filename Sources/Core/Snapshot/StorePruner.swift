// StorePruner.swift
// Removes blobs the ledger no longer needs. Everything referenced by a change
// or a checkpoint inside the retention window is kept, including every file
// inside a kept manifest; anything else is deleted. Ledger rows are never
// removed: a change older than the window stays in the timeline and, if its
// copy is gone, a revert says so rather than pretending.

import Foundation

/// What a prune did.
struct PruneResult: Equatable {
    let kept: Int
    let removed: Int
    let bytesFreed: Int64
}

/// Prunes the object store by retention.
struct StorePruner {
    let ledger: Ledger
    let store: ObjectStore
    /// How long a copy stays restorable.
    var retention: TimeInterval = 30 * 24 * 60 * 60

    /// Deletes every blob not referenced within the retention window.
    /// - Parameter now: The reference instant.
    /// - Returns: Counts of what was kept and removed.
    func prune(now: Date = Date()) throws -> PruneResult {
        let referenced = try ledger.referencedHashes(since: now.addingTimeInterval(-retention))
        var keep = referenced.contents.union(referenced.manifests)
        for hash in referenced.manifests {
            if let manifest = try store.manifest(hash) {
                keep.formUnion(manifest.entries.values.map(\.hash))
            }
        }
        var removed = 0
        var freed: Int64 = 0
        for (hash, url) in try store.allBlobs() where !keep.contains(hash) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try FileManager.default.removeItem(at: url)
            removed += 1
            freed += Int64(size)
        }
        return PruneResult(kept: keep.count, removed: removed, bytesFreed: freed)
    }
}

extension ObjectStore {
    /// Every blob on disk.
    /// - Returns: Pairs of hash and file location.
    func allBlobs() throws -> [(hash: String, url: URL)] {
        let objects = root.appendingPathComponent("objects")
        let prefixes = try FileManager.default.contentsOfDirectory(at: objects, includingPropertiesForKeys: nil)
        var result: [(String, URL)] = []
        for prefix in prefixes where prefix.lastPathComponent.count == 2 {
            for file in try FileManager.default.contentsOfDirectory(at: prefix, includingPropertiesForKeys: nil) {
                result.append((prefix.lastPathComponent + file.lastPathComponent, file))
            }
        }
        return result
    }
}
