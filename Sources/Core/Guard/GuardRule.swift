// GuardRule.swift
// One rule of guard mode: a pattern over the paths a tool call declares or
// over the command it runs, and what to do when it matches. Patterns are
// globs: `*` within a path segment, `**` across segments, `?` one character.
// Path patterns match whole absolute paths; command patterns match anywhere
// in the command line. These are the user's rules, applied by the user's own
// choice; Notchd promises no protection beyond them.

import Foundation

/// What a matching rule asks the vendor to do.
enum GuardAction: String, Codable, CaseIterable, Identifiable {
    /// Refuse the call.
    case deny
    /// Let the vendor put the call to the user.
    case ask

    var id: String { rawValue }

    /// The picker label.
    var title: String {
        switch self {
        case .deny: return "Deny"
        case .ask: return "Ask"
        }
    }
}

/// What a rule looks at.
enum GuardSubject: String, Codable, CaseIterable, Identifiable {
    /// The absolute paths a call declares.
    case path
    /// The command line of a shell call.
    case command

    var id: String { rawValue }

    /// The picker label.
    var title: String {
        switch self {
        case .path: return "Path"
        case .command: return "Command"
        }
    }
}

/// One rule.
struct GuardRule: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var subject: GuardSubject
    var pattern: String
    var action: GuardAction
    /// A note shown to the agent and the user when the rule fires.
    var note: String = ""

    /// Coding keys, so the id round-trips.
    enum CodingKeys: String, CodingKey {
        case id, subject, pattern, action, note
    }

    /// The regular expression the pattern compiles to, anchored for paths.
    var regex: NSRegularExpression? {
        let expanded = subject == .path ? GuardGlob.expandingHome(pattern) : pattern
        return GuardGlob.regex(expanded, anchored: subject == .path)
    }

    /// Whether this rule fires for a call.
    /// - Parameters:
    ///   - paths: The call's declared absolute paths.
    ///   - command: The call's command line, if any.
    /// - Returns: True when it matches.
    func matches(paths: [String], command: String?) -> Bool {
        guard let regex else { return false }
        switch subject {
        case .path:
            return paths.contains { GuardGlob.matches(regex, $0) }
        case .command:
            guard let command else { return false }
            return GuardGlob.matches(regex, command)
        }
    }

    /// The sentence a refusal carries.
    var reason: String {
        let what = subject == .path ? "path" : "command"
        let base = "Notchd guard rule: \(what) matches \"\(pattern)\""
        return note.isEmpty ? base : base + ". " + note
    }

    /// Rules offered when guard mode is first turned on.
    static let suggested: [GuardRule] = [
        GuardRule(subject: .path, pattern: "~/.ssh/**", action: .deny, note: "SSH keys stay untouched."),
        GuardRule(subject: .path, pattern: "~/.aws/**", action: .deny, note: "Cloud credentials stay untouched."),
        GuardRule(subject: .path, pattern: "~/.gnupg/**", action: .deny, note: "GPG keys stay untouched."),
        GuardRule(subject: .command, pattern: "rm -rf /*", action: .deny, note: "Never from the root."),
        GuardRule(subject: .command, pattern: "rm -rf *", action: .ask),
        GuardRule(subject: .command, pattern: "git reset --hard*", action: .ask),
        GuardRule(subject: .command, pattern: "git push*--force*", action: .ask),
        GuardRule(subject: .command, pattern: "sudo *", action: .ask),
    ]
}

/// Glob to regular expression.
enum GuardGlob {
    /// A leading `~` as the home directory.
    /// - Parameter pattern: A path pattern.
    /// - Returns: The pattern with the home expanded.
    static func expandingHome(_ pattern: String) -> String {
        guard pattern.hasPrefix("~/") || pattern == "~" else { return pattern }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + pattern.dropFirst(1)
    }

    /// Compiles a glob. `**` matches across path separators, `*` within one
    /// segment, `?` one character; a trailing `/**` also matches the directory
    /// itself.
    /// - Parameters:
    ///   - glob: The pattern.
    ///   - anchored: Whether the whole string must match.
    /// - Returns: The expression, or nil for a pattern that cannot compile.
    static func regex(_ glob: String, anchored: Bool) -> NSRegularExpression? {
        var expression = ""
        var characters = Array(glob)
        if anchored, characters.suffix(3) == ["/", "*", "*"] {
            characters.removeLast(3)
            expression = translate(characters) + "(/.*)?"
        } else {
            expression = translate(characters)
        }
        let pattern = anchored ? "^" + expression + "$" : expression
        return try? NSRegularExpression(pattern: pattern, options: [])
    }

    /// Whether an expression matches a string.
    /// - Parameters:
    ///   - regex: The expression.
    ///   - string: The candidate.
    /// - Returns: True on a match.
    static func matches(_ regex: NSRegularExpression, _ string: String) -> Bool {
        regex.firstMatch(in: string, options: [], range: NSRange(string.startIndex..., in: string)) != nil
    }

    /// Translates glob characters to regex syntax.
    private static func translate(_ characters: [Character]) -> String {
        var result = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "*" {
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    result += ".*"
                    index += 2
                    continue
                }
                result += "[^/]*"
            } else if character == "?" {
                result += "."
            } else {
                result += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        return result
    }
}
