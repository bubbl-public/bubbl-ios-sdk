import Foundation

/// How much the SDK says (BubblOptions.logLevel), most important first.
package enum LogSeverity: Int, Sendable, Comparable, CaseIterable {
    case error, warning, info, debug

    package static func < (lhs: LogSeverity, rhs: LogSeverity) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The SDK's log, as Android's BubblLog: one place the core reports whatever it drops or holds
/// back (a question type a newer dashboard added, a refused event, a batch the server rejected),
/// so a developer can see why. Silent until the iOS layer points it at os.Logger and sets the
/// level BubblOptions asks for; a message below that level is never even built.
///
/// **What a message may say.** It can end up in Console and sysdiagnose for anyone holding the
/// device, so: ids, types, counts, codes and statuses only. Never coordinates or fixes, push
/// tokens, the credential or its secret, survey answers, or the app's own event properties.
package enum BubblLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sink: @Sendable (LogSeverity, String) -> Void = { _, _ in }
    nonisolated(unsafe) private static var level: LogSeverity = .warning
    nonisolated(unsafe) private static var lastErrorMessage: String?

    /// Where messages go from now on (the iOS layer, or a test), and from which level up.
    package static func setSink(level: LogSeverity = .debug, _ sink: @escaping @Sendable (LogSeverity, String) -> Void) {
        lock.sync {
            self.sink = sink
            self.level = level
        }
    }

    /// The level messages are kept from (BubblOptions.logLevel).
    package static func setLevel(_ level: LogSeverity) {
        lock.sync { self.level = level }
    }

    /// The last error logged, for diagnostics (kept whatever the level).
    package static var lastError: String? { lock.sync { lastErrorMessage } }

    package static func error(_ message: @autoclosure () -> String) { log(.error, message) }
    package static func warning(_ message: @autoclosure () -> String) { log(.warning, message) }
    package static func info(_ message: @autoclosure () -> String) { log(.info, message) }
    package static func debug(_ message: @autoclosure () -> String) { log(.debug, message) }

    private static func log(_ level: LogSeverity, _ message: () -> String) {
        let (sink, wanted) = lock.sync { (self.sink, level <= self.level) }
        guard wanted || level == .error else { return }
        let text = message()
        if level == .error { lock.sync { lastErrorMessage = text } }
        if wanted { sink(level, text) }
    }
}
