#if os(iOS)
import CoreLocation
import Foundation
#if !COCOAPODS
import BubblCore
#endif

/// What the user allowed, as far as geofences go.
@available(iOS 17, *)
enum LocationAccess: Sendable, Equatable {
    /// No location, or only approximate (iOS doesn't monitor conditions without precise location,
    /// and an approximate fix can't place the device in or out of a geofence).
    case none
    /// While the app is in use: geofences are checked from fixes while it's open.
    case whenInUse
    /// Always: iOS watches the geofences and relaunches the app for them.
    case always
}

/// CoreLocation for the engine, as Android's PlayServicesRegionMonitor and receivers:
///  - Bubbl's circles (named "bubbl.…") watched as CLMonitor conditions (ConditionWatcher), plus
///    significant location changes; both relaunch the app in the background, and neither needs
///    the location background mode. iOS's 20 are shared with the app and other SDKs: what Bubbl
///    asks for is lowered when iOS refuses some as over the limit (RegionBudget);
///  - one-off fixes (for a check, or a polygon), and fixes while the app is open when iOS isn't
///    watching ("While Using" only, or no condition monitoring on the device), from which the
///    engine decides entering and leaving itself;
///  - on iOS 18+, a CLServiceSession for "Always" while geofences are watched, so their events
///    arrive in the background.
/// Created on the main thread at start, so events that relaunched the app are delivered to it.
@available(iOS 17, *)
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    /// Significant location changes and permission; also sees the app's own regions (the older
    /// API's), which count against the 20.
    private let changes = CLLocationManager()
    /// One-off fixes.
    private let oneShot = CLLocationManager()
    /// Fixes while the app is open and iOS isn't watching the geofences.
    private let inUse = CLLocationManager()
    private var waiting: [CheckedContinuation<Fix?, Never>] = []
    /// Which request for a fix is outstanding, so an earlier one's timeout can't end a later one.
    private var fixRequest = 0
    private var updatingInUse = false
    private var saidWhy: Set<String> = []
    /// The access last seen, so only a change is acted on (iOS reports it once at every launch too).
    private var knownAccess: LocationAccess?
    private var budget = RegionBudget()
    /// iOS can't monitor Bubbl's conditions on this device (none of them, or not the refresh one).
    private var cantWatch = false
    /// iOS 18+: the CLServiceSession held while geofences are watched.
    private var session: AnyObject?

    private static let fixTimeoutSeconds: UInt64 = 20

    override private init() {
        super.init()
        for manager in [changes, oneShot, inUse] { manager.delegate = self }
        inUse.desiredAccuracy = kCLLocationAccuracyHundredMeters
        inUse.distanceFilter = 20
        inUse.pausesLocationUpdatesAutomatically = true
    }

    /// Makes sure the managers exist, the service session is held and CLMonitor's events are
    /// listened to: an app relaunched for a geofence gets the event only then.
    func activate() {
        // Regions an older build watched with the region API, which Bubbl no longer uses.
        for region in changes.monitoredRegions where region.identifier.hasPrefix(GeofenceEngine.regionPrefix) {
            changes.stopMonitoring(for: region)
        }
        holdSession()
        Task { await ConditionWatcher.shared.listen() }
    }

    var access: LocationAccess {
        switch changes.authorizationStatus {
        case .authorizedAlways where changes.accuracyAuthorization == .fullAccuracy: return .always
        case .authorizedWhenInUse where changes.accuracyAuthorization == .fullAccuracy: return .whenInUse
        case .authorizedAlways, .authorizedWhenInUse:
            explain("Precise location is off for this app: geofences need it")
            return .none
        default: return .none
        }
    }

    /// iOS watches the geofences. Otherwise entering and leaving are decided from fixes: while the
    /// app is open, and with "Always" from significant location changes too, which still relaunch
    /// the app (Android's approach when the OS won't watch).
    var osWatches: Bool { access == .always && !cantWatch }

    /// The freshest fix CoreLocation has, if any.
    var lastFix: Fix? {
        [oneShot.location, inUse.location, changes.location].compactMap { $0 }.max { $0.timestamp < $1.timestamp }.map(Fix.init)
    }

    // MARK: - RegionMonitor

    /// iOS's 20 less the app's own regions (those it can see), within what iOS has let Bubbl have.
    func capacity() -> Int {
        guard !cantWatch else { return 0 }
        let others = changes.monitoredRegions.filter { !$0.identifier.hasPrefix(GeofenceEngine.regionPrefix) }.count
        return budget.capacity(othersVisible: others)
    }

    /// Watch exactly `wanted` with "Always" (otherwise nothing: fixes decide while the app is
    /// open), each radius between 100 m (iOS is unreliable below) and iOS's maximum.
    func watch(_ wanted: [WatchedRegion]) async -> Bool {
        guard access == .always else {
            await stopWatching()
            if access == .whenInUse { explain("Location only while in use: geofences are checked while the app is open") }
            return true
        }
        holdSession()
        changes.startMonitoringSignificantLocationChanges()
        guard !cantWatch else {
            // Nothing iOS can watch here: significant changes bring the fixes that decide.
            await ConditionWatcher.shared.removeAll()
            return true
        }

        let limit = changes.maximumRegionMonitoringDistance
        let regions = wanted.map { WatchedRegion($0.id, $0.center, Self.radius($0.radiusMeters, limit: limit)) }
        budget.watching(regions.map(\.id))
        await ConditionWatcher.shared.watch(regions)
        BubblLog.debug("Watching \(regions.count) geofence conditions")
        return true
    }

    static func radius(_ meters: Double, limit: CLLocationDistance) -> Double {
        let capped = limit > 0 ? min(meters, limit) : meters
        return max(GeofenceEngine.minWatchRadiusMeters, capped)
    }

    func stopWatching() async {
        await ConditionWatcher.shared.removeAll()
        changes.stopMonitoringSignificantLocationChanges()
        releaseSession()
    }

    func stopAll() async {
        stopInUseUpdates()
        await stopWatching()
    }

    // MARK: - What CLMonitor reports

    /// iOS isn't watching `id` because the app is over its 20: ask for fewer from now on.
    func overLimit(_ id: String) {
        guard budget.overLimit(id) else { return }
        explain("iOS's 20 geofences are shared with the app and other SDKs: Bubbl watches fewer (\(budget.cap) now)", key: "overLimit")
        EngineHost.shared.watchFailed()
        EngineHost.shared.checkGeofences(rewatch: true)
    }

    /// Bubbl's conditions iOS can't monitor here: the engine picks the next nearest instead.
    func excluded() -> Set<String> { budget.excluded }

    /// iOS can't monitor `id` at all: that one is left out (for good, and the next nearest is
    /// watched in its place), unless none can be watched here.
    func unsupported(_ id: String) {
        switch budget.unsupported(id, refreshRegionId: GeofenceEngine.refreshRegionId) {
        case nil:
            return
        case .dropOne:
            BubblLog.warning("iOS can't watch one geofence: another is watched in its place")
            Task { await ConditionWatcher.shared.remove(id) }
            EngineHost.shared.watchFailed()
            EngineHost.shared.checkGeofences(rewatch: true)
        case .deviceCantWatch:
            guard !cantWatch else { return }
            cantWatch = true
            explain("iOS can't watch geofences on this device: they're checked from location changes")
            EngineHost.shared.checkGeofences(rewatch: true)
        }
    }

    /// iOS stopped watching `id` for another reason (`why`, on iOS 18+): watched again at the next check.
    func unmonitored(_ id: String, why: String) {
        BubblLog.warning("CoreLocation isn't watching a geofence\(why)")
        EngineHost.shared.watchFailed()
    }

    // MARK: - Fixes

    /// A fix now: the last one if recent enough (30 s and within 100 m when `precise`, for a
    /// polygon; 5 min otherwise), else a fresh one. Nil without permission or within 20 s.
    func currentFix(precise: Bool) async -> Fix? {
        guard access != .none else { return nil }
        let maxAge: TimeInterval = precise ? 30 : 300
        for candidate in [oneShot.location, inUse.location, changes.location].compactMap({ $0 }) {
            if -candidate.timestamp.timeIntervalSinceNow <= maxAge && (!precise || (0...GeofenceEngine.maxPolygonAccuracyMeters).contains(candidate.horizontalAccuracy)) {
                return Fix(candidate)
            }
        }

        oneShot.desiredAccuracy = precise ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            guard waiting.count == 1 else { return }
            fixRequest += 1
            let request = fixRequest
            oneShot.requestLocation()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.fixTimeoutSeconds * 1_000_000_000)
                if self.fixRequest == request { self.deliver(nil) }
            }
        }
    }

    /// While the app is open and iOS isn't watching the geofences: fixes every 20 m or so.
    func startInUseUpdates() {
        guard access != .none, !osWatches, !updatingInUse else { return }
        updatingInUse = true
        inUse.startUpdatingLocation()
    }

    func stopInUseUpdates() {
        guard updatingInUse else { return }
        updatingInUse = false
        inUse.stopUpdatingLocation()
    }

    // MARK: - CLLocationManagerDelegate (on the main thread, where the managers were made)

    // Only Sendable values cross into the main actor: a Fix, the manager's identity.

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last.map(Fix.init) else { return }
        let from = ObjectIdentifier(manager)
        MainActor.assumeIsolated {
            if from == ObjectIdentifier(oneShot) {
                deliver(fix)
            } else if from == ObjectIdentifier(inUse) {
                EngineHost.shared.locationFix(fix, osWatches: false)
            } else {
                // A significant change: fresher polygons, and whether to pick or fetch again (or,
                // where iOS can't watch, whether a geofence was entered or left).
                EngineHost.shared.locationFix(fix, osWatches: osWatches)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        let from = ObjectIdentifier(manager)
        MainActor.assumeIsolated {
            if from == ObjectIdentifier(oneShot) { deliver(nil) }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let from = ObjectIdentifier(manager)
        MainActor.assumeIsolated {
            guard from == ObjectIdentifier(changes) else { return }
            let now = access
            defer { knownAccess = now }
            guard let before = knownAccess, before != now else { return }
            if now != .always { releaseSession() }
            if now == .none || osWatches { stopInUseUpdates() }
            EngineHost.shared.locationAccessChanged(now)
        }
    }

    // MARK: -

    /// iOS 18+: "Always" declared for as long as geofences are watched. Only once it's granted:
    /// a session asking for it before then would put up the system prompt.
    private func holdSession() {
        guard #available(iOS 18, *), session == nil, access == .always else { return }
        session = CLServiceSession(authorization: .always)
    }

    private func releaseSession() {
        guard #available(iOS 18, *), let held = session as? CLServiceSession else { return }
        held.invalidate()
        session = nil
    }

    private func deliver(_ fix: Fix?) {
        fixRequest += 1
        let continuations = waiting
        waiting.removeAll()
        continuations.forEach { $0.resume(returning: fix) }
    }

    /// Says why geofences are limited, once per reason.
    private func explain(_ message: String, key: String? = nil) {
        guard saidWhy.insert(key ?? message).inserted else { return }
        BubblLog.info(message)
    }

    nonisolated static func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

/// CLMonitor for Bubbl's circles, one monitor named for the SDK. Its conditions persist across
/// launches; its events are listened to from start, as iOS relaunches the app to deliver them. A
/// condition added "assuming unsatisfied" reports satisfied at once if the device is already
/// inside, so nothing needs to ask for its state.
@available(iOS 17, *)
actor ConditionWatcher {
    static let shared = ConditionWatcher()
    /// Letters and digits only: CLMonitor throws (crashing the app) for a name like "tech.bubbl.sdk".
    private static let name = "BubblSDK"
    private var monitor: CLMonitor?

    /// The monitor, made and listened to on first use.
    private func current() async -> CLMonitor {
        if let monitor { return monitor }
        let created = await CLMonitor(Self.name)
        monitor = created
        Task { await Self.deliver(created) }
        return created
    }

    func listen() async { _ = await current() }

    func watch(_ wanted: [WatchedRegion]) async {
        let monitor = await current()
        let ids = Set(wanted.map(\.id))
        for id in await monitor.identifiers where id.hasPrefix(GeofenceEngine.regionPrefix) && !ids.contains(id) {
            await monitor.remove(id)
        }
        for region in wanted {
            let center = CLLocationCoordinate2D(latitude: region.center.latitude, longitude: region.center.longitude)
            // Unchanged: left alone, so it isn't reported again.
            if let existing = await monitor.record(for: region.id)?.condition as? CLMonitor.CircularGeographicCondition,
               abs(existing.center.latitude - center.latitude) < 1e-7, abs(existing.center.longitude - center.longitude) < 1e-7,
               abs(existing.radius - region.radiusMeters) < 0.01 {
                continue
            }
            await monitor.add(CLMonitor.CircularGeographicCondition(center: center, radius: region.radiusMeters), identifier: region.id, assuming: .unsatisfied)
        }
    }

    func remove(_ id: String) async {
        await current().remove(id)
    }

    func removeAll() async {
        let monitor = await current()
        for id in await monitor.identifiers where id.hasPrefix(GeofenceEngine.regionPrefix) { await monitor.remove(id) }
    }

    private enum Unmonitored: Sendable {
        case overLimit, unsupported, other(String)
    }

    private static func deliver(_ monitor: CLMonitor) async {
        do {
            for try await event in await monitor.events {
                let id = event.identifier
                guard id.hasPrefix(GeofenceEngine.regionPrefix) else { continue }
                let millis = Int64(event.date.timeIntervalSince1970 * 1000)
                switch event.state {
                case .satisfied, .unsatisfied:
                    let entered = event.state == .satisfied
                    await MainActor.run {
                        EngineHost.shared.regionEvent([id], entered: entered, fix: LocationService.shared.lastFix, deviceTimeMillis: millis)
                    }
                case .unmonitored:
                    let reason = unmonitored(event)
                    await MainActor.run {
                        switch reason {
                        case .overLimit: LocationService.shared.overLimit(id)
                        case .unsupported: LocationService.shared.unsupported(id)
                        case .other(let why): LocationService.shared.unmonitored(id, why: why)
                        }
                    }
                default:
                    continue
                }
            }
        } catch {
            BubblLog.warning("CoreLocation's geofence events ended: \(type(of: error))")
        }
    }

    /// Why a condition isn't monitored, as far as iOS 18+ says.
    private static func unmonitored(_ event: CLMonitor.Event) -> Unmonitored {
        guard #available(iOS 18, *) else { return .other("") }
        if event.conditionLimitExceeded { return .overLimit }
        if event.conditionUnsupported { return .unsupported }
        let reasons: [(Bool, String)] = [
            (event.authorizationDenied, "location denied"),
            (event.authorizationDeniedGlobally, "location services off"),
            (event.authorizationRestricted, "location restricted"),
            (event.insufficientlyInUse, "not in use and no Always"),
            (event.accuracyLimited, "approximate location"),
            (event.persistenceUnavailable, "persistence unavailable"),
            (event.serviceSessionRequired, "service session required"),
            (event.authorizationRequestInProgress, "permission prompt showing"),
        ]
        let found = reasons.filter(\.0).map(\.1)
        return .other(found.isEmpty ? "" : ": " + found.joined(separator: ", "))
    }
}

/// The engine's RegionMonitor, on LocationService.
@available(iOS 17, *)
struct CoreLocationRegionMonitor: RegionMonitor {
    func capacity() async -> Int { await LocationService.shared.capacity() }
    func watch(_ regions: [WatchedRegion]) async -> Bool { await LocationService.shared.watch(regions) }
    func stop() async { await LocationService.shared.stopAll() }
    func excluded() async -> Set<String> { await LocationService.shared.excluded() }
}

@available(iOS 17, *)
extension Fix {
    init(_ location: CLLocation) {
        self.init(
            LatLng(location.coordinate.latitude, location.coordinate.longitude),
            accuracyMeters: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
            timeMillis: Int64(location.timestamp.timeIntervalSince1970 * 1000)
        )
    }
}
#endif
