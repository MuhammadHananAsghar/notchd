// Snapshotter.swift
// Captures the files under a set of roots into the object store and returns a
// manifest. Bounded by limits so a checkpoint of a large tree stays cheap and
// says when it was cut short. A stat cache means an unchanged file costs one
// lstat rather than a read, which is what makes checkpointing before every
// shell command affordable.

import Darwin
import Foundation

/// What a snapshot will and will not include.
struct SnapshotLimits: Equatable {
    /// Files larger than this are skipped and counted.
    var maxFileBytes: Int64 = 50 * 1024 * 1024
    /// After this many files the snapshot stops and is marked truncated.
    var maxFiles = 20_000
    /// Directory names never descended into unless named as a root.
    var excludedNames: Set<String> = [
        ".git", "node_modules", "build", "DerivedData", ".venv", "venv", "__pycache__", ".cache",
        "Pods", "target", "dist", ".next", ".turbo", ".gradle", ".idea", ".tox", ".mypy_cache", ".pytest_cache",
    ]

    /// The defaults.
    static let standard = SnapshotLimits()

    /// Whether a root is sensible to snapshot or watch. The home directory,
    /// the filesystem root, and system trees are refused: they are too large
    /// to be honest about and are never a project.
    /// - Parameter root: An absolute path.
    /// - Returns: True when the root is a project-sized directory.
    func isReasonableRoot(_ root: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let standardized = URL(fileURLWithPath: root).standardizedFileURL.path
        if standardized == "/" || standardized == home { return false }
        for prefix in ["/System", "/Library", "/usr", "/bin", "/sbin", "/private/var", "/dev"] where standardized.hasPrefix(prefix) {
            return false
        }
        return true
    }

    /// Whether any component of a path is an excluded directory name.
    /// - Parameter path: An absolute path.
    /// - Returns: True when the path is inside an excluded directory.
    func isExcluded(_ path: String) -> Bool {
        path.split(separator: "/").dropLast().contains { excludedNames.contains(String($0)) }
    }
}

/// The result of one snapshot.
struct SnapshotResult: Equatable {
    let manifest: Manifest
    /// True when the file cap stopped the walk early.
    let truncated: Bool
    /// Files skipped for exceeding the size limit.
    let skippedLarge: Int
    /// Blobs written that were not already in the store.
    let newObjects: Int
    /// Bytes read from disk.
    let bytesRead: Int64
}

/// Remembers the hash of a file by its stat signature so unchanged files are
/// not re-read. Safe to share across queues.
final class StatCache {
    /// The signature a file had when it was last hashed.
    struct Signature: Equatable {
        let size: Int64
        let mtimeNanoseconds: Int64
        let inode: UInt64
    }

    private struct Cached {
        let signature: Signature
        let entry: ManifestEntry
    }

    private var cache: [String: Cached] = [:]
    private let lock = NSLock()

    /// The remembered entry for a path if its signature still matches.
    /// - Parameters:
    ///   - path: The absolute path.
    ///   - signature: The file's current signature.
    /// - Returns: The entry, or nil when the file changed or was never seen.
    func entry(for path: String, signature: Signature) -> ManifestEntry? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached = cache[path], cached.signature == signature else { return nil }
        return cached.entry
    }

    /// The last entry seen for a path regardless of whether it has changed
    /// since. This is what an unattributed change is compared against.
    /// - Parameter path: The absolute path.
    /// - Returns: The entry, or nil when never seen.
    func lastKnown(_ path: String) -> ManifestEntry? {
        lock.lock()
        defer { lock.unlock() }
        return cache[path]?.entry
    }

    /// Remembers an entry.
    /// - Parameters:
    ///   - entry: The hashed entry.
    ///   - path: The absolute path.
    ///   - signature: The signature at hashing time.
    func remember(_ entry: ManifestEntry, for path: String, signature: Signature) {
        lock.lock()
        cache[path] = Cached(signature: signature, entry: entry)
        lock.unlock()
    }

    /// Forgets a path, after it was deleted.
    /// - Parameter path: The absolute path.
    func forget(_ path: String) {
        lock.lock()
        cache.removeValue(forKey: path)
        lock.unlock()
    }
}

/// What lstat says about a path.
struct FileStat: Equatable {
    enum Kind: Equatable { case regular, symlink, directory, other }
    let kind: Kind
    let mode: UInt16
    let size: Int64
    let signature: StatCache.Signature

    /// Stats a path without following symlinks.
    /// - Parameter path: An absolute path.
    /// - Returns: The stat, or nil when the path does not exist.
    static func of(_ path: String) -> FileStat? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        let kind: Kind
        switch status.st_mode & S_IFMT {
        case S_IFREG: kind = .regular
        case S_IFLNK: kind = .symlink
        case S_IFDIR: kind = .directory
        default: kind = .other
        }
        let mtime = Int64(status.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(status.st_mtimespec.tv_nsec)
        return FileStat(kind: kind, mode: UInt16(status.st_mode & 0o7777), size: Int64(status.st_size),
                        signature: StatCache.Signature(size: Int64(status.st_size), mtimeNanoseconds: mtime, inode: UInt64(status.st_ino)))
    }
}

/// Captures trees into the store.
final class Snapshotter {
    let store: ObjectStore
    let limits: SnapshotLimits
    let cache: StatCache

    /// Creates a snapshotter.
    /// - Parameters:
    ///   - store: Where contents go.
    ///   - limits: What to skip.
    ///   - cache: The shared stat cache.
    init(store: ObjectStore, limits: SnapshotLimits = .standard, cache: StatCache = StatCache()) {
        self.store = store
        self.limits = limits
        self.cache = cache
    }

    /// Snapshots every file under the roots. A root that does not exist
    /// contributes nothing, which is how a file about to be created diffs as a
    /// create.
    /// - Parameter roots: Absolute paths to files or directories.
    /// - Returns: The manifest and what was skipped.
    func snapshot(roots: [String]) throws -> SnapshotResult {
        var entries: [String: ManifestEntry] = [:]
        var truncated = false
        var skippedLarge = 0
        var newObjects = 0
        var bytesRead: Int64 = 0
        for root in Self.normalized(roots) where !truncated {
            guard let status = FileStat.of(root) else { continue }
            switch status.kind {
            case .regular, .symlink:
                if let outcome = try capture(root, status: status, skippedLarge: &skippedLarge, newObjects: &newObjects, bytesRead: &bytesRead) {
                    entries[root] = outcome
                }
            case .directory:
                try walk(root, into: &entries, truncated: &truncated, skippedLarge: &skippedLarge, newObjects: &newObjects, bytesRead: &bytesRead)
            case .other:
                continue
            }
        }
        return SnapshotResult(manifest: Manifest(entries: entries), truncated: truncated, skippedLarge: skippedLarge,
                              newObjects: newObjects, bytesRead: bytesRead)
    }

    /// Hashes one file or symlink, reading it only if the cache cannot vouch.
    /// - Parameters:
    ///   - path: The absolute path.
    ///   - status: Its stat.
    /// - Returns: The entry, or nil when the file was skipped for size.
    func capture(_ path: String, status: FileStat, skippedLarge: inout Int, newObjects: inout Int, bytesRead: inout Int64) throws -> ManifestEntry? {
        if let cached = cache.entry(for: path, signature: status.signature), store.contains(cached.hash) { return cached }
        let data: Data
        if status.kind == .symlink {
            data = Data(try FileManager.default.destinationOfSymbolicLink(atPath: path).utf8)
        } else {
            guard status.size <= limits.maxFileBytes else {
                skippedLarge += 1
                return nil
            }
            data = try Data(contentsOf: URL(fileURLWithPath: path), options: .uncached)
        }
        bytesRead += Int64(data.count)
        let hash = ObjectStore.hash(data)
        if !store.contains(hash) {
            try store.put(data)
            newObjects += 1
        }
        let entry = ManifestEntry(hash: hash, mode: status.mode, size: Int64(data.count), isSymlink: status.kind == .symlink)
        cache.remember(entry, for: path, signature: status.signature)
        return entry
    }

    /// Walks a directory, skipping excluded names and stopping at the cap.
    private func walk(_ root: String, into entries: inout [String: ManifestEntry], truncated: inout Bool,
                      skippedLarge: inout Int, newObjects: inout Int, bytesRead: inout Int64) throws {
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return }
        while let relative = enumerator.nextObject() as? String {
            let path = root + "/" + relative
            let name = (relative as NSString).lastPathComponent
            guard let status = FileStat.of(path) else { continue }
            if status.kind == .directory {
                if limits.excludedNames.contains(name) { enumerator.skipDescendants() }
                continue
            }
            guard status.kind == .regular || status.kind == .symlink else { continue }
            if entries.count >= limits.maxFiles {
                truncated = true
                return
            }
            if let entry = try capture(path, status: status, skippedLarge: &skippedLarge, newObjects: &newObjects, bytesRead: &bytesRead) {
                entries[path] = entry
            }
        }
    }

    /// Roots as absolute standardised paths, with any root inside another
    /// root dropped so nothing is walked twice.
    /// - Parameter roots: Paths as declared.
    /// - Returns: The minimal set, sorted.
    static func normalized(_ roots: [String]) -> [String] {
        let absolute = Set(roots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }).sorted()
        return absolute.filter { candidate in
            !absolute.contains { other in other != candidate && candidate.hasPrefix(other + "/") }
        }
    }
}
