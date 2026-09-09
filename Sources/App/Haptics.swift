// Haptics.swift
// One small tap on the trackpad when an agent finishes, so a turn that ends
// while the eyes are elsewhere is still felt. macOS plays haptics only on a
// Force Touch trackpad and only through this API, so on a mouse-only Mac
// the call is a quiet no-op. Nothing here makes a sound.

import AppKit

/// Trackpad feedback for finished turns.
@MainActor
enum Haptics {
    /// Plays one level-change tap, the lightest pattern macOS offers, at
    /// the next moment the trackpad is free.
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
    }
}
