import Foundation

/// One step of a geofence decision, as the dashboard's `geofence.decision` event (BUB-436). The same
/// fields, result and reason strings, and buffer size as Android's, so one shape reaches the dashboard.
///
/// Holds ids, ages and accuracies only: never a coordinate, a token or anything personal.
package struct GeofenceDecision: Codable, Sendable, Equatable {
    /// The event's id on POST /events (the server de-duplicates on it).
    package var id: String
    /// The geofence's id (the location uuid), or `GeofenceDecision.trackingRegion` for a tracking session.
    package var regionId: String
    /// "enter" or "exit".
    package var event: String
    package var fixAgeMs: Int64?
    package var fixAccuracyM: Double?
    /// What was decided: inside_polygon, outside_polygon, circle_only, outside_circle, … ^[a-z0-9_.:-]+$, at most 40.
    package var result: String
    /// Why nothing showed, or why a result is what it is (notifications_off, cooldown, once_per_device,
    /// app_listener, …). Same pattern, at most 80.
    package var reason: String?
    /// Which re-check of a pending polygon this was, 0 to 20.
    package var recheckAttempt: Int?
    package var sessionId: String?
    /// Device clock, unix milliseconds.
    package var tsMillis: Int64
    /// Already uploaded (or given up on): kept in the buffer for diagnostics, never sent again.
    package var sent = false

    /// Tracking sessions have no region: they're logged under this name.
    package static let trackingRegion = "tracking"
    package static let maxRegionId = 64
    package static let maxResult = 40
    package static let maxReason = 80
    package static let maxSessionId = 64
    package static let maxRecheck = 20

    package init(
        id: String = UUID().uuidString.lowercased(), regionId: String, event: String, result: String, reason: String? = nil,
        fixAgeMs: Int64? = nil, fixAccuracyM: Double? = nil, recheckAttempt: Int? = nil, sessionId: String? = nil, tsMillis: Int64
    ) {
        self.id = id
        self.regionId = regionId
        self.event = event
        self.result = result
        self.reason = reason
        self.fixAgeMs = fixAgeMs
        self.fixAccuracyM = fixAccuracyM
        self.recheckAttempt = recheckAttempt
        self.sessionId = sessionId
        self.tsMillis = tsMillis
    }

    /// `text` as a result or reason: lower case, anything outside a-z 0-9 _ . : - becomes "_", cut to `limit`.
    package static func slug(_ text: String, limit: Int) -> String {
        let mapped = text.lowercased().unicodeScalars.map { scalar -> Character in
            let ok = scalar.isASCII && (CharacterSet.lowercaseLetters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || "_.:-".unicodeScalars.contains(scalar))
            return ok ? Character(scalar) : "_"
        }
        return String(mapped.prefix(limit))
    }

    /// The entry made to fit the contract's rules, whatever was passed in.
    package func clamped() -> GeofenceDecision {
        var copy = self
        copy.regionId = String(regionId.prefix(Self.maxRegionId))
        copy.event = event == "exit" ? "exit" : "enter"
        copy.result = Self.slug(result, limit: Self.maxResult)
        copy.reason = reason.map { Self.slug($0, limit: Self.maxReason) }.flatMap { $0.isEmpty ? nil : $0 }
        copy.fixAgeMs = fixAgeMs.map { max(0, $0) }
        copy.fixAccuracyM = fixAccuracyM.flatMap { $0.isFinite ? max(0, $0) : nil }
        copy.recheckAttempt = recheckAttempt.map { min(max(0, $0), Self.maxRecheck) }
        copy.sessionId = sessionId.map { String($0.prefix(Self.maxSessionId)) }
        return copy
    }

    /// The event's `data` object on POST /events (optional fields left out when absent).
    package var eventData: [String: JSONValue] {
        var data: [String: JSONValue] = [
            "region_id": .string(regionId), "event": .string(event), "result": .string(result),
            "ts": .string(EventQueue.isoTimestamp(tsMillis)),
        ]
        if let reason { data["reason"] = .string(reason) }
        if let fixAgeMs { data["fix_age_ms"] = .int(fixAgeMs) }
        if let fixAccuracyM { data["fix_accuracy_m"] = .double(fixAccuracyM) }
        if let recheckAttempt { data["recheck_attempt"] = .int(Int64(recheckAttempt)) }
        if let sessionId { data["session_id"] = .string(sessionId) }
        return data
    }

    /// One line for a tester to read in Diagnostics (no Xcode needed).
    package var summary: String {
        let time = EventQueue.isoTimestamp(tsMillis)
        var parts = ["\(time) \(event) \(regionId.prefix(8)) \(result)"]
        if let reason { parts.append("(\(reason))") }
        if let fixAgeMs { parts.append("age=\(fixAgeMs)ms") }
        if let fixAccuracyM { parts.append("acc=\(Int(fixAccuracyM))m") }
        if let recheckAttempt { parts.append("recheck=\(recheckAttempt)") }
        return parts.joined(separator: " ")
    }
}

/// The last geofence sync, for Diagnostics: when, what set it off (push, open, refresh), how many
/// regions are watched and what location permission there was.
package struct GeofenceSyncInfo: Codable, Sendable, Equatable {
    package var atMillis: Int64
    package var trigger: String
    package var regions: Int
    package var permission: String

    package init(atMillis: Int64, trigger: String, regions: Int, permission: String) {
        self.atMillis = atMillis
        self.trigger = trigger
        self.regions = regions
        self.permission = permission
    }

    package var summary: String {
        "\(EventQueue.isoTimestamp(atMillis)) trigger=\(trigger) regions=\(regions) permission=\(permission)"
    }
}

/// What the decision log keeps on disk: the entries, the last sync, and when uploading may try again.
package struct DecisionLogState: Codable, Sendable, Equatable {
    package var entries: [GeofenceDecision] = []
    package var lastSync: GeofenceSyncInfo?
    /// Device unix seconds before which nothing is uploaded (the server refused the type).
    package var holdUntilSeconds: Int64 = 0

    package init(entries: [GeofenceDecision] = [], lastSync: GeofenceSyncInfo? = nil, holdUntilSeconds: Int64 = 0) {
        self.entries = entries
        self.lastSync = lastSync
        self.holdUntilSeconds = holdUntilSeconds
    }
}

/// The last `capacity` geofence decisions, kept on disk so they survive the process being killed
/// (a closed-app wake is a short life) and uploaded later. A write is one small atomic file.
/// A file that can't be read yet (before the first unlock) loses the entry rather than blocking.
package final class DecisionLog: Sendable {
    package static let capacity = 100

    private let store: any ValueStore<DecisionLogState>
    private let lock = NSLock()
    private let capacity: Int
    private let session = SessionBox()

    private final class SessionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var id: String?
        var value: String? {
            get { lock.sync { id } }
            set { lock.sync { id = newValue } }
        }
    }

    /// The live tracking session running now (this process): decisions made during it carry its id.
    package var currentSessionId: String? {
        get { session.value }
        set { session.value = newValue }
    }

    package init(store: any ValueStore<DecisionLogState>, capacity: Int = DecisionLog.capacity) {
        self.store = store
        self.capacity = capacity
    }

    package func record(_ decision: GeofenceDecision) {
        var entry = decision
        if entry.sessionId == nil, entry.regionId != GeofenceDecision.trackingRegion { entry.sessionId = currentSessionId }
        change { $0.entries = Array(($0.entries + [entry.clamped()]).suffix(self.capacity)) }
    }

    package func recordSync(_ info: GeofenceSyncInfo) {
        change { $0.lastSync = info }
    }

    /// The last `count` decisions, oldest first.
    package func recent(_ count: Int = 5) -> [GeofenceDecision] { Array(state().entries.suffix(max(count, 0))) }

    package var all: [GeofenceDecision] { state().entries }
    package var lastSync: GeofenceSyncInfo? { state().lastSync }
    package var holdUntilSeconds: Int64 { state().holdUntilSeconds }

    /// Decisions not yet uploaded, oldest first. Tracking-session entries stay on the device (the
    /// server's region_id is a location id): buffer and Diagnostics only.
    package func unsent(limit: Int) -> [GeofenceDecision] {
        Array(state().entries.filter { !$0.sent && $0.regionId != GeofenceDecision.trackingRegion }.prefix(max(limit, 0)))
    }

    /// Marks `ids` uploaded (or given up on), and, for a refusal, holds uploads until `holdUntilSeconds`.
    package func markSent(_ ids: Set<String>, holdUntilSeconds: Int64? = nil) {
        change { state in
            for index in state.entries.indices where ids.contains(state.entries[index].id) { state.entries[index].sent = true }
            if let holdUntilSeconds { state.holdUntilSeconds = holdUntilSeconds }
        }
    }

    /// Forget everything (opt-out, deleteMyData).
    package func clear() { lock.sync { _ = try? store.delete() } }

    private func state() -> DecisionLogState {
        lock.sync { ((try? store.load()) ?? nil) ?? DecisionLogState() }
    }

    private func change(_ body: (inout DecisionLogState) -> Void) {
        lock.sync {
            // Unreadable (locked): not overwritten, the change is lost.
            guard let loaded = try? store.load() ?? DecisionLogState() else { return }
            var state = loaded
            body(&state)
            _ = try? store.save(state)
        }
    }
}

/// The log level the host set at its last start, kept so an app woken in the background (no
/// Flutter or React Native engine, hence no `start` call yet) logs at that level rather than warning.
package struct LogLevelMemory: Sendable {
    private let store: any ValueStore<String>

    package init(store: any ValueStore<String>) { self.store = store }

    package func remember(_ level: String) { try? store.save(level) }
    package func recall() -> String? { (try? store.load()) ?? nil }
}
