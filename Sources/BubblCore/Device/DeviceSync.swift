import Foundation

package enum SyncResult: Sendable, Equatable {
    /// The server already has all of it.
    case upToDate
    /// Sent; `fields` are the ones that had changed.
    case sent(fields: Set<String>)
    case failed(ApiFailure)
}

/// Keeps the server's copy of the device (PUT /device) in step with the device itself: the OS and
/// app version, locale, the push token, permissions, consent. Only fields that changed since the
/// server last acknowledged them are sent (the contract leaves anything left out unchanged), so an
/// app open where nothing changed costs no request at all.
package final class DeviceSync: Sendable {
    private let api: DeviceApiClient
    /// What the server last acknowledged, as sent.
    private let acknowledged: any ValueStore<[String: JSONValue]>
    private let lock = AsyncMutex()

    package init(api: DeviceApiClient, acknowledged: any ValueStore<[String: JSONValue]>) {
        self.api = api
        self.acknowledged = acknowledged
    }

    /// Send whatever in `attributes` the server doesn't have yet; everything when `force`.
    package func sync(_ attributes: [String: JSONValue], force: Bool = false) async -> SyncResult {
        await lock.withLock { await self.syncLocked(attributes, force: force) }
    }

    private func syncLocked(_ attributes: [String: JSONValue], force: Bool) async -> SyncResult {
        let known: [String: JSONValue]?
        do {
            known = force ? nil : try acknowledged.load()
        } catch {
            return .failed(.backoff)
        }
        // JSONValue compares objects by content, so key order is never a change.
        let changes = attributes.filter { key, value in known?[key] != value || known?.keys.contains(key) != true }
        if changes.isEmpty { return .upToDate }

        let response: ApiResponse
        do {
            let body = String(decoding: try JSONEncoder().encode(changes), as: UTF8.self)
            response = try await api.request("PUT", "api/v1/device", body: body)
        } catch {
            return .failed(.backoff)
        }
        guard response.isSuccessful else { return .failed(ApiFailure.of(response)) }

        var merged = known ?? [:]
        merged.merge(changes) { _, new in new }
        try? acknowledged.save(merged)
        return .sent(fields: Set(changes.keys))
    }

    /// POST /installs has just sent `attributes` in full: the server has exactly those now.
    package func registered(_ attributes: [String: JSONValue]) {
        try? acknowledged.save(attributes)
    }

    /// Whether the server has ever acknowledged this device.
    package var known: Bool { (try? acknowledged.load()) != nil }

    /// The server lost track of the device (or it was erased): send everything next time.
    package func forget() {
        try? acknowledged.delete()
    }

    /// The server dropped `fields` (a push token Apple called dead): send them again next time,
    /// and only them.
    package func forget(_ fields: Set<String>) async {
        await lock.withLock {
            guard var known = try? self.acknowledged.load() else { return }
            for field in fields { known.removeValue(forKey: field) }
            try? self.acknowledged.save(known)
        }
    }
}

/// The device's segments as the app last set them, and whether the server has them yet
/// (PUT /device/segments replaces them whole). Registration sends them too.
package final class Segments: Sendable {
    package static let maxSegments = 100
    package static let maxLength = 255

    package struct Saved: Codable, Sendable, Equatable {
        package var segments: [String]
        package var pending: Bool
    }

    private let store: any ValueStore<Saved>
    private let lock = NSLock()
    private let cache = Cached<Saved>()

    package init(store: any ValueStore<Saved>) {
        self.store = store
    }

    /// The segments the app set; nil if it never has.
    package var current: [String]? { lock.sync { (try? load())??.segments } }

    package var pending: Bool { lock.sync { (try? load())??.pending == true } }

    /// Forget them (deleteMyData): the device starts again with none.
    package func forget() throws {
        try lock.sync {
            try store.delete()
            cache.set(nil)
        }
    }

    private func load() throws -> Saved? {
        try cache.value { try store.load() }
    }

    private func save(_ saved: Saved) throws {
        try store.save(saved)
        cache.set(saved)
    }

    /// Keeps `segments` (trimmed, de-duplicated, at most 100 of 255 characters); false if unchanged.
    @discardableResult
    package func set(_ segments: [String]) throws -> Bool {
        var seen = Set<String>()
        let clean = segments
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxLength)) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(Self.maxSegments)
        return try lock.sync {
            let saved = try load()
            if saved?.segments == Array(clean), saved?.pending == false { return false }
            try save(Saved(segments: Array(clean), pending: true))
            return true
        }
    }

    /// The server has `segments` now (unless the app changed them again meanwhile).
    package func sent(_ segments: [String]) {
        lock.sync {
            guard (try? load())??.segments == segments else { return }
            try? save(Saved(segments: segments, pending: false))
        }
    }

    /// PUT /device/segments with the pending segments, if any.
    package func push(_ api: DeviceApiClient) async -> SyncResult {
        guard pending, let segments = current else { return .upToDate }
        let response: ApiResponse
        do {
            let body = String(decoding: try JSONEncoder().encode(["segments": segments]), as: UTF8.self)
            response = try await api.request("PUT", "api/v1/device/segments", body: body)
        } catch {
            return .failed(.backoff)
        }
        guard response.isSuccessful else { return .failed(ApiFailure.of(response)) }
        sent(segments)
        return .sent(fields: ["segments"])
    }
}
