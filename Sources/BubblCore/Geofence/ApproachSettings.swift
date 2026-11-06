import Foundation

/// How the approach zones and live tracking sessions are sized, from /config `geofencing`
/// (min_os_radius_m, approach_buffer_m, max_session_s), as Android's ApproachSettings. The keys may
/// be missing (a server that doesn't send them yet) or odd: anything not a sensible number falls
/// back to the default.
package struct ApproachSettings: Sendable, Hashable {
    package static let defaultMinOsRadiusMeters = 150
    package static let defaultBufferMeters = 50
    package static let defaultMaxSessionSeconds = 600

    /// The OS is told to watch at least this radius: it can't be trusted below about 100-150 m.
    package var minOsRadiusMeters = defaultMinOsRadiusMeters
    /// Added beyond the geofence, so tracking starts before the device gets there.
    package var bufferMeters = defaultBufferMeters
    /// The longest a live tracking session runs.
    package var maxSessionSeconds = defaultMaxSessionSeconds

    package init(minOsRadiusMeters: Int = defaultMinOsRadiusMeters, bufferMeters: Int = defaultBufferMeters, maxSessionSeconds: Int = defaultMaxSessionSeconds) {
        self.minOsRadiusMeters = minOsRadiusMeters
        self.bufferMeters = bufferMeters
        self.maxSessionSeconds = maxSessionSeconds
    }

    /// From the config's `geofencing` object (nil: all defaults).
    package init(_ geofencing: JSONValue?) {
        self.init(
            minOsRadiusMeters: Self.number(geofencing, "min_os_radius_m", 0...5_000) ?? Self.defaultMinOsRadiusMeters,
            bufferMeters: Self.number(geofencing, "approach_buffer_m", 0...5_000) ?? Self.defaultBufferMeters,
            maxSessionSeconds: Self.number(geofencing, "max_session_s", 10...3_600) ?? Self.defaultMaxSessionSeconds
        )
    }

    /// A whole number within `allowed`; nil (so the default) for anything else, as Android does.
    private static func number(_ geofencing: JSONValue?, _ key: String, _ allowed: ClosedRange<Int>) -> Int? {
        geofencing?[key]?.int64.flatMap { allowed.contains(Int($0)) ? Int($0) : nil }
    }

    /// The radius the OS watches for `geofence`: its farthest reach (a polygon's corner, say) plus
    /// the buffer, and not under the floor.
    package func osRadiusMeters(_ geofence: Geofence) -> Double {
        let reach = geofence.polygon?.map { Geo.distanceMeters(geofence.center, $0) }.max() ?? 0
        return max((max(Double(geofence.radiusMeters), reach) + Double(bufferMeters)).rounded(.up), Double(minOsRadiusMeters))
    }
}

/// When a live tracking session (precise fixes every second or so, even with the app closed) runs:
/// only while the device is in an approach zone but not (as far as a fix can tell) in the geofence
/// itself, and with "Always". The platform ends it at `ApproachSettings.maxSessionSeconds` too.
package enum TrackingSession {
    package enum Action: Sendable, Equatable {
        case start
        case keep
        /// Entered, left, or no longer allowed: end it.
        case stop
        /// Something is pending but the session can't run without "Always": the caller logs it and relies on the re-check fixes.
        case needsAlways
        case idle
    }

    /// `pending`: some geofence's approach zone is entered and the geofence itself isn't (yet).
    package static func decide(active: Bool, pending: Bool, hasAlways: Bool) -> Action {
        if active { return pending && hasAlways ? .keep : .stop }
        guard pending else { return .idle }
        return hasAlways ? .start : .needsAlways
    }
}
