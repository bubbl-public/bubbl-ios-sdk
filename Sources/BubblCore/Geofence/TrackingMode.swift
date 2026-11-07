import Foundation

/// How a workspace wants location watched, from /config `geofencing.mode`: "zone" (the approach zone and
/// short live tracking sessions, BUB-441; the default) or "always" (continuous background location
/// as SDK 4 did, BUB-442: more reliable, much more battery, and the blue status bar indicator all the time).
package enum TrackingMode: String, Sendable, Equatable {
    case zone, always

    /// The mode in force: the test-only override of the app if set, else the config's, else "zone".
    /// Anything the config says that isn't "zone" or "always" is "zone".
    package static func resolve(forced: TrackingMode?, _ geofencing: JSONValue?) -> TrackingMode {
        forced ?? geofencing?["mode"]?.stringValue.flatMap(TrackingMode.init(rawValue:)) ?? .zone
    }
}

/// How always-on tracking samples, from /config `geofencing` (interval_s, distance_m). Missing or odd
/// values give the defaults. iOS has no interval for location updates: `intervalSeconds` is the
/// shortest time between fixes the SDK acts on.
package struct AlwaysSettings: Sendable, Hashable {
    package static let defaultIntervalSeconds = 30
    package static let defaultDistanceMeters = 25

    package var intervalSeconds = defaultIntervalSeconds
    package var distanceMeters = defaultDistanceMeters

    package init(intervalSeconds: Int = defaultIntervalSeconds, distanceMeters: Int = defaultDistanceMeters) {
        self.intervalSeconds = intervalSeconds
        self.distanceMeters = distanceMeters
    }

    package init(_ geofencing: JSONValue?) {
        self.init(
            intervalSeconds: Self.number(geofencing, "interval_s", 1...3_600) ?? Self.defaultIntervalSeconds,
            distanceMeters: Self.number(geofencing, "distance_m", 1...5_000) ?? Self.defaultDistanceMeters
        )
    }

    private static func number(_ geofencing: JSONValue?, _ key: String, _ allowed: ClosedRange<Int>) -> Int? {
        geofencing?[key]?.int64.flatMap { allowed.contains(Int($0)) ? Int($0) : nil }
    }
}

/// When always-on tracking runs: the mode is "always", Bubbl may use location, and the app has "Always".
/// It ends when any of those stops being so. Without "Always" the SDK stays in zone mode (the caller logs it once).
package enum AlwaysTracking {
    package enum Action: Sendable, Equatable {
        case start, keep, stop
        /// Wanted but can't run without "Always".
        case needsAlways
        case idle
    }

    package static func decide(mode: TrackingMode, active: Bool, locationActive: Bool, hasAlways: Bool) -> Action {
        let wanted = mode == .always && locationActive
        if active { return wanted && hasAlways ? .keep : .stop }
        guard wanted else { return .idle }
        return hasAlways ? .start : .needsAlways
    }
}

/// Significant-change monitoring is the relaunch backstop (with the CLMonitor geofences) whenever Bubbl may use location and the app
/// has "Always". It is registered at every launch, before any fix: iOS requires a relaunched app to register it again, and a launch
/// with no fix never reaches the geofence check that does it too (BUB-449).
package enum RelaunchBackstop {
    package static func shouldRegister(locationActive: Bool, hasAlways: Bool) -> Bool { locationActive && hasAlways }
}

extension SdkConfig {
    /// geofencing.mode, "zone" unless the config says "always".
    package func trackingMode(forced: TrackingMode? = nil) -> TrackingMode { TrackingMode.resolve(forced: forced, json["geofencing"]) }
    package var always: AlwaysSettings { AlwaysSettings(json["geofencing"]) }
}
