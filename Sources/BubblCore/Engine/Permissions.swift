import Foundation

/// Where the device stands on the permissions Bubbl uses: the contract's Permissions for PUT
/// /device, and what the app sees (BubblPermissionStatus).
package struct PermissionStatus: Sendable, Equatable {
    package enum Notifications: String, Sendable {
        case granted, denied
        case notDetermined = "not_determined"
    }

    package enum Location: String, Sendable {
        case always, denied
        case whenInUse = "when_in_use"
        case notDetermined = "not_determined"
    }

    package let notifications: Notifications
    package let location: Location
    /// Precise rather than approximate location.
    package let preciseLocation: Bool

    package init(notifications: Notifications, location: Location, preciseLocation: Bool) {
        self.notifications = notifications
        self.location = location
        self.preciseLocation = preciseLocation
    }

    package var hasLocation: Bool { location == .always || location == .whenInUse }

    /// As PUT /device takes it.
    package var json: JSONValue {
        ["notifications": .string(notifications.rawValue), "location": .string(location.rawValue), "precise_location": .bool(preciseLocation)]
    }
}

/// What an app asks Bubbl to get permission for.
package enum PermissionRequest: Sendable, Equatable {
    case notifications, locationWhenInUse, locationAlways
}

/// One step of asking: explain first (the privacy view), or show the system's prompt.
package enum PermissionStep: Sendable, Equatable {
    /// The privacy view, for "notifications", "location" or "background_location".
    case explain(String)
    case ask(PermissionRequest)
}

/// The steps to get a permission on iOS, given where the device stands (Android's
/// PermissionPlanner, with iOS's rules):
///  - iOS prompts for each only once: a permission already refused (or "Always" already asked for
///    and not given) has no steps; the app can send the person to Settings instead;
///  - "Always" comes in two steps, as iOS expects: "While Using" first, then "Always" (asked for
///    straight away, iOS gives only a provisional Always).
/// The privacy view comes before each prompt as the dashboard's notice mode says: "never",
/// "always", or "automatic" (the first time each kind is asked for).
package enum PermissionPlanner {
    package static func plan(_ request: PermissionRequest, status: PermissionStatus, notice: String, explained: Set<String>, askedAlways: Bool) -> [PermissionStep] {
        var steps: [PermissionStep] = []
        func explain(_ kind: String) {
            if notice == "always" || (notice != "never" && !explained.contains(kind)) { steps.append(.explain(kind)) }
        }

        switch request {
        case .notifications:
            if status.notifications == .notDetermined {
                explain("notifications")
                steps.append(.ask(.notifications))
            }
        case .locationWhenInUse:
            if status.location == .notDetermined {
                explain("location")
                steps.append(.ask(.locationWhenInUse))
            }
        case .locationAlways:
            switch status.location {
            case .notDetermined:
                explain("location")
                steps.append(.ask(.locationWhenInUse))
                explain("background_location")
                steps.append(.ask(.locationAlways))
            case .whenInUse where !askedAlways:
                explain("background_location")
                steps.append(.ask(.locationAlways))
            default:
                break
            }
        }
        return steps
    }
}
