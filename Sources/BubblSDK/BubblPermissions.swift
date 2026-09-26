import Foundation
#if !COCOAPODS
import BubblCore
#endif

/// Where the device stands on the permissions Bubbl uses. The same as Android's.
public struct BubblPermissionStatus: Sendable, Equatable {
    public enum Notifications: Sendable, Equatable { case granted, denied, notDetermined }
    public enum Location: Sendable, Equatable { case always, whenInUse, denied, notDetermined }

    public let notifications: Notifications
    public let location: Location
    /// Precise rather than approximate location (geofences need it).
    public let preciseLocation: Bool

    init(_ status: PermissionStatus) {
        notifications = switch status.notifications {
        case .granted: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        }
        location = switch status.location {
        case .always: .always
        case .whenInUse: .whenInUse
        case .denied: .denied
        case .notDetermined: .notDetermined
        }
        preciseLocation = status.preciseLocation
    }
}

/// The permissions Bubbl uses (`Bubbl.permissions`): where they stand, and asking for them. Asking
/// shows the privacy view first when the dashboard says to, then the system's prompt; it works from
/// anywhere in the app. iOS prompts for each permission once: after a refusal, `openSettings()`.
public struct BubblPermissions: Sendable {
    /// Where the device stands, as last looked (at start, when the app comes to the front, after
    /// asking); nil before `Bubbl.start`, and where Bubbl isn't supported (below iOS 17).
    public func status() -> BubblPermissionStatus? {
        Bubbl.backend.permissionStatus()
    }

    /// Notifications: the privacy view if the dashboard says so, then the system prompt.
    public func requestNotifications() async -> BubblPermissionStatus? {
        await request(.notifications, "permissions.requestNotifications")
    }

    /// Location: the privacy view if the dashboard says so, then the system prompt; with `always`,
    /// the second step to "Always" too (geofences with the app closed).
    public func requestLocation(always: Bool = false) async -> BubblPermissionStatus? {
        await request(always ? .locationAlways : .locationWhenInUse, "permissions.requestLocation")
    }

    /// `requestNotifications()` for code that can't await; `completion` runs on the main thread.
    public func requestNotifications(completion: @escaping @MainActor @Sendable (BubblPermissionStatus?) -> Void) {
        Task {
            let result = await requestNotifications()
            await MainActor.run { completion(result) }
        }
    }

    /// `requestLocation(always:)` for code that can't await; `completion` runs on the main thread.
    public func requestLocation(always: Bool, completion: @escaping @MainActor @Sendable (BubblPermissionStatus?) -> Void) {
        Task {
            let result = await requestLocation(always: always)
            await MainActor.run { completion(result) }
        }
    }

    /// The app's page in the system's Settings.
    public func openSettings() {
        Bubbl.backend.openSettings()
    }

    private func request(_ request: PermissionRequest, _ call: String) async -> BubblPermissionStatus? {
        await Bubbl.backend.requestPermission(request, call)
    }
}
