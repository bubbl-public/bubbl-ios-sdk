import Foundation

/// What to do about a notification that has arrived (a push iOS handed the app, a pull, a geofence).
package enum PushHandling: Sendable, Equatable {
    /// Show this notification (Bubbl's screen, or the app's own listener). `received`: it arrived
    /// just now for the first time (notification.received was recorded), rather than being opened
    /// again.
    case show(JSONValue, received: Bool)
    /// A dashboard test push: there's nothing behind it to show or report.
    case test(title: String, body: String)
    /// Nothing to do: not Bubbl's, a newer format, already shown, gone, or Bubbl isn't active.
    case nothing
    /// It came without its notification and fetching it failed: try again (`failure` says when).
    case fetchFailed(campaignNotificationId: String, failure: ApiFailure)
}

extension EngineCore {
    /// A push iOS handed the app: its top-level data (beside aps), when it arrived with the app in
    /// front (`opened` false) or when its notification was tapped (`opened` true).
    ///
    /// Unlike Android, where the SDK draws every push, iOS shows the alert itself and the app
    /// hears of it only then. The first time a notification arrives, notification.received is
    /// recorded and it's to be shown; after that (a push and a pull, the same push in front and
    /// then tapped) it's shown again only when tapped: the person asked for it.
    package func receivedPush(_ data: [String: JSONValue], opened: Bool) async -> PushHandling {
        guard let message = PushMessage.parse(data) else { return .nothing }

        switch message {
        case .test(let title, let body):
            return .test(title: title, body: body)
        case .unsupported:
            return .nothing
        case .full(_, let notification):
            return await notificationArrived(notification, opened: opened)
        case .reference(let id):
            guard isActive else { return .nothing }
            switch await notifications.fetch(id) {
            case .found(let found):
                guard let notification = found.first else { return .nothing }
                return await notificationArrived(notification, opened: opened)
            case .gone:
                BubblLog.info("Notification \(id) is no longer available (deleted, or its campaign ended)")
                return .nothing
            case .failed(let failure):
                return .fetchFailed(campaignNotificationId: id, failure: failure)
            }
        }
    }

    /// A notification that has arrived, however it came: recorded as received and to be shown the
    /// first time; shown again only when `opened` (tapped). Nothing is shown or recorded without
    /// consent, after an opt-out, or paused.
    package func notificationArrived(_ notification: JSONValue, opened: Bool) async -> PushHandling {
        guard isActive, let id = notification["campaign_notification_id"]?.nonEmptyString else { return .nothing }
        let first = recentNotifications.firstTime(id)
        if first {
            _ = try? await events.enqueue("notification.received", data: ["campaign_notification_id": .string(id)])
        }
        return first || opened ? .show(notification, received: first) : .nothing
    }
}
