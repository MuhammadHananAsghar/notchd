// SetupView.swift
// The settings window: the notch first, then one card per agent. Each
// integration shows exactly what Notchd will write, with Install and Remove.
// Codex has no hooks or plugins, so its card is a switch for following the
// transcripts it writes, at derived fidelity. Nothing is written silently.

import AppKit
import SwiftUI

/// Where the hook binary lives inside this app bundle.
enum HookBinary {
    /// The absolute path to `notchd-hook`, or nil in a build that lacks it.
    static var path: String? {
        Bundle.main.url(forAuxiliaryExecutable: "notchd-hook")?.path
    }
}

/// The state of one integration.
enum SetupState: Equatable {
    case vendorMissing
    case hookMissing
    case installed
    case unreadable(String)
}

/// Reads and changes one integration.
@MainActor
final class SetupModel: ObservableObject {
    @Published private(set) var state: SetupState = .hookMissing
    @Published private(set) var lastError: String?

    let integration: AgentIntegration
    let binaryPath: String?

    /// Creates a model over an integration.
    /// - Parameters:
    ///   - integration: The agent's integration.
    ///   - binaryPath: The hook binary, defaulting to the one in this bundle.
    init(integration: AgentIntegration, binaryPath: String? = HookBinary.path) {
        self.integration = integration
        self.binaryPath = binaryPath
        refresh()
    }

    /// The agent's name.
    var displayName: String { integration.displayName }

    /// The exact text Install will write.
    var snippet: String {
        integration.snippet(binaryPath: binaryPath ?? "/Applications/Notchd.app/Contents/MacOS/notchd-hook")
    }

    /// Re-reads the target and classifies it.
    func refresh() {
        guard integration.vendorPresent else {
            state = .vendorMissing
            return
        }
        do {
            state = try integration.isInstalled() ? .installed : .hookMissing
        } catch {
            state = .unreadable(String(describing: error))
        }
    }

    /// Writes the integration.
    func install() {
        guard let binaryPath else {
            lastError = "This build has no notchd-hook binary inside it."
            return
        }
        perform { try integration.install(binaryPath: binaryPath) }
    }

    /// Removes the integration.
    func uninstall() {
        perform { try integration.uninstall() }
    }

    /// Runs a change and refreshes, keeping any error for the view.
    private func perform(_ change: () throws -> Void) {
        do {
            try change()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        refresh()
    }

    /// The standard set: Claude Code, Gemini CLI, OpenCode, Cursor.
    /// - Parameter binaryPath: The hook binary.
    /// - Returns: One model per integration.
    static func standard(binaryPath: String? = HookBinary.path) -> [SetupModel] {
        [
            SetupModel(integration: HookSettingsFile(url: HookVendor.claude.defaultURL(), vendor: .claude), binaryPath: binaryPath),
            SetupModel(integration: HookSettingsFile(url: HookVendor.gemini.defaultURL(), vendor: .gemini), binaryPath: binaryPath),
            SetupModel(integration: OpenCodePlugin(url: OpenCodePlugin.defaultURL()), binaryPath: binaryPath),
            SetupModel(integration: CursorHooksFile(url: CursorHooksFile.defaultURL()), binaryPath: binaryPath),
        ]
    }
}

/// The settings window.
struct SetupView: View {
    let models: [SetupModel]
    @ObservedObject var preferences: Preferences
    @ObservedObject var guardModel: GuardModel
    /// Whether Codex's sessions directory exists.
    var codexPresent: Bool = FileManager.default.fileExists(atPath: CodexRolloutTailer.defaultRoot.path)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                notchCard
                doneCard
                GuardCard(model: guardModel)
                intro
                ForEach(Array(models.enumerated()), id: \.offset) { _, model in
                    IntegrationCard(model: model)
                }
                codexCard
                locations
            }
            .padding(24)
        }
        .background(Palette.surface)
        .onAppear { models.forEach { $0.refresh() } }
    }

    /// Where the notch sits and how much of itself it shows at rest.
    private var notchCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notch").font(Typography.heading)
            Text("Notchd lives on a screen edge. At rest it is a slim handle; reach for it and it opens with every agent that is running, what each changed, and the way into the timeline.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
            Picker("Placement", selection: $preferences.notchEdge) {
                ForEach(NotchEdge.allCases) { edge in Text(edge.title).tag(edge) }
            }
            .pickerStyle(.segmented)
            Text(preferences.notchEdge.explanation).font(Typography.caption).foregroundStyle(Palette.textSecondary)
            Picker("Visibility", selection: $preferences.notchVisibility) {
                ForEach(NotchVisibility.allCases) { visibility in Text(visibility.title).tag(visibility) }
            }
            .pickerStyle(.segmented)
            Text(preferences.notchVisibility.explanation).font(Typography.caption).foregroundStyle(Palette.textSecondary)
        }
        .padding(16)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.separator))
    }

    /// What happens when an agent finishes a turn.
    private var doneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("When an agent finishes").font(Typography.heading)
            Text("When an agent finishes a turn it can post a notification, with no sound, peek out of the closed notch for a moment with its mark and what it did, and tap the trackpad once. Clicking the notification opens the session.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
            Toggle("Post a notification", isOn: $preferences.notifyOnDone)
            Toggle("Peek out of the notch", isOn: $preferences.celebrateInNotch)
            Toggle("Tap the trackpad", isOn: $preferences.hapticOnDone)
            Toggle("Also for plain replies with no tool calls or file changes", isOn: $preferences.noticeChatReplies)
        }
        .padding(16)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.separator))
    }

    /// What the agent cards are for.
    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agents").font(Typography.heading)
            Text("Notchd records what an agent does through the hooks or plugins that agent already supports. Each card shows the exact text that will be written. Nothing is written until you click Install, and Remove puts the file back as it was.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    /// Codex: no hooks, so a switch for reading its transcripts.
    private var codexCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Codex").font(Typography.heading)
                Spacer()
                Text(codexPresent ? (preferences.codexTranscripts ? "Following transcripts" : "Off") : "Codex not found")
                    .font(Typography.caption)
                    .foregroundStyle(codexPresent && preferences.codexTranscripts ? Palette.create : Palette.textSecondary)
            }
            Text("Codex has no tool hooks, so Notchd reads the transcripts it writes under ~/.codex/sessions instead. Every tool call still appears, with the files a patch names and the directory a command ran in, at reduced fidelity: Notchd learns of a call after it has started, so the changes are matched to it afterwards and the timeline draws these ticks dashed. Nothing is installed into Codex.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
            Toggle("Follow Codex transcripts", isOn: $preferences.codexTranscripts)
                .disabled(!codexPresent)
        }
        .padding(16)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.separator))
    }

    /// Where Notchd keeps its own files.
    private var locations: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notchd's files").font(Typography.heading)
            Text("Ledger: \(NotchdPaths.ledgerURL.path)").font(Typography.caption).foregroundStyle(Palette.textSecondary)
            Text("Socket: \(NotchdPaths.socketPath)").font(Typography.caption).foregroundStyle(Palette.textSecondary)
            if let path = models.first?.binaryPath {
                Text("Hook: \(path)").font(Typography.caption).foregroundStyle(Palette.textSecondary)
            }
        }
    }
}

/// One integration's card.
struct IntegrationCard: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.displayName).font(Typography.heading)
                Spacer()
                statusBadge
            }
            Text(statusExplanation).font(Typography.body).foregroundStyle(Palette.textSecondary)
            Text("Written to \(model.integration.targetPath)").font(Typography.caption).foregroundStyle(Palette.textSecondary)
            ScrollView([.horizontal, .vertical]) {
                Text(model.snippet)
                    .font(Typography.code)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(maxHeight: 220)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                if let error = model.lastError {
                    Text(error).font(Typography.caption).foregroundStyle(Palette.attention).lineLimit(2)
                }
                Spacer()
                if model.state == .installed {
                    Button("Remove", role: .destructive) { model.uninstall() }
                } else {
                    Button("Install") { model.install() }
                        .disabled(model.state == .vendorMissing || model.binaryPath == nil)
                }
            }
        }
        .padding(16)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.separator))
    }

    /// The coloured status word.
    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            switch model.state {
            case .installed: return ("Installed", Palette.create)
            case .hookMissing: return ("Not installed", Palette.textSecondary)
            case .vendorMissing: return ("\(model.displayName) not found", Palette.textSecondary)
            case .unreadable: return ("File unreadable", Palette.attention)
            }
        }()
        return Text(text).font(Typography.caption).foregroundStyle(color)
    }

    /// The integration's own explanation, or the state's when it matters more.
    private var statusExplanation: String {
        switch model.state {
        case .vendorMissing:
            return "No \(model.displayName) configuration was found for this user, so there is nothing to install into."
        case .unreadable(let why):
            return "The file could not be parsed, so Notchd will not touch it. \(why)"
        case .installed, .hookMissing:
            return model.integration.explanation
        }
    }
}
