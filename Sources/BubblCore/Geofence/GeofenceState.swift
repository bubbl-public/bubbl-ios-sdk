import Foundation

/// What the engine knows between runs (the app may be killed between any two events).
package struct GeofenceState: Sendable, Hashable, Codable {
    package var set: GeofenceSet?
    /// Geofences whose circle the device is in, as the OS last said.
    package var insideCircles: Set<String>
    /// Polygon geofences the device is in (a subset of insideCircles).
    package var insidePolygons: Set<String>
    /// Whether the OS took the set on. False from saving a new set until the OS confirms, so a
    /// watch cut short (the app killed, the OS refusing) is done again at the next check.
    package var watching: Bool
    /// The centre and radius of the refresh region as last watched: where the device was when
    /// its nearest geofences were picked (iOS can't watch them all at once).
    package var watchCenter: LatLng?
    package var watchRadiusMeters: Double?

    package init(
        set: GeofenceSet? = nil,
        insideCircles: Set<String> = [],
        insidePolygons: Set<String> = [],
        watching: Bool = false,
        watchCenter: LatLng? = nil,
        watchRadiusMeters: Double? = nil
    ) {
        self.set = set
        self.insideCircles = insideCircles
        self.insidePolygons = insidePolygons
        self.watching = watching
        self.watchCenter = watchCenter
        self.watchRadiusMeters = watchRadiusMeters
    }
}

/// The state file couldn't be read or written, so it did neither. Before the first unlock after a
/// reboot iOS keeps protected files closed: an unreadable state is never taken for "no state",
/// which would forget where the device is and write over the file.
package struct GeofenceStateUnavailable: Error {
    package let underlying: any Error
}

package protocol GeofenceStateStore: Sendable {
    func load() throws -> GeofenceState
    func save(_ state: GeofenceState) throws
}

/// GeofenceState in memory: for tests.
package final class InMemoryGeofenceStateStore: GeofenceStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: GeofenceState

    package init(_ state: GeofenceState = GeofenceState()) {
        self.state = state
    }

    package func load() -> GeofenceState { lock.sync { state } }

    package func save(_ state: GeofenceState) {
        lock.sync { self.state = state }
    }
}

/// GeofenceState as a small JSON file, written atomically (on iOS, with file protection and kept
/// out of backups: a restored backup mustn't claim the device is inside places it isn't).
///
/// A missing file is no state; a file that reads but doesn't decode is no state too (the next
/// refresh starts afresh). A file that can't be read at all throws GeofenceStateUnavailable.
package final class FileGeofenceStateStore: GeofenceStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let writeOptions: Data.WritingOptions

    /// - Parameter writeOptions: added to `.atomic`; on iOS, the file protection class.
    package init(url: URL, writeOptions: Data.WritingOptions = []) {
        self.url = url
        self.writeOptions = writeOptions.union(.atomic)
    }

    package func load() throws -> GeofenceState {
        try lock.sync {
            guard FileManager.default.fileExists(atPath: url.path) else { return GeofenceState() }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw GeofenceStateUnavailable(underlying: error)
            }
            return (try? JSONDecoder().decode(GeofenceState.self, from: data)) ?? GeofenceState()
        }
    }

    package func save(_ state: GeofenceState) throws {
        try lock.sync {
            let data = try JSONEncoder().encode(state)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: writeOptions)
            } catch {
                throw GeofenceStateUnavailable(underlying: error)
            }
        }
    }
}
