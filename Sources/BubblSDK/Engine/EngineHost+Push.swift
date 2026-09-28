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

/// Shows a notification inside the app: Bubbl's notification screen (M2 slice 10), or the app's
/// own listener. True when it was shown there, so the system's banner isn't needed as well.
@available(iOS 17, *)
protocol NotificationPresenting: Sendable {
    func present(_ notification: JSONValue, opened: Bool) async -> Bool
}

/// Until the notification screen (slice 10): nothing is shown in the app, so a push in front keeps
/// the system's banner, and a tap just opens the app.
@available(iOS 17, *)
struct SystemAlertPresenter: NotificationPresenting {
    func present(_ notification: JSONValue, opened: Bool) async -> Bool {
        BubblLog.debug("A notification to show\(opened ? " (tapped)" : "")")
        return false
    }
}

/// A value the compiler can't see is safe to hand across: the completion handlers iOS passes the
/// notification delegate, which are called exactly once, from any thread.
@available(iOS 17, *)
struct Handed<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Push in the host: the APNs device token, and Bubbl's pushes as iOS hands them to the app (with
/// the app in front, and when their notification is tapped). The automatic integration
/// (PushIntegration) and the manual hooks on Bubbl both come here.
@available(iOS 17, *)
extension EngineHost {
    /// The APNs device token iOS gave the app: kept with its environment, and sent with PUT /device
    /// when it's new or changed.
    func pushTokenReceived(_ deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        let token = PushToken(token: hex, type: "apns", environment: Self.apnsEnvironment)
        guard platform.pushToken() != token else { return }
        platform.setPushToken(token)
        BubblLog.info("Got the device's APNs token (\(token.environment ?? "unknown environment"))")
        submit("device") { await $0.syncDevice() }
    }

    /// Which APNs environment this build's tokens belong to: the provisioning profile's
    /// aps-environment; no profile (the App Store's own signing) is production; the Simulator's
    /// tokens are sandbox ones.
    static let apnsEnvironment: String = {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let profile = try? Data(contentsOf: url)
        else { return "production" }
        return ProvisioningProfile.apnsEnvironment(profile) ?? "production"
        #endif
    }()

    /// A push's payload as JSON: its top level, where Bubbl's data sits beside aps. Values that
    /// aren't JSON are left out.
    static func pushData(_ userInfo: [AnyHashable: Any]) -> [String: JSONValue] {
        var data: [String: JSONValue] = [:]
        for (key, value) in userInfo {
            if let key = key as? String, let json = JSONValue(app: value) { data[key] = json }
        }
        return data
    }

    /// A notification to show now: `received` (it has just arrived for the first time) tells the
    /// app's event listeners; the app's notification listener may take it (then Bubbl shows
    /// nothing); otherwise Bubbl's screen. True when it was shown in the app.
    func show(_ json: JSONValue, received: Bool, opened: Bool) async -> Bool {
        guard let notification = BubblNotification(json) else { return false }
        let message = BubblMessage(notification)
        if received { BubblEvents.shared.emit(.notificationReceived(message)) }
        if let listener = notificationListener, await MainActor.run(body: { listener(message) }) { return true }
        return await presenter.present(json, opened: opened)
    }

    /// Notifications a geofence or a pull brought, each shown the first time it arrives.
    func arrived(_ notifications: [JSONValue], _ core: EngineCore) async {
        for notification in notifications {
            if case .show(let json, let received) = await core.notificationArrived(notification, opened: false) {
                _ = await show(json, received: received, opened: false)
            }
        }
    }

    /// The events of a notification's life, recorded for Bubbl and told to the app's listeners.
    func notificationEvents(_ core: EngineCore) -> NotificationEvents {
        NotificationEvents(
            observe: { type, notification in
                BubblEvents.event(type, BubblMessage(notification)).map(BubblEvents.shared.emit)
            },
            enqueue: { type, data in try await core.events.enqueue(type, data: data) }
        )
    }

    #if canImport(UserNotifications)
    /// The system banner, list entry and sound: how iOS shows a push in front when asked to.
    static let systemPresentation: UNNotificationPresentationOptions = [.banner, .list, .sound]

    /// A Bubbl push arrived with the app in front: how iOS should show it. Bubbl's screen shows a
    /// campaign's notification when it can (then no banner); a test push is a plain banner; a
    /// notification already shown, or anything while Bubbl isn't active, isn't shown again.
    func presentation(forArriving data: [String: JSONValue]) async -> UNNotificationPresentationOptions {
        // Started later in this launch (a wrapper's JavaScript or Dart not run yet): the system
        // shows it, rather than swallowing a push.
        guard let core = current else { return Self.systemPresentation }

        switch await core.receivedPush(data, opened: false) {
        case .show(let notification, let received):
            return await show(notification, received: received, opened: false) ? [] : Self.systemPresentation
        case .test:
            return Self.systemPresentation
        case .fetchFailed:
            // The alert has its title and body; a tap fetches it again.
            return Self.systemPresentation
        case .nothing:
            return []
        }
    }
    #endif

    /// A Bubbl push's notification was tapped: its notification opens (fetched first if it came
    /// without it; retried with backoff when that fails). A test push just opens the app.
    func pushOpened(_ data: [String: JSONValue]) async {
        guard let core = current else { return }

        switch await core.receivedPush(data, opened: true) {
        case .show(let notification, let received):
            _ = await show(notification, received: received, opened: true)
        case .fetchFailed(let id, _):
            submit("notifications.fetch.\(id)") { core in
                switch await core.receivedPush(data, opened: true) {
                case .show(let notification, let received):
                    _ = await self.show(notification, received: received, opened: true)
                    return .done
                case .fetchFailed(_, let failure):
                    return await core.handle(failure, "Fetching a notification")
                case .test, .nothing:
                    return .done
                }
            }
        case .test, .nothing:
            break
        }
    }

    #if os(iOS)
    /// A remote notification arrived via application(_:didReceiveRemoteNotification:fetchCompletionHandler:).
    /// Returns the UIBackgroundFetchResult to hand iOS's completion handler.
    func receivedRemoteNotification(_ data: [String: JSONValue]) async -> UIBackgroundFetchResult {
        if current == nil {
            applicationDidFinishLaunching()
        }
        guard let core = current, core.isActive else { return .noData }

        guard let message = PushMessage.parse(data) else { return .noData }
        switch message {
        case .syncGeofences:
            BubblLog.info("Silent push received: syncing geofences")
            let outcome = await runCheck(core, force: true, precise: false, rewatch: false, fix: nil)
            switch outcome {
            case .done:
                return .newData
            case .retry:
                return .failed
            }
        case .full, .reference:
            _ = await presentation(forArriving: data)
            return .newData
        case .test, .unsupported:
            return .noData
        }
    }
    #endif
}
