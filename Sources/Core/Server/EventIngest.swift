// EventIngest.swift
// Turns a socket line into ledger rows: parse the envelope, pick the vendor
// adapter, normalise, judge against the guard, record, then hand each stored
// event to the observers that checkpoint and diff. A denied call is recorded
// with the decision and skips the observers, since it will not run. Nothing
// here throws to the caller: a bad line is logged and counted, because the
// hook that sent it is waiting only for an answer and the useful response is
// to keep the server up.

import Foundation
import os

/// What became of one line.
enum IngestOutcome: Equatable {
    /// Events recorded, with their ledger ids.
    case recorded([Int64])
    /// The line was not a valid envelope.
    case malformedEnvelope(String)
    /// No adapter for the vendor, or the adapter rejected the payload.
    case rejected(String)
    /// The ledger refused the write.
    case storageFailed(String)
}

/// The pipeline from socket line to ledger.
final class EventIngest {
    typealias RecordedHandler = ([EventRow]) -> Void

    private let ledger: Ledger
    private let registry: AdapterRegistry
    private let observers: [EventObserver]
    private let guardPolicy: GuardPolicy?
    private let onRecorded: RecordedHandler?
    private let log = Logger(subsystem: "com.muhammad.notchd", category: "ingest")

    /// Builds the pipeline.
    /// - Parameters:
    ///   - ledger: Where events are written.
    ///   - registry: The adapters to normalise with.
    ///   - observers: Told about each stored event before the line is
    ///     answered. An observer's error is logged, never propagated.
    ///   - guardPolicy: The rules, or nil to never refuse.
    ///   - onRecorded: Called after each successful write, on the ingest thread.
    init(ledger: Ledger, registry: AdapterRegistry = .standard, observers: [EventObserver] = [],
         guardPolicy: GuardPolicy? = nil, onRecorded: RecordedHandler? = nil) {
        self.ledger = ledger
        self.registry = registry
        self.observers = observers
        self.guardPolicy = guardPolicy
        self.onRecorded = onRecorded
    }

    /// Processes one line.
    /// - Parameter line: UTF-8 JSON for a single envelope.
    /// - Returns: The outcome, for callers and tests that want to know.
    @discardableResult
    func ingest(_ line: Data) -> IngestOutcome {
        process(line).outcome
    }

    /// Processes one line and says what the hook should be told.
    /// - Parameter line: UTF-8 JSON for a single envelope.
    /// - Returns: The guard's decision, allow when nothing fired.
    func handle(_ line: Data) -> HookDecision {
        process(line).decision
    }

    /// The shared path behind `ingest` and `handle`.
    private func process(_ line: Data) -> (outcome: IngestOutcome, decision: HookDecision) {
        let envelope: Envelope
        do {
            envelope = try Envelope.parse(line)
        } catch {
            log.error("dropped a line that was not an envelope: \(String(describing: error), privacy: .public)")
            return (.malformedEnvelope(String(describing: error)), .allow)
        }
        let events: [NotchdEvent]
        do {
            let adapter = try registry.adapter(for: envelope.vendor)
            events = try adapter.events(from: envelope.raw, receivedAt: envelope.receivedDate)
        } catch {
            log.error("rejected a \(envelope.vendor, privacy: .public) payload: \(String(describing: error), privacy: .public)")
            return (.rejected(String(describing: error)), .allow)
        }
        var decision = HookDecision.allow
        do {
            let rows = try events.map { event -> EventRow in
                let verdict = guardPolicy?.evaluate(event).decision ?? .allow
                if verdict != .allow { decision = verdict }
                let row = try ledger.record(Self.stamped(event, with: verdict))
                if case .deny = verdict {
                    log.notice("guard denied \(event.tool ?? "a call", privacy: .public) for \(event.vendor, privacy: .public)")
                } else {
                    notify(row, event: event)
                }
                return row
            }
            onRecorded?(rows)
            return (.recorded(rows.map(\.id)), decision)
        } catch {
            log.error("ledger write failed: \(String(describing: error), privacy: .public)")
            return (.storageFailed(String(describing: error)), decision)
        }
    }

    /// The event with the guard's decision kept in its meta.
    private static func stamped(_ event: NotchdEvent, with decision: HookDecision) -> NotchdEvent {
        guard let guardMeta = decision.meta else { return event }
        var meta = event.meta?.objectValue ?? [:]
        meta["guard"] = guardMeta
        var stamped = event
        stamped.meta = .object(meta)
        return stamped
    }

    /// Records events that arrive already normalised, such as those a
    /// transcript tailer derives, running the same observers. An event the
    /// ledger already holds is skipped, so replaying a transcript after a
    /// relaunch records nothing twice.
    /// - Parameter events: The events, in order.
    /// - Returns: The ledger ids of those recorded.
    @discardableResult
    func ingest(events: [NotchdEvent]) -> [Int64] {
        var rows: [EventRow] = []
        for event in events {
            do {
                if try ledger.contains(event) { continue }
                let row = try ledger.record(event)
                notify(row, event: event)
                rows.append(row)
            } catch {
                log.error("ledger write failed: \(String(describing: error), privacy: .public)")
            }
        }
        if !rows.isEmpty { onRecorded?(rows) }
        return rows.map(\.id)
    }

    /// Hands a stored event to every observer, logging any failure.
    private func notify(_ row: EventRow, event: NotchdEvent) {
        for observer in observers {
            do {
                try observer.observe(row, event: event)
            } catch {
                log.error("observer failed on event \(row.id): \(String(describing: error), privacy: .public)")
            }
        }
    }
}
