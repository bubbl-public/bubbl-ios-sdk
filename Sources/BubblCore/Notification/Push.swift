import Foundation

/// A push's data, read as the contract's push.json describes it. Only pushes marked bubbl=1 are
/// Bubbl's; everything else is the app's own and is left alone. On iOS the data keys sit beside
/// `aps` in the payload (FCM-relayed pushes too); the iOS layer turns the payload into
/// JSONValue once and hands its top level here.
package enum PushMessage: Sendable, Equatable {
    /// The whole notification came in the push.
    case full(campaignNotificationId: String, notification: JSONValue)
    /// Too big for the push: fetch it with GET /notifications/{id}.
    case reference(campaignNotificationId: String)
    /// A dashboard test push: no campaign behind it, so nothing to fetch or report.
    case test(title: String, body: String)
    /// Bubbl's, but not something this SDK can show (a newer format): not the app's to handle either.
    case unsupported(version: String)

    package static let version = "1"
    /// The data keys a Bubbl push carries (push.json).
    package static let keys = ["bubbl", "bubbl_v", "campaign_notification_id", "notification", "test", "title", "body", "image_url"]

    /// The picture for the system notification (image_url), for the notification service
    /// extension: there even when the notification itself was too big to come in the push. Only
    /// https, and only in Bubbl's pushes of a format this SDK reads.
    package static func imageUrl(_ data: [String: JSONValue]) -> String? {
        guard isBubbl(data), (data["bubbl_v"].flatMap(text) ?? version) == version,
              let url = data["image_url"]?.nonEmptyString, url.lowercased().hasPrefix("https://")
        else { return nil }
        return url
    }

    /// The contract's push data is all strings (FCM's data is, and the APNs sender puts the same
    /// string map beside aps). Flags are also taken as 1 or true, so a backend change can't make
    /// pushes vanish silently.
    package static func isBubbl(_ data: [String: JSONValue]) -> Bool {
        isSet(data["bubbl"])
    }

    /// Nil when the push isn't Bubbl's.
    package static func parse(_ data: [String: JSONValue]) -> PushMessage? {
        guard isBubbl(data) else { return nil }
        let version = data["bubbl_v"].flatMap(text) ?? Self.version
        guard version == Self.version else {
            BubblLog.warning("A push in data format \(version) was left alone: this SDK reads format \(Self.version)")
            return .unsupported(version: version)
        }
        if isSet(data["test"]) {
            return .test(title: data["title"]?.stringValue ?? "", body: data["body"]?.stringValue ?? "")
        }

        guard let id = data["campaign_notification_id"]?.nonEmptyString else {
            BubblLog.warning("A Bubbl push with no campaign_notification_id was left alone")
            return .unsupported(version: version)
        }
        // A notification that doesn't parse is fetched instead, rather than lost.
        switch data["notification"] {
        case .object?:
            return .full(campaignNotificationId: id, notification: data["notification"] ?? .null)
        case .string(let text)?:
            if let notification = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), case .object = notification {
                return .full(campaignNotificationId: id, notification: notification)
            }
            return .reference(campaignNotificationId: id)
        default:
            return .reference(campaignNotificationId: id)
        }
    }

    /// "1", 1 or true.
    private static func isSet(_ value: JSONValue?) -> Bool {
        switch value {
        case .string("1")?, .int(1)?, .bool(true)?: true
        default: false
        }
    }

    /// A string, or a whole number as one ("1" or 1).
    private static func text(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): text
        case .int(let number): String(number)
        default: nil
        }
    }
}

package enum NotificationsResult: Sendable, Equatable {
    case found([JSONValue])
    /// The notification no longer exists (deleted, or the campaign ended).
    case gone
    case failed(ApiFailure)
}

/// GET /notifications/{id} and POST /notifications/pull.
package struct NotificationSource: Sendable {
    private let api: DeviceApiClient

    package init(api: DeviceApiClient) {
        self.api = api
    }

    /// One notification a push referred to without carrying it.
    package func fetch(_ campaignNotificationId: String) async -> NotificationsResult {
        let response: ApiResponse
        do {
            let id = campaignNotificationId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? campaignNotificationId
            response = try await api.request("GET", "api/v1/notifications/\(id)")
        } catch {
            return .failed(.backoff)
        }

        struct One: Decodable { let data: JSONValue }
        if (200...299).contains(response.status) {
            guard let one = response.decode(One.self), case .object = one.data else { return .failed(.backoff) }
            return .found([one.data])
        }
        if response.status == 404 { return .gone }
        return .failed(ApiFailure.of(response))
    }

    /// Scheduled pushes this device hasn't had (a safety net for pushes the OS dropped). Each is
    /// claimed by the call, so a notification comes back from here at most once.
    package func pull() async -> NotificationsResult {
        let response: ApiResponse
        do {
            response = try await api.request("POST", "api/v1/notifications/pull")
        } catch {
            return .failed(.backoff)
        }

        struct Many: Decodable { let data: [JSONValue]? }
        guard (200...299).contains(response.status) else { return .failed(ApiFailure.of(response)) }
        return .found((response.decode(Many.self)?.data ?? []).filter { if case .object = $0 { true } else { false } })
    }
}
