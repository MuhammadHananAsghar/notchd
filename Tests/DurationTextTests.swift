// DurationTextTests.swift
// The command line's `--last` values must parse the obvious spellings and
// refuse the rest.

import XCTest
@testable import Notchd

final class DurationTextTests: XCTestCase {
    /// Seconds, minutes, hours, and days, with case and whitespace tolerated.
    func testParsesUnits() {
        XCTAssertEqual(DurationText.parse("90s"), 90)
        XCTAssertEqual(DurationText.parse("10m"), 600)
        XCTAssertEqual(DurationText.parse("2h"), 7200)
        XCTAssertEqual(DurationText.parse("1d"), 86_400)
        XCTAssertEqual(DurationText.parse(" 1.5H "), 5400)
    }

    /// Anything else is nil.
    func testRejectsNonsense() {
        XCTAssertNil(DurationText.parse(""))
        XCTAssertNil(DurationText.parse("m"))
        XCTAssertNil(DurationText.parse("10"))
        XCTAssertNil(DurationText.parse("10x"))
        XCTAssertNil(DurationText.parse("-5m"))
    }

    /// Formatting picks the largest whole unit.
    func testFormats() {
        XCTAssertEqual(DurationText.format(45), "45 s")
        XCTAssertEqual(DurationText.format(600), "10 min")
        XCTAssertEqual(DurationText.format(7200), "2 h")
        XCTAssertEqual(DurationText.format(172_800), "2 d")
    }
}
