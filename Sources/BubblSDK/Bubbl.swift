import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif
#if !COCOAPODS
import BubblCore
#endif

/// Bubbl, for an iOS app: the same functions as Android's `tech.bubbl.sdk.Bubbl`
/// (docs/PUBLIC_API.md). Two steps to install: add the package, and in
/// `application(_:didFinishLaunchingWithOptions:)` (or the SwiftUI `App`'s init)
///
///     Bubbl.start(apiKey: "pk_live_…", options: BubblOptions(baseUrl: "https://…"))
///
/// Every call is safe from any thread. Calls before `start` do nothing (and log a warning), except
/// `permissions.openSettings()`, which needs nothing of Bubbl's. Bubbl never stops the app: a mistake (an empty key, an http:// URL) is logged, not thrown.
///
/// Bubbl works on iOS 17 and later. An app supporting older versions can still include it: on
/// those phones `isSupported` is false and every call does nothing (see `isSupported`).
public enum Bubbl {
    /// This SDK's version.
    public static let sdkVersion = BubblVersion.sdk

    /// Whether Bubbl works on this device (iOS 17 and later). When false, `start` logs that it
    /// does nothing here and returns: nothing is installed or sent, nothing prompts, no
    /// notification delegate or background task is set up, and no location is used. Every other
    /// call does nothing too, permission calls report nil, notification listeners are never
    /// called, and `diagnostics()` says `supported: false`.
    public static var isSupported: Bool { backend.isSupported }

    // MARK: - Starting

    /// Start Bubbl. Call once per launch, early (so background launches for a geofence or a push
    /// have it too); calling again with the same key and options changes nothing.
    public static func start(apiKey: String, options: BubblOptions) {
        backend.start(apiKey: apiKey, options: options)
    }

    /// Start Bubbl with a device credential issued outside the app (installs provisioned ahead of
    /// time, an app's own pairing flow) instead of an API key: the device never registers itself.
    /// As `start(apiKey:options:)` otherwise, and called the same way at every launch. A different
    /// credential than last time (or switching from an API key) starts afresh as a new device:
    /// nothing kept from before is sent under the new one. If the server refuses the credential,
    /// Bubbl stops and says so (`BubblEvent.credentialRejected`, diagnostics) until it's started
    /// with a new one.
    public static func start(credential: BubblCredential, options: BubblOptions) {
        backend.start(credential: credential, options: options)
    }

    /// Stop Bubbl on this device until `start` is called again: nothing more runs; nothing is
    /// dropped, and the server isn't told (unlike `optOut`).
    public static func stop() {
        backend.stop()
    }

    // MARK: - Consent and privacy

    /// The user's answer, for apps started with `requireConsent` (and to give consent again after
    /// an opt-out): true starts everything; false is the same as `optOut()`.
    public static func setConsent(_ granted: Bool) {
        backend.setConsent(granted)
    }

    /// Stop Bubbl for this user: nothing more is sent, shown or tracked, what's queued is dropped,
    /// and the server is told.
    public static func optOut() {
        backend.optOut()
    }

    /// Erase this device and everything Bubbl recorded about it, on the server and here. It keeps
    /// trying until it's done, and Bubbl stays off afterwards (`setConsent(true)` later starts
    /// afresh, as a new device).
    public static func deleteMyData() {
        backend.deleteMyData()
    }

    /// Turn Bubbl's use of location (geofences) off, or on again; the rest carries on.
    public static func setLocationEnabled(_ enabled: Bool) {
        backend.setLocationEnabled(enabled)
    }

    // MARK: - Sandbox

    /// Approve this device as a Sandbox test device with a registration code from the dashboard
    /// (Test devices › Registration codes; each approves one device, within 24 hours), e.g. from a
    /// hidden debug menu or a device farm's set-up. The other ways need no code in the app: the
    /// dashboard's "Add a test device", or matching the code Bubbl logs at start in Sandbox.
    /// `approved` once it is; otherwise `message` says why, to show whoever typed the code (a
    /// wrong, used or expired code, the Sandbox's 25 test devices taken, before `start`, no
    /// network). Also said in the log.
    public static func registerTestDevice(_ code: String) async -> BubblTestDeviceResult {
        await backend.registerTestDevice(code)
    }

    /// `registerTestDevice(_:)` for code that can't await; `completion` runs on the main thread.
    public static func registerTestDevice(_ code: String, completion: @escaping @Sendable @MainActor (BubblTestDeviceResult) -> Void) {
        Task {
            let result = await registerTestDevice(code)
            await MainActor.run { completion(result) }
        }
    }

    // MARK: - Permissions

    /// The permissions Bubbl uses: where they stand, and asking for them.
    public static let permissions = BubblPermissions()

    // MARK: - Targeting and events

    /// The device's segments, for targeting campaigns (replaces any set before).
    public static func setSegments(_ segments: [String]) {
        backend.setSegments(segments)
    }

    /// Record an event of the app's own, for reports: a `name` of letters, digits and . _ : - (at
    /// most 100), and up to 50 flat `properties` (text, numbers, true/false or nil).
    public static func track(_ name: String, properties: [String: Any?] = [:]) {
        backend.track(name, properties: properties)
    }

    // MARK: - Notifications

    /// Have a say over each notification before Bubbl shows it: return true to show it yourself
    /// (then report what happens with `reportDisplayed` and the others), false to let Bubbl. Nil
    /// goes back to Bubbl showing everything. Called on the main thread.
    public static func setNotificationListener(_ listener: (@MainActor @Sendable (BubblMessage) -> Bool)?) {
        backend.setNotificationListener(listener)
    }

    /// Be told of what Bubbl does as it happens (`BubblEvent`), on the main thread. Keep the token
    /// to remove the listener with.
    @discardableResult
    public static func addEventListener(_ listener: @escaping @MainActor @Sendable (BubblEvent) -> Void) -> BubblEventToken {
        backend.addEventListener(listener)
    }

    public static func removeEventListener(_ token: BubblEventToken) {
        backend.removeEventListener(token)
    }

    /// Show `message` in Bubbl's notification screen (one the listener held back, say).
    public static func present(_ message: BubblMessage) {
        backend.present(message)
    }

    /// For an app drawing notifications itself: it's on screen.
    public static func reportDisplayed(_ message: BubblMessage) {
        backend.report("reportDisplayed") { try await $0.displayed(message.notification) }
    }

    /// …the user opened it (tapped it, rather than it opening on its own).
    public static func reportOpened(_ message: BubblMessage) {
        backend.report("reportOpened") { try await $0.opened(message.notification) }
    }

    /// …the user tapped its call to action.
    public static func reportCtaClicked(_ message: BubblMessage) {
        backend.report("reportCtaClicked") { try await $0.ctaClicked(message.notification) }
    }

    /// …the user closed it without acting.
    public static func reportDismissed(_ message: BubblMessage) {
        backend.report("reportDismissed") { try await $0.dismissed(message.notification) }
    }

    /// …its media (video, audio, a YouTube video, an image) was shown or started playing.
    public static func reportMediaViewed(_ message: BubblMessage) {
        backend.report("reportMediaViewed") { try await $0.mediaViewed(message.notification, positionSeconds: 0) }
    }

    /// …its video or audio played to the end, `durationSeconds` long.
    public static func reportMediaCompleted(_ message: BubblMessage, durationSeconds: Double) {
        backend.report("reportMediaCompleted") { try await $0.mediaCompleted(message.notification, positionSeconds: durationSeconds) }
    }

    /// …the user started answering its survey.
    public static func reportSurveyStarted(_ message: BubblMessage) {
        backend.report("reportSurveyStarted") { try await $0.surveyStarted(message.notification) }
    }

    /// Send the answers to a survey the app showed itself: `answers` by question id, as each
    /// `BubblQuestion` says. Checked as the server checks them; false (and a warning logged, with
    /// why) when they can't be sent, e.g. a required question unanswered or a rating of 6.
    @discardableResult
    public static func submitSurvey(_ message: BubblMessage, answers: [String: Any?]) -> Bool {
        backend.submitSurvey(message, answers: answers)
    }

    /// Open `message`'s call to action as Bubbl's screen would, and report the click.
    public static func openCta(_ message: BubblMessage) {
        backend.openCta(message)
    }

    // MARK: - Push

    /// Whether a push is Bubbl's (its payload's `userInfo`), so the app's own handling can leave it
    /// alone.
    public static func isBubblMessage(_ userInfo: [AnyHashable: Any]) -> Bool {
        backend.isBubblMessage(userInfo)
    }

    #if os(iOS)
    // Bubbl takes the device token and its own pushes by itself. With BubblAutoIntegrationEnabled
    // set to NO in Info.plist it doesn't, and the app hands them over with these three.

    /// The device token, from the app delegate's
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`. Before `start` too.
    public static func setPushToken(_ deviceToken: Data) {
        backend.setPushToken(deviceToken)
    }

    /// From the notification center delegate's `userNotificationCenter(_:willPresent:…)`: true
    /// when the push is Bubbl's, and Bubbl calls `completionHandler`; false when it isn't, and the
    /// app's own code decides.
    public static func willPresent(_ notification: UNNotification, completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) -> Bool {
        backend.willPresent(notification, completionHandler: completionHandler)
    }

    /// From the notification center delegate's `userNotificationCenter(_:didReceive:…)`: true when
    /// the tapped notification is Bubbl's, and Bubbl calls `completionHandler`; false when it
    /// isn't.
    public static func didReceive(_ response: UNNotificationResponse, completionHandler: @escaping () -> Void) -> Bool {
        backend.didReceive(response, completionHandler: completionHandler)
    }
    #endif

    // MARK: - Diagnostics

    /// Where Bubbl stands on this device, for support and for an app's own debug screen. The same
    /// fields as Android's, and iOS's own at the end.
    public struct Diagnostics: Sendable, Equatable {
        public let started: Bool
        /// Bubbl works on this device (iOS 17 and later): `Bubbl.isSupported`.
        public let supported: Bool
        public let sdkVersion: String
        /// False when the workspace requires a newer SDK.
        public let sdkSupported: Bool
        public let registered: Bool
        /// The install id the engine keeps (how Dashboard › Active users finds this device); nil
        /// before there is one.
        public let installId: String?
        /// Running: started, consent allows it, not paused by the server, supported.
        public let active: Bool
        /// Unix seconds until which the server paused Bubbl, if it has.
        public let pausedUntil: Int64?
        public let consentRequired: Bool
        public let consent: Bool?
        public let locationEnabled: Bool
        /// Where the device stands on the permissions Bubbl uses (as `permissions.status()`).
        public let permissions: BubblPermissionStatus?
        public let hasPushToken: Bool
        public let geofences: Int
        public let queuedEvents: Int
        public let lastError: String?
        /// Started with a credential the server refused (`Bubbl.start(credential:options:)`).
        public let credentialRejected: Bool
        /// Geofences work with the app closed ("Always"); else only while it's open.
        public let backgroundLocation: Bool
        /// Geofence entries and exits that happened before the first unlock after a reboot, when
        /// they couldn't be kept (always 0 on Android).
        public let transitionsDroppedWhileLocked: Int
        /// iOS: Background App Refresh is on for the app.
        public let backgroundRefreshAvailable: Bool
        /// iOS: Low Power Mode is on (background work is held back).
        public let lowPowerMode: Bool
        /// iOS watches the geofences ("Always", precise, and the device can). Otherwise they're
        /// checked from location changes, which is coarser.
        public let osWatchesGeofences: Bool
        /// The workspace the key belongs to: "sandbox" (pk_test_) or "production" (pk_live_); nil
        /// before the device has registered (or from a server that predates Sandbox).
        public let environment: String?
        /// In Sandbox, where this device stands as a test device; nil in Production.
        public let testDevice: TestDevice?

        /// A Sandbox test device: "pending" until someone approves it (in the dashboard, with
        /// `code`, or with `Bubbl.registerTestDevice`), then "approved". Unused for 30 days, or
        /// removed in the dashboard, it's pending again.
        public struct TestDevice: Sendable, Equatable {
            public let status: String
            /// While pending: the short code the dashboard lists this device under (e.g. K7Q-2MX).
            public let code: String?
        }
    }

    public static func diagnostics() async -> Diagnostics {
        await backend.diagnostics()
    }

    /// `diagnostics()` for code that can't await; `completion` runs on the main thread.
    public static func diagnostics(completion: @escaping @Sendable @MainActor (Diagnostics) -> Void) {
        Task {
            let result = await diagnostics()
            await MainActor.run { completion(result) }
        }
    }

    // MARK: - Internals

    /// https only; http for local development (localhost, the Simulator's host, *.test).
    static func isAllowedBaseUrl(_ url: String) -> Bool {
        guard let components = URLComponents(string: url), let host = components.host?.lowercased(), !host.isEmpty else { return false }
        switch components.scheme?.lowercased() {
        case "https": return true
        case "http": return host == "localhost" || host == "127.0.0.1" || host == "10.0.2.2" || host.hasSuffix(".test")
        default: return false
        }
    }
}
