// Envelope.swift
// What `notchd-hook` writes to the socket: the vendor's raw payload, untouched,
// wrapped with the vendor slug and the moment it was received. Normalising in
// the app rather than in the hook keeps the hook binary trivial and means a
// fix to an adapter never requires reinstalling anything in a vendor's config.

import Foundation

/// One line on the socket.
struct Envelope: Codable, Equatable {
    /// Envelope format version. Always 1.
    var v: Int = 1
    /// The vendor slug the hook was invoked for, or `notchd` for a payload that
    /// is already a protocol event.
    var vendor: String
    /// Seconds since 1970 when the hook read its input.
    var receivedAt: Double
    /// The vendor's payload, verbatim.
    var raw: JSONValue

    /// Coding keys in the wire spelling.
    enum CodingKeys: String, CodingKey {
        case v, vendor
        case receivedAt = "received_at"
        case raw
    }

    /// The receipt time as a date.
    var receivedDate: Date { Date(timeIntervalSince1970: receivedAt) }

    /// Parses one socket line.
    /// - Parameter line: UTF-8 JSON for a single envelope.
    /// - Returns: The envelope.
    static func parse(_ line: Data) throws -> Envelope {
        try NotchdProtocol.decoder().decode(Envelope.self, from: line)
    }
}
