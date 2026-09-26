import Foundation
#if !COCOAPODS
import BubblCore
#endif

/// Runs the engine's work while the app is alive, as WorkManager does on Android: each job by name,
/// one at a time (asked for again while running, it runs once more after), retried with a growing
/// wait when it says `.retry`, and held back until the engine's data can be read: before the first
/// unlock after a reboot the Keychain and the engine's files are closed. From then on they stay
/// readable while the phone is locked, which is when most region events arrive, so nothing waits
/// for an unlock.
@available(iOS 17, *)
actor WorkRunner {
    typealias Work = @Sendable () async -> WorkOutcome

    private static let maxDelaySeconds = 15 * 60

    /// Whether the engine's data can be read now. Once it can, it stays so until the next reboot
    /// (which ends the process), so it's asked only until it says yes.
    private let dataReadable: @Sendable () -> Bool
    private var ready = false
    private var running: Set<String> = []
    private var again: [String: Work] = [:]
    private var held: [String: Work] = [:]
    private var attempts: [String: Int] = [:]
    private var waits: [String: Task<Void, Never>] = [:]

    init(dataReadable: @escaping @Sendable () -> Bool = { true }) {
        self.dataReadable = dataReadable
    }

    /// Run `work` as `name` now (or once the engine's data can be read).
    func submit(_ name: String, _ work: @escaping Work) {
        guard isReady() else {
            held[name] = work
            return
        }
        start(name, work)
    }

    /// Ask again whether the engine's data can be read (the device was unlocked).
    func recheck() {
        _ = isReady()
    }

    /// Asks until the data can be read; the moment it can, held work starts.
    private func isReady() -> Bool {
        guard !ready else { return true }
        ready = dataReadable()
        if ready {
            let waiting = held
            held.removeAll()
            waiting.forEach { start($0.key, $0.value) }
        }
        return ready
    }

    private func start(_ name: String, _ work: @escaping Work) {
        guard !running.contains(name) else {
            again[name] = work
            return
        }
        // Asked for now: whatever retry was waiting is overtaken.
        waits.removeValue(forKey: name)?.cancel()
        running.insert(name)
        Task {
            let outcome = await work()
            finished(name, outcome, work)
        }
    }

    /// Forget every job not already running (Bubbl.stop, an opt-out).
    func cancelAll() {
        waits.values.forEach { $0.cancel() }
        waits.removeAll()
        again.removeAll()
        held.removeAll()
        attempts.removeAll()
    }

    private func finished(_ name: String, _ outcome: WorkOutcome, _ work: @escaping Work) {
        running.remove(name)
        switch outcome {
        case .done:
            attempts[name] = nil
            if let next = again.removeValue(forKey: name) { submit(name, next) }
        case .retry(let afterSeconds):
            let attempt = (attempts[name] ?? 0) + 1
            attempts[name] = attempt
            let next = again.removeValue(forKey: name) ?? work
            // 30 s, 1 min, 2 min… up to 15 min, never sooner than asked, with a little jitter.
            let backoff = min(30 << min(attempt - 1, 10), Self.maxDelaySeconds)
            let seconds = Double(max(afterSeconds, backoff)) * Double.random(in: 1.0...1.1)
            waits[name]?.cancel()
            waits[name] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.retry(name, next)
            }
        }
    }

    private func retry(_ name: String, _ work: @escaping Work) {
        waits[name] = nil
        submit(name, work)
    }
}
