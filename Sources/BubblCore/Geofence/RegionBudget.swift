import Foundation

/// How many regions Bubbl may ask the OS to watch, learnt from what the OS refuses (iOS's CLMonitor
/// says so per condition, after the fact). iOS's 20 are shared with the app's own and other SDKs'
/// conditions, which Bubbl can't see: when some of Bubbl's go unmonitored for being over the
/// limit, Bubbl asks for that many fewer from then on (never fewer than one, the refresh region),
/// rather than asking for the same number again and again.
///
/// A condition the OS can't monitor at all ("unsupported") is dropped on its own; only when all of
/// Bubbl's are, or the refresh region is, does the device count as unable to watch geofences (and
/// the platform decides entering and leaving from fixes instead).
package struct RegionBudget: Sendable, Equatable {
    package enum Unsupported: Sendable, Equatable {
        /// Only this condition: the rest are watched.
        case dropOne
        /// Nothing can be watched here: decide from fixes.
        case deviceCantWatch
    }

    package static let osLimit = 20

    /// Bubbl's own cap, lowered by each condition refused for being over the limit.
    package private(set) var cap = RegionBudget.osLimit
    private var watched: Set<String> = []
    private var overLimit: Set<String> = []
    /// For the life of the process: the OS won't take these however often they're asked for.
    private var unsupported: Set<String> = []

    /// Bubbl's conditions the OS can't watch here, for the engine to pick others in their place.
    package var excluded: Set<String> { unsupported }

    package init() {}

    /// What Bubbl may watch: the OS's limit less the regions it can see others watching, and no
    /// more than its own cap.
    package func capacity(othersVisible: Int) -> Int {
        max(0, min(Self.osLimit - othersVisible, cap))
    }

    /// Bubbl has just asked the OS to watch `ids` (replacing what it watched before).
    package mutating func watching(_ ids: [String]) {
        watched = Set(ids)
        overLimit = []
    }

    /// The OS isn't watching `id` because the app is over its limit. True when that lowered the
    /// cap (so the next watch asks for fewer).
    package mutating func overLimit(_ id: String) -> Bool {
        guard watched.contains(id), overLimit.insert(id).inserted else { return false }
        let lowered = max(1, watched.count - overLimit.count)
        guard lowered < cap else { return false }
        cap = lowered
        return true
    }

    /// The OS can't watch `id` at all. Nil when that was known already (nothing new to say).
    package mutating func unsupported(_ id: String, refreshRegionId: String) -> Unsupported? {
        guard unsupported.insert(id).inserted else { return nil }
        if id == refreshRegionId || (!watched.isEmpty && watched.isSubset(of: unsupported)) { return .deviceCantWatch }
        return .dropOne
    }
}
