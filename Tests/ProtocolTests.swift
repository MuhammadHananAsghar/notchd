// ProtocolTests.swift
// The wire format has to survive a round trip and read the way the spec says:
// snake_case keys, ISO 8601 timestamps, and arbitrary JSON in args and result.
// The native adapter is what third-party agents hit, so it is exercised here
// with and without the optional fields.

import XCTest
@testable import Notchd

final class ProtocolTests: XCTestCase {
    /// Encoding then decoding yields an equal event with the documented keys.
    func testEventRoundTripsWithWireKeys() throws {
        let event = NotchdEvent(
            kind: .toolBefore, vendor: "my-agent", session: "s1", pid: 42, cwd: "/tmp/proj",
            tool: "shell", toolUseId: "t1", args: .object(["command": .string("make build")]),
            result: nil, error: nil, paths: ["/tmp/proj"], meta: .object(["note": .string("x")]),
            ts: Date(timeIntervalSince1970: 1_757_400_000.5), fidelity: .official
        )
        let data = try NotchdProtocol.encoder().encode(event)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"tool_use_id\":\"t1\""), text)
        XCTAssertTrue(text.contains("\"kind\":\"tool.before\""), text)
        XCTAssertTrue(text.contains("\"ts\":\"2025-09-09T06:40:00.500Z\""), text)
        let decoded = try NotchdProtocol.decoder().decode(NotchdEvent.self, from: data)
        XCTAssertEqual(decoded, event)
    }

    /// Timestamps without fractional seconds are accepted too.
    func testPlainTimestampsDecode() throws {
        let json = """
        {"v":1,"kind":"note","vendor":"x","session":"s","cwd":"/","paths":[],"ts":"2025-09-09T06:40:00Z","fidelity":"derived"}
        """
        let event = try NotchdProtocol.decoder().decode(NotchdEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.ts, Date(timeIntervalSince1970: 1_757_400_000))
        XCTAssertEqual(event.fidelity, .derived)
    }

    /// An envelope parses and exposes its receipt time as a date.
    func testEnvelopeParses() throws {
        let line = Data("""
        {"v":1,"vendor":"claude","received_at":1757400000.25,"raw":{"hook_event_name":"Stop"}}
        """.utf8)
        let envelope = try Envelope.parse(line)
        XCTAssertEqual(envelope.vendor, "claude")
        XCTAssertEqual(envelope.receivedDate, Date(timeIntervalSince1970: 1_757_400_000.25))
        XCTAssertEqual(envelope.raw["hook_event_name"]?.stringValue, "Stop")
    }

    /// A third-party emitter may leave out `ts` and `fidelity`; the receipt
    /// time and `official` fill them.
    func testNativeAdapterFillsDefaults() throws {
        let raw = JSONValue.object([
            "kind": .string("tool.after"), "vendor": .string("my-agent"), "session": .string("s"),
            "cwd": .string("/work"), "tool": .string("write"), "paths": .array([.string("/work/a.txt")]),
        ])
        let received = Date(timeIntervalSince1970: 1_000)
        let events = try NativeAdapter().events(from: raw, receivedAt: received)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].ts, received)
        XCTAssertEqual(events[0].fidelity, .official)
        XCTAssertEqual(events[0].paths, ["/work/a.txt"])
    }

    /// A payload missing required fields is a malformed error, not a crash.
    func testNativeAdapterRejectsIncompletePayload() {
        XCTAssertThrowsError(try NativeAdapter().events(from: .object(["kind": .string("note")]), receivedAt: Date())) { error in
            guard case AdapterError.malformed = error else { return XCTFail("unexpected \(error)") }
        }
    }

    /// The registry knows its slugs and refuses others.
    func testRegistryResolvesKnownVendors() throws {
        let registry = AdapterRegistry.standard
        XCTAssertEqual(registry.vendors, ["claude", "cursor", "gemini", "notchd"])
        XCTAssertNoThrow(try registry.adapter(for: "claude"))
        XCTAssertThrowsError(try registry.adapter(for: "codex")) { error in
            XCTAssertEqual(error as? AdapterError, .unknownVendor("codex"))
        }
    }

    /// Long strings anywhere in a value are cut and marked, everything else is
    /// left alone.
    func testTruncatingStringsMarksWhatItCut() {
        let value = JSONValue.object([
            "stdout": .string(String(repeating: "x", count: 100)),
            "code": .number(0),
            "nested": .array([.string("short")]),
        ])
        let cut = value.truncatingStrings(to: 10)
        XCTAssertEqual(cut["stdout"]?["truncated"]?.boolValue, true)
        XCTAssertEqual(cut["stdout"]?["bytes"]?.numberValue, 100)
        XCTAssertEqual(cut["stdout"]?["prefix"]?.stringValue, "xxxxxxxxxx")
        XCTAssertEqual(cut["code"]?.numberValue, 0)
        XCTAssertEqual(cut["nested"]?.arrayValue?.first?.stringValue, "short")
    }
}
