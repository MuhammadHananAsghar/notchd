// LineDiffTests.swift
// The inspector's diff must name added and removed lines correctly, fold long
// unchanged runs, refuse binary content, decline pairs too large to compute,
// and treat missing versions as empty.

import XCTest
@testable import Notchd

final class LineDiffTests: XCTestCase {
    private func lines(_ result: LineDiffResult) -> [DiffLine] {
        if case .lines(let lines) = result { return lines }
        return []
    }

    /// A one-line edit reads as one removed and one added line with context.
    func testSimpleEdit() {
        let result = LineDiff.diff(before: Data("a\nb\nc\n".utf8), after: Data("a\nB\nc\n".utf8))
        XCTAssertEqual(lines(result), [
            DiffLine(kind: .context, text: "a"),
            DiffLine(kind: .removed, text: "b"),
            DiffLine(kind: .added, text: "B"),
            DiffLine(kind: .context, text: "c"),
        ])
    }

    /// A created file is all additions; a deleted one all removals.
    func testCreateAndDelete() {
        XCTAssertEqual(lines(LineDiff.diff(before: nil, after: Data("x\ny\n".utf8))).map(\.kind), [.added, .added])
        XCTAssertEqual(lines(LineDiff.diff(before: Data("x\n".utf8), after: nil)).map(\.kind), [.removed])
    }

    /// Long unchanged runs fold, keeping three lines of context on each side.
    func testFoldsUnchangedRuns() {
        let body = (1...20).map(String.init).joined(separator: "\n")
        let before = Data((body + "\nend\n").utf8)
        let after = Data((body + "\nEND\n").utf8)
        let result = lines(LineDiff.diff(before: before, after: after))
        XCTAssertEqual(result.first?.kind, .fold)
        XCTAssertEqual(result.first?.text, "17 unchanged lines")
        XCTAssertEqual(result.filter { $0.kind == .context }.count, 3)
        XCTAssertEqual(result.map(\.kind).suffix(2), [.removed, .added])
    }

    /// Identical bytes are reported as such.
    func testIdentical() {
        XCTAssertEqual(LineDiff.diff(before: Data("same".utf8), after: Data("same".utf8)), .identical)
    }

    /// Bytes with a NUL are binary.
    func testBinary() {
        XCTAssertEqual(LineDiff.diff(before: Data([0, 1, 2]), after: Data("text".utf8)), .binary(beforeBytes: 3, afterBytes: 4))
    }

    /// Very large pairs are declined rather than computed.
    func testTooLarge() {
        let big = Data(Array(repeating: "line\n", count: 3000).joined().utf8)
        let other = Data(Array(repeating: "other\n", count: 3000).joined().utf8)
        XCTAssertEqual(LineDiff.diff(before: big, after: other), .tooLarge(beforeLines: 3000, afterLines: 3000))
    }
}
