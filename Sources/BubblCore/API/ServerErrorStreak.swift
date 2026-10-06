import Foundation

/// Server errors in a row (Android's ServerErrorStreak). A 5xx is retried quietly with backoff,
/// which is right for a blip, but a server that keeps failing (a staging database it can't reach,
/// say) left nothing in the log or in diagnostics' lastError: the install just never registered.
/// So once the server has answered 5xx to `threshold` requests in a row, that's said once, as an
/// error; any other answer ends the run, and a new run can say it again.
package final class ServerErrorStreak: @unchecked Sendable {
    package static let threshold = 3

    private let lock = NSLock()
    private var count = 0

    package init() {}

    /// The error to log for a response with `status` to `method` `path`, when it's the one that
    /// makes the run long enough; nil otherwise.
    package func record(status: Int, method: String, path: String) -> String? {
        let run: Int = lock.sync {
            count = status >= 500 ? count + 1 : 0
            return count
        }
        guard run == Self.threshold else { return nil }
        return "The Bubbl server answered HTTP \(status) to \(Self.threshold) requests in a row (the last: \(method) \(path)). Bubbl keeps retrying; nothing reaches the server until it recovers"
    }
}
