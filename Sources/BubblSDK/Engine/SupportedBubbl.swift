import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif
#if !COCOAPODS
import BubblCore
#endif

/// `Bubbl`'s calls on iOS 17 and later: the engine.
@available(iOS 17, *)
struct SupportedBubbl: BubblBackend {
    var isSupported: Bool { true }

    // MARK: - Starting

    func start(apiKey: String, options: BubblOptions) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var baseUrl = options.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while baseUrl.hasSuffix("/") { baseUrl.removeLast() }

        guard !key.isEmpty else {
            SystemLog.use(options.logLevel)
            return BubblLog.error("Bubbl.start: the API key is empty")
        }
        guard Bubbl.isAllowedBaseUrl(baseUrl) else {
            SystemLog.use(options.logLevel)
            return BubblLog.error("Bubbl.start: baseUrl must be https:// (http:// only for localhost or a .test host)")
        }

        guard let core = EngineHost.shared.start(EngineConfig(apiKey: key, baseUrl: baseUrl), options: options) else { return }
        BubblLog.info("Bubbl \(BubblVersion.sdk) started")
        if let warning = EngineStart.keyWarning(apiKey: key, debugBuild: Self.debugBuild) { BubblLog.warning(warning) }
        core.announceSandbox()
    }

    /// The app's build, as the SDK was built with it (a Swift package builds in the app's
    /// configuration): for the key-and-build warning.
    static var debugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    func start(credential: BubblCredential, options: BubblOptions) {
        var baseUrl = options.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while baseUrl.hasSuffix("/") { baseUrl.removeLast() }

        guard [credential.keyId, credential.secret, credential.installId].allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            SystemLog.use(options.logLevel)
            return BubblLog.error("Bubbl.start: the credential is incomplete")
        }
        guard Bubbl.isAllowedBaseUrl(baseUrl) else {
            SystemLog.use(options.logLevel)
            return BubblLog.error("Bubbl.start: baseUrl must be https:// (http:// only for localhost or a .test host)")
        }

        guard let core = EngineHost.shared.start(EngineConfig(apiKey: nil, baseUrl: baseUrl), credential: credential.issued, options: options) else { return }
        BubblLog.info("Bubbl \(BubblVersion.sdk) started with a credential")
        core.announceSandbox()
    }

    func stop() {
        EngineHost.shared.stop()
    }

    // MARK: - Consent and privacy

    func setConsent(_ granted: Bool) {
        guard granted else { return optOut() }
        guard let core = started("setConsent") else { return }
        do {
            if try core.grantConsent() { EngineHost.shared.consentGiven(core) }
        } catch {
            BubblLog.warning("Bubbl.setConsent can't be saved until the device is unlocked: ask again then")
        }
    }

    func optOut() {
        guard let core = started("optOut") else { return }
        EngineHost.shared.optOut(core)
    }

    func deleteMyData() {
        guard let core = started("deleteMyData") else { return }
        EngineHost.shared.erase(core)
    }

    func setLocationEnabled(_ enabled: Bool) {
        guard let core = started("setLocationEnabled") else { return }
        EngineHost.shared.setLocationEnabled(enabled, core)
    }

    func registerTestDevice(_ code: String) async -> BubblTestDeviceResult {
        guard let core = started("registerTestDevice") else {
            return BubblTestDeviceResult(approved: false, message: "Bubbl.start hasn't been called")
        }
        let result = await core.registerTestDevice(code)
        return BubblTestDeviceResult(approved: result.approved, message: result.message)
    }

    // MARK: - Targeting and events

    func setSegments(_ segments: [String]) {
        guard let core = started("setSegments") else { return }
        do {
            if try core.segments.set(segments) { EngineHost.shared.submit("segments") { await $0.pushSegments() } }
        } catch {
            BubblLog.warning("Bubbl.setSegments: they can't be saved until the device is unlocked")
        }
    }

    func track(_ name: String, properties: [String: Any?]) {
        guard let core = started("track") else { return }
        var converted: [String: JSONValue] = [:]
        for (key, value) in properties {
            if let json = JSONValue(app: value) { converted[key] = json } else {
                BubblLog.warning("Bubbl.track: a property that isn't text, a number or true/false was left out")
            }
        }
        Task {
            if await core.track(name, properties: converted) {
                EngineHost.shared.submit("events") { await $0.flushEvents() }
            }
        }
    }

    // MARK: - Notifications

    func setNotificationListener(_ listener: (@MainActor @Sendable (BubblMessage) -> Bool)?) {
        EngineHost.shared.notificationListener = listener
    }

    func addEventListener(_ listener: @escaping @MainActor @Sendable (BubblEvent) -> Void) -> BubblEventToken {
        BubblEvents.shared.add(listener)
    }

    func removeEventListener(_ token: BubblEventToken) {
        BubblEvents.shared.remove(token)
    }

    func present(_ message: BubblMessage) {
        guard started("present") != nil else { return }
        Task { _ = await EngineHost.shared.presenter.present(message.notification.json, opened: false) }
    }

    /// Records a notification event the app reports (and tells its event listeners), then sends
    /// the queue.
    func report(_ call: String, _ record: @escaping @Sendable (NotificationEvents) async throws -> Void) {
        guard let core = started(call), core.isActive else { return }
        let events = EngineHost.shared.notificationEvents(core)
        Task {
            do {
                try await record(events)
                EngineHost.shared.submit("events") { await $0.flushEvents() }
            } catch {
                BubblLog.warning("Bubbl.\(call): not recorded (\(type(of: error)))")
            }
        }
    }

    func submitSurvey(_ message: BubblMessage, answers: [String: Any?]) -> Bool {
        var converted: [String: JSONValue] = [:]
        for (id, value) in answers {
            guard let json = JSONValue(app: value) else {
                BubblLog.warning("Bubbl.submitSurvey: the answer to \(id) isn't a choice id, a list of them, a number, true/false or text")
                return false
            }
            converted[id] = json
        }
        switch SurveyForm.fromAnswers(message.notification.questions, converted) {
        case .failure(let problem):
            BubblLog.warning("Bubbl.submitSurvey: \(problem)")
            return false
        case .success(let form):
            report("submitSurvey") { try await $0.surveySubmitted(message.notification, form) }
            return true
        }
    }

    func openCta(_ message: BubblMessage) {
        guard let link = message.ctaUrl, LinkPolicy.canOpen(link), let url = URL(string: link) else { return }
        report("reportCtaClicked") { try await $0.ctaClicked(message.notification) }
        #if canImport(UIKit) && !os(watchOS)
        Task { @MainActor in UIApplication.shared.open(url) }
        #endif
    }

    // MARK: - Push

    func isBubblMessage(_ userInfo: [AnyHashable: Any]) -> Bool {
        PushMessage.isBubbl(EngineHost.pushData(userInfo))
    }

    #if os(iOS)
    func setPushToken(_ deviceToken: Data) {
        EngineHost.shared.pushTokenReceived(deviceToken)
    }

    func willPresent(_ notification: UNNotification, completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) -> Bool {
        NotificationDelegateHooks.willPresent(notification, completionHandler)
    }

    func didReceive(_ response: UNNotificationResponse, completionHandler: @escaping () -> Void) -> Bool {
        NotificationDelegateHooks.didReceive(response, completionHandler)
    }
    #endif

    // MARK: - Permissions

    func permissionStatus() -> BubblPermissionStatus? {
        guard EngineHost.shared.current != nil else { return nil }
        return EngineHost.shared.platform.permissionStatus.map(BubblPermissionStatus.init)
    }

    func requestPermission(_ request: PermissionRequest, _ call: String) async -> BubblPermissionStatus? {
        guard EngineHost.shared.current != nil else {
            BubblLog.warning("Bubbl.\(call) before Bubbl.start: ignored")
            return nil
        }
        #if os(iOS)
        return BubblPermissionStatus(await PermissionFlow.shared.request(request))
        #else
        return nil
        #endif
    }

    func openSettings() {
        #if os(iOS)
        Task { @MainActor in PermissionFlow.shared.openSettings() }
        #endif
    }

    // MARK: - Diagnostics

    func diagnostics() async -> Bubbl.Diagnostics {
        let backgroundRefresh = await Self.backgroundRefreshAvailable()
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let core = EngineHost.shared.current else {
            return Bubbl.Diagnostics(
                started: false, supported: true, sdkVersion: Bubbl.sdkVersion, sdkSupported: true, registered: false, installId: nil, active: false,
                pausedUntil: nil, consentRequired: false, consent: nil, locationEnabled: true, permissions: nil, hasPushToken: false,
                geofences: 0, queuedEvents: 0, lastError: BubblLog.lastError, credentialRejected: EngineHost.shared.isCredentialRejected, backgroundLocation: false,
                transitionsDroppedWhileLocked: 0, backgroundRefreshAvailable: backgroundRefresh, lowPowerMode: lowPower,
                osWatchesGeofences: false, environment: nil, testDevice: nil
            )
        }
        let privacy = core.privacy.state
        return Bubbl.Diagnostics(
            started: true,
            supported: true,
            sdkVersion: Bubbl.sdkVersion,
            sdkSupported: core.sdkSupported,
            registered: core.everRegistered,
            installId: core.keptInstallId,
            active: core.isActive,
            pausedUntil: core.pausedUntilSeconds,
            consentRequired: privacy?.requireConsent ?? false,
            consent: privacy?.consent,
            locationEnabled: privacy?.locationEnabled ?? true,
            permissions: permissionStatus(),
            hasPushToken: EngineHost.shared.platform.pushToken() != nil,
            geofences: (try? await core.geofences.geofenceCount()) ?? 0,
            queuedEvents: (try? await core.events.size()) ?? 0,
            lastError: BubblLog.lastError,
            credentialRejected: EngineHost.shared.isCredentialRejected,
            backgroundLocation: await Self.backgroundLocation(),
            transitionsDroppedWhileLocked: core.transitionsDroppedWhileLocked,
            backgroundRefreshAvailable: backgroundRefresh,
            lowPowerMode: lowPower,
            osWatchesGeofences: await Self.osWatchesGeofences(),
            environment: core.workspace?.environment,
            testDevice: core.workspace?.testDevice.map { Bubbl.Diagnostics.TestDevice(status: $0.status, code: $0.code) }
        )
    }

    // MARK: - Internals

    private func started(_ call: String) -> EngineCore? {
        guard let core = EngineHost.shared.current else {
            BubblLog.warning("Bubbl.\(call) before Bubbl.start: ignored")
            return nil
        }
        return core
    }

    /// "Always", with precise location: iOS watches the geofences with the app closed.
    @MainActor
    private static func backgroundLocation() -> Bool {
        #if os(iOS)
        LocationService.shared.access == .always
        #else
        false
        #endif
    }

    @MainActor
    private static func osWatchesGeofences() -> Bool {
        #if os(iOS)
        LocationService.shared.osWatches
        #else
        false
        #endif
    }

    @MainActor
    private static func backgroundRefreshAvailable() -> Bool {
        #if canImport(UIKit) && !os(watchOS)
        UIApplication.shared.backgroundRefreshStatus == .available
        #else
        false
        #endif
    }
}
