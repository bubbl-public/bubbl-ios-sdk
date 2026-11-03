import Foundation

/// The server-controlled wait before the requests a push sets off, so a campaign sent to every
/// device doesn't have every device call the API in the same second. The window is
/// `sync.pull_jitter_seconds` from GET /config (the server retunes it without an SDK release): a
/// push waits a uniformly random 0..window seconds. Missing or 0 is no wait, never a default of the
/// SDK's own; a negative number is 0; a window over `maxSeconds` is `maxSeconds`.
///
/// The field is named for the pull the server's design called it after, but this SDK pulls only
/// when the app comes to the front, which is never delayed. What it spaces out are the calls a push
/// wakes the SDK to make: the geofence fetch of a `sync_geofences` push, and the
/// GET /notifications/{id} of a push too big to carry its notification. Nothing the person asked
/// for waits: an app open, and a tap on the notification, never jitter. (iOS sends a push's
/// notification.received with the queue, not on arrival, so there is no event send to space out.)
///
/// `random` and `sleep` are the tests' to replace.
package struct PushJitter: Sendable {
    package typealias Random = @Sendable (ClosedRange<Double>) -> Double
    package typealias Sleep = @Sendable (Double) async -> Void

    /// What waits, and the longest it may.
    package enum Kind: Sendable, Equatable, CaseIterable {
        /// The fetch of a sync_geofences push: nobody sees it, so the whole window.
        case geofenceSync
        /// The fetch of a push's notification: its card waits for it, so at most 10 s.
        case notificationFetch

        var ceilingSeconds: Int64 {
            switch self {
            case .geofenceSync: PushJitter.maxSeconds
            case .notificationFetch: min(10, PushJitter.maxSeconds)
            }
        }
    }

    /// What iOS gives a push that wakes the app to finish (about 30 s: Apple's figure, not a
    /// promise), before it ends the handler and may throttle the app's later background pushes.
    package static let handlerBudgetSeconds: Double = 30

    /// The longest the API client waits on one request (URLSessionHttpClient's request timeout):
    /// what a wait must leave for the request that follows it.
    package static let requestTimeoutSeconds: Double = 20

    /// The longest window honoured, whatever the server says: what the handler's budget leaves
    /// after one request that runs to its timeout, 10 s.
    package static let maxSeconds: Int64 = Int64(handlerBudgetSeconds - requestTimeoutSeconds)

    /// When a push wake that starts at `start` must be finished by (see `wait`'s `finishBy`).
    package static func deadline(from start: Date = Date()) -> Date {
        start.addingTimeInterval(handlerBudgetSeconds)
    }

    package static let defaultRandom: Random = { Double.random(in: $0) }
    package static let defaultSleep: Sleep = { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    /// sync.pull_jitter_seconds as served (nil: the config has none).
    private let windowSeconds: @Sendable () -> Int64?
    private let random: Random
    private let sleep: Sleep

    package init(
        windowSeconds: @escaping @Sendable () -> Int64?,
        random: @escaping Random = PushJitter.defaultRandom,
        sleep: @escaping Sleep = PushJitter.defaultSleep
    ) {
        self.windowSeconds = windowSeconds
        self.random = random
        self.sleep = sleep
    }

    /// How long this push waits: 0 when the server asks for nothing. `finishBy` (a push wake's
    /// deadline) trims it to what leaves a request that runs to its timeout still inside the
    /// handler's budget, so a slow location fix before the wait can't push the handler past it.
    package func delaySeconds(_ kind: Kind, finishBy: Date? = nil, now: Date = Date()) -> Double {
        let window = min(max(windowSeconds() ?? 0, 0), kind.ceilingSeconds)
        guard window > 0 else { return 0 }
        let seconds = min(max(random(0...Double(window)), 0), Double(window))
        guard let finishBy else { return seconds }
        return min(seconds, max(0, finishBy.timeIntervalSince(now) - Self.requestTimeoutSeconds))
    }

    /// Waits `delaySeconds`, inside work that is already running.
    package func wait(_ kind: Kind, finishBy: Date? = nil) async {
        let seconds = delaySeconds(kind, finishBy: finishBy)
        if seconds > 0 { await sleep(seconds) }
    }
}
