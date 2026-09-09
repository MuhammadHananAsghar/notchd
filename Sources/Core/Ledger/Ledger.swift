// Ledger.swift
// The append-only record of what every agent did. Five tables: sessions,
// events, checkpoints, changes, and reverts. A row is never changed once
// written, with two narrow exceptions on sessions: the end time when the agent
// reports one, and the time of the last event. A revert is recorded as new
// events and changes, never by editing old ones, which is what makes the
// ledger an audit trail rather than a cache. Access is serialised on one queue.

import Foundation

/// A session as stored.
struct SessionRow: Equatable, Identifiable {
    let id: Int64
    let vendor: String
    let vendorSessionId: String
    let pid: Int32?
    let cwd: String
    let startedAt: Date
    let endedAt: Date?
    let lastEventAt: Date
    let fidelity: Fidelity

    /// Whether the agent has not reported an end and has been heard from
    /// within the activity window.
    /// - Parameters:
    ///   - now: The reference instant.
    ///   - window: How long silence counts as still active.
    /// - Returns: True when the session should be drawn as live.
    func isActive(at now: Date = Date(), window: TimeInterval = 30 * 60) -> Bool {
        endedAt == nil && now.timeIntervalSince(lastEventAt) < window
    }

    /// The last path component of the working directory, for labels.
    var projectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }
}

/// An event as stored.
struct EventRow: Equatable, Identifiable {
    let id: Int64
    let sessionId: Int64
    let kind: NotchdEvent.Kind
    let tool: String?
    let toolUseId: String?
    let args: JSONValue?
    let result: JSONValue?
    let error: String?
    let paths: [String]
    let meta: JSONValue?
    let ts: Date
    let fidelity: Fidelity
}

/// A checkpoint as stored.
struct CheckpointRow: Equatable, Identifiable {
    let id: Int64
    let eventId: Int64?
    let sessionId: Int64?
    let toolUseId: String?
    let roots: [String]
    let manifestHash: String
    let createdAt: Date
    let objectCount: Int
    let byteCount: Int64
    /// The file cap stopped the walk early.
    let truncated: Bool
    /// The snapshot took longer than the hook waited, so the tool may have
    /// started before it finished.
    let late: Bool
    let durationMs: Int
}

/// A change waiting to be written.
struct NewChange: Equatable {
    let eventId: Int64?
    let sessionId: Int64?
    let path: String
    let kind: ChangeKind
    let before: ManifestEntry?
    let after: ManifestEntry?
    let attributed: Bool
    let ts: Date
}

/// A change as stored.
struct ChangeRow: Equatable, Identifiable {
    let id: Int64
    let eventId: Int64?
    let sessionId: Int64?
    let path: String
    let kind: ChangeKind
    let before: ManifestEntry?
    let after: ManifestEntry?
    let attributed: Bool
    let ts: Date
}

/// How a revert ended.
enum RevertOutcome: String, Codable {
    case complete
    case partial
}

/// A revert as stored.
struct RevertRow: Equatable, Identifiable {
    let id: Int64
    let eventId: Int64
    let createdAt: Date
    let scope: JSONValue
    let result: RevertOutcome
    let note: String
}

/// Activity totals for the menu bar.
struct LedgerCounts: Equatable {
    let activeSessions: Int
    let recentChanges: Int
}

/// The persistent record.
final class Ledger {
    private let db: SQLiteDatabase
    private let queue = DispatchQueue(label: "com.muhammad.notchd.ledger")

    /// Opens or creates the ledger and brings its schema up to date.
    /// - Parameter path: The SQLite file, or `:memory:`.
    init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try db.exec(Self.schema)
    }

    /// The schema. `IF NOT EXISTS` makes it safe to run on every launch.
    private static let schema = """
    PRAGMA journal_mode = WAL;
    CREATE TABLE IF NOT EXISTS sessions (
        id INTEGER PRIMARY KEY,
        vendor TEXT NOT NULL,
        vendor_session_id TEXT NOT NULL,
        pid INTEGER,
        cwd TEXT NOT NULL,
        started_at REAL NOT NULL,
        ended_at REAL,
        last_event_at REAL NOT NULL,
        fidelity TEXT NOT NULL,
        UNIQUE(vendor, vendor_session_id)
    );
    CREATE TABLE IF NOT EXISTS events (
        id INTEGER PRIMARY KEY,
        session_id INTEGER NOT NULL REFERENCES sessions(id),
        kind TEXT NOT NULL,
        tool TEXT,
        tool_use_id TEXT,
        args_json TEXT,
        result_json TEXT,
        error TEXT,
        paths_json TEXT NOT NULL,
        meta_json TEXT,
        ts REAL NOT NULL,
        fidelity TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS checkpoints (
        id INTEGER PRIMARY KEY,
        event_id INTEGER REFERENCES events(id),
        session_id INTEGER REFERENCES sessions(id),
        tool_use_id TEXT,
        roots_json TEXT NOT NULL,
        manifest_hash TEXT NOT NULL,
        created_at REAL NOT NULL,
        object_count INTEGER NOT NULL,
        byte_count INTEGER NOT NULL,
        truncated INTEGER NOT NULL,
        late INTEGER NOT NULL,
        duration_ms INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS changes (
        id INTEGER PRIMARY KEY,
        event_id INTEGER REFERENCES events(id),
        session_id INTEGER REFERENCES sessions(id),
        path TEXT NOT NULL,
        kind TEXT NOT NULL,
        before_json TEXT,
        after_json TEXT,
        attributed INTEGER NOT NULL,
        ts REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS reverts (
        id INTEGER PRIMARY KEY,
        event_id INTEGER NOT NULL REFERENCES events(id),
        created_at REAL NOT NULL,
        scope_json TEXT NOT NULL,
        result TEXT NOT NULL,
        note TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS events_by_session ON events(session_id, ts);
    CREATE INDEX IF NOT EXISTS events_by_time ON events(ts);
    CREATE INDEX IF NOT EXISTS sessions_by_activity ON sessions(last_event_at);
    CREATE INDEX IF NOT EXISTS checkpoints_by_call ON checkpoints(session_id, tool_use_id);
    CREATE INDEX IF NOT EXISTS changes_by_time ON changes(ts);
    CREATE INDEX IF NOT EXISTS changes_by_event ON changes(event_id);
    CREATE INDEX IF NOT EXISTS changes_by_session ON changes(session_id, ts);
    """

    /// Records an event, creating its session if this is the first time the
    /// vendor session has been seen.
    /// - Parameter event: The normalised event.
    /// - Returns: The stored row.
    @discardableResult
    func record(_ event: NotchdEvent) throws -> EventRow {
        try queue.sync {
            try db.exec("BEGIN")
            do {
                let sessionId = try upsertSession(for: event)
                let id = try db.run("""
                    INSERT INTO events (session_id, kind, tool, tool_use_id, args_json, result_json, error, paths_json, meta_json, ts, fidelity)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [
                    .integer(sessionId), .text(event.kind.rawValue), text(event.tool), text(event.toolUseId),
                    json(event.args), json(event.result), text(event.error),
                    .text(JSONValue.array(event.paths.map(JSONValue.string)).serializedString),
                    json(event.meta), .real(event.ts.timeIntervalSince1970), .text(event.fidelity.rawValue),
                ])
                try db.exec("COMMIT")
                return EventRow(id: id, sessionId: sessionId, kind: event.kind, tool: event.tool, toolUseId: event.toolUseId,
                                args: event.args, result: event.result, error: event.error, paths: event.paths,
                                meta: event.meta, ts: event.ts, fidelity: event.fidelity)
            } catch {
                try? db.exec("ROLLBACK")
                throw error
            }
        }
    }

    /// Finds or creates the session row for an event and updates its activity.
    private func upsertSession(for event: NotchdEvent) throws -> Int64 {
        let ts = event.ts.timeIntervalSince1970
        let existing = try db.query("SELECT id FROM sessions WHERE vendor = ? AND vendor_session_id = ?",
                                    [.text(event.vendor), .text(event.session)])
        if let id = existing.first?["id"]?.int64 {
            try db.run("UPDATE sessions SET last_event_at = MAX(last_event_at, ?) WHERE id = ?", [.real(ts), .integer(id)])
            if event.kind == .sessionEnd {
                try db.run("UPDATE sessions SET ended_at = ? WHERE id = ?", [.real(ts), .integer(id)])
            }
            if let pid = event.pid {
                try db.run("UPDATE sessions SET pid = ? WHERE id = ? AND pid IS NULL", [.integer(Int64(pid)), .integer(id)])
            }
            return id
        }
        return try db.run("""
            INSERT INTO sessions (vendor, vendor_session_id, pid, cwd, started_at, ended_at, last_event_at, fidelity)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [
            .text(event.vendor), .text(event.session), event.pid.map { .integer(Int64($0)) } ?? .null,
            .text(event.cwd), .real(ts), event.kind == .sessionEnd ? .real(ts) : .null, .real(ts),
            .text(event.fidelity.rawValue),
        ])
    }

    /// Whether an event with the same vendor session, kind, instant, and tool
    /// call id is already recorded. Transcript tailers replay a file when the
    /// app relaunches, and this is what keeps a replay from doubling it.
    /// - Parameter event: The event about to be recorded.
    /// - Returns: True when an equal event exists.
    func contains(_ event: NotchdEvent) throws -> Bool {
        try queue.sync {
            let rows = try db.query("""
                SELECT 1 FROM events e JOIN sessions s ON s.id = e.session_id
                WHERE s.vendor = ? AND s.vendor_session_id = ? AND e.kind = ? AND e.ts = ? AND IFNULL(e.tool_use_id, '') = ?
                LIMIT 1
                """, [.text(event.vendor), .text(event.session), .text(event.kind.rawValue),
                      .real(event.ts.timeIntervalSince1970), .text(event.toolUseId ?? "")])
            return !rows.isEmpty
        }
    }

    /// Sessions ordered by most recent activity.
    /// - Parameter limit: Maximum rows.
    /// - Returns: Session rows.
    func sessions(limit: Int = 200) throws -> [SessionRow] {
        try queue.sync {
            try db.query("SELECT * FROM sessions ORDER BY last_event_at DESC LIMIT ?", [.integer(Int64(limit))])
                .compactMap(Self.session)
        }
    }

    /// One session by its ledger id.
    /// - Parameter id: The row id.
    /// - Returns: The session, or nil.
    func session(id: Int64) throws -> SessionRow? {
        try queue.sync {
            try db.query("SELECT * FROM sessions WHERE id = ?", [.integer(id)]).compactMap(Self.session).first
        }
    }

    /// Every event of one session, oldest first.
    /// - Parameter sessionId: The session's ledger id.
    /// - Returns: Event rows.
    func events(sessionId: Int64) throws -> [EventRow] {
        try queue.sync {
            try db.query("SELECT * FROM events WHERE session_id = ? ORDER BY ts, id", [.integer(sessionId)])
                .compactMap(Self.event)
        }
    }

    /// Events across all sessions in a time range, newest first.
    /// - Parameters:
    ///   - since: The earliest instant to include.
    ///   - until: The latest instant to include.
    ///   - limit: Maximum rows.
    /// - Returns: Event rows.
    func events(since: Date, until: Date = .distantFuture, limit: Int = 1000) throws -> [EventRow] {
        try queue.sync {
            try db.query("SELECT * FROM events WHERE ts >= ? AND ts <= ? ORDER BY ts DESC, id DESC LIMIT ?",
                         [.real(since.timeIntervalSince1970), .real(until.timeIntervalSince1970), .integer(Int64(limit))])
                .compactMap(Self.event)
        }
    }

    /// Records a checkpoint.
    /// - Parameters:
    ///   - eventId: The tool.before event it precedes, if any.
    ///   - sessionId: The session, if any.
    ///   - toolUseId: The vendor's tool call id, for pairing after a restart.
    ///   - roots: The roots that were captured.
    ///   - manifestHash: The stored manifest.
    ///   - result: What the snapshot reported.
    ///   - late: Whether it outran the hook's wait.
    ///   - durationMs: How long it took.
    ///   - createdAt: When.
    /// - Returns: The checkpoint id.
    @discardableResult
    func recordCheckpoint(eventId: Int64?, sessionId: Int64?, toolUseId: String?, roots: [String], manifestHash: String,
                          result: SnapshotResult, late: Bool, durationMs: Int, createdAt: Date = Date()) throws -> Int64 {
        try queue.sync {
            try db.run("""
                INSERT INTO checkpoints (event_id, session_id, tool_use_id, roots_json, manifest_hash, created_at, object_count, byte_count, truncated, late, duration_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [
                eventId.map(SQLiteValue.integer) ?? .null, sessionId.map(SQLiteValue.integer) ?? .null, text(toolUseId),
                .text(JSONValue.array(roots.map(JSONValue.string)).serializedString), .text(manifestHash),
                .real(createdAt.timeIntervalSince1970), .integer(Int64(result.manifest.entries.count)), .integer(result.bytesRead),
                .integer(result.truncated ? 1 : 0), .integer(late ? 1 : 0), .integer(Int64(durationMs)),
            ])
        }
    }

    /// The most recent checkpoint for a tool call, used when the pairing
    /// tool.before was recorded by a previous run of the app.
    /// - Parameters:
    ///   - sessionId: The session.
    ///   - toolUseId: The vendor's tool call id.
    /// - Returns: The checkpoint, or nil.
    func checkpoint(sessionId: Int64, toolUseId: String) throws -> CheckpointRow? {
        try queue.sync {
            try db.query("SELECT * FROM checkpoints WHERE session_id = ? AND tool_use_id = ? ORDER BY id DESC LIMIT 1",
                         [.integer(sessionId), .text(toolUseId)]).compactMap(Self.checkpoint).first
        }
    }

    /// The checkpoint recorded for an event.
    /// - Parameter eventId: The event.
    /// - Returns: The checkpoint, or nil.
    func checkpoint(eventId: Int64) throws -> CheckpointRow? {
        try queue.sync {
            try db.query("SELECT * FROM checkpoints WHERE event_id = ? ORDER BY id DESC LIMIT 1", [.integer(eventId)])
                .compactMap(Self.checkpoint).first
        }
    }

    /// Appends changes in one transaction.
    /// - Parameter changes: The changes.
    /// - Returns: Their ids, in order.
    @discardableResult
    func recordChanges(_ changes: [NewChange]) throws -> [Int64] {
        guard !changes.isEmpty else { return [] }
        return try queue.sync {
            try db.exec("BEGIN")
            do {
                let ids = try changes.map { change in
                    try db.run("""
                        INSERT INTO changes (event_id, session_id, path, kind, before_json, after_json, attributed, ts)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """, [
                        change.eventId.map(SQLiteValue.integer) ?? .null, change.sessionId.map(SQLiteValue.integer) ?? .null,
                        .text(change.path), .text(change.kind.rawValue), entryJSON(change.before), entryJSON(change.after),
                        .integer(change.attributed ? 1 : 0), .real(change.ts.timeIntervalSince1970),
                    ])
                }
                try db.exec("COMMIT")
                return ids
            } catch {
                try? db.exec("ROLLBACK")
                throw error
            }
        }
    }

    /// Changes in a time range, oldest first.
    /// - Parameters:
    ///   - since: The earliest instant.
    ///   - until: The latest instant.
    ///   - sessionIds: Restrict to these sessions, or nil for all.
    ///   - includeUnattributed: Whether changes no agent claimed are included.
    /// - Returns: Change rows.
    func changes(since: Date, until: Date = .distantFuture, sessionIds: [Int64]? = nil, includeUnattributed: Bool = false) throws -> [ChangeRow] {
        try queue.sync {
            var sql = "SELECT * FROM changes WHERE ts >= ? AND ts <= ?"
            var params: [SQLiteValue] = [.real(since.timeIntervalSince1970), .real(until.timeIntervalSince1970)]
            if let sessionIds {
                sql += " AND session_id IN (" + sessionIds.map { _ in "?" }.joined(separator: ",") + ")"
                params += sessionIds.map(SQLiteValue.integer)
            }
            if !includeUnattributed { sql += " AND attributed = 1" }
            sql += " ORDER BY ts, id"
            return try db.query(sql, params).compactMap(Self.change)
        }
    }

    /// Changes recorded for one event, sorted by path.
    /// - Parameter eventId: The event.
    /// - Returns: Change rows.
    func changes(eventId: Int64) throws -> [ChangeRow] {
        try queue.sync {
            try db.query("SELECT * FROM changes WHERE event_id = ? ORDER BY path", [.integer(eventId)]).compactMap(Self.change)
        }
    }

    /// Every change of one session, keyed by event.
    /// - Parameter sessionId: The session.
    /// - Returns: Change rows grouped by event id.
    func changesByEvent(sessionId: Int64) throws -> [Int64: [ChangeRow]] {
        try queue.sync {
            let rows = try db.query("SELECT * FROM changes WHERE session_id = ? ORDER BY path", [.integer(sessionId)]).compactMap(Self.change)
            return Dictionary(grouping: rows.filter { $0.eventId != nil }, by: { $0.eventId! })
        }
    }

    /// Changes no agent claimed, newest first.
    /// - Parameter limit: Maximum rows.
    /// - Returns: Change rows.
    func unattributedChanges(limit: Int = 500) throws -> [ChangeRow] {
        try queue.sync {
            try db.query("SELECT * FROM changes WHERE attributed = 0 ORDER BY ts DESC, id DESC LIMIT ?", [.integer(Int64(limit))])
                .compactMap(Self.change)
        }
    }

    /// Unattributed changes inside a time range, oldest first.
    /// - Parameters:
    ///   - since: The earliest instant.
    ///   - until: The latest instant.
    /// - Returns: Change rows.
    func unattributedChanges(since: Date, until: Date) throws -> [ChangeRow] {
        try queue.sync {
            try db.query("SELECT * FROM changes WHERE attributed = 0 AND ts >= ? AND ts <= ? ORDER BY ts, id",
                         [.real(since.timeIntervalSince1970), .real(until.timeIntervalSince1970)]).compactMap(Self.change)
        }
    }

    /// Gives unattributed changes to a tool call. The one correction the
    /// ledger allows on a change row: a transcript-derived vendor tells
    /// Notchd about a call after it has run, so the watcher may already have
    /// filed its changes as nobody's, and the truth is that the call made
    /// them.
    /// - Parameters:
    ///   - ids: The change rows.
    ///   - eventId: The tool call's after-event.
    ///   - sessionId: The session.
    func attribute(changeIds ids: [Int64], to eventId: Int64, sessionId: Int64) throws {
        guard !ids.isEmpty else { return }
        try queue.sync {
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            try db.run("UPDATE changes SET attributed = 1, event_id = ?, session_id = ? WHERE attributed = 0 AND id IN (\(placeholders))",
                       [.integer(eventId), .integer(sessionId)] + ids.map(SQLiteValue.integer))
        }
    }

    /// Records a revert.
    /// - Parameters:
    ///   - eventId: The synthetic event the revert's changes hang on.
    ///   - scope: What was asked for.
    ///   - result: How it ended.
    ///   - note: What could not be undone, if anything.
    ///   - createdAt: When.
    /// - Returns: The revert id.
    @discardableResult
    func recordRevert(eventId: Int64, scope: JSONValue, result: RevertOutcome, note: String, createdAt: Date = Date()) throws -> Int64 {
        try queue.sync {
            try db.run("INSERT INTO reverts (event_id, created_at, scope_json, result, note) VALUES (?, ?, ?, ?, ?)",
                       [.integer(eventId), .real(createdAt.timeIntervalSince1970), .text(scope.serializedString),
                        .text(result.rawValue), .text(note)])
        }
    }

    /// Every revert, newest first.
    /// - Returns: Revert rows.
    func reverts() throws -> [RevertRow] {
        try queue.sync {
            try db.query("SELECT * FROM reverts ORDER BY id DESC").compactMap(Self.revert)
        }
    }

    /// Every content hash and manifest hash referenced by changes and
    /// checkpoints since an instant. What the pruner keeps.
    /// - Parameter since: The retention boundary.
    /// - Returns: Hashes of file contents and of manifests.
    func referencedHashes(since: Date) throws -> (contents: Set<String>, manifests: Set<String>) {
        try queue.sync {
            let floor = since.timeIntervalSince1970
            var contents = Set<String>()
            for row in try db.query("SELECT before_json, after_json FROM changes WHERE ts >= ?", [.real(floor)]) {
                if let hash = Self.entry(row["before_json"])?.hash { contents.insert(hash) }
                if let hash = Self.entry(row["after_json"])?.hash { contents.insert(hash) }
            }
            let manifests = Set(try db.query("SELECT manifest_hash FROM checkpoints WHERE created_at >= ?", [.real(floor)])
                .compactMap { $0["manifest_hash"]?.string })
            return (contents, manifests)
        }
    }

    /// Totals for the menu bar.
    /// - Parameters:
    ///   - now: The reference instant.
    ///   - window: How far back to count changes.
    /// - Returns: The counts.
    func counts(now: Date = Date(), window: TimeInterval = 60 * 60) throws -> LedgerCounts {
        try queue.sync {
            let active = try db.query("SELECT COUNT(*) AS n FROM sessions WHERE ended_at IS NULL AND last_event_at >= ?",
                                      [.real(now.timeIntervalSince1970 - 30 * 60)])
            let changes = try db.query("SELECT COUNT(*) AS n FROM changes WHERE ts >= ? AND attributed = 1",
                                       [.real(now.timeIntervalSince1970 - window)])
            return LedgerCounts(activeSessions: Int(active.first?["n"]?.int64 ?? 0),
                                recentChanges: Int(changes.first?["n"]?.int64 ?? 0))
        }
    }

    /// Binds an optional string.
    private func text(_ value: String?) -> SQLiteValue {
        value.map(SQLiteValue.text) ?? .null
    }

    /// Binds an optional JSON value as text.
    private func json(_ value: JSONValue?) -> SQLiteValue {
        value.map { .text($0.serializedString) } ?? .null
    }

    /// Binds an optional manifest entry as JSON text.
    private func entryJSON(_ entry: ManifestEntry?) -> SQLiteValue {
        guard let entry, let data = try? JSONEncoder().encode(entry) else { return .null }
        return .text(String(decoding: data, as: UTF8.self))
    }

    /// Maps a sessions row.
    private static func session(_ row: [String: SQLiteValue]) -> SessionRow? {
        guard let id = row["id"]?.int64, let vendor = row["vendor"]?.string,
              let vendorSessionId = row["vendor_session_id"]?.string, let cwd = row["cwd"]?.string,
              let started = row["started_at"]?.double, let last = row["last_event_at"]?.double,
              let fidelity = row["fidelity"]?.string.flatMap(Fidelity.init(rawValue:)) else { return nil }
        return SessionRow(id: id, vendor: vendor, vendorSessionId: vendorSessionId,
                          pid: row["pid"]?.int64.map(Int32.init), cwd: cwd,
                          startedAt: Date(timeIntervalSince1970: started),
                          endedAt: row["ended_at"]?.double.map(Date.init(timeIntervalSince1970:)),
                          lastEventAt: Date(timeIntervalSince1970: last), fidelity: fidelity)
    }

    /// Maps an events row.
    private static func event(_ row: [String: SQLiteValue]) -> EventRow? {
        guard let id = row["id"]?.int64, let sessionId = row["session_id"]?.int64,
              let kind = row["kind"]?.string.flatMap(NotchdEvent.Kind.init(rawValue:)),
              let ts = row["ts"]?.double,
              let fidelity = row["fidelity"]?.string.flatMap(Fidelity.init(rawValue:)) else { return nil }
        let paths = parse(row["paths_json"])?.arrayValue?.compactMap(\.stringValue) ?? []
        return EventRow(id: id, sessionId: sessionId, kind: kind, tool: row["tool"]?.string,
                        toolUseId: row["tool_use_id"]?.string, args: parse(row["args_json"]),
                        result: parse(row["result_json"]), error: row["error"]?.string, paths: paths,
                        meta: parse(row["meta_json"]), ts: Date(timeIntervalSince1970: ts), fidelity: fidelity)
    }

    /// Maps a checkpoints row.
    private static func checkpoint(_ row: [String: SQLiteValue]) -> CheckpointRow? {
        guard let id = row["id"]?.int64, let manifestHash = row["manifest_hash"]?.string,
              let created = row["created_at"]?.double else { return nil }
        return CheckpointRow(id: id, eventId: row["event_id"]?.int64, sessionId: row["session_id"]?.int64,
                             toolUseId: row["tool_use_id"]?.string,
                             roots: parse(row["roots_json"])?.arrayValue?.compactMap(\.stringValue) ?? [],
                             manifestHash: manifestHash, createdAt: Date(timeIntervalSince1970: created),
                             objectCount: Int(row["object_count"]?.int64 ?? 0), byteCount: row["byte_count"]?.int64 ?? 0,
                             truncated: (row["truncated"]?.int64 ?? 0) != 0, late: (row["late"]?.int64 ?? 0) != 0,
                             durationMs: Int(row["duration_ms"]?.int64 ?? 0))
    }

    /// Maps a changes row.
    private static func change(_ row: [String: SQLiteValue]) -> ChangeRow? {
        guard let id = row["id"]?.int64, let path = row["path"]?.string,
              let kind = row["kind"]?.string.flatMap(ChangeKind.init(rawValue:)), let ts = row["ts"]?.double else { return nil }
        return ChangeRow(id: id, eventId: row["event_id"]?.int64, sessionId: row["session_id"]?.int64, path: path, kind: kind,
                         before: entry(row["before_json"]), after: entry(row["after_json"]),
                         attributed: (row["attributed"]?.int64 ?? 0) != 0, ts: Date(timeIntervalSince1970: ts))
    }

    /// Maps a reverts row.
    private static func revert(_ row: [String: SQLiteValue]) -> RevertRow? {
        guard let id = row["id"]?.int64, let eventId = row["event_id"]?.int64, let created = row["created_at"]?.double,
              let result = row["result"]?.string.flatMap(RevertOutcome.init(rawValue:)) else { return nil }
        return RevertRow(id: id, eventId: eventId, createdAt: Date(timeIntervalSince1970: created),
                         scope: parse(row["scope_json"]) ?? .null, result: result, note: row["note"]?.string ?? "")
    }

    /// Parses a JSON text column.
    private static func parse(_ value: SQLiteValue?) -> JSONValue? {
        guard let text = value?.string, let data = text.data(using: .utf8) else { return nil }
        return try? JSONValue.parse(data)
    }

    /// Parses a manifest entry column.
    private static func entry(_ value: SQLiteValue?) -> ManifestEntry? {
        guard let text = value?.string else { return nil }
        return try? JSONDecoder().decode(ManifestEntry.self, from: Data(text.utf8))
    }
}
