// NotchdPaths.swift
// Where Notchd keeps its own files: the ledger, the object store, and the
// socket the hook binary connects to. Everything lives under one directory in
// Application Support so it can be found, inspected, and deleted as a unit.
// `NOTCHD_HOME` overrides the directory for tests and for running a
// development build beside an installed one; the hook and the CLI honour the
// same variable. A directory left by the app's earlier name is moved into
// place on first use so nothing recorded is lost.

import Foundation

/// Notchd's own file locations.
enum NotchdPaths {
    /// The environment variable that relocates everything.
    static let homeVariable = "NOTCHD_HOME"

    /// The directory name an earlier build used under Application Support.
    static let legacyDirectoryName = "Rewind"

    /// The user's Application Support directory.
    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }

    /// The directory holding the ledger, the store, and the socket.
    static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment[homeVariable], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return applicationSupport.appendingPathComponent("Notchd", isDirectory: true)
    }

    /// The SQLite ledger.
    static var ledgerURL: URL { supportDirectory.appendingPathComponent("ledger.sqlite") }

    /// The unix socket the hook binary writes to.
    static var socketPath: String { supportDirectory.appendingPathComponent("notchd.sock").path }

    /// The guard rules.
    static var guardURL: URL { supportDirectory.appendingPathComponent("guard.json") }

    /// Creates the support directory, readable by this user only, moving an
    /// earlier build's directory into place first if there is one and no
    /// override is set.
    static func ensureDirectories() throws {
        let manager = FileManager.default
        let legacy = applicationSupport.appendingPathComponent(legacyDirectoryName, isDirectory: true)
        let overridden = ProcessInfo.processInfo.environment[homeVariable].map { !$0.isEmpty } ?? false
        if !overridden, !manager.fileExists(atPath: supportDirectory.path), manager.fileExists(atPath: legacy.path) {
            try manager.moveItem(at: legacy, to: supportDirectory)
        }
        try manager.createDirectory(at: supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
