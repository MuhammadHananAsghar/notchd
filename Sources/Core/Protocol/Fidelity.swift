// Fidelity.swift
// How much a recorded fact can be trusted. Carried on every session and event
// so the timeline can draw hook-recorded changes solid, transcript-derived ones
// hatched, and unattributed filesystem changes grey. Notchd never displays a
// fidelity higher than the source supports.

import Foundation

/// The provenance of a recorded fact.
enum Fidelity: String, Codable, Equatable, CaseIterable {
    /// Reported by the agent itself through a hook it invoked.
    case official
    /// Reconstructed from a transcript or log the agent wrote for its own use.
    case derived
    /// Observed on the filesystem with no agent claiming it.
    case unknown

    /// A short label for the timeline legend.
    var label: String {
        switch self {
        case .official: return "Recorded by hook"
        case .derived: return "Derived from transcript"
        case .unknown: return "Not from any known agent"
        }
    }
}
