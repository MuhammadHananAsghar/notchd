// CodexRolloutTailer.swift
// Follows the rollout transcripts Codex writes under ~/.codex/sessions and
// hands new lines to a parser per file. A file seen for the first time is
// read from its end, after its first line for the session and working
// directory, so an old transcript that happens to be appended to does not
// replay hours of history as if it were happening now. Polling rather than
// FSEvents: the directory is small, a second's latency is fine for derived
// fidelity, and it makes the tailer testable without a real filesystem
// event.

import Foundation
import os

/// Tails Codex rollouts.
final class CodexRolloutTailer {
    typealias Handler = ([NotchdEvent]) -> Void

    /// The environment variable that points a development copy at a scratch
    /// sessions directory instead of the real one.
    static let rootVariable = "NOTCHD_CODEX_SESSIONS"

    /// Where Codex keeps them, unless overridden.
    static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment[rootVariable], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// Per-file progress.
    private struct Cursor {
        var offset: UInt64
        var remainder: Data
        var parser: CodexRolloutParser
    }

    let root: URL
    /// Files not modified within this window are ignored.
    let recentWindow: TimeInterval
    private let handler: Handler
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "com.muhammad.notchd.codex")
    private var timer: DispatchSourceTimer?
    private var cursors: [String: Cursor] = [:]
    private let log = Logger(subsystem: "com.muhammad.notchd", category: "codex")

    /// Creates a tailer.
    /// - Parameters:
    ///   - root: The sessions directory.
    ///   - interval: Seconds between polls.
    ///   - recentWindow: How recently a file must have changed to be followed.
    ///   - handler: Called on the tailer's queue with each batch of events.
    init(root: URL = CodexRolloutTailer.defaultRoot, interval: TimeInterval = 1, recentWindow: TimeInterval = 15 * 60, handler: @escaping Handler) {
        self.root = root
        self.interval = interval
        self.recentWindow = recentWindow
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// Whether there is anything to follow.
    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: root.path)
    }

    /// Starts polling.
    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    /// Stops polling.
    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// One pass over the recent files. Public so tests can drive it.
    func poll() {
        let now = Date()
        for url in recentFiles(now: now) {
            do {
                try follow(url)
            } catch {
                log.error("could not read \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        cursors = cursors.filter { FileManager.default.fileExists(atPath: $0.key) }
    }

    /// Rollout files modified within the window, in the day directories that
    /// could hold them.
    private func recentFiles(now: Date) -> [URL] {
        let calendar = Calendar.current
        let days = [now, now.addingTimeInterval(-86_400)].map { calendar.dateComponents([.year, .month, .day], from: $0) }
        var result: [URL] = []
        for day in days {
            guard let year = day.year, let month = day.month, let dayOfMonth = day.day else { continue }
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", year, month, dayOfMonth), isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                let url = dir.appendingPathComponent(name)
                if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   now.timeIntervalSince(modified) <= recentWindow {
                    result.append(url)
                }
            }
        }
        return result
    }

    /// Reads whatever a file gained since the last poll.
    private func follow(_ url: URL) throws {
        let path = url.path
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        if cursors[path] == nil {
            if isNew(url) {
                cursors[path] = Cursor(offset: 0, remainder: Data(),
                                       parser: CodexRolloutParser(fallbackSession: CodexRolloutParser.sessionId(fromFileName: url.lastPathComponent)))
            } else {
                cursors[path] = try adopt(handle, size: size, name: url.lastPathComponent)
                return
            }
        }
        guard var cursor = cursors[path], size > cursor.offset else {
            if let cursor = cursors[path], size < cursor.offset { cursors[path] = nil }
            return
        }
        try handle.seek(toOffset: cursor.offset)
        let fresh = try handle.readToEnd() ?? Data()
        cursor.offset = size
        let events = consume(fresh, cursor: &cursor)
        cursors[path] = cursor
        if !events.isEmpty { handler(events) }
    }

    /// Whether a file was created within the window, and so is a session that
    /// began after Notchd was already watching: those are read from the
    /// start, so a thread that is only chat so far still appears with its
    /// prompts. Older files are adopted at their end.
    /// - Parameter url: The rollout file.
    /// - Returns: True for a recently created file.
    private func isNew(_ url: URL) -> Bool {
        guard let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else { return false }
        return Date().timeIntervalSince(created) <= recentWindow
    }

    /// Starts following a file at its end, having read its first line for
    /// the session and working directory.
    private func adopt(_ handle: FileHandle, size: UInt64, name: String) throws -> Cursor {
        var parser = CodexRolloutParser(fallbackSession: CodexRolloutParser.sessionId(fromFileName: name))
        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: 256 * 1024) ?? Data()
        if let newline = head.firstIndex(of: UInt8(ascii: "\n")) {
            _ = parser.events(from: Data(head[head.startIndex..<newline]))
        }
        return Cursor(offset: size, remainder: Data(), parser: parser)
    }

    /// Splits new bytes into whole lines, keeping a trailing partial line.
    private func consume(_ fresh: Data, cursor: inout Cursor) -> [NotchdEvent] {
        var buffer = cursor.remainder + fresh
        var events: [NotchdEvent] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer = Data(buffer[(newline + 1)...])
            if !line.isEmpty { events += cursor.parser.events(from: line) }
        }
        cursor.remainder = buffer
        return events
    }
}
