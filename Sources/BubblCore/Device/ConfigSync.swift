import Foundation

/// GET /config's data (every field is always present, per the contract), read leniently.
package struct SdkConfig: Sendable, Hashable {
    package static let defaultRefreshSeconds: Int64 = 3_600

    package let json: JSONValue

    package init(_ json: JSONValue) {
        self.json = json
    }

    package var enabled: Bool {
        if case .bool(let value)? = json["enabled"] { value } else { true }
    }

    /// Whether the server has this device's push token (device.push_token_registered). False while
    /// the app holds one means the server dropped it (Apple or FCM called it dead, or it was sent
    /// for the wrong APNs environment); nil before the device has described itself.
    package var pushTokenRegistered: Bool? {
        if case .bool(let value)? = json["device"]?["push_token_registered"] { value } else { nil }
    }

    package var minimumVersion: String? { json["sdk"]?["minimum_version"]?.nonEmptyString }

    package var logLevel: String { json["sdk"]?["log_level"]?.nonEmptyString ?? "warning" }

    /// From one minute to a week, whatever the server says.
    package var configRefreshSeconds: Int64 {
        json["sync"]?["config_refresh_seconds"]?.int64(in: 60...604_800) ?? Self.defaultRefreshSeconds
    }

    /// From 1 to the queue's 100.
    package var maxEventsPerRequest: Int {
        json["sync"]?["max_events_per_request"]?.int64(in: 1...Int64(EventQueue.batchSize)).map { Int($0) } ?? EventQueue.batchSize
    }

    /// The dashboard's privacy view: when to explain before asking for a permission.
    package var privacyNotice: String {
        let notice = json["privacy"]?["notice"]?.stringValue ?? ""
        return ["automatic", "always", "never"].contains(notice) ? notice : "automatic"
    }

    /// The dashboard's own words for the privacy view, if it has set any.
    package var privacyText: String? {
        json["privacy"]?["text"]?.nonEmptyString.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// The workspace's privacy policy, linked from the privacy view.
    package var privacyUrl: String? {
        json["privacy"]?["callback_url"]?.nonEmptyString.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// Whether `sdkVersion` is at least the minimum the workspace allows (none: any).
    package func supports(_ sdkVersion: String) -> Bool {
        guard let minimumVersion else { return true }
        return Versions.compare(sdkVersion, minimumVersion) >= 0
    }
}

package enum ConfigResult: Sendable, Equatable {
    case updated
    case unchanged
    case notDue
    case failed(ApiFailure)
}

/// The runtime configuration: what POST /installs returned, then GET /config every
/// config_refresh_seconds (conditional, If-None-Match). Kept on disk, so the engine starts with the
/// last known configuration when offline.
package final class ConfigSync: Sendable {
    package struct Saved: Codable, Sendable, Equatable {
        package var config: JSONValue
        package var etag: String?
        package var fetchedAtSeconds: Int64
    }

    private let api: DeviceApiClient
    private let clock: ServerClock
    private let store: any ValueStore<Saved>
    private let lock = AsyncMutex()
    /// The saved config, once read (it's asked for often: enabled, the log level, the batch size).
    private let cache = Cached<Saved>()

    package init(api: DeviceApiClient, clock: ServerClock, store: any ValueStore<Saved>) {
        self.api = api
        self.clock = clock
        self.store = store
    }

    /// The last known configuration; nil before the first, or while it can't be read.
    package var current: SdkConfig? {
        (try? load())?.map { SdkConfig($0.config) }
    }

    /// The config that came with a registration.
    package func registered(_ config: JSONValue) throws {
        try save(Saved(config: config, etag: nil, fetchedAtSeconds: clock.nowSeconds()))
    }

    /// The workspace block from POST /test-device, put into the saved config (where GET /config
    /// would bring it), so the device reads as approved without another request.
    package func setWorkspace(_ workspace: JSONValue) async throws {
        try await lock.withLock {
            guard var saved = try self.load(), case .object(var fields) = saved.config else { return }
            fields["workspace"] = workspace
            saved.config = .object(fields)
            try self.save(saved)
        }
    }

    /// Forget it (deleteMyData): the next registration brings the config afresh.
    package func forget() throws {
        try store.delete()
        cache.set(nil)
    }

    private func load() throws -> Saved? {
        try cache.value { try store.load() }
    }

    private func save(_ saved: Saved) throws {
        try store.save(saved)
        cache.set(saved)
    }

    /// GET /config when it's due: every config_refresh_seconds, or sooner with `maxAgeSeconds` (the
    /// app coming to the front, so a change such as a Sandbox approval is seen on the next open).
    /// Conditional, so an unchanged config costs a 304.
    package func refresh(force: Bool = false, maxAgeSeconds: Int64? = nil) async -> ConfigResult {
        await lock.withLock { await self.refreshLocked(force: force, maxAgeSeconds: maxAgeSeconds) }
    }

    private func refreshLocked(force: Bool, maxAgeSeconds: Int64?) async -> ConfigResult {
        let saved: Saved?
        do {
            saved = try load()
        } catch {
            return .failed(.backoff)
        }
        let refreshSeconds = SdkConfig(saved?.config ?? .null).configRefreshSeconds
        if !force, let saved, clock.nowSeconds() - saved.fetchedAtSeconds < min(refreshSeconds, maxAgeSeconds ?? refreshSeconds) {
            return .notDue
        }

        let response: ApiResponse
        do {
            response = try await api.request("GET", "api/v1/config", headers: saved?.etag.map { ["If-None-Match": $0] } ?? [:])
        } catch {
            return .failed(.backoff)
        }

        do {
            if response.status == 304, var saved {
                saved.fetchedAtSeconds = clock.nowSeconds()
                try save(saved)
                return .unchanged
            }
            struct Body: Decodable { let data: JSONValue }
            if response.status == 200, let body = response.decode(Body.self), case .object = body.data {
                try save(Saved(config: body.data, etag: response.header("ETag"), fetchedAtSeconds: clock.nowSeconds()))
                return .updated
            }
        } catch {
            return .failed(.backoff)
        }
        return response.isSuccessful ? .failed(.backoff) : .failed(ApiFailure.of(response))
    }
}

/// Semantic version order: numbers compared numerically, and a pre-release before its release.
package enum Versions {
    package static func compare(_ a: String, _ b: String) -> Int {
        let (coreA, preA) = split(a)
        let (coreB, preB) = split(b)
        for i in 0..<max(coreA.count, coreB.count) {
            let x = i < coreA.count ? coreA[i] : 0
            let y = i < coreB.count ? coreB[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        switch (preA, preB) {
        case (nil, nil): return 0
        case (nil, _): return 1
        case (_, nil): return -1
        case let (a?, b?): return comparePre(a, b)
        }
    }

    private static func split(_ version: String) -> ([Int], String?) {
        var clean = version.trimmingCharacters(in: .whitespaces)
        if clean.hasPrefix("v") { clean.removeFirst() }
        if let plus = clean.firstIndex(of: "+") { clean = String(clean[..<plus]) }
        let parts = clean.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts[0].split(separator: ".").map { Int($0) ?? 0 }
        let pre = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
        return (core, pre)
    }

    private static func comparePre(_ a: String, _ b: String) -> Int {
        let partsA = a.split(separator: ".")
        let partsB = b.split(separator: ".")
        for i in 0..<min(partsA.count, partsB.count) {
            let x = Int(partsA[i])
            let y = Int(partsB[i])
            let diff: Int
            switch (x, y) {
            case let (x?, y?): diff = x == y ? 0 : (x < y ? -1 : 1)
            case (_?, nil): diff = -1
            case (nil, _?): diff = 1
            default: diff = partsA[i] == partsB[i] ? 0 : (partsA[i] < partsB[i] ? -1 : 1)
            }
            if diff != 0 { return diff }
        }
        return partsA.count == partsB.count ? 0 : (partsA.count < partsB.count ? -1 : 1)
    }
}
