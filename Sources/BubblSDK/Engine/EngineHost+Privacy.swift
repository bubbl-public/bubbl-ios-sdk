import Foundation
#if !COCOAPODS
import BubblCore
#endif

/// The user's decisions (Bubbl.setConsent, optOut, deleteMyData, setLocationEnabled) in the host:
/// the engine changes its state and stops what it must (EngineCore's PrivacyControls); the host
/// cancels its waiting work and runs what each needs, retried until done.
@available(iOS 17, *)
extension EngineHost {
    /// Consent given (again): everything consent allows starts, geofences fetched afresh.
    func consentGiven(_ core: EngineCore) {
        resume(core)
        if core.locationActive { checkGeofences(force: true) }
    }

    /// The user opted out: nothing more runs, what's queued goes, and the server is told once.
    func optOut(_ core: EngineCore) {
        Task {
            await runner.cancelAll()
            do {
                if try await core.optOut() { submit("privacy.withdrawn") { await $0.consentWithdrawn() } }
            } catch {
                BubblLog.warning("Bubbl.optOut can't be saved until the device is unlocked: ask again then")
            }
        }
    }

    /// The user asked for their data to be erased: stopped now, erased (server, then here) as work.
    func erase(_ core: EngineCore) {
        Task {
            await runner.cancelAll()
            do {
                try await core.requestErasure()
                submit("privacy.erase") { await $0.eraseDevice() }
            } catch {
                BubblLog.warning("Bubbl.deleteMyData can't be saved until the device is unlocked: ask again then")
            }
        }
    }

    /// Location (geofences) on or off; the rest carries on.
    func setLocationEnabled(_ enabled: Bool, _ core: EngineCore) {
        Task {
            do {
                guard try await core.setLocationEnabled(enabled), enabled else { return }
                checkGeofences(force: true)
                appOpenedForLocation()
            } catch {
                BubblLog.warning("Bubbl.setLocationEnabled can't be saved until the device is unlocked: ask again then")
            }
        }
    }

    /// At every start: an erasure or an opt-out a killed app didn't finish telling the server about
    /// carries on (the work runner isn't kept between launches).
    func resumePrivacyWork(_ core: EngineCore) {
        guard let state = core.privacy.state else { return }
        if state.pendingDelete {
            submit("privacy.erase") { await $0.eraseDevice() }
        } else if state.consent == false {
            submit("privacy.withdrawn") { await $0.consentWithdrawn() }
        }
    }
}
