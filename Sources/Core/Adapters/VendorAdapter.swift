// VendorAdapter.swift
// The seam between each agent's own hook payload and the Notchd protocol. An
// adapter turns one raw payload into zero or more events. The registry picks
// the adapter for an envelope's vendor slug, and the native adapter accepts
// payloads that are already protocol events, which is how third-party agents
// integrate.

import Foundation

/// Why a payload could not be normalised.
enum AdapterError: Error, Equatable {
    /// No adapter knows this vendor slug.
    case unknownVendor(String)
    /// The payload lacked a field the adapter cannot do without.
    case missingField(String)
    /// The payload was not the shape the adapter expected.
    case malformed(String)
}

/// Turns one vendor payload into protocol events.
protocol VendorAdapter {
    /// The slug this adapter answers to.
    static var vendor: String { get }

    /// Normalises a payload.
    /// - Parameters:
    ///   - raw: The vendor's payload, verbatim.
    ///   - receivedAt: When the hook received it, used as the event time for
    ///     vendors whose payloads carry no timestamp.
    /// - Returns: The events the payload describes.
    func events(from raw: JSONValue, receivedAt: Date) throws -> [NotchdEvent]
}

/// Accepts payloads that are already protocol events.
struct NativeAdapter: VendorAdapter {
    static let vendor = "notchd"

    /// Decodes the payload as a `NotchdEvent`, filling in the receipt time when
    /// the emitter left `ts` out.
    /// - Parameters:
    ///   - raw: A protocol event as JSON.
    ///   - receivedAt: Fallback timestamp.
    /// - Returns: The single event.
    func events(from raw: JSONValue, receivedAt: Date) throws -> [NotchdEvent] {
        var object = raw.objectValue ?? [:]
        if object["ts"] == nil {
            object["ts"] = .string(NotchdProtocol.string(from: receivedAt))
        }
        if object["fidelity"] == nil {
            object["fidelity"] = .string(Fidelity.official.rawValue)
        }
        let data = try JSONValue.object(object).serialized()
        do {
            return [try NotchdProtocol.decoder().decode(NotchdEvent.self, from: data)]
        } catch {
            throw AdapterError.malformed(String(describing: error))
        }
    }
}

/// Finds the adapter for a vendor slug.
struct AdapterRegistry {
    private let adapters: [String: VendorAdapter]

    /// The adapters Notchd ships with.
    static let standard = AdapterRegistry(adapters: [NativeAdapter(), ClaudeCodeAdapter(), GeminiAdapter(), CursorAdapter()])

    /// Builds a registry from a list of adapters, keyed by their vendor slug.
    /// - Parameter adapters: The adapters to register.
    init(adapters: [VendorAdapter]) {
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { (type(of: $0).vendor, $0) })
    }

    /// Looks up the adapter for a slug.
    /// - Parameter vendor: The slug from an envelope.
    /// - Returns: The adapter.
    func adapter(for vendor: String) throws -> VendorAdapter {
        guard let adapter = adapters[vendor] else { throw AdapterError.unknownVendor(vendor) }
        return adapter
    }

    /// Every slug this registry knows.
    var vendors: [String] { adapters.keys.sorted() }
}
