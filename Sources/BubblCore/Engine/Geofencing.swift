import Foundation

/// What sending the pending geofence transitions came to.
package struct TransitionsSent: Sendable, Equatable {
    package var outcome: WorkOutcome = .done
    /// Notifications the server says to show now.
    package var notifications: [JSONValue] = []
    /// A transition was refused because its location has gone: check the geofences again.
    package var recheck = false

    package init(outcome: WorkOutcome = .done, notifications: [JSONValue] = [], recheck: Bool = false) {
        self.outcome = outcome
        self.notifications = notifications
        self.recheck = recheck
    }
}

/// Geofencing as work, as Android's GeofenceWork and receivers: the OS's region events and
/// location fixes become transitions, which are saved before anything else (the app can be
/// suspended or killed at any moment in the background) and then sent; checks watch the geofences
/// and fetch them when due. The platform supplies the fixes and runs the work.
extension EngineCore {
    /// At most this many transitions wait to be sent; the oldest go first.
    package static let maxPendingTransitions = 200

    /// The OS says the device entered or left `regionIds` (Bubbl's region names; others are
    /// ignored). Returns what to do next: its transitions are already saved for sending.
    package func regionEvent(_ regionIds: [String], entered: Bool, fix: Fix?, deviceTimeMillis: Int64) async -> Outcome {
        let geofenceEvents = regionIds.filter { $0.hasPrefix(GeofenceEngine.regionPrefix) && $0 != GeofenceEngine.refreshRegionId }.count
        // Before the first unlock after a reboot nothing can be read, not even whether location
        // is allowed: the event is lost (accepted), and counted for diagnostics.
        guard let privacy = privacy.state else {
            droppedWhileLocked(geofenceEvents)
            return Outcome()
        }
        guard privacy.locationActive, isActive else { return Outcome() }

        var outcome: Outcome
        do {
            outcome = try await geofences.onRegionEvent(regionIds, entered: entered, fix: fix, deviceTimeMillis: deviceTimeMillis)
        } catch {
            droppedWhileLocked(geofenceEvents)
            return Outcome()
        }
        if !record(outcome.transitions) { outcome.transitions = [] }
        return outcome
    }

    /// A location fix (significant change, in-use updates, one asked for). `osWatches`: the OS
    /// watches the geofences ("Always"); otherwise entering and leaving are decided from the fix.
    package func locationFix(_ fix: Fix, osWatches: Bool) async -> Outcome {
        guard locationActive else { return Outcome() }
        var outcome: Outcome
        do {
            outcome = osWatches ? try await geofences.onFix(fix) : try await geofences.onFixWithoutOs(fix)
        } catch {
            return Outcome()
        }
        if !record(outcome.transitions) { outcome.transitions = [] }
        return outcome
    }

    /// Android's CheckGeofencesWorker: make sure the geofences are watched (`rewatch`: the OS
    /// dropped them), check them against `fix`, and fetch them if due (or `force`).
    package func checkGeofences(fix: Fix, force: Bool = false, rewatch: Bool = false, osWatches: Bool) async -> WorkOutcome {
        guard locationActive else { return .done }
        saveLockedDrops()
        do {
            _ = rewatch ? try await geofences.rewatch() : try await geofences.ensureWatching()
        } catch {
            BubblLog.warning("Couldn't watch the geofences: their state can't be read yet")
        }

        // Its transitions are saved for sending; its refresh is the one below.
        _ = await locationFix(fix, osWatches: osWatches)

        let result: RefreshResult
        do {
            result = try await geofences.refresh(fix, force: force)
        } catch {
            return .retry(afterSeconds: 30)
        }
        BubblLog.debug("Geofence check: \(result)")
        if case .failed(let failure) = result { return await handle(failure, "Checking geofences") }
        return .done
    }

    /// Send the saved transitions, oldest first, stopping at the first that has to wait. One
    /// sending at a time: a retry and a new region event never send the same one twice.
    package func sendTransitions() async -> TransitionsSent {
        await sendingTransitions.withLock { await self.sendPendingTransitions() }
    }

    private func sendPendingTransitions() async -> TransitionsSent {
        guard locationActive else { return TransitionsSent() }
        saveLockedDrops()
        let pending: [Transition]
        do {
            pending = try transitionsLock.sync { try stores.transitions.load() ?? [] }
        } catch {
            return TransitionsSent(outcome: .retry(afterSeconds: 30))
        }

        var sent = TransitionsSent()
        var finished: Set<String> = []
        loop: for transition in pending {
            switch await geofences.send(transition) {
            case .delivered(let notifications):
                BubblLog.debug("Geofence \(transition.enter ? "entry" : "exit") sent: \(notifications.count) notification(s) to show")
                sent.notifications += notifications
                finished.insert(transition.key)
            case .dropped(let reason):
                sent.recheck = sent.recheck || reason == "unknown_location"
                finished.insert(transition.key)
            case .failed(let failure):
                sent.outcome = await handle(failure, "Sending a geofence transition")
                break loop
            }
        }

        if !finished.isEmpty {
            try? transitionsLock.sync {
                let left = (try stores.transitions.load() ?? []).filter { !finished.contains($0.key) }
                try stores.transitions.save(left)
            }
        }
        return sent
    }

    /// Whether transitions are waiting to be sent (false while that can't be read).
    package var hasPendingTransitions: Bool {
        transitionsLock.sync { ((try? stores.transitions.load()) ?? nil)?.isEmpty == false }
    }

    /// Region events lost before the first unlock after a reboot, since this install began.
    package var transitionsDroppedWhileLocked: Int {
        let saved: Int?? = try? stores.lockedDrops.load()
        return ((saved ?? nil) ?? 0) + unsavedLockedDrops.value
    }

    /// Save `transitions` to be sent. False (and counted as lost) when they can't be written.
    private func record(_ transitions: [Transition]) -> Bool {
        guard !transitions.isEmpty else { return true }
        do {
            try transitionsLock.sync {
                let all = (try stores.transitions.load() ?? []) + transitions
                try stores.transitions.save(Array(all.suffix(Self.maxPendingTransitions)))
            }
            return true
        } catch {
            droppedWhileLocked(transitions.count)
            return false
        }
    }

    private func droppedWhileLocked(_ count: Int) {
        guard count > 0 else { return }
        unsavedLockedDrops.add(count)
        BubblLog.info("\(count) geofence event(s) before the first unlock since the phone restarted: not kept")
        saveLockedDrops()
    }

    /// Adds the drops counted in memory to the saved count, once it can be written.
    private func saveLockedDrops() {
        try? unsavedLockedDrops.drain { count in
            let saved = try stores.lockedDrops.load() ?? 0
            try stores.lockedDrops.save(saved + count)
        }
    }
}
