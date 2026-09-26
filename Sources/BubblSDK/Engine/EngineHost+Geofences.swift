import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if !COCOAPODS
import BubblCore
#endif

/// Geofencing in the host, as Android's GeofenceWork: what CoreLocation reports becomes saved
/// transitions, sent at once in the time iOS gives the event; checks (fetch when due, watch the
/// nearest, re-watch after a failure or a change of permission) run as work, retried with backoff.
@available(iOS 17, *)
extension EngineHost {
    static func regionMonitor() -> any RegionMonitor {
        #if os(iOS)
        CoreLocationRegionMonitor()
        #else
        InactiveRegionMonitor()
        #endif
    }

    /// Makes CoreLocation's managers now, on the main thread: an app relaunched for a region event
    /// gets the event only once they exist.
    func startLocation() {
        #if os(iOS)
        if Thread.isMainThread {
            MainActor.assumeIsolated { LocationService.shared.activate() }
        } else {
            Task { @MainActor in LocationService.shared.activate() }
        }
        #endif
    }

    /// Check the geofences soon: fetch them if due (or `force`), from `fix` or a fresh one
    /// (`precise` for a polygon), watching them again first if `rewatch`. A check asked for while
    /// one runs replaces any other waiting.
    func checkGeofences(force: Bool = false, precise: Bool = false, rewatch: Bool = false, fix: Fix? = nil) {
        #if os(iOS)
        submit("geofences.check") { core in
            await self.runCheck(core, force: force, precise: precise, rewatch: rewatch, fix: fix)
        }
        #endif
    }

    /// The app came to the front: where iOS isn't watching the geofences, they're checked from
    /// fixes while it's open.
    func appOpenedForLocation() {
        #if os(iOS)
        guard let core = current, core.locationActive else { return }
        Task { @MainActor in LocationService.shared.startInUseUpdates() }
        checkGeofences()
        #endif
    }

    #if os(iOS)
    @MainActor
    func appWentToTheBackForLocation() {
        LocationService.shared.stopInUseUpdates()
    }

    // MARK: - From LocationService (main thread)

    /// CoreLocation says the device entered or left Bubbl's regions `ids`.
    @MainActor
    func regionEvent(_ ids: [String], entered: Bool, fix: Fix?, deviceTimeMillis: Int64) {
        guard let core = current else { return }
        let time = BackgroundTime("tech.bubbl.sdk.geofence")
        Task {
            let outcome = await core.regionEvent(ids, entered: entered, fix: fix, deviceTimeMillis: deviceTimeMillis)
            await act(on: outcome, core, fix: nil)
            time.end()
        }
    }

    /// A fix: a significant change (`osWatches`), or one while the app is open with location only
    /// while in use.
    @MainActor
    func locationFix(_ fix: Fix, osWatches: Bool) {
        guard let core = current else { return }
        let time = BackgroundTime("tech.bubbl.sdk.location")
        Task {
            let outcome = await core.locationFix(fix, osWatches: osWatches)
            await act(on: outcome, core, fix: fix)
            time.end()
        }
    }

    /// CoreLocation couldn't watch a region: the next check watches them all again (not now, which
    /// would go round and round while iOS keeps refusing).
    @MainActor
    func watchFailed() {
        guard let core = current else { return }
        Task { try? await core.geofences.watchFailed() }
    }

    /// The user changed the app's location permission.
    @MainActor
    func locationAccessChanged(_ access: LocationAccess) {
        guard let core = current, core.locationActive else { return }
        switch access {
        case .none:
            Task { await LocationService.shared.stopAll() }
        case .whenInUse, .always:
            if UIApplication.shared.applicationState != .background { LocationService.shared.startInUseUpdates() }
            checkGeofences(rewatch: true)
        }
    }

    // MARK: - Work

    /// Android's CheckGeofencesWorker, with the fix from CoreLocation.
    func runCheck(_ core: EngineCore, force: Bool, precise: Bool, rewatch: Bool, fix: Fix?) async -> WorkOutcome {
        guard core.locationActive else { return .done }
        let (access, osWatches) = await MainActor.run { (LocationService.shared.access, LocationService.shared.osWatches) }
        guard access != .none else { return .done }

        let current: Fix?
        if let fix { current = fix } else { current = await LocationService.shared.currentFix(precise: precise) }
        guard let current else {
            BubblLog.debug("Geofence check: no location fix")
            return .done
        }

        let result = await core.checkGeofences(fix: current, force: force, rewatch: rewatch, osWatches: osWatches)
        if core.hasPendingTransitions { await sendTransitionsNow(core) }
        return result
    }

    /// What an event or a fix led to: its transitions sent now, and a check if it asked for one,
    /// all in the time iOS gave the event.
    private func act(on outcome: Outcome, _ core: EngineCore, fix: Fix?) async {
        for transition in outcome.transitions {
            BubblEvents.shared.emit(transition.enter ? .geofenceEntered(locationId: transition.locationId) : .geofenceExited(locationId: transition.locationId))
        }
        if !outcome.transitions.isEmpty { await sendTransitionsNow(core) }
        guard outcome.refresh || outcome.needsFix else { return }
        let checked = await runCheck(core, force: outcome.refresh, precise: outcome.needsFix, rewatch: false, fix: outcome.needsFix ? nil : fix)
        if case .retry = checked { checkGeofences(force: outcome.refresh, precise: outcome.needsFix) }
    }

    /// Send the saved transitions now; what couldn't go is retried, with backoff, as work.
    private func sendTransitionsNow(_ core: EngineCore) async {
        if case .retry = await sendTransitions(core) {
            submit("geofences.transitions") { await self.sendTransitions($0) }
        }
    }

    private func sendTransitions(_ core: EngineCore) async -> WorkOutcome {
        let sent = await core.sendTransitions()
        await arrived(sent.notifications, core)
        if sent.recheck { checkGeofences(force: true) }
        return sent.outcome
    }
    #endif
}

#if canImport(UIKit) && !os(watchOS)
/// The few seconds iOS gives to finish something in the background, asked for when it starts and
/// handed back when it's done (or when iOS says time is up).
@available(iOS 17, *)
@MainActor
final class BackgroundTime {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
