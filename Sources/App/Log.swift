// Log.swift
// Loggers for the app process. A menu bar app has no console, so anything
// worth diagnosing goes to the unified log:
//
//     log stream --predicate 'subsystem == "com.muhammad.notchd"' --level debug

import os

/// The app's loggers, one per concern.
enum Log {
    static let app = Logger(subsystem: "com.muhammad.notchd", category: "app")
    static let server = Logger(subsystem: "com.muhammad.notchd", category: "server")
    static let updates = Logger(subsystem: "com.muhammad.notchd", category: "updates")
}
