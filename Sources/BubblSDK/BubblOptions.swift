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

    /// TEST-ONLY location mode, for QA rigs. Production apps leave it nil: the workspace's setting
    /// (/config `geofencing.mode`, "zone" by default) decides. When set it wins over the server,
    /// and "always" runs continuous background location (battery, blue status bar indicator).
    /// Not available in the Flutter and React Native wrappers.
    public enum GeofencingMode: String, Sendable, Equatable, CaseIterable { case zone, always }

    /// TEST-ONLY: forces the location mode over /config. Leave nil in production.
    public var forceGeofencingMode: GeofencingMode?

    public init(baseUrl: String, requireConsent: Bool = false, logLevel: LogLevel = .warning, segments: [String]? = nil, forceGeofencingMode: GeofencingMode? = nil) {
        self.forceGeofencingMode = forceGeofencingMode
        self.baseUrl = baseUrl
        self.requireConsent = requireConsent
        self.logLevel = logLevel
        self.segments = segments
    }
}
