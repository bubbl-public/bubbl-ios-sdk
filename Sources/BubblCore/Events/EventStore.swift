import Foundation

/// One event waiting to be sent to POST /events: the id the server de-duplicates on, its type,
/// when it happened (unix milliseconds, on the server's clock) and its `data` object.
package struct QueuedEvent: Sendable, Equatable, Codable {
    package let id: String
    package let type: String
    package let occurredAtMillis: Int64
    package let data: [String: JSONValue]

    package init(id: String, type: String, occurredAtMillis: Int64, data: [String: JSONValue] = [:]) {
        self.id = id
        self.type = type
        self.occurredAtMillis = occurredAtMillis
        self.data = data
    }
}

/// The store couldn't be read or written, so it did neither: nothing was lost or overwritten.
/// Before the first unlock after a reboot iOS keeps protected files closed; try again later.
package struct EventStoreUnavailable: Error {
    package let underlying: any Error
}

/// Where queued events wait: on disk on a device, so they survive the app being killed and the
/// phone being offline. Oldest first throughout (id breaks ties).
package protocol EventStore: Actor {
    func add(_ event: QueuedEvent) throws
    /// Up to `limit` of the oldest events, oldest first.
    func oldest(_ limit: Int) throws -> [QueuedEvent]
    func remove(_ ids: Set<String>) throws
    func count() throws -> Int
    /// Drops the `count` oldest events (the queue's size cap).
    func dropOldest(_ count: Int) throws
    /// Drops events that happened before `millis` (the queue's age cap); returns how many.
    @discardableResult func dropOccurred(before millis: Int64) throws -> Int
    /// Drops everything (opt-out, deleteMyData).
    func clear() throws
}

/// The events themselves, however they're kept: shared by the memory and file stores.
private struct Events {
    var all: [QueuedEvent] = []

    mutating func add(_ event: QueuedEvent) {
        if !all.contains(where: { $0.id == event.id }) { all.append(event) }
    }

    func oldest(_ limit: Int) -> [QueuedEvent] { Array(sorted().prefix(max(limit, 0))) }

    mutating func remove(_ ids: Set<String>) { all.removeAll { ids.contains($0.id) } }

    mutating func dropOldest(_ count: Int) { remove(Set(oldest(count).map(\.id))) }

    mutating func dropOccurred(before millis: Int64) -> Int {
        let before = all.count
        all.removeAll { $0.occurredAtMillis < millis }
        return before - all.count
    }

    /// By when they happened; events of the same millisecond in the order they were recorded (not
    /// by id, which is random).
    private func sorted() -> [QueuedEvent] {
        all.enumerated()
            .sorted { ($0.element.occurredAtMillis, $0.offset) < ($1.element.occurredAtMillis, $1.offset) }
            .map(\.element)
    }
}

/// An EventStore in memory: for tests.
package actor InMemoryEventStore: EventStore {
    private var events = Events()

    package init() {}

    package func add(_ event: QueuedEvent) { events.add(event) }
    package func oldest(_ limit: Int) -> [QueuedEvent] { events.oldest(limit) }
    package func remove(_ ids: Set<String>) { events.remove(ids) }
    package func count() -> Int { events.all.count }
    package func dropOldest(_ count: Int) { events.dropOldest(count) }
    @discardableResult package func dropOccurred(before millis: Int64) -> Int { events.dropOccurred(before: millis) }
    package func clear() { events.all.removeAll() }
}

/// An EventStore in one JSON file, written whole and atomically on every change (the queue is
/// capped at 1000 small events). Loaded on first use.
///
/// A file that exists but can't be read (protected before the first unlock) is never taken for
/// an empty queue: every call throws EventStoreUnavailable and nothing is written over it until
/// it can be read. A missing file is an empty queue.
///
/// One process only: the file is cached in memory and rewritten whole from that cache, so a
/// second writer's events would be lost. The notification service extension (a separate process)
/// must never share this file; anything it reports goes its own way (its own file, merged by the
/// app, or a request of its own).
package actor FileEventStore: EventStore {
    private let url: URL
    private let writeOptions: Data.WritingOptions
    private var loaded: Events?

    /// - Parameter writeOptions: added to `.atomic`; on iOS, the file protection class.
    package init(url: URL, writeOptions: Data.WritingOptions = []) {
        self.url = url
        self.writeOptions = writeOptions.union(.atomic)
    }

    package func add(_ event: QueuedEvent) throws { try change { $0.add(event) } }
    package func oldest(_ limit: Int) throws -> [QueuedEvent] { try events().oldest(limit) }
    package func remove(_ ids: Set<String>) throws { try change { $0.remove(ids) } }
    package func count() throws -> Int { try events().all.count }
    package func dropOldest(_ count: Int) throws { try change { $0.dropOldest(count) } }

    @discardableResult
    package func dropOccurred(before millis: Int64) throws -> Int {
        var dropped = 0
        try change { dropped = $0.dropOccurred(before: millis) }
        return dropped
    }

    package func clear() throws { try change { $0.all.removeAll() } }

    private func events() throws -> Events {
        if let loaded { return loaded }

        var events = Events()
        if FileManager.default.fileExists(atPath: url.path) {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                // Can't be read yet (protected until the first unlock): wait, don't overwrite.
                throw EventStoreUnavailable(underlying: error)
            }
            // Read but not understood (corrupt, or from an incompatible build): starting afresh
            // loses some analytics; keeping it would stop the queue for good.
            if let decoded = try? JSONDecoder().decode([QueuedEvent].self, from: data) {
                events = Events(all: decoded)
            }
        }
        loaded = events
        return events
    }

    /// Applies `body` and writes the result; memory changes only once the file has. Only reading
    /// or writing the file counts as "unavailable": an event that can't be encoded throws its
    /// EncodingError, since trying again later can't help it.
    private func change(_ body: (inout Events) -> Void) throws {
        var events = try events()
        body(&events)
        let data = try JSONEncoder().encode(events.all)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: writeOptions)
        } catch {
            throw EventStoreUnavailable(underlying: error)
        }
        loaded = events
    }
}
