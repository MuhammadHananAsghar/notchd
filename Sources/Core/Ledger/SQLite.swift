// SQLite.swift
// A thin, dependency-free wrapper over the system sqlite3 library: open a
// database, run statements with bound parameters, read rows back as typed
// values. Everything the ledger needs and nothing it does not.

import Foundation
import SQLite3

/// A value bound to or read from a statement.
enum SQLiteValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    /// The value as an integer, converting a real when necessary.
    var int64: Int64? {
        switch self {
        case .integer(let value): return value
        case .real(let value): return Int64(value)
        default: return nil
        }
    }

    /// The value as a double, converting an integer when necessary.
    var double: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .real(let value): return value
        default: return nil
        }
    }

    /// The value as text.
    var string: String? {
        guard case .text(let value) = self else { return nil }
        return value
    }
}

/// A failure reported by sqlite3.
struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { "sqlite error \(code): \(message)" }
}

/// One open database connection. Not thread-safe; the ledger serialises access.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    /// Binds a transient string so sqlite copies it.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens or creates the database at a path.
    /// - Parameter path: The file path, or `:memory:` for an in-memory database.
    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open"
            sqlite3_close(handle)
            throw SQLiteError(code: code, message: message)
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Runs one or more statements that return no rows.
    /// - Parameter sql: The SQL text.
    func exec(_ sql: String) throws {
        var errorText: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &errorText)
        guard code == SQLITE_OK else {
            let message = errorText.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(errorText)
            throw SQLiteError(code: code, message: message)
        }
    }

    /// Runs a statement with bound parameters and returns the last inserted
    /// row id.
    /// - Parameters:
    ///   - sql: The SQL text with `?` placeholders.
    ///   - params: Values for the placeholders, in order.
    /// - Returns: The rowid of the most recent insert on this connection.
    @discardableResult
    func run(_ sql: String, _ params: [SQLiteValue] = []) throws -> Int64 {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw currentError(code) }
        return sqlite3_last_insert_rowid(handle)
    }

    /// Runs a query and returns every row as a dictionary keyed by column name.
    /// - Parameters:
    ///   - sql: The SQL text with `?` placeholders.
    ///   - params: Values for the placeholders, in order.
    /// - Returns: The rows, in the order sqlite produced them.
    func query(_ sql: String, _ params: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        let columnCount = sqlite3_column_count(statement)
        let names = (0..<columnCount).map { String(cString: sqlite3_column_name(statement, $0)) }
        var rows: [[String: SQLiteValue]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw currentError(code) }
            rows.append(readRow(statement, names: names))
        }
        return rows
    }

    /// Compiles a statement and binds its parameters.
    private func prepare(_ sql: String, _ params: [SQLiteValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw currentError(code) }
        for (offset, param) in params.enumerated() {
            let index = Int32(offset + 1)
            switch param {
            case .null: sqlite3_bind_null(statement, index)
            case .integer(let value): sqlite3_bind_int64(statement, index, value)
            case .real(let value): sqlite3_bind_double(statement, index, value)
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, Self.transient)
            }
        }
        return statement
    }

    /// Reads the current row of a stepped statement.
    private func readRow(_ statement: OpaquePointer, names: [String]) -> [String: SQLiteValue] {
        var row: [String: SQLiteValue] = [:]
        for (index, name) in names.enumerated() {
            let column = Int32(index)
            switch sqlite3_column_type(statement, column) {
            case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, column))
            case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, column))
            case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(statement, column)))
            default: row[name] = .null
            }
        }
        return row
    }

    /// The connection's most recent error, wrapped.
    private func currentError(_ code: Int32) -> SQLiteError {
        SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }
}
