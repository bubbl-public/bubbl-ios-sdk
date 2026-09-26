import Foundation

/// How a flush ended, so whoever scheduled it (a background task, an app resume) knows what next.
package enum FlushResult: Sendable, Equatable {
    /// Everything queued was sent (accepted, a duplicate, or rejected for good).
    case done(sent: Int, rejected: [Rejection])
    /// Stopped part way; what's left stays queued.
    case failed(ApiFailure)
}

/// An event that can never be sent as it is (its data has a NaN or infinite number, which JSON
/// can't carry): refused by enqueue rather than queued.
package struct InvalidEvent: Error, Equatable {
    package let type: String

    package init(type: String) {
        self.type = type
    }
}

/// An event the server refused for good, with its reasons: logged, never retried.
package struct Rejection: Sendable, Equatable {
    package let id: String
    package let type: String
    /// The server's reasons, as JSON.
    package let errors: String
    /// The names of the fields it refused, for the log.
    package let fields: [String]
}

/// The offline event queue behind POST /events. Events are stored the moment they happen and sent
/// in batches of `batchSize` (at most 100), oldest first. Each carries its own id, which the server
/// de-duplicates on, so a batch whose answer was lost can simply be sent again.
///
/// Capped at `maxEvents` and `maxAgeMillis`: past either, the oldest go (analytics from days ago
/// isn't worth unbounded storage). One flush at a time. A request that couldn't be made (offline,
/// the Keychain or the store not readable yet) never drops anything: it's "try again later".
package final class EventQueue: Sendable {
    package static let batchSize = 100
    package static let maxEvents = 1_000
    package static let maxAgeMillis: Int64 = 72 * 60 * 60 * 1000

    private let store: any EventStore
    private let api: DeviceApiClient
    private let clock: ServerClock
    private let batchSize: @Sendable () -> Int
    private let newId: @Sendable () -> String
    private let flushing = AsyncMutex()

    /// - Parameter batchSize: GET /config's max_events_per_request, once known; never more than 100.
    package init(
        store: any EventStore,
        api: DeviceApiClient,
        clock: ServerClock,
        batchSize: @escaping @Sendable () -> Int = { EventQueue.batchSize },
        newId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.store = store
        self.api = api
        self.clock = clock
        self.batchSize = batchSize
        self.newId = newId
    }

    /// Queue an event of `type` ("notification.displayed", …) with its `data`, as happening now on
    /// the server's clock. Returns the event's id. Throws InvalidEvent when it can never be sent
    /// (a NaN or infinite number), and EventStoreUnavailable when it can't be stored yet.
    @discardableResult
    package func enqueue(_ type: String, data: [String: JSONValue] = [:], occurredAtMillis: Int64? = nil) async throws -> String {
        // Refused here, before the store: stored, it would stop every flush of its batch.
        guard JSONValue.object(data).isEncodable else {
            BubblLog.warning("Event \(type) refused: its data has a number JSON can't carry (NaN or infinite)")
            throw InvalidEvent(type: type)
        }

        let id = newId()
        try await store.add(QueuedEvent(id: id, type: type, occurredAtMillis: occurredAtMillis ?? clock.nowSeconds() * 1000, data: data))

        let overflow = try await store.count() - Self.maxEvents
        if overflow > 0 { try await store.dropOldest(overflow) }
        return id
    }

    /// Send everything queued, batch by batch, until the queue is empty or the server says stop.
    package func flush() async -> FlushResult {
        await flushing.withLock { await self.flushLocked() }
    }

    /// How many events are waiting to be sent.
    package func size() async throws -> Int { try await store.count() }

    /// Drop everything queued (opt-out, deleteMyData).
    package func clear() async throws { try await store.clear() }

    private func flushLocked() async -> FlushResult {
        var sent = 0
        var rejected: [Rejection] = []
        let size = min(max(batchSize(), 1), Self.batchSize)

        do {
            try await store.dropOccurred(before: clock.nowSeconds() * 1000 - Self.maxAgeMillis)

            while true {
                let batch = try await store.oldest(size)
                if batch.isEmpty { return .done(sent: sent, rejected: rejected) }

                let body: String
                do {
                    body = try Self.body(batch)
                } catch {
                    // Can't be written as JSON (enqueue refuses such events, so only a store
                    // filled some other way): drop the batch rather than retry it forever.
                    BubblLog.warning("Dropped \(batch.count) queued event(s) that can't be written as JSON")
                    try await store.remove(Set(batch.map(\.id)))
                    continue
                }

                let response = try await api.request("POST", "api/v1/events", body: body)

                // 202 is the contract's answer; any 2xx (a proxy's 200) settles the batch too.
                if (200...299).contains(response.status) {
                    let refused = Self.rejections(batch, response)
                    // Field names only: the errors can quote what was sent.
                    refused.forEach { BubblLog.warning("Event \($0.type) \($0.id) rejected by the server (fields: \($0.fields.joined(separator: ", ")))") }
                    rejected += refused
                    // Accepted, duplicate or rejected: each has had its answer, so none is resent.
                    try await store.remove(Set(batch.map(\.id)))
                    sent += batch.count
                    continue
                }

                let failure = ApiFailure.of(response)
                // Only a malformed batch gets a 422, and resending it can't help: drop it rather
                // than wedge the queue behind it.
                guard case .drop(_, let status, let code) = failure else { return .failed(failure) }
                BubblLog.warning("Dropped a batch of \(batch.count) event(s) the server refused (HTTP \(status) \(code ?? ""))")
                try await store.remove(Set(batch.map(\.id)))
            }
        } catch {
            // Offline, the credential or the store not readable yet: nothing refused, all kept.
            return .failed(.backoff)
        }
    }

    // MARK: - The wire format (contracts/v1: POST /events)

    private struct Body: Encodable {
        let events: [Event]

        struct Event: Encodable {
            let id: String
            let type: String
            let occurred_at: String
            let data: [String: JSONValue]
        }
    }

    private struct Response: Decodable {
        let data: Results

        struct Results: Decodable {
            let results: [Result]
        }

        struct Result: Decodable {
            let id: String
            let status: String
            let errors: JSONValue?
        }
    }

    private static func body(_ batch: [QueuedEvent]) throws -> String {
        let events = batch.map { Body.Event(id: $0.id, type: $0.type, occurred_at: isoTimestamp($0.occurredAtMillis), data: $0.data) }
        return String(decoding: try JSONEncoder().encode(Body(events: events)), as: UTF8.self)
    }

    /// The events a 202 marked rejected, with the server's reasons.
    private static func rejections(_ batch: [QueuedEvent], _ response: ApiResponse) -> [Rejection] {
        guard let results = response.decode(Response.self)?.data.results else { return [] }
        let types = Dictionary(batch.map { ($0.id, $0.type) }, uniquingKeysWith: { first, _ in first })

        return results.filter { $0.status == "rejected" }.map { result in
            let errors = result.errors.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let fields = if case .object(let byField)? = result.errors { byField.keys.sorted() } else { [String]() }
            return Rejection(id: result.id, type: types[result.id] ?? "", errors: errors, fields: fields)
        }
    }

    /// Unix milliseconds as ISO 8601 in UTC ("2026-09-24T10:15:30Z", with milliseconds when there
    /// are any), as the contract's occurred_at.
    package static func isoTimestamp(_ millis: Int64) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let date = Date(timeIntervalSince1970: TimeInterval(millis / 1000))
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = "\(pad(parts.year ?? 0, 4))-\(pad(parts.month ?? 0, 2))-\(pad(parts.day ?? 0, 2))"
        let time = "\(pad(parts.hour ?? 0, 2)):\(pad(parts.minute ?? 0, 2)):\(pad(parts.second ?? 0, 2))"
        let fraction = Int(millis % 1000)
        return "\(day)T\(time)" + (fraction == 0 ? "Z" : ".\(pad(fraction, 3))Z")
    }

    /// `value` with leading zeros to `width` digits.
    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(width - digits.count, 0)) + digits
    }
}
