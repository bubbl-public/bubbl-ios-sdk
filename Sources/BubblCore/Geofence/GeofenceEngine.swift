import Foundation

/// A circle for the OS to watch, for both entering and leaving.
package struct WatchedRegion: Sendable, Hashable {
    package let id: String
    package let center: LatLng
    package let radiusMeters: Double

    package init(_ id: String, _ center: LatLng, _ radiusMeters: Double) {
        self.id = id
        self.center = center
        self.radiusMeters = radiusMeters
    }
}

/// The OS's region monitoring (CoreLocation on iOS).
package protocol RegionMonitor: Sendable {
    /// How many regions Bubbl may watch now: the OS's limit less what the app itself and other
    /// SDKs watch (iOS allows 20 per app, all told).
    func capacity() async -> Int

    /// Watch exactly `regions`, replacing whatever Bubbl watched before. True once they're being
    /// watched (or deliberately aren't: location only while in use); false when the OS refused.
    func watch(_ regions: [WatchedRegion]) async -> Bool

    func stop() async

    /// Bubbl's region names the OS can't watch on this device, so others are picked in their place.
    func excluded() async -> Set<String>
}

extension RegionMonitor {
    package func excluded() async -> Set<String> { [] }
}

/// The device entered or left a geofence: to send to POST /geofence-events.
package struct Transition: Sendable, Hashable, Codable {
    /// Sent as Idempotency-Key, so a retry gets the first answer instead of counting twice.
    package let key: String
    package let locationId: String
    package let enter: Bool
    /// On the server's clock.
    package let occurredAtMillis: Int64
    package let fix: Fix?

    package init(key: String, locationId: String, enter: Bool, occurredAtMillis: Int64, fix: Fix?) {
        self.key = key
        self.locationId = locationId
        self.enter = enter
        self.occurredAtMillis = occurredAtMillis
        self.fix = fix
    }
}

package enum RefreshResult: Sendable, Equatable {
    /// A new set of geofences is being watched.
    case updated(geofences: Int)
    /// The server's set hadn't changed (304); watching goes on from the new position.
    case unchanged
    /// Not time to ask again yet (the nearest geofences may still have been picked afresh).
    case notDue
    case failed(ApiFailure)
}

package enum SendResult: Sendable, Equatable {
    /// The server recorded it; `notifications` are to be shown now (often none).
    case delivered(notifications: [JSONValue])
    /// Given up on: too old to send, or refused for good.
    case dropped(reason: String)
    case failed(ApiFailure)
}

/// What a region event or a location fix led to, for the platform layer to act on.
package struct Outcome: Sendable, Equatable {
    package var transitions: [Transition] = []
    /// The device has left the area its geofences were picked for: refresh now.
    package var refresh = false
    /// A polygon's circle was entered without a fix good enough to check the polygon: get one.
    package var needsFix = false

    package init(transitions: [Transition] = [], refresh: Bool = false, needsFix: Bool = false) {
        self.transitions = transitions
        self.refresh = refresh
        self.needsFix = needsFix
    }
}

/// The geofencing logic, free of iOS: which geofences to watch and when to ask for new ones
/// (GET /geofences), turning the OS's circle events and location fixes into enter and exit
/// transitions (checking polygons on the device), and sending them (POST /geofence-events). The
/// same engine as Android's, with iOS's region budget.
///
/// The OS watches the nearest geofences' circles, as many as the budget allows, plus one more
/// around where the device was (REFRESH_REGION_ID): leaving it means picking again, and asking
/// the server again once the device is refresh_distance_meters from where it last asked. When
/// geofences had to be left out, that region stops short of the nearest one left out, so the
/// device re-picks before it could get there. The server's refresh_seconds covers a device
/// that stays put.
///
/// Transitions are checked against GeofenceState, so the OS saying "entered" twice is reported
/// once. Every decision about what to show (cooldowns, trigger limits, quiet hours) is the
/// server's. Methods throw when the state can't be read yet (GeofenceStateUnavailable).
package final class GeofenceEngine: Sendable {
    /// Every region Bubbl asks the OS to watch is named with this prefix, so the platform layer
    /// can tell Bubbl's from the app's own and other SDKs' (iOS's 20 are shared).
    package static let regionPrefix = "bubbl."
    package static let refreshRegionId = regionPrefix + "refresh"
    /// A fix vaguer than this can't place the device inside or outside a polygon.
    package static let maxPolygonAccuracyMeters = 100.0
    /// …nor one older than this (iOS reports entering a region without a location, and the last
    /// known one can be minutes old).
    package static let maxPolygonFixAgeMillis: Int64 = 2 * 60 * 1000
    /// …nor a circle, when the SDK decides entering and leaving itself.
    package static let maxCircleAccuracyMeters = 200.0
    /// The server keeps an Idempotency-Key's answer for a day; stop retrying before then.
    package static let maxSendAgeMillis: Int64 = 23 * 60 * 60 * 1000
    /// The smallest refresh region worth watching (iOS is unreliable below about 100 m).
    package static let minWatchRadiusMeters = 100.0

    private let api: DeviceApiClient
    private let clock: ServerClock
    private let store: any GeofenceStateStore
    private let monitor: any RegionMonitor
    private let newKey: @Sendable () -> String
    private let stateLock = AsyncMutex()
    private let refreshing = AsyncMutex()

    package init(
        api: DeviceApiClient,
        clock: ServerClock,
        store: any GeofenceStateStore,
        monitor: any RegionMonitor,
        newKey: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.api = api
        self.clock = clock
        self.store = store
        self.monitor = monitor
        self.newKey = newKey
    }

    /// Fetch geofences for `fix` if there are none yet, the set is older than its
    /// refresh_seconds, the device has moved refresh_distance_meters from where it asked, or
    /// `force`; then watch the nearest. When a fetch isn't due but the device has left the
    /// region its nearest geofences were picked for, they're picked again around it.
    package func refresh(_ fix: Fix, force: Bool = false) async throws -> RefreshResult {
        try await refreshing.withLock { try await self.refreshLocked(fix, force: force) }
    }

    private func refreshLocked(_ fix: Fix, force: Bool) async throws -> RefreshResult {
        let saved = try await stateLock.withLock { try self.store.load() }

        if !force, let current = saved.set, !isDue(current, fix.position) {
            if Self.leftWatchRegion(saved, fix) {
                _ = try await watchSaved(around: fix.position)
            }
            return .notDue
        }

        let response: ApiResponse
        do {
            response = try await api.request(
                "GET", "api/v1/geofences",
                query: ["latitude": Self.coordinate(fix.position.latitude), "longitude": Self.coordinate(fix.position.longitude)],
                headers: saved.set?.etag.map { ["If-None-Match": $0] } ?? [:]
            )
        } catch {
            return .failed(.backoff)
        }

        let now = clock.nowSeconds()
        let set: GeofenceSet
        let result: RefreshResult
        if response.status == 304, var current = saved.set {
            current.origin = fix.position
            current.fetchedAtSeconds = now
            set = current
            result = .unchanged
        } else if response.status == 200 {
            guard let fetched = GeofenceSet.fromResponse(Data(response.body.utf8), origin: fix.position, fetchedAtSeconds: now, etag: response.header("ETag")) else {
                return .failed(.backoff)
            }
            set = fetched
            result = .updated(geofences: fetched.geofences.count)
        } else if response.isSuccessful {
            return .failed(.backoff)
        } else {
            return .failed(ApiFailure.of(response))
        }

        try await stateLock.withLock {
            let state = try self.store.load()
            let ids = Set(set.geofences.map(\.id))
            // Geofences no longer in the set are forgotten, not reported as left.
            try self.store.save(GeofenceState(
                set: set,
                insideCircles: state.insideCircles.intersection(ids),
                insidePolygons: state.insidePolygons.intersection(ids),
                watching: false
            ))
        }
        _ = try await watchSaved(around: fix.position)
        return result
    }

    /// Watch the saved geofences if the OS hasn't taken them on yet (a watch cut short, or one it
    /// refused). Every check calls this, so geofencing mends itself. True when they're watched.
    package func ensureWatching() async throws -> Bool {
        let state = try await stateLock.withLock { try self.store.load() }
        guard let set = state.set else { return false }
        if state.watching { return true }
        return try await watchSaved(around: state.watchCenter ?? set.origin)
    }

    /// The OS dropped or refused Bubbl's regions (a reboot, location switched off, iOS's
    /// monitoringDidFailFor): watch them again now.
    package func rewatch() async throws -> Bool {
        try await watchFailed()
        return try await ensureWatching()
    }

    /// The OS couldn't watch a region: the next check watches everything again.
    package func watchFailed() async throws {
        try await stateLock.withLock {
            var state = try self.store.load()
            state.watching = false
            try self.store.save(state)
        }
    }

    private func watchSaved(around center: LatLng) async throws -> Bool {
        guard let set = try await stateLock.withLock({ try self.store.load().set }) else { return false }
        let picked = Self.regions(set, around: center, capacity: await monitor.capacity(), excluding: await monitor.excluded())
        let watched = await monitor.watch(picked.regions)

        try await stateLock.withLock {
            var state = try self.store.load()
            // Only if the set is still the one just watched (a refresh may have replaced it).
            guard state.set == set else { return }
            state.watching = watched
            state.watchCenter = center
            state.watchRadiusMeters = picked.radius
            try self.store.save(state)
        }
        return watched
    }

    /// The OS region name for a geofence.
    package static func regionId(for geofenceId: String) -> String { regionPrefix + geofenceId }

    /// The OS says the device entered (or left) the regions `regionIds` (the names Bubbl gave
    /// them; others are ignored), at `deviceTimeMillis`, with the latest fix when there is one.
    package func onRegionEvent(_ regionIds: [String], entered: Bool, fix: Fix?, deviceTimeMillis: Int64) async throws -> Outcome {
        let ids = regionIds.compactMap { id -> String? in
            if id == Self.refreshRegionId { return id }
            guard id.hasPrefix(Self.regionPrefix) else { return nil }
            return String(id.dropFirst(Self.regionPrefix.count))
        }
        return try await transitions(ids, entered: entered, fix: fix, deviceTimeMillis: deviceTimeMillis)
    }

    /// onRegionEvent with geofence ids (and the refresh region's name) rather than OS names.
    private func transitions(_ regionIds: [String], entered: Bool, fix: Fix?, deviceTimeMillis: Int64) async throws -> Outcome {
        try await stateLock.withLock {
            var state = try self.store.load()
            guard let set = state.set else { return Outcome() }
            let byId = Dictionary(set.geofences.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var outcome = Outcome()

            for id in regionIds {
                if id == Self.refreshRegionId {
                    outcome.refresh = outcome.refresh || !entered
                    continue
                }
                guard let geofence = byId[id] else { continue }

                if entered {
                    guard !state.insideCircles.contains(id) else { continue }
                    state.insideCircles.insert(id)
                    if !geofence.isPolygon {
                        if geofence.reportsEnter { outcome.transitions.append(self.transition(geofence, enter: true, deviceTimeMillis, fix)) }
                    } else if fix.map({ Self.canCheckPolygon($0, at: deviceTimeMillis) }) != true {
                        outcome.needsFix = true
                    }
                } else {
                    guard state.insideCircles.contains(id) else { continue }
                    state.insideCircles.remove(id)
                    let wasInside = !geofence.isPolygon || state.insidePolygons.contains(id)
                    state.insidePolygons.remove(id)
                    if wasInside && geofence.reportsExit { outcome.transitions.append(self.transition(geofence, enter: false, deviceTimeMillis, fix)) }
                }
            }

            // Polygons whose circle the device is in are checked against the fix, if it's good enough.
            if let fix, Self.canCheckPolygon(fix, at: deviceTimeMillis) {
                self.checkPolygons(&state, byId, fix, deviceTimeMillis, &outcome.transitions)
            }

            try self.store.save(state)
            return outcome
        }
    }

    /// A location fix from anywhere (significant changes, a fix asked for): re-checks polygons.
    package func onFix(_ fix: Fix) async throws -> Outcome {
        try await stateLock.withLock {
            var state = try self.store.load()
            guard let set = state.set else { return Outcome(refresh: true) }
            var transitions: [Transition] = []

            if Self.canCheckPolygon(fix, at: fix.timeMillis) {
                self.checkPolygons(&state, Dictionary(set.geofences.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }), fix, fix.timeMillis, &transitions)
                try self.store.save(state)
            }
            // Leaving the watch region is also caught here: significant-change fixes back up a
            // small refresh region iOS may not fire for.
            return Outcome(transitions: transitions, refresh: self.isDue(set, fix.position) || Self.leftWatchRegion(state, fix))
        }
    }

    /// A fix when the OS isn't watching the geofences (the user allowed location only while the
    /// app is in use): entering and leaving are worked out here, from the fix. A fix vaguer than
    /// maxCircleAccuracyMeters decides nothing; leaving needs the device clearly outside (by more
    /// than the fix's accuracy), so a jittery fix at the edge doesn't flap in and out.
    package func onFixWithoutOs(_ fix: Fix) async throws -> Outcome {
        let state = try await stateLock.withLock { try self.store.load() }
        guard let set = state.set else { return Outcome(refresh: true) }
        guard let accuracy = fix.accuracyMeters, accuracy <= Self.maxCircleAccuracyMeters else {
            return Outcome(refresh: isDue(set, fix.position))
        }

        let entered = set.geofences.filter {
            !state.insideCircles.contains($0.id) && Geo.distanceMeters($0.center, fix.position) <= Double($0.radiusMeters)
        }.map(\.id)
        let left = set.geofences.filter {
            state.insideCircles.contains($0.id) && Geo.distanceMeters($0.center, fix.position) - accuracy > Double($0.radiusMeters)
        }.map(\.id)

        let leaving = try await transitions(left, entered: false, fix: fix, deviceTimeMillis: fix.timeMillis)
        let entering = try await transitions(entered, entered: true, fix: fix, deviceTimeMillis: fix.timeMillis)
        return Outcome(transitions: leaving.transitions + entering.transitions, refresh: isDue(set, fix.position), needsFix: entering.needsFix)
    }

    /// POST /geofence-events for `transition`. Safe to call again for the same one.
    package func send(_ transition: Transition) async -> SendResult {
        if clock.nowSeconds() * 1000 - transition.occurredAtMillis > Self.maxSendAgeMillis {
            BubblLog.info("A geofence \(transition.enter ? "entry" : "exit") for \(transition.locationId) was given up on: too old to send")
            return .dropped(reason: "stale")
        }

        struct Body: Encodable {
            let location_id: String
            let event: String
            let occurred_at: String
            let latitude: Double?
            let longitude: Double?
            let accuracy_meters: Double?
        }
        let body = Body(
            location_id: transition.locationId,
            event: transition.enter ? "enter" : "exit",
            occurred_at: EventQueue.isoTimestamp(transition.occurredAtMillis),
            latitude: transition.fix?.position.latitude,
            longitude: transition.fix?.position.longitude,
            accuracy_meters: transition.fix?.accuracyMeters
        )

        let response: ApiResponse
        do {
            let json = String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
            response = try await api.request("POST", "api/v1/geofence-events", body: json, headers: ["Idempotency-Key": transition.key])
        } catch {
            // Offline, or the Keychain not readable yet: try again later.
            return .failed(.backoff)
        }

        if (200...299).contains(response.status) {
            struct Delivered: Decodable {
                let data: Notifications
                struct Notifications: Decodable { let notifications: [JSONValue]? }
            }
            return .delivered(notifications: response.decode(Delivered.self)?.data.notifications ?? [])
        }

        let failure = ApiFailure.of(response)
        guard case .drop(let refreshGeofences, let status, let code) = failure else { return .failed(failure) }
        // The location has gone from the workspace: the next refresh fetches the set again.
        if refreshGeofences { try? await markStale() }
        BubblLog.warning("A geofence \(transition.enter ? "entry" : "exit") for \(transition.locationId) was refused: HTTP \(status) \(code ?? "")")
        return .dropped(reason: code ?? "http_\(status)")
    }

    /// Stop watching and forget everything (opt-out, deleteMyData, stop).
    package func stop() async throws {
        await monitor.stop()
        try await stateLock.withLock { try self.store.save(GeofenceState()) }
    }

    /// How many geofences the engine has (not counting its refresh region).
    package func geofenceCount() async throws -> Int {
        try await stateLock.withLock { try self.store.load().set?.geofences.count ?? 0 }
    }

    /// What should be watched now, e.g. to compare with what the OS has after a relaunch.
    package func watchedRegions() async throws -> [WatchedRegion] {
        let state = try await stateLock.withLock { try self.store.load() }
        guard let set = state.set else { return [] }
        return Self.regions(set, around: state.watchCenter ?? set.origin, capacity: await monitor.capacity(), excluding: await monitor.excluded()).regions
    }

    /// The geofences whose edges are nearest `center`, as many as fit in `capacity`, plus the
    /// refresh region. When some are left out, the refresh region stops short of the nearest
    /// edge among them, so the device picks again before it could reach one unwatched. Region
    /// names in `excluding` (ones the OS can't watch) are passed over for the next nearest.
    package static func regions(_ set: GeofenceSet, around center: LatLng, capacity: Int, excluding: Set<String> = []) -> (regions: [WatchedRegion], radius: Double?) {
        guard capacity > 0 else { return ([], nil) }

        // Distance to the edge, not the centre: a big geofence far off can be closer than a
        // small one nearby.
        let byEdge = set.geofences
            .filter { !excluding.contains(regionId(for: $0.id)) }
            .map { (geofence: $0, edge: max(0, Geo.distanceMeters(center, $0.center) - Double($0.radiusMeters))) }
            .sorted { ($0.edge, $0.geofence.id) < ($1.edge, $1.geofence.id) }
        let kept = byEdge.prefix(capacity - 1)
        let leftOut = byEdge.dropFirst(kept.count)

        var radius = Double(set.refreshDistanceMeters)
        if let nearestLeftOut = leftOut.map(\.edge).min() {
            radius = min(radius, max(minWatchRadiusMeters, nearestLeftOut))
        }

        let regions = kept.map { WatchedRegion(regionId(for: $0.geofence.id), $0.geofence.center, Double($0.geofence.radiusMeters)) }
        return (regions + [WatchedRegion(refreshRegionId, center, radius)], radius)
    }

    private func checkPolygons(_ state: inout GeofenceState, _ byId: [String: Geofence], _ fix: Fix, _ deviceTimeMillis: Int64, _ transitions: inout [Transition]) {
        for id in state.insideCircles.sorted() {
            guard let geofence = byId[id], let ring = geofence.polygon else { continue }
            let nowInside = Geo.contains(ring, fix.position)
            if nowInside && !state.insidePolygons.contains(id) {
                state.insidePolygons.insert(id)
                if geofence.reportsEnter { transitions.append(transition(geofence, enter: true, deviceTimeMillis, fix)) }
            } else if !nowInside && state.insidePolygons.contains(id) {
                state.insidePolygons.remove(id)
                if geofence.reportsExit { transitions.append(transition(geofence, enter: false, deviceTimeMillis, fix)) }
            }
        }
    }

    private func markStale() async throws {
        try await stateLock.withLock {
            var state = try self.store.load()
            guard state.set != nil else { return }
            state.set?.fetchedAtSeconds = 0
            try self.store.save(state)
        }
    }

    private func transition(_ geofence: Geofence, enter: Bool, _ deviceTimeMillis: Int64, _ fix: Fix?) -> Transition {
        Transition(key: newKey(), locationId: geofence.id, enter: enter, occurredAtMillis: deviceTimeMillis + clock.offsetSeconds * 1000, fix: fix)
    }

    private func isDue(_ set: GeofenceSet, _ position: LatLng) -> Bool {
        clock.nowSeconds() - set.fetchedAtSeconds >= set.refreshSeconds ||
            Geo.distanceMeters(set.origin, position) >= Double(set.refreshDistanceMeters)
    }

    /// Clearly outside the region the nearest geofences were picked for (by more than the fix's
    /// accuracy, as for leaving a geofence): time to pick again. A rough fix (a cell tower's,
    /// kilometres wide) or one without an accuracy isn't clearly anywhere.
    private static func leftWatchRegion(_ state: GeofenceState, _ fix: Fix) -> Bool {
        guard let center = state.watchCenter, let radius = state.watchRadiusMeters, let accuracy = fix.accuracyMeters else { return false }
        return Geo.distanceMeters(center, fix.position) - accuracy >= radius
    }

    /// Whether `fix` can say which side of a polygon's edge the device is: precise enough, and
    /// taken no more than maxPolygonFixAgeMillis before `deviceTimeMillis` (nor after it).
    private static func canCheckPolygon(_ fix: Fix, at deviceTimeMillis: Int64) -> Bool {
        let age = deviceTimeMillis - fix.timeMillis
        return (fix.accuracyMeters ?? .greatestFiniteMagnitude) <= maxPolygonAccuracyMeters &&
            age >= 0 && age <= maxPolygonFixAgeMillis
    }

    /// Six decimal places is about 10 cm.
    private static func coordinate(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}
