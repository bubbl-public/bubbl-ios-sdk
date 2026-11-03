import Foundation

/// The device-wide "not before" the server asked for with a 429. While it runs, no call to the
/// device API goes out (see DeviceApiClient): each fails at once, as the wait that's left, so a
/// device the server turned away doesn't spend a request on every one of its jobs to be turned
/// away again. Nothing is dropped by it: events stay queued and each job tries again when it has
/// passed. Android's RetryHold.
///
/// Kept in `store`, so a wait outlives the process. Kept as a device-clock time, which a clock set
/// back must not stretch: what's left never exceeds `RetryDelay.maxSeconds`. A store that can't
/// be read yet (before the first unlock after a reboot) is no hold, and is asked again.
package final class RetryHold: @unchecked Sendable {
    private let store: any ValueStore<Int64>
    private let now: @Sendable () -> Int64
    private let lock = NSLock()
    private var notBefore: Int64?

    /// - Parameter now: Unix seconds, the device's clock.
    package init(
        store: any ValueStore<Int64> = InMemoryValueStore(),
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.store = store
        self.now = now
    }

    /// Seconds until calls may go out again; 0 when they may.
    package func remainingSeconds() -> Int {
        lock.sync { remaining() }
    }

    /// No calls for `seconds` from now (or until a hold already running ends, if that is later).
    package func hold(seconds: Int) {
        lock.sync {
            let until = now() + Int64(min(max(seconds, 0), RetryDelay.maxSeconds))
            let kept = max(until, now() + Int64(remaining()))
            notBefore = kept
            try? store.save(kept)
        }
    }

    /// Must be called with the lock held.
    private func remaining() -> Int {
        if notBefore == nil {
            let saved: Int64? = (try? store.load()) ?? nil
            notBefore = saved
        }
        guard let notBefore else { return 0 }
        return Int(min(max(notBefore - now(), 0), Int64(RetryDelay.maxSeconds)))
    }
}
