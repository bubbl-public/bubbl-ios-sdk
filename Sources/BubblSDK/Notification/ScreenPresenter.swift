#if os(iOS)
import SwiftUI
import UIKit
import UserNotifications
#if !COCOAPODS
import BubblCore
#endif

/// Shows notifications as Android's NotificationPresenter does: Bubbl's screen straight away when
/// the app is in front (or the notification was tapped); otherwise a system notification whose tap
/// opens the screen. True when it's been taken care of, so the system banner isn't needed too.
@available(iOS 17, *)
struct ScreenPresenter: NotificationPresenting {
    func present(_ notification: JSONValue, opened: Bool) async -> Bool {
        await present(notification, opened: opened, region: nil)
    }

    func present(_ notification: JSONValue, opened: Bool, region: BubblPresentationRegion?) async -> Bool {
        await present(notification, opened: opened, region: region, preview: false)
    }

    func present(_ notification: JSONValue, opened: Bool, region: BubblPresentationRegion?, preview: Bool) async -> Bool {
        guard let parsed = BubblNotification(notification) else { return false }
        let inFront = await MainActor.run { UIApplication.shared.applicationState != .background }
        if opened || inFront {
            return await MainActor.run { NotificationScreens.shared.show(parsed, opened: opened, region: region, preview: preview) }
        }
        // A preview is only ever shown on screen: no system notification, no delivery event.
        if preview { return false }
        return await SystemNotifications.post(parsed)
    }
}

/// Bubbl's screen, one notification at a time, in a window of its own over the app. Others that
/// arrive meanwhile wait their turn; one launched by a tap before the app has a scene waits for it.
@available(iOS 17, *)
@MainActor
final class NotificationScreens {
    static let shared = NotificationScreens()

    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?
    private var showing: String?
    private var model: NotificationModel?
    private var waiting: [(notification: BubblNotification, opened: Bool, region: BubblPresentationRegion?, preview: Bool)] = []
    private var watchingScenes = false

    func show(_ notification: BubblNotification, opened: Bool, region: BubblPresentationRegion? = nil, preview: Bool = false) -> Bool {
        let id = notification.campaignNotificationId
        guard showing != id, !waiting.contains(where: { $0.notification.campaignNotificationId == id }) else { return true }
        guard window == nil, let scene = activeScene() else {
            waiting.append((notification, opened, region, preview))
            watchScenes()
            return true
        }

        let events = EngineHost.shared.current.map(EngineHost.shared.notificationEvents).map { preview ? $0.asPreview() : $0 }
        let model = NotificationModel(notification: notification, opened: opened, events: events) { [weak self] in
            self?.closeCurrent()
        }
        let host = UIHostingController(rootView: NotificationScreen(model: model, region: region))
        host.view.backgroundColor = .clear

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = host
        previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        window.makeKeyAndVisible()
        self.window = window
        self.model = model
        showing = id
        return true
    }

    /// Closes the screen showing, if any, as its close button does (the dismissal reported).
    func dismissCurrent() {
        model?.dismiss()
    }

    private func closeCurrent() {
        window?.isHidden = true
        window = nil
        model = nil
        showing = nil
        previousKeyWindow?.makeKey()
        showNext()
    }

    private func showNext() {
        guard window == nil, !waiting.isEmpty, activeScene() != nil else { return }
        let next = waiting.removeFirst()
        _ = show(next.notification, opened: next.opened, region: next.region, preview: next.preview)
    }

    private func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first { $0.activationState == .foregroundInactive }
    }

    /// A notification waiting for the app to come to the front shows when it does.
    private func watchScenes() {
        guard !watchingScenes else { return }
        watchingScenes = true
        _ = NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NotificationScreens.shared.showNext() }
        }
    }
}

/// A notification that arrived with the app in the background (a geofence's): a system notification
/// carrying it, whose tap opens Bubbl's screen (it comes back as a Bubbl push, `opened`).
@available(iOS 17, *)
enum SystemNotifications {
    static func post(_ notification: BubblNotification) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await PermissionFlow.notificationAuthorization()
        guard status == .authorized || status == .provisional || status == .ephemeral else {
            BubblLog.warning("A notification wasn't shown: the app is in the background and notifications aren't allowed")
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = notification.headline
        content.body = notification.body
        content.sound = .default
        content.userInfo = [
            "bubbl": "1",
            "bubbl_v": PushMessage.version,
            "campaign_notification_id": notification.campaignNotificationId,
            "notification": notification.jsonText,
        ]
        if let picture = await attachment(notification) { content.attachments = [picture] }

        do {
            try await center.add(UNNotificationRequest(identifier: "bubbl.\(notification.campaignNotificationId)", content: content, trigger: nil))
        } catch {
            BubblLog.warning("A notification couldn't be posted (\(type(of: error)))")
            return false
        }
        BubblLog.debug("Notification posted (the app is in the background)")
        if let core = EngineHost.shared.current {
            try? await EngineHost.shared.notificationEvents(core).displayed(notification)
            EngineHost.shared.submit("events") { await $0.flushEvents() }
        }
        return true
    }

    /// The notification's picture, downloaded for the system notification when it's quick (a
    /// geofence's event has only seconds); none otherwise.
    private static func attachment(_ notification: BubblNotification) async -> UNNotificationAttachment? {
        guard let link = notification.media?.pictureUrl, link.lowercased().hasPrefix("https://"), let url = URL(string: link) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let downloaded = try? await session.download(from: url),
              let http = downloaded.1 as? HTTPURLResponse, (200...299).contains(http.statusCode)
        else { return nil }
        let location = downloaded.0
        let fileExtension = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        guard (try? FileManager.default.moveItem(at: location, to: file)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "bubbl-image", url: file)
    }
}
#endif
