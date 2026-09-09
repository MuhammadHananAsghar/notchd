// NotchdEvent.swift
// The open protocol, version 1. One event describes one thing an agent did:
// a session starting or ending, a tool call about to run, finished, or failed,
// or a free-form note. Vendor adapters produce these from each agent's own hook
// payloads, and any agent developer can emit them directly through
// `notchd-hook emit`. The wire format is one JSON object per line.

import Foundation

/// One recorded action by an agent.
struct NotchdEvent: Codable, Equatable {
    /// What happened.
    enum Kind: String, Codable, CaseIterable {
        case sessionStart = "session.start"
        case sessionEnd = "session.end"
        case toolBefore = "tool.before"
        case toolAfter = "tool.after"
        case toolFailed = "tool.failed"
        case note
    }

    /// Protocol version. Always 1 for this schema.
    var v: Int = NotchdProtocol.version
    var kind: Kind
    /// A short vendor slug such as `claude`, `codex`, `gemini`, or the name of
    /// a third-party agent.
    var vendor: String
    /// The vendor's own session identifier.
    var session: String
    /// The agent's process id, when the vendor reports one.
    var pid: Int32?
    /// The working directory the agent was operating in.
    var cwd: String
    /// The tool name, for tool events.
    var tool: String?
    /// The vendor's identifier pairing a `tool.before` with its `tool.after`.
    var toolUseId: String?
    /// The tool's input, verbatim from the vendor.
    var args: JSONValue?
    /// The tool's output, bounded by the adapter.
    var result: JSONValue?
    /// The failure description, for `tool.failed`.
    var error: String?
    /// Paths the tool declared it would touch. Empty for read-only tools.
    var paths: [String] = []
    /// Vendor-specific extras Notchd stores but does not interpret.
    var meta: JSONValue?
    /// When it happened.
    var ts: Date
    var fidelity: Fidelity

    /// Coding keys in the protocol's snake_case spelling.
    enum CodingKeys: String, CodingKey {
        case v, kind, vendor, session, pid, cwd, tool
        case toolUseId = "tool_use_id"
        case args, result, error, paths, meta, ts, fidelity
    }

    /// Creates an event from its fields.
    init(v: Int = NotchdProtocol.version, kind: Kind, vendor: String, session: String, pid: Int32? = nil, cwd: String,
         tool: String? = nil, toolUseId: String? = nil, args: JSONValue? = nil, result: JSONValue? = nil,
         error: String? = nil, paths: [String] = [], meta: JSONValue? = nil, ts: Date, fidelity: Fidelity) {
        self.v = v
        self.kind = kind
        self.vendor = vendor
        self.session = session
        self.pid = pid
        self.cwd = cwd
        self.tool = tool
        self.toolUseId = toolUseId
        self.args = args
        self.result = result
        self.error = error
        self.paths = paths
        self.meta = meta
        self.ts = ts
        self.fidelity = fidelity
    }

    /// Decodes an event, treating `v` and `paths` as optional so a third-party
    /// emitter can leave them out.
    /// - Parameter decoder: The decoder.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decodeIfPresent(Int.self, forKey: .v) ?? NotchdProtocol.version
        kind = try container.decode(Kind.self, forKey: .kind)
        vendor = try container.decode(String.self, forKey: .vendor)
        session = try container.decode(String.self, forKey: .session)
        pid = try container.decodeIfPresent(Int32.self, forKey: .pid)
        cwd = try container.decode(String.self, forKey: .cwd)
        tool = try container.decodeIfPresent(String.self, forKey: .tool)
        toolUseId = try container.decodeIfPresent(String.self, forKey: .toolUseId)
        args = try container.decodeIfPresent(JSONValue.self, forKey: .args)
        result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        paths = try container.decodeIfPresent([String].self, forKey: .paths) ?? []
        meta = try container.decodeIfPresent(JSONValue.self, forKey: .meta)
        ts = try container.decode(Date.self, forKey: .ts)
        fidelity = try container.decode(Fidelity.self, forKey: .fidelity)
    }
}

/// Encoders and decoders configured for the wire format.
enum NotchdProtocol {
    /// The current protocol version.
    static let version = 1

    /// Timestamps are ISO 8601 with fractional seconds in UTC.
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// A formatter that also accepts timestamps without fractional seconds.
    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Formats a date for the wire.
    /// - Parameter date: The instant to format.
    /// - Returns: ISO 8601 text.
    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    /// Parses a wire timestamp, with or without fractional seconds.
    /// - Parameter string: ISO 8601 text.
    /// - Returns: The instant, or nil if the text is not a timestamp.
    static func date(from string: String) -> Date? {
        formatter.date(from: string) ?? plainFormatter.date(from: string)
    }

    /// A decoder for protocol objects.
    /// - Returns: A configured decoder.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an ISO 8601 timestamp: \(text)")
            }
            return date
        }
        return decoder
    }

    /// An encoder for protocol objects, with stable key order.
    /// - Returns: A configured encoder.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        return encoder
    }
}
