import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if !COCOAPODS
import BubblCore
import BubblLaunch
#endif

/// Found by name by BubblLaunch's +load (which can't import this module): the end of launch.
@available(iOS 17, *)
@objc(BubblLaunchHook)
final class BubblLaunchHook: NSObject {
    @objc static func applicationDidFinishLaunching() {
        EngineHost.shared.applicationDidFinishLaunching()
    }

    /// From +load, before main(): iOS wants background task handlers registered before launch ends.
    @objc static func registerBackgroundTasks() {
        #if os(iOS)
        BackgroundRefresh.register()
        #endif
    }
}

/// Holds the engine for the life of the process and runs its work: on start, when the app comes to
/// the front, and when it goes to the back (with the few seconds iOS gives). Work waits while the
/// engine's data can't be read (before the first unlock after a reboot).
@available(iOS 17, *)
final class EngineHost: @unchecked Sendable {
    static let shared = EngineHost()

    let runner = WorkRunner(dataReadable: { EngineHost.dataReadable() })
    let platform = AppleDevicePlatform()
    /// Shows notifications: Bubbl's screen in front, a system notification in the background.
    #if os(iOS)
    let presenter: any NotificationPresenting = ScreenPresenter()
    #else
    let presenter: any NotificationPresenting = SystemAlertPresenter()
    #endif
    private let lock = NSLock()
    private var core: EngineCore?
    private var observing = false
    private var listener: (@MainActor @Sendable (BubblMessage) -> Bool)?

    var current: EngineCore? { lock.sync { core } }

    /// The app's say over each notification before Bubbl shows it (Bubbl.setNotificationListener).
    var notificationListener: (@MainActor @Sendable (BubblMessage) -> Bool)? {
        get { lock.sync { listener } }
        set { lock.sync { listener = newValue } }
    }

    /// What `start` was called with, kept so Bubbl can start itself at a later launch.
    struct Started: Codable, Equatable {
        let config: EngineConfig
        let logLevel: BubblOptions.LogLevel
    }

    /// Starts (or keeps) the engine for `config`, with an API key or a credential issued outside the
    /// app (Android's Bubbl.begin): the same again changes nothing; a different identity (another
    /// credential, or switching between an API key and a credential) wipes what's kept here first
    /// and starts as a new device.
    func start(_ config: EngineConfig, credential: IssuedCredential? = nil, options: BubblOptions) -> EngineCore? {
        SystemLog.use(options.logLevel)
        let identity = EngineStart.identity(config, credential)
        let afresh = EngineStart.startsAfresh(previous: previousIdentity(), next: identity)
        guard let core = engine(for: config, fresh: afresh) else { return nil }
        try? identityStore()?.save(identity)
        try? rejectedStore()?.delete()
        try? startedStore()?.save(Started(config: config, logLevel: options.logLevel))

        guard afresh || credential != nil else {
            proceed(core, options)
            return core
        }
        // A new identity (wiped first) or a credential to keep, before anything of the engine's runs.
        Task {
            if afresh {
                BubblLog.info("Bubbl starts afresh as a new device")
                await runner.cancelAll()
                do { try await core.wipeLocalData() } catch { BubblLog.warning("What an earlier device kept here couldn't all be removed yet") }
            }
            if let credential {
                do { try core.useCredential(credential) } catch { BubblLog.warning("The credential can't be kept until the device is unlocked") }
            }
            proceed(core, options)
        }
        return core
    }

    /// What every start does once the engine is set up: the app's options, then whatever may run.
    private func proceed(_ core: EngineCore, _ options: BubblOptions) {
        do {
            try core.privacy.update { $0.requireConsent = options.requireConsent }
        } catch {
            BubblLog.info("Bubbl's settings can't be read until the device is unlocked: it starts then")
        }
        if let segments = options.segments { _ = try? core.segments.set(segments) }
        run(core, launchFinished: false)
    }

    /// What the device was started as before; an install from before identities were kept, started
    /// with an API key, counts as one.
    /// An identity kept before it named the key ("api_key" alone) is read with the key the last
    /// start saved, so a key change is seen from the first update too.
    private func previousIdentity() -> String? {
        let started = (try? startedStore()?.load()) ?? nil
        let lastKey = started?.config.apiKey.map { EngineStart.identity(EngineConfig(apiKey: $0, baseUrl: ""), nil) }
        if let kept = (try? identityStore()?.load()) ?? nil { return kept == EngineStart.apiKey ? lastKey ?? kept : kept }
        return lastKey
    }

    /// The server refused the credential Bubbl was started with: stopped, and staying stopped (no
    /// self-restart) until the app starts Bubbl with a new one. Nothing is wiped: that start decides.
    /// The app is told (BubblEvent.credentialRejected) and diagnostics say so.
    func credentialRejected(_ core: EngineCore) {
        guard current === core else { return }
        try? rejectedStore()?.save(true)
        BubblLog.error("The device's credential was refused: Bubbl has stopped until it's started with a new one")
        stop()
        BubblEvents.shared.emit(.credentialRejected)
    }

    /// Started with a credential the server has refused.
    var isCredentialRejected: Bool { ((try? rejectedStore()?.load()) ?? nil) == true }

    /// The end of every launch (BubblLaunch's +load watches for it): when an earlier launch started
    /// Bubbl and it wasn't stopped since, it starts again now, as it was, so an app launched for a
    /// geofence, a push or a tap has it before the app's own code (a wrapper's JavaScript or Dart)
    /// runs. The app's own `start` later changes nothing, or applies its new options.
    func applicationDidFinishLaunching() {
        guard current == nil else { return }
        // Before the first unlock after a reboot it can't be read: nothing starts (such events are lost).
        guard let saved = (try? startedStore()?.load()) ?? nil else { return }
        SystemLog.use(saved.logLevel)
        guard let core = engine(for: saved.config) else { return }
        BubblLog.info("Bubbl started itself for this launch, as the app last started it")
        run(core, launchFinished: true)
    }

    /// The engine for `config`: the running one if it's for the same (and not `fresh`), a new one
    /// otherwise.
    private func engine(for config: EngineConfig, fresh: Bool = false) -> EngineCore? {
        BubblLaunchLinked()
        guard let directory = Self.directory() else {
            BubblLog.error("Bubbl couldn't create its folder in Application Support")
            return nil
        }
        return lock.sync {
            if !fresh, let existing = self.core, existing.config == config { return existing }
            let stores = EngineStores.files(in: directory, writeOptions: Self.writeOptions, credentials: KeychainCredentialStore())
            let created = EngineCore(config: config, stores: stores, platform: platform, http: URLSessionHttpClient(), monitor: Self.regionMonitor())
            created.onCredentialRejected { [weak created] in
                guard let created else { return }
                EngineHost.shared.credentialRejected(created)
            }
            self.core = created
            return created
        }
    }

    /// Location, push and the app's comings and goings, then whatever work the engine may do.
    private func run(_ core: EngineCore, launchFinished: Bool) {
        startLocation()
        #if os(iOS)
        PushIntegration.installWhenLaunched(launchFinished: launchFinished)
        refreshPermissions()
        #endif
        observeTheApp()
        resume(core)
    }

    private func startedStore() -> FileValueStore<Started>? {
        Self.directory().map { FileValueStore(url: $0.appendingPathComponent("started.json"), writeOptions: Self.writeOptions) }
    }

    /// What the device was last started as (EngineStart.identity); outlives `stop`.
    private func identityStore() -> FileValueStore<String>? {
        Self.directory().map { FileValueStore(url: $0.appendingPathComponent("identity.json"), writeOptions: Self.writeOptions) }
    }

    private func rejectedStore() -> FileValueStore<Bool>? {
        Self.directory().map { FileValueStore(url: $0.appendingPathComponent("credential_rejected.json"), writeOptions: Self.writeOptions) }
    }

    /// Stop until start is called again: nothing more runs, no geofences are watched, and Bubbl
    /// doesn't start itself at the next launch (what it was started as is kept, so the next start
    /// still knows whether it's the same device); nothing is dropped or told to the server.
    func stop() {
        try? startedStore()?.delete()
        let stopped: EngineCore? = lock.sync {
            defer { core = nil }
            return core
        }
        Task {
            await runner.cancelAll()
            try? await stopped?.geofences.stop()
        }
    }

    /// Whatever the engine may do now: the device, the queue, segments, the config.
    func resume(_ core: EngineCore) {
        if !core.sdkSupported {
            BubblLog.error("This SDK (\(BubblVersion.sdk)) is older than the workspace's minimum: update it to use Bubbl")
        } else if !core.isActive {
            BubblLog.info(core.privacy.state?.active == true ? "Bubbl is paused by the server" : "Bubbl is waiting for consent")
        }
        resumePrivacyWork(core)
        // Maintenance runs whatever the state: it's how an SDK below the minimum comes back.
        submit("maintenance") { await $0.maintenance(configMaxAgeSeconds: EngineCore.openConfigMaxAgeSeconds) }
        guard core.isActive else { return }
        submit("device") { await $0.syncDevice() }
        submit("events") { await $0.flushEvents() }
        submit("segments") { await $0.pushSegments() }
        if core.locationActive { checkGeofences() }
    }

    /// Runs `work` against whichever engine is current when it runs (none after `stop`).
    func submit(_ name: String, _ work: @escaping @Sendable (EngineCore) async -> WorkOutcome) {
        Task {
            await runner.submit(name) {
                guard let core = self.current else { return .done }
                return await work(core)
            }
        }
    }

    // MARK: - The app

    private func observeTheApp() {
        let first: Bool = lock.sync {
            defer { observing = true }
            return !observing
        }
        guard first else { return }

        #if canImport(UIKit) && !os(watchOS)
        let center = NotificationCenter.default
        // Every unlock, the first after a reboot included: held work may be able to run now. (Not
        // protectedDataWillBecomeUnavailable, nor isProtectedDataAvailable: those follow the
        // Complete class, which closes at every lock, while the engine's data stays readable.)
        center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            Task { await self.runner.recheck() }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.appOpened()
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appWentToTheBack() }
        }
        Task { @MainActor [weak self] in
            // Launched into the front (not woken in the background): that's an app open.
            if UIApplication.shared.applicationState != .background { self?.appOpened() }
        }
        #endif
    }

    /// Where the device stands on permissions, for PUT /device and `permissions.status()` (the
    /// person may have changed them in Settings while the app was away).
    func refreshPermissions() {
        #if os(iOS)
        Task { @MainActor in _ = await PermissionFlow.shared.status() }
        #endif
    }

    /// The app came to the front: app.opened, the queue, and the config if it's due.
    private func appOpened() {
        refreshPermissions()
        #if os(iOS)
        // Notifications may have been allowed since (by the app, a plugin, Settings): the device token
        // then, not only at the next launch. (With the integration off, the app hands it over.)
        PushIntegration.registerIfAllowed()
        #endif
        submit("app.opened") { core in
            // Pushes iOS never delivered: pulled, and shown in front.
            for notification in await core.appOpened(pull: true) {
                _ = await self.show(notification, received: true, opened: false)
            }
            return .done
        }
        submit("events") { await $0.flushEvents() }
        submit("maintenance") { await $0.maintenance(configMaxAgeSeconds: EngineCore.openConfigMaxAgeSeconds) }
        appOpenedForLocation()
    }

    #if canImport(UIKit) && !os(watchOS)
    /// The app went to the back: send what's queued in the time iOS allows.
    @MainActor
    private func appWentToTheBack() {
        appWentToTheBackForLocation()
        guard let core = current, core.isActive else { return }
        BackgroundRefresh.schedule()
        let time = BackgroundTime("tech.bubbl.sdk.flush")
        Task {
            // Not sent in time: the runner retries it, with its backoff, when the app next runs.
            if case .retry = await core.flushEvents() { submit("events") { await $0.flushEvents() } }
            time.end()
        }
    }
    #endif

    // MARK: - Files

    /// Application Support/tech.bubbl.sdk, kept out of backups: a restored install id would make two
    /// phones one device, and a restored geofence state would claim places the device isn't in.
    static func directory() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        var directory = base.appendingPathComponent("tech.bubbl.sdk", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
        } catch {
            // Already there (and excluded), or not writable yet: the stores say which when used.
        }
        return directory
    }

    /// Whether the engine's files (and the Keychain item, whose class matches) can be read now,
    /// tried on a file of their protection class: before the first unlock after a reboot an
    /// existing one can't be read and a new one can't be made.
    static func dataReadable(in directory: URL? = directory()) -> Bool {
        guard let directory else { return false }
        let probe = directory.appendingPathComponent("readable")
        if (try? Data(contentsOf: probe)) != nil { return true }
        guard !FileManager.default.fileExists(atPath: probe.path) else { return false }
        do {
            try Data([1]).write(to: probe, options: writeOptions.union(.atomic))
            return true
        } catch {
            return false
        }
    }

    /// Readable from the first unlock after a reboot until the next reboot (region events in the
    /// background need that); unreadable before it.
    static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        [.completeFileProtectionUntilFirstUserAuthentication]
        #else
        []
        #endif
    }
}

/// Region monitoring until the location slice (7): watches nothing, as for a user who allowed
/// location only while the app is in use.
@available(iOS 17, *)
struct InactiveRegionMonitor: RegionMonitor {
    func capacity() async -> Int { 0 }
    func watch(_ regions: [WatchedRegion]) async -> Bool { true }
    func stop() async {}
}
