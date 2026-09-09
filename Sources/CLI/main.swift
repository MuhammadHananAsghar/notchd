// main.swift
// The `notchd` command line: list sessions and changes, and plan or apply a
// revert. It reads the same ledger and object store as the app, so it works
// while the app is running or after it has quit. Usage:
//
//     notchd sessions
//     notchd changes --last 10m [--session ID] [--unattributed]
//     notchd revert  --last 10m [--session ID] [--unattributed] [--dry-run] [--yes]
//
// Exit status: 0 on success or a complete revert, 2 for a partial revert, 1
// for a usage or storage error.

import Foundation

/// Parsed command-line options.
struct Options {
    var command = "help"
    var last: TimeInterval = 10 * 60
    var sessionIds: [Int64]?
    var includeUnattributed = false
    var dryRun = false
    var yes = false

    /// Parses arguments after the program name.
    /// - Parameter arguments: The arguments.
    /// - Returns: The options.
    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var rest = arguments[...]
        if let first = rest.first, !first.hasPrefix("--") {
            options.command = first
            rest = rest.dropFirst()
        }
        while let flag = rest.first {
            rest = rest.dropFirst()
            switch flag {
            case "--last":
                guard let text = rest.first, let seconds = DurationText.parse(text) else { throw CLIError.usage("--last needs a duration such as 10m") }
                options.last = seconds
                rest = rest.dropFirst()
            case "--session":
                guard let text = rest.first, let id = Int64(text) else { throw CLIError.usage("--session needs a ledger id") }
                options.sessionIds = (options.sessionIds ?? []) + [id]
                rest = rest.dropFirst()
            case "--unattributed": options.includeUnattributed = true
            case "--dry-run": options.dryRun = true
            case "--yes", "-y": options.yes = true
            case "--help", "-h": options.command = "help"
            default: throw CLIError.usage("unknown option \(flag)")
            }
        }
        return options
    }
}

/// A usage or storage failure.
enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    var description: String {
        switch self {
        case .usage(let text): return text
        }
    }
}

/// Opens the ledger and store where the app keeps them.
/// - Returns: The engine and ledger.
func openStorage() throws -> (Ledger, RevertEngine) {
    try NotchdPaths.ensureDirectories()
    let ledger = try Ledger(path: NotchdPaths.ledgerURL.path)
    let store = try ObjectStore(root: NotchdPaths.supportDirectory.appendingPathComponent("store"))
    return (ledger, RevertEngine(ledger: ledger, store: store, snapshotter: Snapshotter(store: store)))
}

/// Prints usage.
func printHelp() {
    print("""
    notchd sessions
    notchd changes --last 10m [--session ID] [--unattributed]
    notchd revert  --last 10m [--session ID] [--unattributed] [--dry-run] [--yes]
    """)
}

/// A short local time.
/// - Parameter date: The instant.
/// - Returns: `HH:mm:ss`.
func clock(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
}

/// Lists sessions, most recent first.
func listSessions(_ ledger: Ledger) throws {
    let sessions = try ledger.sessions()
    if sessions.isEmpty {
        print("no sessions recorded")
        return
    }
    for session in sessions {
        let state = session.isActive() ? "active" : (session.endedAt == nil ? "silent" : "ended")
        print("\(session.id)\t\(session.vendor)\t\(state)\t\(clock(session.lastEventAt))\t\(session.cwd)")
    }
}

/// Lists changes in the window.
func listChanges(_ ledger: Ledger, options: Options) throws {
    let since = Date().addingTimeInterval(-options.last)
    let changes = try ledger.changes(since: since, sessionIds: options.sessionIds, includeUnattributed: options.includeUnattributed)
    if changes.isEmpty {
        print("no changes in the last \(DurationText.format(options.last))")
        return
    }
    for change in changes {
        let who = change.attributed ? "session \(change.sessionId ?? 0)" : "unattributed"
        print("\(clock(change.ts))\t\(change.kind.rawValue)\t\(who)\t\(change.path)")
    }
}

/// Describes a plan.
func describe(_ plan: RevertPlan) {
    for target in plan.targets {
        switch target.action {
        case .restore(let entry): print("restore\t\(target.path)\t(\(entry.size) bytes)")
        case .delete: print("delete\t\(target.path)")
        case .impossible(let reason): print("cannot\t\(target.path)\t\(reason)")
        }
    }
    if !plan.commands.isEmpty {
        print("\nShell commands in this range. Their files are restored above; anything else they did is not undone:")
        for command in plan.commands { print("  \(command)") }
    }
}

/// Plans and, unless told not to, applies a revert.
func revert(_ ledger: Ledger, engine: RevertEngine, options: Options) throws -> Int32 {
    let now = Date()
    let scope = RevertScope(since: now.addingTimeInterval(-options.last), until: now, sessionIds: options.sessionIds,
                            includeUnattributed: options.includeUnattributed)
    let plan = try engine.plan(scope)
    if plan.isEmpty {
        print("nothing to revert in the last \(DurationText.format(options.last))")
        return 0
    }
    describe(plan)
    if options.dryRun { return 0 }
    if !options.yes {
        print("\nRestore \(plan.targets.count) paths? [y/N] ", terminator: "")
        guard let answer = readLine(), answer.lowercased().hasPrefix("y") else {
            print("not reverted")
            return 0
        }
    }
    let result = try engine.apply(plan)
    print("\nrestored \(result.restored.count) of \(plan.targets.count) paths")
    for failure in result.failed { print("  could not restore \(failure.path): \(failure.reason)") }
    print(result.outcome == .complete ? "complete: every path verified bit for bit" : "partial: see above")
    return result.outcome == .complete ? 0 : 2
}

/// Runs the command line.
/// - Returns: The exit status.
func run() -> Int32 {
    do {
        let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
        switch options.command {
        case "sessions":
            let (ledger, _) = try openStorage()
            try listSessions(ledger)
            return 0
        case "changes":
            let (ledger, _) = try openStorage()
            try listChanges(ledger, options: options)
            return 0
        case "revert":
            let (ledger, engine) = try openStorage()
            return try revert(ledger, engine: engine, options: options)
        default:
            printHelp()
            return options.command == "help" ? 0 : 1
        }
    } catch {
        FileHandle.standardError.write(Data("notchd: \(error)\n".utf8))
        return 1
    }
}

exit(run())
