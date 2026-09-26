#if os(iOS)
import CoreLocation
import UIKit
import UserNotifications
#if !COCOAPODS
import BubblCore
#endif

/// Asking for the permissions Bubbl uses, from anywhere in the app: the privacy view first when the
/// dashboard says so, then the system's prompt, "Always" location in the two steps iOS expects
/// (PermissionPlanner). Where the device stands is reported to the server with the device.
@available(iOS 17, *)
@MainActor
final class PermissionFlow: NSObject, CLLocationManagerDelegate {
    static let shared = PermissionFlow()

    private let manager = CLLocationManager()
    private var asking = false

    override private init() {
        super.init()
        manager.delegate = self
    }

    /// Where the device stands now.
    func status() async -> PermissionStatus {
        let notifications: PermissionStatus.Notifications = switch await Self.notificationAuthorization() {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        default: .notDetermined
        }
        let location: PermissionStatus.Location = switch manager.authorizationStatus {
        case .authorizedAlways: .always
        case .authorizedWhenInUse: .whenInUse
        case .denied, .restricted: .denied
        default: .notDetermined
        }
        let status = PermissionStatus(notifications: notifications, location: location, preciseLocation: manager.accuracyAuthorization == .fullAccuracy)
        EngineHost.shared.platform.permissionStatus = status
        return status
    }

    /// Asks for `request` as the planner says, one request at a time. "Not now" on the privacy view,
    /// or a refusal, ends it. Returns where the device stands afterwards.
    func request(_ request: PermissionRequest) async -> PermissionStatus {
        guard !asking else { return await status() }
        asking = true
        defer { asking = false }

        let memory = PermissionMemory.shared
        let config = EngineHost.shared.current?.configSync.current
        let steps = PermissionPlanner.plan(
            request,
            status: await status(),
            notice: config?.privacyNotice ?? "automatic",
            explained: memory.explained,
            askedAlways: memory.askedAlways
        )

        for step in steps {
            switch step {
            case .explain(let kind):
                memory.markExplained(kind)
                guard await PrivacyView.show(kind: kind, text: config?.privacyText, policy: config?.privacyUrl) else {
                    return await finished()
                }
            case .ask(.notifications):
                let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
                if !granted { return await finished() }
            case .ask(.locationWhenInUse):
                await prompt { manager.requestWhenInUseAuthorization() }
                // Refused: "Always" can't follow.
                if !(await status()).hasLocation { return await finished() }
            case .ask(.locationAlways):
                memory.markAskedAlways()
                await prompt { manager.requestAlwaysAuthorization() }
            }
        }
        return await finished()
    }

    /// Whether notifications are allowed (only the status crosses over: the settings object isn't
    /// Sendable).
    nonisolated static func notificationAuthorization() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// What asking changed: a device token once notifications are allowed, the server told, and
    /// geofences checked with the location now allowed.
    private func finished() async -> PermissionStatus {
        let now = await status()
        if now.notifications == .granted { UIApplication.shared.registerForRemoteNotifications() }
        EngineHost.shared.submit("device") { await $0.syncDevice() }
        if now.hasLocation { EngineHost.shared.checkGeofences(rewatch: true) }
        return now
    }

    /// Shows a system location prompt and waits for its answer. iOS doesn't say when it decides not
    /// to show one (asked before), so: a prompt makes the app inactive; if that hasn't happened
    /// within a second, there wasn't one.
    private func prompt(_ ask: () -> Void) async {
        ask()
        var shown = false
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if UIApplication.shared.applicationState != .active {
                shown = true
                break
            }
        }
        guard shown else { return }
        while UIApplication.shared.applicationState != .active {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // The answer reaches CoreLocation just after the app is active again.
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in _ = await PermissionFlow.shared.status() }
    }
}

/// What Bubbl has explained (the privacy view, per kind) and whether it has asked for "Always"
/// (iOS shows that prompt once), kept between launches.
@available(iOS 17, *)
@MainActor
final class PermissionMemory {
    static let shared = PermissionMemory()

    private struct Saved: Codable {
        var explained: [String] = []
        var askedAlways = false
    }

    private let store: FileValueStore<Saved>?
    private var saved: Saved

    private init() {
        store = EngineHost.directory().map { FileValueStore(url: $0.appendingPathComponent("permissions.json"), writeOptions: EngineHost.writeOptions) }
        saved = ((try? store?.load()) ?? nil) ?? Saved()
    }

    var explained: Set<String> { Set(saved.explained) }
    var askedAlways: Bool { saved.askedAlways }

    func markExplained(_ kind: String) {
        guard !saved.explained.contains(kind) else { return }
        saved.explained.append(kind)
        try? store?.save(saved)
    }

    func markAskedAlways() {
        saved.askedAlways = true
        try? store?.save(saved)
    }
}
#endif
