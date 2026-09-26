import Foundation

package struct LatLng: Sendable, Hashable, Codable {
    package let latitude: Double
    package let longitude: Double

    package init(_ latitude: Double, _ longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Where the device is, as a location fix gives it. `timeMillis` is on the device's clock.
package struct Fix: Sendable, Hashable, Codable {
    package let position: LatLng
    package let accuracyMeters: Double?
    package let timeMillis: Int64

    package init(_ position: LatLng, accuracyMeters: Double?, timeMillis: Int64) {
        self.position = position
        self.accuracyMeters = accuracyMeters
        self.timeMillis = timeMillis
    }
}

/// One geofence from GET /geofences. A polygon is watched through the circle around it
/// (`center`, `radiusMeters`); only being inside the polygon itself counts as being there.
package struct Geofence: Sendable, Hashable, Codable {
    package let id: String
    package let name: String
    package let center: LatLng
    package let radiusMeters: Int
    /// Nil for a circle. A ring, not closed: the last point joins the first.
    package let polygon: [LatLng]?
    package let reportsEnter: Bool
    package let reportsExit: Bool

    package init(id: String, name: String, center: LatLng, radiusMeters: Int, polygon: [LatLng]?, reportsEnter: Bool, reportsExit: Bool) {
        self.id = id
        self.name = name
        self.center = center
        self.radiusMeters = radiusMeters
        self.polygon = polygon
        self.reportsEnter = reportsEnter
        self.reportsExit = reportsExit
    }

    package var isPolygon: Bool { polygon != nil }
}

/// What GET /geofences last returned, with where and when it was asked from: the device asks
/// again after `refreshSeconds`, or once it has moved `refreshDistanceMeters` from `origin`.
package struct GeofenceSet: Sendable, Hashable, Codable {
    package var geofences: [Geofence]
    package var refreshSeconds: Int64
    package var refreshDistanceMeters: Int
    package var origin: LatLng
    /// On the server's clock.
    package var fetchedAtSeconds: Int64
    package var etag: String?

    package init(geofences: [Geofence], refreshSeconds: Int64, refreshDistanceMeters: Int, origin: LatLng, fetchedAtSeconds: Int64, etag: String?) {
        self.geofences = geofences
        self.refreshSeconds = refreshSeconds
        self.refreshDistanceMeters = refreshDistanceMeters
        self.origin = origin
        self.fetchedAtSeconds = fetchedAtSeconds
        self.etag = etag
    }

    /// From a GET /geofences 200 body; nil when it isn't one. Geofences this SDK can't watch (an
    /// unknown shape, a ring of fewer than three points) are left out.
    package static func fromResponse(_ body: Data, origin: LatLng, fetchedAtSeconds: Int64, etag: String?) -> GeofenceSet? {
        guard let response = try? JSONDecoder().decode(GeofencesResponse.self, from: body) else { return nil }
        return GeofenceSet(
            geofences: response.data.compactMap(\.geofence),
            refreshSeconds: response.meta.refresh_seconds,
            refreshDistanceMeters: response.meta.refresh_distance_meters,
            origin: origin,
            fetchedAtSeconds: fetchedAtSeconds,
            etag: etag
        )
    }
}

/// GET /geofences as the contract describes it (contracts/v1: Geofence, GeofencesMeta).
private struct GeofencesResponse: Decodable {
    let data: [Item]
    let meta: Meta

    struct Meta: Decodable {
        let refresh_seconds: Int64
        let refresh_distance_meters: Int
    }

    struct Item: Decodable {
        let id: String
        let name: String?
        let shape: String
        let center: LatLng
        let radius_meters: Int
        let polygon: [LatLng]?
        let triggers: [String]

        var geofence: Geofence? {
            let ring: [LatLng]?
            switch shape {
            case "circle":
                ring = nil
            case "polygon":
                guard let polygon, polygon.count >= 3 else { return nil }
                ring = polygon
            default:
                return nil
            }
            return Geofence(
                id: id,
                name: name ?? "",
                center: center,
                radiusMeters: radius_meters,
                polygon: ring,
                reportsEnter: triggers.contains("enter"),
                reportsExit: triggers.contains("exit")
            )
        }
    }
}

package enum Geo {
    private static let earthRadiusMeters = 6_371_008.8

    /// Great-circle distance (haversine).
    package static func distanceMeters(_ a: LatLng, _ b: LatLng) -> Double {
        let radians = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * radians
        let dLng = (b.longitude - a.longitude) * radians
        let sinLat = sin(dLat / 2)
        let sinLng = sin(dLng / 2)
        let h = sinLat * sinLat + cos(a.latitude * radians) * cos(b.latitude * radians) * sinLng * sinLng
        return 2 * earthRadiusMeters * asin(min(1, h.squareRoot()))
    }

    /// Whether `point` is inside `ring` (even-odd ray casting on latitude/longitude). Exact enough
    /// at geofence scale; not for rings that cross the antimeridian or a pole, which a shop or a
    /// venue never does.
    package static func contains(_ ring: [LatLng], _ point: LatLng) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i]
            let b = ring[j]
            if (a.latitude > point.latitude) != (b.latitude > point.latitude) {
                let crossing = (b.longitude - a.longitude) * (point.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude
                if point.longitude < crossing { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}
