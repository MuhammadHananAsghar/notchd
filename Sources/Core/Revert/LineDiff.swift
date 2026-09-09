// LineDiff.swift
// A line-level diff between two versions of a file for the inspector. A plain
// longest-common-subsequence over lines, capped so a pair of huge files says
// so instead of stalling the window, with long unchanged runs folded into a
// count. Binary content is reported as such rather than rendered.

import Foundation

/// One line of a rendered diff.
struct DiffLine: Equatable {
    enum Kind: Equatable { case context, added, removed, fold }
    let kind: Kind
    let text: String
}

/// The diff, or the reason there is none.
enum LineDiffResult: Equatable {
    case lines([DiffLine])
    case binary(beforeBytes: Int, afterBytes: Int)
    case tooLarge(beforeLines: Int, afterLines: Int)
    case identical
}

/// Line diffs.
enum LineDiff {
    /// Above this product of line counts the diff is declined.
    static let maximumWork = 4_000_000
    /// Unchanged lines kept on either side of a change.
    static let context = 3

    /// Diffs two versions.
    /// - Parameters:
    ///   - before: The earlier bytes, nil when the file did not exist.
    ///   - after: The later bytes, nil when the file no longer exists.
    /// - Returns: The rendered diff.
    static func diff(before: Data?, after: Data?) -> LineDiffResult {
        let beforeData = before ?? Data()
        let afterData = after ?? Data()
        if beforeData == afterData { return .identical }
        guard let beforeText = text(beforeData), let afterText = text(afterData) else {
            return .binary(beforeBytes: beforeData.count, afterBytes: afterData.count)
        }
        let old = lines(beforeText)
        let new = lines(afterText)
        guard old.count * new.count <= maximumWork else { return .tooLarge(beforeLines: old.count, afterLines: new.count) }
        return .lines(fold(edits(old, new)))
    }

    /// Text if the bytes decode as UTF-8 and contain no NUL.
    private static func text(_ data: Data) -> String? {
        guard !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Splits into lines without a trailing empty line.
    private static func lines(_ text: String) -> [Substring] {
        var result = text.split(separator: "\n", omittingEmptySubsequences: false)
        if result.last == "" { result.removeLast() }
        return result
    }

    /// The full edit script from an LCS table.
    private static func edits(_ old: [Substring], _ new: [Substring]) -> [DiffLine] {
        var table = [[Int]](repeating: [Int](repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [DiffLine] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, old[i] == new[j] {
                result.append(DiffLine(kind: .context, text: String(old[i])))
                i += 1
                j += 1
            } else if i < old.count, j == new.count || table[i + 1][j] >= table[i][j + 1] {
                result.append(DiffLine(kind: .removed, text: String(old[i])))
                i += 1
            } else {
                result.append(DiffLine(kind: .added, text: String(new[j])))
                j += 1
            }
        }
        return result
    }

    /// Replaces long unchanged runs with a fold line.
    private static func fold(_ lines: [DiffLine]) -> [DiffLine] {
        var result: [DiffLine] = []
        var run: [DiffLine] = []
        func flush(atEnd: Bool) {
            let keepLeading = result.isEmpty ? 0 : context
            let keepTrailing = atEnd ? 0 : context
            if run.count > keepLeading + keepTrailing + 1 {
                result += run.prefix(keepLeading)
                result.append(DiffLine(kind: .fold, text: "\(run.count - keepLeading - keepTrailing) unchanged lines"))
                result += run.suffix(keepTrailing)
            } else {
                result += run
            }
            run = []
        }
        for line in lines {
            if line.kind == .context {
                run.append(line)
            } else {
                flush(atEnd: false)
                result.append(line)
            }
        }
        flush(atEnd: true)
        return result
    }
}
