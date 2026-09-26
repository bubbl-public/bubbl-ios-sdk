/// A lock for async code: one caller at a time runs the body, the rest wait their turn (in
/// order) without blocking a thread. An actor alone isn't enough, since an actor lets other
/// calls in whenever the running one awaits; registering the install must not interleave.
package actor AsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    package init() {}

    /// Runs `body` holding the lock, and releases it however `body` ends.
    package nonisolated func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await lock()
        do {
            let result = try await body()
            await unlock()
            return result
        } catch {
            await unlock()
            throw error
        }
    }

    private func lock() async {
        guard locked else {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            // The lock passes straight to the next waiter: it stays held.
            waiters.removeFirst().resume()
        }
    }
}
