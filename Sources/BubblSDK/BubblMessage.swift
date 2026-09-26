import Foundation
#if !COCOAPODS
import BubblCore
#endif

/// A notification from Bubbl, as an app's own handler sees it (`Bubbl.setNotificationListener`):
/// enough to draw it itself, or to hand back to `Bubbl.present` to show Bubbl's screen. The same
/// as Android's BubblMessage.
public struct BubblMessage: Sendable, Hashable, CustomStringConvertible {
    let notification: BubblNotification

    init(_ notification: BubblNotification) {
        self.notification = notification
    }

    /// A message back from its `json` (kept for an in-app inbox, say, then shown again with
    /// `Bubbl.present`); nil when it isn't one.
    public init?(json: String) {
        guard let notification = BubblNotification(json: json) else { return nil }
        self.init(notification)
    }

    /// Echo this on anything the app reports about it.
    public var id: String { notification.campaignNotificationId }
    public var headline: String { notification.headline }
    public var body: String { notification.body }
    public var isSurvey: Bool { notification.isSurvey }
    /// From a Sandbox workspace: an app drawing it itself should mark it as such, as Bubbl's
    /// screen does with its SANDBOX ribbon.
    public var isSandbox: Bool { notification.sandbox }

    /// image, video, audio, youtube, application, text or file; nil without media.
    public var mediaType: String? { notification.media?.kind.rawValue }
    public var mediaUrl: String? { notification.media?.url }
    public var mediaThumbnailUrl: String? { notification.media?.pictureUrl }

    public var ctaLabel: String? { notification.cta?.label }
    public var ctaUrl: String? { notification.cta?.url }

    /// A survey's questions in order (empty for a message), for an app drawing it itself.
    public var questions: [BubblQuestion] { notification.questions.map(BubblQuestion.init) }

    /// The whole notification as the device API sent it (JSON), e.g. to pass to a wrapper.
    public var json: String { notification.jsonText }

    public var description: String { "BubblMessage(\(id), \"\(headline)\")" }
}

/// One question of a survey, and what `Bubbl.submitSurvey` takes as its answer, by `type`:
/// single choice a choice id; multiple choice a list of choice ids; rating a whole number 1–5;
/// boolean true/false; number a number; slider a number from 0 to 10; open-ended text (≤ 2000).
public struct BubblQuestion: Sendable, Hashable {
    /// Android's BubblQuestion.Type (`Type` is taken in Swift).
    public enum Kind: String, Sendable, CaseIterable {
        case openEnded = "open_ended"
        case singleChoice = "single_choice"
        case multipleChoice = "multiple_choice"
        case rating, boolean, number, slider
    }

    public struct Choice: Sendable, Hashable {
        public let id: String
        public let text: String
    }

    public let id: String
    public let text: String
    public let type: Kind
    public let required: Bool
    public let choices: [Choice]

    init(_ question: BubblNotification.Question) {
        id = question.id
        text = question.text
        type = Kind(rawValue: question.kind.rawValue) ?? .openEnded
        required = question.required
        choices = question.choices.map { Choice(id: $0.id, text: $0.text) }
    }
}

/// What Bubbl does, as it happens, for an app that wants to know (`Bubbl.addEventListener`): each
/// step of a notification's life, geofences entered and left, and errors. Delivered on the main
/// thread. They're for the app's own use (its analytics, its UI); Bubbl records its own.
///
/// New cases arrive in minor versions, so switch over it with a `default:` branch.
public enum BubblEvent: Sendable, Hashable {
    /// A notification arrived (from a geofence, a push or a pull), before it's shown.
    case notificationReceived(BubblMessage)
    case notificationDisplayed(BubblMessage)
    /// Opened from its system notification.
    case notificationOpened(BubblMessage)
    case notificationCtaClicked(BubblMessage)
    case notificationDismissed(BubblMessage)
    case mediaViewed(BubblMessage)
    case mediaCompleted(BubblMessage)
    case surveyStarted(BubblMessage)
    case surveySubmitted(BubblMessage)
    /// The device entered one of the workspace's locations.
    case geofenceEntered(locationId: String)
    case geofenceExited(locationId: String)
    /// Something went wrong that Bubbl couldn't fix itself (also in diagnostics' lastError).
    case error(message: String)
    /// The server refused the credential Bubbl was started with (`Bubbl.start(credential:options:)`):
    /// Bubbl has stopped until it's started with a new one.
    case credentialRejected
}

/// What `Bubbl.addEventListener` returns, to remove that listener with (Swift closures have no
/// identity to remove them by).
public struct BubblEventToken: Hashable, Sendable {
    let id: UUID
}

/// The app's event listeners, each told of every event on the main thread.
final class BubblEvents: @unchecked Sendable {
    static let shared = BubblEvents()

    private let lock = NSLock()
    private var listeners: [UUID: @MainActor @Sendable (BubblEvent) -> Void] = [:]

    func add(_ listener: @escaping @MainActor @Sendable (BubblEvent) -> Void) -> BubblEventToken {
        let id = UUID()
        lock.sync { listeners[id] = listener }
        return BubblEventToken(id: id)
    }

    func remove(_ token: BubblEventToken) {
        lock.sync { _ = listeners.removeValue(forKey: token.id) }
    }

    func emit(_ event: BubblEvent) {
        let current = lock.sync { Array(listeners.values) }
        guard !current.isEmpty else { return }
        Task { @MainActor in current.forEach { $0(event) } }
    }

    /// The event for a notification event the engine recorded (NotificationEvents' types).
    static func event(_ type: String, _ message: BubblMessage) -> BubblEvent? {
        switch type {
        case "notification.displayed": .notificationDisplayed(message)
        case "notification.opened": .notificationOpened(message)
        case "notification.cta_clicked": .notificationCtaClicked(message)
        case "notification.dismissed": .notificationDismissed(message)
        case "media.viewed": .mediaViewed(message)
        case "media.completed": .mediaCompleted(message)
        case "notification.survey_started": .surveyStarted(message)
        case "survey.submitted": .surveySubmitted(message)
        default: nil
        }
    }
}
