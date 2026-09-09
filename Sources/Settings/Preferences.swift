// Preferences.swift
// The settings that survive a relaunch: which edge the notch is on and how
// much of itself it shows at rest. Backed by UserDefaults and published so the
// app delegate can apply a change the moment it is made.

import Combine
import Foundation

/// Persistent settings.
@MainActor
final class Preferences: ObservableObject {
    private static let edgeKey = "notchEdge"
    private static let visibilityKey = "notchVisibility"
    private static let codexKey = "codexTranscripts"
    private static let notifyKey = "notifyOnDone"
    private static let celebrateKey = "celebrateInNotch"

    /// Whether a finished turn posts a macOS notification.
    @Published var notifyOnDone: Bool {
        didSet { defaults.set(notifyOnDone, forKey: Self.notifyKey) }
    }

    /// Whether a finished turn peeks out of the closed notch.
    @Published var celebrateInNotch: Bool {
        didSet { defaults.set(celebrateInNotch, forKey: Self.celebrateKey) }
    }

    /// Whether a turn that only replied, with no tool calls and no file
    /// changes, also notifies and peeks.
    @Published var noticeChatReplies: Bool {
        didSet { defaults.set(noticeChatReplies, forKey: Self.chatKey) }
    }

    private static let chatKey = "noticeChatReplies"

    /// Whether a finished turn taps the trackpad once.
    @Published var hapticOnDone: Bool {
        didSet { defaults.set(hapticOnDone, forKey: Self.hapticKey) }
    }

    private static let hapticKey = "hapticOnDone"

    @Published var notchEdge: NotchEdge {
        didSet { defaults.set(notchEdge.rawValue, forKey: Self.edgeKey) }
    }

    @Published var notchVisibility: NotchVisibility {
        didSet { defaults.set(notchVisibility.rawValue, forKey: Self.visibilityKey) }
    }

    /// Whether Codex's transcripts are followed. Off means Notchd never reads
    /// them.
    @Published var codexTranscripts: Bool {
        didSet { defaults.set(codexTranscripts, forKey: Self.codexKey) }
    }

    private let defaults: UserDefaults

    /// Loads settings, falling back to a right-edge notch that opens on hover
    /// and Codex transcripts followed.
    /// - Parameter defaults: The store, injectable for tests.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notchEdge = defaults.string(forKey: Self.edgeKey).flatMap(NotchEdge.init(rawValue:)) ?? .right
        notchVisibility = defaults.string(forKey: Self.visibilityKey).flatMap(NotchVisibility.init(rawValue:)) ?? .onHover
        codexTranscripts = defaults.object(forKey: Self.codexKey) as? Bool ?? true
        notifyOnDone = defaults.object(forKey: Self.notifyKey) as? Bool ?? true
        celebrateInNotch = defaults.object(forKey: Self.celebrateKey) as? Bool ?? true
        noticeChatReplies = defaults.object(forKey: Self.chatKey) as? Bool ?? true
        hapticOnDone = defaults.object(forKey: Self.hapticKey) as? Bool ?? true
    }
}
