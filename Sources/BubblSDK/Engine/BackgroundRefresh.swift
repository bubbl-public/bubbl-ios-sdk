#if os(iOS)
import BackgroundTasks
import Foundation
#if !COCOAPODS
import BubblCore
#endif

/// Background app refresh (optional): iOS wakes the app now and then, and Bubbl sends what's queued
/// and refreshes its config, so events don't wait for the app's next run. Only when the app allows
/// it in its Info.plist: "tech.bubbl.sdk.refresh" in BGTaskSchedulerPermittedIdentifiers, and
/// "fetch" in UIBackgroundModes (Background fetch). Without those, events go when the app goes to
/// the background and on its next run, as before.
///
/// iOS wants the handler registered before launch finishes (later is an exception), which is why
/// it's done from BubblLaunch's +load, before main().
@available(iOS 17, *)
enum BackgroundRefresh {
    static let identifier = "tech.bubbl.sdk.refresh"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var registered = false

    /// The app lets Bubbl refresh in the background.
    static var declared: Bool {
        let identifiers = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        return identifiers.contains(identifier) && modes.contains("fetch")
    }

    /// From +load. (Not main-actor code: iOS runs the handler on a queue of its own.)
    static func register() {
        guard declared else { return }
        let done = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            EngineHost.shared.backgroundRefresh(task)
        }
        lock.sync { registered = done }
    }

    /// Asks iOS for the next refresh, no sooner than half an hour from now (iOS picks the time).
    static func schedule() {
        guard lock.sync({ registered }) else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            BubblLog.debug("Background refresh not scheduled (\(type(of: error)))")
        }
    }
}

@available(iOS 17, *)
extension EngineHost {
    /// iOS woke the app for a background refresh: the next one asked for, then the config, the
    /// device, what's queued and segments sent (maintenance), within the time iOS gives.
    func backgroundRefresh(_ task: BGTask) {
        BackgroundRefresh.schedule()
        // Launched in the background for this: Bubbl starts itself as the app last started it.
        if current == nil { applicationDidFinishLaunching() }

        let handed = Handed(task)
        let finished = Once()
        guard let core = current, core.isActive else {
            finished.run { handed.value.setTaskCompleted(success: true) }
            return
        }
        let work = Task {
            _ = await core.maintenance()
            finished.run { handed.value.setTaskCompleted(success: true) }
        }
        task.expirationHandler = {
            work.cancel()
            finished.run { handed.value.setTaskCompleted(success: false) }
        }
    }
}

/// Runs its body once, whichever caller gets there first.
@available(iOS 17, *)
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let first: Bool = lock.sync {
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
#endif
