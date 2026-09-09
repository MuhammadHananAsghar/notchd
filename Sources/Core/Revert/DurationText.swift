// DurationText.swift
// Parses the short durations the command line takes, such as `10m`, `2h`,
// `90s`, or `1d`, and formats intervals for people.

import Foundation

/// Human duration text.
enum DurationText {
    /// Parses text like `10m` into seconds.
    /// - Parameter text: Digits followed by one of `s`, `m`, `h`, `d`.
    /// - Returns: The interval, or nil when the text is not a duration.
    static func parse(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = trimmed.last, let amount = Double(trimmed.dropLast()), amount >= 0 else { return nil }
        switch unit {
        case "s": return amount
        case "m": return amount * 60
        case "h": return amount * 3600
        case "d": return amount * 86_400
        default: return nil
        }
    }

    /// Formats an interval as the largest whole unit that fits.
    /// - Parameter interval: Seconds.
    /// - Returns: Text like `10 min` or `2 h`.
    static func format(_ interval: TimeInterval) -> String {
        if interval < 60 { return "\(Int(interval)) s" }
        if interval < 3600 { return "\(Int(interval / 60)) min" }
        if interval < 86_400 { return "\(Int(interval / 3600)) h" }
        return "\(Int(interval / 86_400)) d"
    }
}
