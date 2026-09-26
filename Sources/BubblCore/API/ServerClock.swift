import Foundation

/// The server's idea of "now", for request timestamps: a signed request is refused when its
/// timestamp is more than 300 s from the server's clock, and phone clocks drift or are set by
/// hand. The offset comes from each response's Date header, and from the server_time a
/// timestamp_out_of_range error carries.
package final class ServerClock: @unchecked Sendable {
    /// Offset changes smaller than this are ignored: the Date header has one-second resolution
    /// and a response takes time to arrive.
    private static let toleranceSeconds: Int64 = 5

    private let lock = NSLock()
    private var offset: Int64
    private let deviceNowSeconds: @Sendable () -> Int64
    private let onChange: @Sendable (Int64) -> Void

    /// - Parameter onChange: told each new offset, so it can be kept across launches.
    package init(
        initialOffsetSeconds: Int64 = 0,
        deviceNowSeconds: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        onChange: @escaping @Sendable (Int64) -> Void = { _ in }
    ) {
        offset = initialOffsetSeconds
        self.deviceNowSeconds = deviceNowSeconds
        self.onChange = onChange
    }

    package var offsetSeconds: Int64 {
        lock.sync { offset }
    }

    /// Unix seconds as the server would read them now.
    package func nowSeconds() -> Int64 {
        deviceNowSeconds() + offsetSeconds
    }

    /// Adopt the server's time.
    package func sync(serverSeconds: Int64) {
        let candidate = serverSeconds - deviceNowSeconds()
        let changed: Bool = lock.sync {
            guard abs(candidate - offset) >= Self.toleranceSeconds else { return false }
            offset = candidate
            return true
        }
        if changed { onChange(candidate) }
    }

    /// sync(serverSeconds:) from an HTTP Date header (RFC 1123); an absent or unreadable one
    /// changes nothing.
    package func sync(dateHeader: String?) {
        guard let dateHeader, let date = Self.httpDate(dateHeader) else { return }
        sync(serverSeconds: Int64(date.timeIntervalSince1970))
    }

    /// Parses "Sun, 06 Nov 1994 08:49:37 GMT". One formatter for every response, used one at a
    /// time (DateFormatter isn't safe to share across threads everywhere the core runs).
    package static func httpDate(_ value: String) -> Date? {
        httpDateLock.sync { httpDateFormatter.date(from: value.trimmingCharacters(in: .whitespaces)) }
    }

    private static let httpDateLock = NSLock()
    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
