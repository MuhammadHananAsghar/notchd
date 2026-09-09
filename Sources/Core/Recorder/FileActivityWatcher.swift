// FileActivityWatcher.swift
// Watches the working directories of active sessions with FSEvents and reports
// the files that changed. The recorder decides whether a report belongs to an
// open tool call, to nobody, or to Notchd itself. File-level events, so a
// report names a file rather than a directory.

import CoreServices
import Foundation

/// An FSEvents stream over a set of roots.
final class FileActivityWatcher {
    typealias Handler = ([String]) -> Void

    private let latency: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.muhammad.notchd.watcher")
    private var stream: FSEventStreamRef?
    private(set) var roots: [String] = []

    /// Creates a watcher that starts on the first `update`.
    /// - Parameters:
    ///   - latency: Seconds FSEvents may coalesce events before delivering.
    ///   - handler: Called on the watcher queue with absolute file paths.
    init(latency: TimeInterval = 0.5, handler: @escaping Handler) {
        self.latency = latency
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// Replaces the watched roots, restarting the stream only when they differ.
    /// - Parameter newRoots: Directories to watch. Nested roots are collapsed.
    func update(roots newRoots: [String]) {
        let collapsed = Snapshotter.normalized(newRoots)
        guard collapsed != roots else { return }
        stop()
        roots = collapsed
        guard !collapsed.isEmpty else { return }
        start()
    }

    /// Stops the stream.
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Creates and starts the stream over the current roots.
    private func start() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, Self.callback, &context, roots as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// The C callback: keeps file and symlink events, drops directory-only ones.
    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info, let paths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] else { return }
        let watcher = Unmanaged<FileActivityWatcher>.fromOpaque(info).takeUnretainedValue()
        let fileMask = UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsSymlink)
        var files: [String] = []
        for index in 0..<count where eventFlags[index] & fileMask != 0 {
            files.append(paths[index])
        }
        if !files.isEmpty { watcher.handler(files) }
    }
}
