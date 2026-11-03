import Foundation

/// How long to wait after the server says wait (a 429, request_in_progress): the Retry-After the
/// server sent, read as whole seconds, never less than `minSeconds` and never more than
/// `maxSeconds`, with up to 10% on top so devices refused together don't come back together.
/// Android's RetryDelay.
///
/// Only whole seconds are read. An HTTP-date (which the header also allows) or a missing header is
/// the default, `defaultSeconds`: the server this SDK talks to sends seconds.
package enum RetryDelay {
    package static let defaultSeconds = 30
    /// However little the server asks for.
    package static let minSeconds = 30
    /// However much it asks for: a device that waits longer is one nobody hears from.
    package static let maxSeconds = 15 * 60

    private static let maxJitter = 0.1

    /// The header as whole seconds in 1...`maxSeconds`; `defaultSeconds` when it isn't whole seconds.
    package static func parse(_ header: String?) -> Int {
        let text = header?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) else { return defaultSeconds }
        // More digits than an Int holds is still "a very long time".
        return min(max(Int(text) ?? maxSeconds, 1), maxSeconds)
    }

    /// `retryAfter` as a wait to ask for: at least `minSeconds`, at most `maxSeconds`.
    package static func waitSeconds(_ retryAfter: Int) -> Int {
        min(max(retryAfter, minSeconds), maxSeconds)
    }

    /// The wait for a Retry-After of `retryAfter` seconds: at least `minSeconds`, 1.0 to 1.1 times
    /// that (`jitter`: 0 up to 1 picks where), and at most `maxSeconds` in all.
    package static func seconds(_ retryAfter: Int, jitter: Double = .random(in: 0...1)) -> Int {
        let base = Double(waitSeconds(retryAfter))
        let seconds = Int((base * (1 + maxJitter * min(max(jitter, 0), 1))).rounded())
        return min(seconds, maxSeconds)
    }
}
