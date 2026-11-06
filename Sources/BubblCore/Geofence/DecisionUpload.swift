import Foundation

/// Uploads the decision log as `geofence.decision` events on POST /events (BUB-436), in requests of
/// their own: never mixed with other events, so a server that doesn't know the type yet (it answers
/// 4xx) can't hold anything else up. Small batches. A refused batch is dropped quietly and uploads
/// wait `holdSeconds` before trying again, so an old server is asked a few times a day, not in a loop.
package final class DecisionUploader: Sendable {
    package static let batchSize = 20
    /// Requests per flush at most (a flush is cheap: it runs after the real events').
    package static let maxBatches = 5
    package static let holdSeconds: Int64 = 6 * 60 * 60

    package static let eventType = "geofence.decision"

    private let log: DecisionLog
    private let api: DeviceApiClient
    private let clock: ServerClock
    private let deviceNowSeconds: @Sendable () -> Int64
    private let flushing = AsyncMutex()

    package init(log: DecisionLog, api: DeviceApiClient, clock: ServerClock, deviceNowSeconds: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.log = log
        self.api = api
        self.clock = clock
        self.deviceNowSeconds = deviceNowSeconds
    }

    /// Send what hasn't been sent. Never throws and never reports a failure to the caller:
    /// diagnostics must not disturb the real work. Offline, 5xx and 429 leave everything for later.
    package func flush() async {
        await flushing.withLock { await self.flushLocked() }
    }

    private func flushLocked() async {
        guard deviceNowSeconds() >= log.holdUntilSeconds else { return }

        for _ in 0..<Self.maxBatches {
            let batch = log.unsent(limit: Self.batchSize)
            if batch.isEmpty { return }

            let events = batch.map { decision in
                JSONValue.object([
                    "id": .string(decision.id),
                    "type": .string(Self.eventType),
                    "occurred_at": .string(EventQueue.isoTimestamp(decision.tsMillis + clock.offsetSeconds * 1000)),
                    "data": .object(decision.eventData),
                ])
            }
            guard let body = try? JSONEncoder().encode(JSONValue.object(["events": .array(events)])) else {
                // Can't be written as JSON: give the batch up rather than retry it for ever.
                log.markSent(Set(batch.map(\.id)))
                continue
            }

            let response: ApiResponse
            do {
                response = try await api.request("POST", "api/v1/events", body: String(decoding: body, as: UTF8.self))
            } catch {
                return  // offline, or the credential can't be read yet: later
            }

            let ids = Set(batch.map(\.id))
            if (200...299).contains(response.status) {
                // Accepted, or rejected per event in a 202: each has had its answer.
                log.markSent(ids)
            } else if Self.refused(response.status) {
                BubblLog.debug("The server refused \(batch.count) geofence decision(s) (HTTP \(response.status)): dropped, trying again later")
                log.markSent(ids, holdUntilSeconds: deviceNowSeconds() + Self.holdSeconds)
                return
            } else {
                return  // 5xx, 429, a pause: the real events' flush handles that; this waits
            }
        }
    }

    /// A 4xx that sending again can't change (the type is unknown to this server): not a rate limit or a timeout.
    package static func refused(_ status: Int) -> Bool {
        (400...499).contains(status) && ![408, 429].contains(status)
    }
}
