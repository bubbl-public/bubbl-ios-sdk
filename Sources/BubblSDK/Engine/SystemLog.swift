import Foundation
import os
#if !COCOAPODS
import BubblCore
#endif

/// Points the core's log at the system log (Console, `log stream --subsystem tech.bubbl.sdk`).
/// Messages are public: the core's rule is that they carry ids, types and codes only. Errors also
/// reach the app's event listeners (BubblEvent.error), whatever the log level.
@available(iOS 17, *)
enum SystemLog {
    private static let logger = Logger(subsystem: "tech.bubbl.sdk", category: "Bubbl")

    static func use(_ level: BubblOptions.LogLevel) {
        let writes = level.core != nil
        BubblLog.setSink(level: level.core ?? .error) { level, message in
            if level == .error { BubblEvents.shared.emit(.error(message: message)) }
            guard writes else { return }
            switch level {
            case .error: logger.error("\(message, privacy: .public)")
            case .warning: logger.warning("\(message, privacy: .public)")
            case .info: logger.info("\(message, privacy: .public)")
            case .debug: logger.debug("\(message, privacy: .public)")
            }
        }
    }
}
