// JSONValue.swift
// A loss-free representation of arbitrary JSON, used wherever Notchd carries
// vendor data it does not interpret: tool arguments, tool results, and the raw
// payload inside an envelope. Codable in both directions and Equatable so
// fixtures can be compared in tests.

import Foundation

/// Any JSON value.
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    /// Decodes whichever JSON type the container holds.
    /// - Parameter decoder: The decoder positioned at a single value.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a JSON value")
        }
    }

    /// Encodes the value as the matching JSON type.
    /// - Parameter encoder: The encoder to write into.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let bool): try container.encode(bool)
        case .number(let number): try container.encode(number)
        case .string(let string): try container.encode(string)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }
}

extension JSONValue {
    /// The member of an object by key, or nil when this is not an object or the
    /// key is absent.
    /// - Parameter key: The object key.
    subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    /// The string payload, or nil for any other type.
    var stringValue: String? {
        guard case .string(let string) = self else { return nil }
        return string
    }

    /// The numeric payload, or nil for any other type.
    var numberValue: Double? {
        guard case .number(let number) = self else { return nil }
        return number
    }

    /// The boolean payload, or nil for any other type.
    var boolValue: Bool? {
        guard case .bool(let bool) = self else { return nil }
        return bool
    }

    /// The object payload, or nil for any other type.
    var objectValue: [String: JSONValue]? {
        guard case .object(let object) = self else { return nil }
        return object
    }

    /// The array payload, or nil for any other type.
    var arrayValue: [JSONValue]? {
        guard case .array(let array) = self else { return nil }
        return array
    }

    /// Parses a JSON document.
    /// - Parameter data: UTF-8 JSON bytes.
    /// - Returns: The parsed value.
    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Serialises the value as compact JSON with stable key order.
    /// - Returns: UTF-8 JSON bytes.
    func serialized() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Serialises the value as compact JSON text with stable key order.
    /// - Returns: The JSON text, or an empty string if encoding fails.
    var serializedString: String {
        guard let data = try? serialized() else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A copy of this value with a string field truncated to a byte budget.
    ///
    /// Tool results can be megabytes of build output. The ledger keeps a bounded
    /// prefix and records that it did so, rather than storing everything or
    /// dropping the result entirely.
    /// - Parameter limit: Maximum number of UTF-8 bytes to keep in any string.
    /// - Returns: The truncated value, with a `truncated` marker on strings that
    ///   were cut.
    func truncatingStrings(to limit: Int) -> JSONValue {
        switch self {
        case .string(let string) where string.utf8.count > limit:
            let prefix = String(decoding: Array(string.utf8.prefix(limit)), as: UTF8.self)
            return .object(["truncated": .bool(true), "bytes": .number(Double(string.utf8.count)), "prefix": .string(prefix)])
        case .array(let array):
            return .array(array.map { $0.truncatingStrings(to: limit) })
        case .object(let object):
            return .object(object.mapValues { $0.truncatingStrings(to: limit) })
        default:
            return self
        }
    }
}
