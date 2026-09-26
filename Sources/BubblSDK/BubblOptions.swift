import Foundation
#if !COCOAPODS
import BubblCore
#endif

/// How `Bubbl.start` sets Bubbl up. The same options as Android's BubblOptions.
public struct BubblOptions: Sendable, Equatable {
    /// How much Bubbl writes to the system log (subsystem "tech.bubbl.sdk").
    public enum LogLevel: String, Sendable, Equatable, CaseIterable, Codable {
        case none, error, warning, info, debug

        var core: LogSeverity? {
            switch self {
            case .none: nil
            case .error: .error
            case .warning: .warning
            case .info: .info
            case .debug: .debug
            }
        }
    }

    /// The Bubbl API to talk to (https). Required for now: 5.0 pre-releases have no default until
    /// the production host is settled.
    public var baseUrl: String
    /// True when the app asks its users first: Bubbl does nothing (no network, no location, no
    /// notifications) until `Bubbl.setConsent(true)`.
    public var requireConsent: Bool
    public var logLevel: LogLevel
    /// The device's segments, as `Bubbl.setSegments` would set them.
    public var segments: [String]?

    public init(baseUrl: String, requireConsent: Bool = false, logLevel: LogLevel = .warning, segments: [String]? = nil) {
        self.baseUrl = baseUrl
        self.requireConsent = requireConsent
        self.logLevel = logLevel
        self.segments = segments
    }
}
