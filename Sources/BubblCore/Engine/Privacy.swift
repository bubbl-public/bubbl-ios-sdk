import Foundation

/// What the app's user has agreed to, and what the engine may do because of it (Android's
/// PrivacyState).
///
///  - requireConsent: the app started Bubbl with consent required; nothing runs (no registration,
///    no network, no location) until consent is true.
///  - consent: nil until the user answers; false after opting out or erasing their data, which
///    stops the engine whether or not consent was required.
///  - locationEnabled: the app can turn location off (setLocationEnabled) while the rest runs.
///  - pendingDelete: deleteMyData() was asked for and DELETE /device hasn't gone through yet.
package struct PrivacyState: Sendable, Equatable, Codable {
    package var requireConsent = false
    package var consent: Bool?
    package var locationEnabled = true
    package var pendingDelete = false

    package init(requireConsent: Bool = false, consent: Bool? = nil, locationEnabled: Bool = true, pendingDelete: Bool = false) {
        self.requireConsent = requireConsent
        self.consent = consent
        self.locationEnabled = locationEnabled
        self.pendingDelete = pendingDelete
    }

    /// The engine may run at all: register, send, fetch.
    package var active: Bool { !pendingDelete && consent != false && (!requireConsent || consent == true) }

    /// The engine may use location: geofences, fixes.
    package var locationActive: Bool { active && locationEnabled }
}

/// PrivacyState kept between runs. While it can't be read (before the first unlock) the engine
/// counts as not allowed to run: it never guesses a user's consent.
package final class PrivacyStore: Sendable {
    private let store: any ValueStore<PrivacyState>
    private let cache = Cached<PrivacyState>()
    private let lock = NSLock()

    package init(store: any ValueStore<PrivacyState>) {
        self.store = store
    }

    /// The state; nil while it can't be read.
    package var state: PrivacyState? {
        lock.sync {
            do {
                return try cache.value { try store.load() } ?? PrivacyState()
            } catch {
                return nil
            }
        }
    }

    @discardableResult
    package func update(_ change: (inout PrivacyState) -> Void) throws -> PrivacyState {
        try lock.sync {
            var state = try cache.value { try store.load() } ?? PrivacyState()
            change(&state)
            try store.save(state)
            cache.set(state)
            return state
        }
    }
}
