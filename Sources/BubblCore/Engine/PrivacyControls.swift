import Foundation

/// What an app's user can decide about Bubbl, and what each decision does to the engine (Android's
/// PrivacyControls). The engine changes its state and stops what it must; the host runs the work
/// each returns (and cancels its own), since only it knows how:
///
///  - consent given: everything runs (with consent required, nothing ran until now);
///  - an opt-out (or consent refused): geofences stop, queued events are dropped, nothing more is
///    sent or shown; a device the server knows is told, once (PUT /device consent=false);
///  - deleteMyData: stops as for an opt-out, then DELETE /device erases the device and all that's
///    recorded about it, and the engine's own data goes too; retried until done, and the engine
///    stays stopped meanwhile and afterwards (consent given again starts afresh, as a new device);
///  - location off: geofences and location stop; the rest carries on.
///
/// Each throws while the state can't be saved (before the first unlock after a reboot).
extension EngineCore {
    /// The user said yes (again, after an opt-out). False when nothing changed: a pending erasure
    /// holds everything until it's done, then consent may be given again.
    @discardableResult
    package func grantConsent() throws -> Bool {
        guard privacy.state?.pendingDelete != true else {
            BubblLog.warning("Bubbl.setConsent(true) while the user's data is being erased: asked again once it's done")
            return false
        }
        let before = privacy.state?.consent
        try privacy.update { $0.consent = true }
        return before != true
    }

    /// The user opted out. True when the server has to be told (Bubbl was running; then run
    /// `consentWithdrawn` as work until it's done).
    @discardableResult
    package func optOut() async throws -> Bool {
        let wasActive = privacy.state?.active == true
        try privacy.update { $0.consent = false }
        await stopWork()
        // The server clears the correlation id when consent is withdrawn and drops one sent while
        // it is: forget that it has ours, so the sync after consent is given again sends it too.
        await deviceSync.forget([CorrelationId.key])
        return wasActive
    }

    /// PUT /device consent=false, the one call made after an opt-out. Nothing to tell for an install
    /// that never registered; nothing left to tell once consent is back, or an erasure took over.
    package func consentWithdrawn() async -> WorkOutcome {
        guard let state = privacy.state else { return .retry(afterSeconds: 60) }
        guard state.consent == false, !state.pendingDelete, everRegistered else { return .done }

        switch await deviceSync.sync(["consent": .bool(false)]) {
        case .failed(.backoff):
            return .retry(afterSeconds: 30)
        case .failed(.retryAfter(let seconds)):
            return .retry(afterSeconds: seconds)
        default:
            // Told, or refused for good (paused, misconfigured): the device stays quiet either way.
            return .done
        }
    }

    /// The user asked for their data to be erased: stopped now; then run `eraseDevice` as work until
    /// it's done.
    package func requestErasure() async throws {
        try privacy.update {
            $0.consent = false
            $0.pendingDelete = true
        }
        await stopWork()
    }

    /// DELETE /device, then the engine's own data. A revoked credential is replaced first by the
    /// client (the install id names the same device), so the right device is erased; an install
    /// that never registered has nothing on the server. Retried until done; given up only on an
    /// error a retry can't fix, after `maxEraseAttempts`, and then said so rather than pretending
    /// the data is gone.
    package func eraseDevice() async -> WorkOutcome {
        guard let state = privacy.state else { return .retry(afterSeconds: 60) }
        guard state.pendingDelete else { return .done }

        if everRegistered {
            let response: ApiResponse
            do {
                response = try await api.request("DELETE", "api/v1/device")
            } catch {
                return .retry(afterSeconds: 30)
            }
            // Erased, or already gone.
            if !response.isSuccessful && response.status != 404 {
                switch ApiFailure.of(response) {
                case .backoff: return .retry(afterSeconds: 30)
                case .retryAfter(let seconds): return .retry(afterSeconds: seconds)
                case .pause(let hours, _): return .retry(afterSeconds: hours * 3_600)
                default:
                    if eraseAttempts.next() < Self.maxEraseAttempts { return .retry(afterSeconds: 60) }
                    BubblLog.error("Couldn't erase this device (HTTP \(response.status) \(response.code ?? "")): its data is still on the server")
                    return .done
                }
            }
        }

        do {
            try await wipeLocalData()
            try privacy.update {
                $0.pendingDelete = false
                $0.consent = false
            }
        } catch {
            BubblLog.warning("The device was erased on the server; its data here goes when it can be written")
            return .retry(afterSeconds: 60)
        }
        BubblLog.info("This device's data was erased")
        return .done
    }

    package static let maxEraseAttempts = 5

    /// Location (geofences) off: they stop, the rest carries on. False when nothing changed.
    @discardableResult
    package func setLocationEnabled(_ enabled: Bool) async throws -> Bool {
        let before = privacy.state?.locationEnabled
        try privacy.update { $0.locationEnabled = enabled }
        if !enabled { try? await geofences.stop() }
        return before != enabled
    }

    /// Everything the engine keeps here, but what the user decided: the credential (the Keychain),
    /// the install id (the next registration is a new device), the queue, geofences, and each saved
    /// piece of state. Throws when something couldn't be removed.
    package func wipeLocalData() async throws {
        try stores.credentials.clear()
        try await events.clear()
        try await geofences.stop()
        try configSync.forget()
        try segments.forget()
        try correlation.forget()
        deviceSync.forget()
        try stores.recentNotifications.delete()
        try stores.installId.delete()
        try stores.clockOffset.delete()
        try stores.pausedUntil.delete()
        try stores.transitions.delete()
        try stores.lockedDrops.delete()
    }

    /// Stops what the engine does and drops what's queued (geofences, events, unsent transitions).
    private func stopWork() async {
        try? await geofences.stop()
        try? await events.clear()
        try? stores.transitions.delete()
    }
}

extension EngineCore {
    /// A device started with a credential issued outside the app: that credential is this device's
    /// (and its install id, the credential's), unless it's the one already kept. Throws while the
    /// Keychain or the files can't be written.
    package func useCredential(_ credential: IssuedCredential) throws {
        if try stores.installId.load() != credential.installId { try stores.installId.save(credential.installId) }
        if case .present(let kept) = stores.credentials.read(), kept.keyId == credential.keyId { return }
        try stores.credentials.save(keyId: credential.keyId, secret: credential.secret)
    }

    /// This install's id as kept, without making one (diagnostics); nil before there is one or
    /// while it can't be read.
    package var keptInstallId: String? {
        guard let id = (try? stores.installId.load()) ?? nil, !id.isEmpty else { return nil }
        return id
    }

    /// Told when the server refuses the credential the device was started with (where an install
    /// would register): the host stops Bubbl until the app starts it with a new one.
    package func onCredentialRejected(_ handler: @escaping @Sendable () -> Void) {
        hooks.credentialRejected = handler
    }
}

/// Counts erasure attempts that failed for good, for the life of the process.
final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Counts one more; returns the count so far.
    func next() -> Int {
        lock.sync {
            count += 1
            return count
        }
    }
}
