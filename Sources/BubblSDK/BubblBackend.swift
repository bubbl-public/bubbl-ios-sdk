import Foundation
import os
#if canImport(UserNotifications)
import UserNotifications
#endif
#if !COCOAPODS
import BubblCore
#endif

/// What `Bubbl`'s calls do: the engine on iOS 17 and later (`SupportedBubbl`), nothing below it
/// (`UnsupportedBubbl`). Apps supporting older iOS versions can install Bubbl; it just does nothing
/// on those phones. The engine and everything it uses are `@available(iOS 17, *)`, so the compiler
/// proves that the one `#available` check in `Bubbl.backend` is the only way in.
protocol BubblBackend: Sendable {
    var isSupported: Bool { get }

    func start(apiKey: String, options: BubblOptions)
    func start(credential: BubblCredential, options: BubblOptions)
    func stop()

    func setConsent(_ granted: Bool)
    func optOut()
    func deleteMyData()
    func setLocationEnabled(_ enabled: Bool)
    func registerTestDevice(_ code: String) async -> BubblTestDeviceResult

    func setSegments(_ segments: [String])
    func track(_ name: String, properties: [String: Any?])

    func setNotificationListener(_ listener: (@MainActor @Sendable (BubblMessage) -> Bool)?)
    func addEventListener(_ listener: @escaping @MainActor @Sendable (BubblEvent) -> Void) -> BubblEventToken
    func removeEventListener(_ token: BubblEventToken)
    func present(_ message: BubblMessage)
    func report(_ call: String, _ record: @escaping @Sendable (NotificationEvents) async throws -> Void)
    func submitSurvey(_ message: BubblMessage, answers: [String: Any?]) -> Bool
    func openCta(_ message: BubblMessage)

    func isBubblMessage(_ userInfo: [AnyHashable: Any]) -> Bool
    #if os(iOS)
    func setPushToken(_ deviceToken: Data)
    func willPresent(_ notification: UNNotification, completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) -> Bool
    func didReceive(_ response: UNNotificationResponse, completionHandler: @escaping () -> Void) -> Bool
    #endif

    func permissionStatus() -> BubblPermissionStatus?
    func requestPermission(_ request: PermissionRequest, _ call: String) async -> BubblPermissionStatus?
    func openSettings()

    func diagnostics() async -> Bubbl.Diagnostics
}

extension Bubbl {
    /// The one way into the engine.
    static let backend: any BubblBackend = {
        if #available(iOS 17, *) { return SupportedBubbl() }
        return UnsupportedBubbl()
    }()
}

/// Below iOS 17: every call returns at once and does nothing. No install, no network, no prompts,
/// no notification delegate, no background tasks, no location. `start` says so in the log, once
/// per call; permission calls report nil (as before `start`) and never prompt; pushes and taps are
/// left to the app.
struct UnsupportedBubbl: BubblBackend {
    var isSupported: Bool { false }

    func start(apiKey: String, options: BubblOptions) { said(options) }
    func start(credential: BubblCredential, options: BubblOptions) { said(options) }
    func stop() {}

    func setConsent(_ granted: Bool) {}
    func optOut() {}
    func deleteMyData() {}
    func setLocationEnabled(_ enabled: Bool) {}
    func registerTestDevice(_ code: String) async -> BubblTestDeviceResult {
        BubblTestDeviceResult(approved: false, message: "Bubbl needs iOS 17 or later")
    }

    func setSegments(_ segments: [String]) {}
    func track(_ name: String, properties: [String: Any?]) {}

    func setNotificationListener(_ listener: (@MainActor @Sendable (BubblMessage) -> Bool)?) {}
    func addEventListener(_ listener: @escaping @MainActor @Sendable (BubblEvent) -> Void) -> BubblEventToken {
        BubblEventToken(id: UUID())
    }
    func removeEventListener(_ token: BubblEventToken) {}
    func present(_ message: BubblMessage) {}
    func report(_ call: String, _ record: @escaping @Sendable (NotificationEvents) async throws -> Void) {}
    func submitSurvey(_ message: BubblMessage, answers: [String: Any?]) -> Bool { false }
    func openCta(_ message: BubblMessage) {}

    func isBubblMessage(_ userInfo: [AnyHashable: Any]) -> Bool { false }
    #if os(iOS)
    func setPushToken(_ deviceToken: Data) {}
    func willPresent(_ notification: UNNotification, completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) -> Bool { false }
    func didReceive(_ response: UNNotificationResponse, completionHandler: @escaping () -> Void) -> Bool { false }
    #endif

    func permissionStatus() -> BubblPermissionStatus? { nil }
    func requestPermission(_ request: PermissionRequest, _ call: String) async -> BubblPermissionStatus? { nil }
    func openSettings() {}

    func diagnostics() async -> Bubbl.Diagnostics {
        Bubbl.Diagnostics(
            started: false, supported: false, sdkVersion: Bubbl.sdkVersion, sdkSupported: true, registered: false, installId: nil,
            active: false, pausedUntil: nil, consentRequired: false, consent: nil, locationEnabled: true, permissions: nil,
            hasPushToken: false, geofences: 0, queuedEvents: 0, lastError: nil, credentialRejected: false, backgroundLocation: false,
            transitionsDroppedWhileLocked: 0, backgroundRefreshAvailable: false, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            osWatchesGeofences: false, environment: nil, testDevice: nil
        )
    }

    /// The one line `start` writes: os_log, since the SDK's own log (os.Logger) is iOS 14 and later.
    private func said(_ options: BubblOptions) {
        guard options.logLevel != .none else { return }
        os_log("Bubbl %{public}@ needs iOS 17 or later: it does nothing on this device", log: OSLog(subsystem: "tech.bubbl.sdk", category: "Bubbl"), type: .info, Bubbl.sdkVersion)
    }
}
