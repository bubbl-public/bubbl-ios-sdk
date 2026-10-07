import Foundation

/// What the app started the engine with, kept so the engine can start itself when the OS wakes the
/// app (a geofence, a push) before the app's own code has run.
package struct EngineConfig: Codable, Sendable, Equatable {
    /// Nil for a device started with a credential issued outside the app.
    package let apiKey: String?
    package let baseUrl: String

    package init(apiKey: String?, baseUrl: String) {
        self.apiKey = apiKey
        self.baseUrl = baseUrl
    }
}

/// A device credential issued outside the app (installs provisioned ahead of time, an app's own
/// pairing flow), which a device can be started with instead of an API key.
package struct IssuedCredential: Sendable, Equatable {
    package let keyId: String
    package let secret: String
    /// The install the credential was issued for.
    package let installId: String

    package init(keyId: String, secret: String, installId: String) {
        self.keyId = keyId
        self.secret = secret
        self.installId = installId
    }
}

/// What starting Bubbl means for the device's identity (Android's EngineStart). A device is either
/// an install that registers itself with an API key, or one started with a credential issued
/// outside the app. Which one, and which credential, is kept (it outlives `stop`), so the next
/// start knows whether it's the same device.
package enum EngineStart {
    package static let apiKey = "api_key"

    /// With an API key, the key itself: a different key is another workspace (Sandbox and
    /// Production have their own), where this device has to register as new. The address isn't
    /// part of it: the same key at another address is the same workspace.
    package static func identity(_ config: EngineConfig, _ credential: IssuedCredential?) -> String {
        guard let credential else { return config.apiKey.map { "\(apiKey) \($0)" } ?? apiKey }
        return "credential \(credential.keyId) \(credential.installId) \(config.baseUrl)"
    }

    /// Whether starting as `next` makes this a new device, so what's kept is wiped first (consent
    /// stays): from an API key to a credential or back, from one credential to another, or from
    /// one API key to another (an app update going live from Sandbox to Production, or back; the
    /// old credential and install id belong to the other workspace). Not on the first start
    /// (nothing to wipe), nor when it's the same again, nor from an API key an older SDK kept
    /// without saying which (it can't tell).
    package static func startsAfresh(previous: String?, next: String) -> Bool {
        guard let previous, previous != next else { return false }
        return !(previous == apiKey && next.hasPrefix("\(apiKey) "))
    }
}

/// This install's push token, as PUT /device takes it.
package struct PushToken: Sendable, Equatable {
    package let token: String
    /// "apns" on iOS.
    package let type: String
    /// "production" or "sandbox" for APNs.
    package let environment: String?

    package init(token: String, type: String, environment: String?) {
        self.token = token
        self.type = type
        self.environment = environment
    }
}

/// What only the platform knows about the device.
package protocol DevicePlatform: Sendable {
    /// The contract's DeviceAttributes the device knows by itself: platform, os_version,
    /// device_model, app_id, app_version, locale, country, timezone.
    func attributes() -> [String: JSONValue]
    /// The permissions object PUT /device takes; nil until the platform can say.
    func permissions() -> JSONValue?
    func pushToken() -> PushToken?
}

/// Where each piece of the engine's state is kept: files on a device, memory in tests.
package struct EngineStores: Sendable {
    package let credentials: any CredentialStore
    package let events: any EventStore
    package let geofenceState: any GeofenceStateStore
    package let config: any ValueStore<ConfigSync.Saved>
    package let deviceAcknowledged: any ValueStore<[String: JSONValue]>
    package let segments: any ValueStore<Segments.Saved>
    package let correlation: any ValueStore<CorrelationId.Saved>
    package let privacy: any ValueStore<PrivacyState>
    package let recentNotifications: any ValueStore<[String]>
    package let installId: any ValueStore<String>
    package let clockOffset: any ValueStore<Int64>
    /// Unix seconds (device clock) until which the server asked not to be called.
    package let pausedUntil: any ValueStore<Int64>
    /// Geofence transitions not yet sent, so one survives the app being suspended or killed.
    package let transitions: any ValueStore<[Transition]>
    /// Region events that came before the first unlock after a reboot, when nothing could be read.
    package let lockedDrops: any ValueStore<Int>

    package init(
        credentials: any CredentialStore, events: any EventStore, geofenceState: any GeofenceStateStore,
        config: any ValueStore<ConfigSync.Saved>, deviceAcknowledged: any ValueStore<[String: JSONValue]>,
        segments: any ValueStore<Segments.Saved>, privacy: any ValueStore<PrivacyState>,
        recentNotifications: any ValueStore<[String]>, installId: any ValueStore<String>,
        clockOffset: any ValueStore<Int64>, pausedUntil: any ValueStore<Int64>,
        transitions: any ValueStore<[Transition]>, lockedDrops: any ValueStore<Int>,
        correlation: any ValueStore<CorrelationId.Saved> = InMemoryValueStore()
    ) {
        self.correlation = correlation
        self.credentials = credentials
        self.events = events
        self.geofenceState = geofenceState
        self.config = config
        self.deviceAcknowledged = deviceAcknowledged
        self.segments = segments
        self.privacy = privacy
        self.recentNotifications = recentNotifications
        self.installId = installId
        self.clockOffset = clockOffset
        self.pausedUntil = pausedUntil
        self.transitions = transitions
        self.lockedDrops = lockedDrops
    }

    /// Everything in memory: for tests.
    package static func inMemory(credentials: any CredentialStore = InMemoryCredentialStore()) -> EngineStores {
        EngineStores(
            credentials: credentials, events: InMemoryEventStore(), geofenceState: InMemoryGeofenceStateStore(),
            config: InMemoryValueStore(), deviceAcknowledged: InMemoryValueStore(), segments: InMemoryValueStore(),
            privacy: InMemoryValueStore(), recentNotifications: InMemoryValueStore(), installId: InMemoryValueStore(),
            clockOffset: InMemoryValueStore(), pausedUntil: InMemoryValueStore(),
            transitions: InMemoryValueStore(), lockedDrops: InMemoryValueStore()
        )
    }

    /// One file each in `directory`, written with `writeOptions` (on iOS, the file protection class).
    /// The credential counts only alongside the install id it was registered with.
    package static func files(in directory: URL, writeOptions: Data.WritingOptions, credentials: any CredentialStore) -> EngineStores {
        func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
        let installId = FileValueStore<String>(url: url("install_id.json"), writeOptions: writeOptions)
        return EngineStores(
            credentials: InstallBoundCredentialStore(credentials, installId: installId),
            events: FileEventStore(url: url("events.json"), writeOptions: writeOptions),
            geofenceState: FileGeofenceStateStore(url: url("geofences.json"), writeOptions: writeOptions),
            config: FileValueStore(url: url("config.json"), writeOptions: writeOptions),
            deviceAcknowledged: FileValueStore(url: url("device.json"), writeOptions: writeOptions),
            segments: FileValueStore(url: url("segments.json"), writeOptions: writeOptions),
            privacy: FileValueStore(url: url("privacy.json"), writeOptions: writeOptions),
            recentNotifications: FileValueStore(url: url("recent_notifications.json"), writeOptions: writeOptions),
            installId: installId,
            clockOffset: FileValueStore(url: url("clock_offset.json"), writeOptions: writeOptions),
            pausedUntil: FileValueStore(url: url("paused_until.json"), writeOptions: writeOptions),
            transitions: FileValueStore(url: url("transitions.json"), writeOptions: writeOptions),
            lockedDrops: FileValueStore(url: url("locked_drops.json"), writeOptions: writeOptions),
            correlation: FileValueStore(url: url("correlation.json"), writeOptions: writeOptions)
        )
    }
}

/// What a piece of background work asks of whoever runs it.
package enum WorkOutcome: Sendable, Equatable {
    case done
    /// Not done yet: run it again after at least this long.
    case retry(afterSeconds: Int)
}

/// The engine, free of iOS: its parts wired together from the saved EngineConfig, what it may do
/// now (consent, a server pause, the minimum SDK version), and each piece of work it runs, as
/// Android's EngineGraph and EngineWork. The iOS layer supplies the platform (Keychain, URLSession,
/// files, device details, region monitoring) and runs the work: now, on retry, and in the
/// background.
package final class EngineCore: Sendable {
    package static let maxProperties = 50

    /// A custom event's name: 1–100 of A–Z a–z 0–9 _ . : -.
    package static func isEventName(_ name: String) -> Bool {
        (1...100).contains(name.unicodeScalars.count) && name.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.:-".unicodeScalars.contains($0))
        }
    }

    package let config: EngineConfig
    package let clock: ServerClock
    package let api: DeviceApiClient
    package let configSync: ConfigSync
    package let deviceSync: DeviceSync
    package let segments: Segments
    package let correlation: CorrelationId
    package let events: EventQueue
    package let geofences: GeofenceEngine
    package let notifications: NotificationSource
    package let recentNotifications: RecentNotifications
    package let privacy: PrivacyStore
    let stores: EngineStores
    private let platform: any DevicePlatform
    let deviceNowSeconds: @Sendable () -> Int64
    let hooks: Hooks
    /// Guards the pending transitions' load-change-save.
    let transitionsLock = NSLock()
    /// One sending of the transitions at a time (a region event's and a retry's), so none is sent twice.
    let sendingTransitions = AsyncMutex()
    /// Region events dropped before the first unlock, not yet added to the saved count.
    let unsavedLockedDrops = Counter()
    /// DELETE /device attempts refused for good, this process (deleteMyData gives up after a few).
    let eraseAttempts = AttemptCounter()
    /// What the log last said about this device in Sandbox (announceSandbox).
    let sandboxAnnounced = LastSaid()

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add(_ n: Int) { lock.sync { count += n } }
        /// The count, and whether `save` kept it (then it starts again from 0).
        func drain(_ save: (Int) throws -> Void) rethrows {
            try lock.sync {
                guard count > 0 else { return }
                try save(count)
                count = 0
            }
        }
        var value: Int { lock.sync { count } }
    }

    /// What the last POST /installs sent about the device, to count as acknowledged once it succeeds.
    final class Hooks: @unchecked Sendable {
        private let lock = NSLock()
        private weak var _core: EngineCore?
        private var _installAttributes: [String: JSONValue]?
        private var _credentialRejected: (@Sendable () -> Void)?
        var credentialRejected: (@Sendable () -> Void)? {
            get { lock.sync { _credentialRejected } }
            set { lock.sync { _credentialRejected = newValue } }
        }
        var core: EngineCore? {
            get { lock.sync { _core } }
            set { lock.sync { _core = newValue } }
        }
        var installAttributes: [String: JSONValue]? {
            get { lock.sync { _installAttributes } }
            set { lock.sync { _installAttributes = newValue } }
        }
    }

    package init(
        config: EngineConfig,
        stores: EngineStores,
        platform: any DevicePlatform,
        http: any HttpClient,
        monitor: any RegionMonitor,
        deviceNowSeconds: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.config = config
        self.stores = stores
        self.platform = platform
        self.deviceNowSeconds = deviceNowSeconds

        let offsetStore = stores.clockOffset
        let clock = ServerClock(
            initialOffsetSeconds: (try? offsetStore.load()) ?? 0,
            deviceNowSeconds: deviceNowSeconds,
            onChange: { try? offsetStore.save($0) }
        )

        let hooks = Hooks()
        let api = DeviceApiClient(
            baseUrl: config.baseUrl,
            apiKey: config.apiKey,
            sdkVersion: BubblVersion.sdk,
            http: http,
            credentials: stores.credentials,
            clock: clock,
            installBody: {
                guard let core = hooks.core else { throw DeviceApiError.credentialsLocked }
                return try core.installBody()
            },
            onRegistered: { data in hooks.core?.registered(data) },
            onCredentialRejected: { hooks.credentialRejected?() }
        )
        let configSync = ConfigSync(api: api, clock: clock, store: stores.config)

        self.clock = clock
        self.api = api
        self.configSync = configSync
        self.hooks = hooks
        deviceSync = DeviceSync(api: api, acknowledged: stores.deviceAcknowledged)
        segments = Segments(store: stores.segments)
        correlation = CorrelationId(store: stores.correlation)
        events = EventQueue(store: stores.events, api: api, clock: clock, batchSize: { configSync.current?.maxEventsPerRequest ?? EventQueue.batchSize })
        geofences = GeofenceEngine(api: api, clock: clock, store: stores.geofenceState, monitor: monitor)
        notifications = NotificationSource(api: api)
        recentNotifications = RecentNotifications(store: stores.recentNotifications)
        privacy = PrivacyStore(store: stores.privacy)
        hooks.core = self
    }

    // MARK: - What the engine may do

    /// The server asked for a pause (workspace_paused, own_app_not_in_plan) that hasn't run out.
    package var isPaused: Bool { deviceNowSeconds() < pausedUntil }

    package var pausedUntilSeconds: Int64? { isPaused ? pausedUntil : nil }

    private var pausedUntil: Int64 {
        let saved: Int64?? = try? stores.pausedUntil.load()
        return (saved ?? nil) ?? 0
    }

    /// This SDK is at least the workspace's minimum version (GET /config); an older one stops.
    package var sdkSupported: Bool { configSync.current?.supports(BubblVersion.sdk) != false }

    /// The engine may call the API and show notifications: consent allows it, not paused, supported.
    package var isActive: Bool { privacy.state?.active == true && !isPaused && sdkSupported }

    /// …and may use location as well.
    package var locationActive: Bool { isActive && privacy.state?.locationActive == true }

    /// Whether this install has ever registered (so there may be a device on the server).
    package var everRegistered: Bool {
        if case .present = stores.credentials.read() { return true }
        return deviceSync.known
    }

    package func pause(hours: Int, code: String?) {
        try? stores.pausedUntil.save(deviceNowSeconds() + Int64(hours) * 3_600)
        BubblLog.warning("Bubbl paused for \(hours)h (\(code ?? "no code"))")
    }

    // MARK: - The device

    /// This installation's id, made on first use and kept until the user erases their data (then
    /// the next one is a new device). Throws while it can't be read.
    package func installId() throws -> String {
        if let id = try stores.installId.load(), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        try stores.installId.save(id)
        return id
    }

    /// What the device says about itself now, for POST /installs and PUT /device.
    package func deviceAttributes() -> [String: JSONValue] {
        var attributes = platform.attributes()
        attributes["sdk_version"] = .string(BubblVersion.sdk)
        if let token = platform.pushToken() {
            attributes["push_token"] = .string(token.token)
            attributes["push_token_type"] = .string(token.type)
            if let environment = token.environment { attributes["apns_environment"] = .string(environment) }
        }
        if let permissions = platform.permissions() { attributes["permissions"] = permissions }
        if let consent = privacy.state?.consent { attributes["consent"] = .bool(consent) }
        correlation.apply(to: &attributes)
        return attributes
    }

    private func installBody() throws -> [String: Any] {
        let id = try installId()
        let attributes = deviceAttributes()
        hooks.installAttributes = attributes
        var body = JSON.any(.object(attributes)) as? [String: Any] ?? [:]
        body["install_id"] = id
        if let segments = segments.current { body["segments"] = segments }
        return body
    }

    private func registered(_ data: [String: Any]) {
        if let attributes = hooks.installAttributes { deviceSync.registered(attributes) }
        if let current = segments.current { segments.sent(current) }
        if let config = data["config"].flatMap(JSON.value) { try? configSync.registered(config) }
        announceSandbox()
    }

    // MARK: - Work

    /// PUT /device with whatever changed (`force`: everything).
    package func syncDevice(force: Bool = false) async -> WorkOutcome {
        guard isActive else { return .done }
        if case .failed(let failure) = await deviceSync.sync(deviceAttributes(), force: force) {
            return await handle(failure, "Syncing the device")
        }
        return .done
    }

    /// Send the event queue.
    package func flushEvents() async -> WorkOutcome {
        guard isActive else { return .done }
        if case .failed(let failure) = await events.flush() {
            return await handle(failure, "Sending events")
        }
        return .done
    }

    /// PUT /device/segments, if the app changed them since.
    package func pushSegments() async -> WorkOutcome {
        guard isActive else { return .done }
        if case .failed(let failure) = await segments.push(api) {
            return await handle(failure, "Setting segments")
        }
        return .done
    }

    /// Every hour or so, and in the background: the config, then the device, events and segments.
    /// An SDK below the workspace's minimum does nothing but ask for the config, so it starts again
    /// when the minimum is lowered (without an app update).
    /// How fresh the config must be when the app comes to the front (at most one GET /config a
    /// minute, a 304 when unchanged): a change made in the dashboard, such as approving a Sandbox
    /// test device, is seen on the next open rather than at the hourly refresh.
    package static let openConfigMaxAgeSeconds: Int64 = 60

    package func maintenance(configMaxAgeSeconds: Int64? = nil) async -> WorkOutcome {
        guard privacy.state?.active == true, !isPaused else { return .done }
        let wasSupported = sdkSupported
        let refreshed = await configSync.refresh(maxAgeSeconds: configMaxAgeSeconds)
        if case .failed(let failure) = refreshed {
            _ = await handle(failure, "Fetching the config")
        }
        announceSandbox()
        guard sdkSupported else {
            if wasSupported { BubblLog.error("This SDK (\(BubblVersion.sdk)) is older than the workspace's minimum: update it to use Bubbl") }
            return .done
        }
        // Only on the server's answer just now: a saved config that still says "dropped" after the
        // token went again would otherwise send it at every maintenance.
        if refreshed == .updated || refreshed == .unchanged { await resendDroppedPushToken() }
        _ = await syncDevice()
        _ = await flushEvents()
        _ = await pushSegments()
        return .done
    }

    /// The push fields PUT /device sends, forgotten together when the server dropped the token.
    package static let pushTokenFields: Set<String> = ["push_token", "push_token_type", "apns_environment"]

    /// GET /config says the server has no push token for this device while the app holds one: it
    /// was dropped (Apple or FCM called it dead, or it came with the wrong APNs environment), so the
    /// next PUT /device sends it again.
    func resendDroppedPushToken() async {
        guard configSync.current?.pushTokenRegistered == false, platform.pushToken() != nil else { return }
        BubblLog.info("The server has no push token for this device: sending it again")
        await deviceSync.forget(Self.pushTokenFields)
    }

    /// The app came to the front: app.opened, and (with `pull`) the pushes the OS may have
    /// dropped. Returns those notifications, for the app to show. Pulling claims them on the
    /// server, so only a caller that will show them pulls.
    package func appOpened(pull: Bool = true) async -> [JSONValue] {
        guard isActive else { return [] }
        let platform = platform.attributes()
        var data: [String: JSONValue] = ["sdk_version": .string(BubblVersion.sdk)]
        data["app_version"] = platform["app_version"] ?? .null
        data["os_version"] = platform["os_version"] ?? .null
        _ = try? await events.enqueue("app.opened", data: data)

        guard pull, case .found(let pulled) = await notifications.pull() else { return [] }
        // Each recorded as received and returned to show only the first time it arrives (a push
        // may have brought it already).
        var toShow: [JSONValue] = []
        for notification in pulled {
            if case .show(let json, _) = await notificationArrived(notification, opened: false) { toShow.append(json) }
        }
        return toShow
    }

    /// An event of the app's own (Bubbl.track): `name` of letters, digits and . _ : - (at most
    /// 100), up to 50 flat properties. False, and a warning, when it can't be recorded.
    package func track(_ name: String, properties: [String: JSONValue]) async -> Bool {
        guard isActive else { return false }
        guard Self.isEventName(name) else {
            BubblLog.warning("Bubbl.track: that isn't a valid event name (letters, digits and . _ : -, at most 100)")
            return false
        }
        var flat: [String: JSONValue] = [:]
        for (key, value) in properties.sorted(by: { $0.key < $1.key }).prefix(Self.maxProperties) {
            switch value {
            case .array, .object: BubblLog.warning("Bubbl.track: a property that isn't text, a number or true/false was left out")
            default: flat[key] = value
            }
        }
        do {
            try await events.enqueue("custom", data: ["name": .string(name), "properties": .object(flat)])
            return true
        } catch {
            return false
        }
    }

    /// What a failure means for the work that met it (Android's EngineWork.result).
    package func handle(_ failure: ApiFailure, _ work: String) async -> WorkOutcome {
        switch failure {
        case .backoff:
            return .retry(afterSeconds: 30)
        case .retryAfter(let seconds):
            return .retry(afterSeconds: seconds)
        case .describeDevice:
            // The server doesn't know the device: tell it everything, then this work tries again.
            deviceSync.forget()
            _ = await syncDevice(force: true)
            return .retry(afterSeconds: 30)
        case .pause(let hours, let code):
            // Nothing is shown in a paused workspace, so there's nothing to retry for.
            if code == "sandbox_pending_full" {
                BubblLog.warning("Bubbl sandbox: the workspace has as many devices waiting for approval as it can take; approve or remove some under Test devices in the dashboard")
            }
            pause(hours: hours, code: code)
            return .done
        case .drop:
            return .done
        case .stopped(let status, let code):
            BubblLog.error("\(work) stopped: HTTP \(status) \(code ?? "")")
            return .done
        }
    }
}

extension JSON {
    /// A JSONValue as JSONSerialization's objects (for APIs that take [String: Any]).
    package static func any(_ value: JSONValue) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// JSONSerialization's objects as a JSONValue, read by JSONDecoder so it's the same everywhere.
    package static func value(_ any: Any) -> JSONValue? {
        guard JSONSerialization.isValidJSONObject(any) || any is String || any is NSNumber,
              let data = try? JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])
        else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}
