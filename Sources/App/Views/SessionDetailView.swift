// SessionDetailView.swift
// The session page: one session as a vertical log of prompts, tool calls, and
// the files each call changed, in order. This is the debugging view for agent
// developers. Also the sidebar row for a session, the list for the
// unattributed lane, and the words and marks shared by every view.

import SwiftUI

/// A session in the sidebar.
struct SessionRowView: View {
    let session: SessionRow

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(session.isActive() ? Palette.create : Palette.separator)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.projectName.isEmpty ? session.cwd : session.projectName)
                    .font(Typography.body)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(VendorNames.display(session.vendor))
                    Text("·")
                    Text(session.lastEventAt, style: .relative)
                }
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The session page.
struct SessionDetailView: View {
    let session: SessionRow
    let events: [EventRow]
    let changesByEvent: [Int64: [ChangeRow]]

    /// Every change in the session.
    private var changeCount: Int { changesByEvent.values.reduce(0) { $0 + $1.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if events.isEmpty {
                Text("No events in this session yet")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(events) { event in
                    EventRowView(event: event, changes: changesByEvent[event.id] ?? [])
                        .listRowSeparator(.visible)
                }
                .listStyle(.plain)
            }
        }
        .background(Palette.panel)
    }

    /// Project, vendor, working directory, and fidelity.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(session.projectName.isEmpty ? "Session" : session.projectName).font(Typography.title)
                Text(VendorNames.display(session.vendor))
                    .font(Typography.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Palette.separator.opacity(0.6), in: Capsule())
                Spacer()
                Text(session.isActive() ? "Active" : (session.endedAt == nil ? "Silent" : "Ended"))
                    .font(Typography.caption)
                    .foregroundStyle(session.isActive() ? Palette.create : Palette.textSecondary)
            }
            Text(session.cwd).font(Typography.mono).foregroundStyle(Palette.textSecondary).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 12) {
                Label(session.fidelity.label, systemImage: session.fidelity == .official ? "checkmark.seal" : "questionmark.circle")
                Text("Started \(session.startedAt.formatted(date: .abbreviated, time: .shortened))")
                Text("\(events.count) events")
                Text("\(changeCount) file changes")
            }
            .font(Typography.caption)
            .foregroundStyle(Palette.textSecondary)
        }
        .padding(16)
    }
}

/// One event in the session log, with the files it changed.
struct EventRowView: View {
    let event: EventRow
    let changes: [ChangeRow]

    /// How many changed paths are listed before folding the rest.
    private static let visibleChanges = 6

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(event.ts.formatted(date: .omitted, time: .standard))
                .font(Typography.mono)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 84, alignment: .leading)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Palette.color(for: event.kind))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(EventCopy.title(for: event)).font(Typography.body)
                    if event.fidelity != .official {
                        Text(event.fidelity.label).font(Typography.caption).foregroundStyle(Palette.attention)
                    }
                }
                if let detail = EventCopy.detail(for: event) {
                    Text(detail).font(Typography.mono).foregroundStyle(Palette.textSecondary).lineLimit(2).truncationMode(.middle)
                }
                if let error = event.error {
                    Text(error).font(Typography.caption).foregroundStyle(Palette.attention).lineLimit(2)
                }
                ForEach(changes.prefix(Self.visibleChanges)) { change in
                    ChangeLine(change: change)
                }
                if changes.count > Self.visibleChanges {
                    Text("and \(changes.count - Self.visibleChanges) more")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// One changed path: a coloured mark for the kind and the path.
struct ChangeLine: View {
    let change: ChangeRow

    var body: some View {
        HStack(spacing: 6) {
            Text(ChangeCopy.mark(for: change.kind))
                .font(Typography.mono)
                .foregroundStyle(Palette.color(for: change.kind))
                .frame(width: 10)
            Text(change.path)
                .font(Typography.mono)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// The page for changes no agent claimed.
struct UnattributedView: View {
    let changes: [ChangeRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Not from any known agent").font(Typography.title)
                Text("Files in a watched project that changed while no agent tool call was open. Your own edits land here. Reverts leave this lane alone unless you include it.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(16)
            Divider()
            List(changes) { change in
                HStack(alignment: .top, spacing: 10) {
                    Text(change.ts.formatted(date: .omitted, time: .standard))
                        .font(Typography.mono)
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 84, alignment: .leading)
                    ChangeLine(change: change)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.plain)
        }
        .background(Palette.panel)
    }
}

/// Human names for vendor slugs.
enum VendorNames {
    /// The display name for a slug, or the slug itself for third parties.
    /// - Parameter slug: The vendor slug.
    /// - Returns: A name for labels.
    static func display(_ slug: String) -> String {
        switch slug {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "gemini": return "Gemini CLI"
        case "opencode": return "OpenCode"
        case "cursor": return "Cursor"
        case "notchd", "rewind": return "Notchd"
        default: return slug
        }
    }
}

/// Words for an event row.
enum EventCopy {
    /// The headline for an event.
    /// - Parameter event: The event.
    /// - Returns: A short phrase.
    static func title(for event: EventRow) -> String {
        let tool = event.tool ?? "Tool"
        switch event.kind {
        case .sessionStart: return "Session started"
        case .sessionEnd: return "Session ended"
        case .toolBefore:
            switch event.meta?["guard"]?["decision"]?.stringValue {
            case "deny": return "\(tool) blocked by guard"
            case "ask": return "\(tool) put to you by guard"
            default: return "\(tool) starting"
            }
        case .toolAfter: return "\(event.tool ?? "Tool") finished"
        case .toolFailed: return "\(event.tool ?? "Tool") failed"
        case .note: return event.meta?["event"]?.stringValue ?? "Note"
        }
    }

    /// The most useful single line under the headline: the command for a
    /// shell tool, the path for a file tool, the prompt for a prompt note.
    /// - Parameter event: The event.
    /// - Returns: The detail, or nil when there is nothing worth showing.
    static func detail(for event: EventRow) -> String? {
        if let command = event.args?["command"]?.stringValue { return command }
        if let path = event.paths.first { return path }
        if let prompt = event.meta?["prompt"]?.stringValue { return prompt }
        if let source = event.meta?["source"]?.stringValue { return source }
        if let reason = event.meta?["reason"]?.stringValue { return reason }
        return nil
    }
}

/// Words and marks for a change.
enum ChangeCopy {
    /// A one-character mark for a change kind.
    /// - Parameter kind: The kind.
    /// - Returns: `+`, `~`, or `-`.
    static func mark(for kind: ChangeKind) -> String {
        switch kind {
        case .create: return "+"
        case .modify: return "~"
        case .delete: return "-"
        }
    }

    /// The past-tense word for a change kind.
    /// - Parameter kind: The kind.
    /// - Returns: `Created`, `Modified`, or `Deleted`.
    static func word(for kind: ChangeKind) -> String {
        switch kind {
        case .create: return "Created"
        case .modify: return "Modified"
        case .delete: return "Deleted"
        }
    }
}

extension Palette {
    /// The colour for a change kind.
    /// - Parameter kind: The kind.
    /// - Returns: The matching semantic colour.
    static func color(for kind: ChangeKind) -> Color {
        switch kind {
        case .create: return create
        case .modify: return modify
        case .delete: return delete
        }
    }
}
