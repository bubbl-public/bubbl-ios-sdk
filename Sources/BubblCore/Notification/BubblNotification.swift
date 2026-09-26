import Foundation

/// A notification as the device API returns it (the contract's Notification: from a geofence
/// event, a push, a pull or a fetch). `json` is kept whole: it's what an app's own handler is
/// given, and what the notification screen and the wrappers are handed.
///
/// Read leniently, as on Android: media of an unknown type and questions of an unknown type are
/// left out (a newer server), and only a missing id makes it no notification at all.
package struct BubblNotification: Sendable, Hashable {
    package let json: JSONValue
    package let campaignNotificationId: String
    package let locationId: String?
    package let isSurvey: Bool
    package let headline: String
    package let body: String
    package let media: Media?
    package let cta: Cta?
    package let questions: [Question]
    /// From a Sandbox workspace: Bubbl's screen shows a SANDBOX ribbon on it.
    package let sandbox: Bool

    package struct Cta: Sendable, Hashable {
        package let label: String
        package let url: String

        package init(label: String, url: String) {
            self.label = label
            self.url = url
        }
    }

    package struct Media: Sendable, Hashable {
        package enum Kind: String, Sendable, CaseIterable {
            case image, video, audio, youtube, application, text, file
        }

        package let kind: Kind
        package let url: String?
        package let mimeType: String?
        package let thumbnailUrl: String?

        /// The picture to show for it: the image itself, or a video's thumbnail.
        package var pictureUrl: String? { kind == .image ? url ?? thumbnailUrl : thumbnailUrl }
    }

    package struct Choice: Sendable, Hashable {
        package let id: String
        package let text: String
    }

    package struct Question: Sendable, Hashable {
        package enum Kind: String, Sendable, CaseIterable {
            case openEnded = "open_ended"
            case singleChoice = "single_choice"
            case multipleChoice = "multiple_choice"
            case rating, boolean, number, slider
        }

        package let id: String
        package let text: String
        package let kind: Kind
        package let required: Bool
        package let choices: [Choice]
    }

    /// Nil when `json` isn't a notification this SDK can show (no id).
    package init?(_ json: JSONValue) {
        guard let id = json["campaign_notification_id"]?.nonEmptyString else {
            BubblLog.warning("A notification without a campaign_notification_id was left out")
            return nil
        }
        self.json = json
        campaignNotificationId = id
        locationId = json["location_id"]?.nonEmptyString
        isSurvey = json["type"]?.stringValue == "survey"
        headline = json["headline"]?.stringValue ?? ""
        body = json["body"]?.stringValue ?? ""
        sandbox = json["sandbox"] == .bool(true)

        if let media = json["media"], media != .null {
            let type = media["type"]?.stringValue ?? ""
            if let kind = Media.Kind(rawValue: type.lowercased()) {
                self.media = Media(kind: kind, url: media["url"]?.nonEmptyString, mimeType: media["mime_type"]?.nonEmptyString, thumbnailUrl: media["thumbnail_url"]?.nonEmptyString)
            } else {
                BubblLog.warning("Media of unknown type \"\(type)\" left out of notification \(id) (a newer SDK shows it)")
                self.media = nil
            }
        } else {
            media = nil
        }

        if let url = json["cta"]?["url"]?.nonEmptyString {
            cta = Cta(label: json["cta"]?["label"]?.nonEmptyString ?? url, url: url)
        } else {
            cta = nil
        }

        if case .array(let items)? = json["survey"]?["questions"] {
            questions = items.compactMap { item in
                let type = item["type"]?.stringValue ?? ""
                guard let questionId = item["id"]?.nonEmptyString, let kind = Question.Kind(rawValue: type.lowercased()) else {
                    BubblLog.warning("A question of type \"\(type)\" left out of notification \(id) (a newer SDK asks it)")
                    return nil
                }
                var choices: [Choice] = []
                if case .array(let options)? = item["choices"] {
                    choices = options.compactMap { option in
                        option["id"]?.nonEmptyString.map { Choice(id: $0, text: option["text"]?.stringValue ?? "") }
                    }
                }
                let required = if case .bool(let value)? = item["required"] { value } else { false }
                return Question(id: questionId, text: item["text"]?.stringValue ?? "", kind: kind, required: required, choices: choices)
            }
        } else {
            questions = []
        }
    }

    /// From the notification's JSON text; nil when it isn't one.
    package init?(json text: String) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return nil }
        self.init(value)
    }

    /// The JSON text, as the device API sent it (key order aside).
    package var jsonText: String {
        (try? JSONEncoder().encode(json)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

extension JSONValue {
    /// A string that isn't empty; nil for anything else.
    package var nonEmptyString: String? {
        guard case .string(let value) = self, !value.isEmpty else { return nil }
        return value
    }
}
