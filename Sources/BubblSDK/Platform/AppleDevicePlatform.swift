import Foundation
#if !COCOAPODS
import BubblCore
#endif

/// What the device says about itself (the contract's DeviceAttributes). Permissions and the push
/// token come with slices 9 and 11; until then the platform can't say.
@available(iOS 17, *)
final class AppleDevicePlatform: DevicePlatform, @unchecked Sendable {
    private let lock = NSLock()
    private var token: PushToken?
    private var status: PermissionStatus?

    func attributes() -> [String: JSONValue] {
        let bundle = Bundle.main
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let locale = Locale.current
        var attributes: [String: JSONValue] = [
            "platform": "ios",
            "os_version": .string("\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"),
            "device_model": .string(String(Self.modelIdentifier.prefix(100))),
            "manufacturer": "Apple",
            "app_id": .string(bundle.bundleIdentifier ?? "unknown"),
            "locale": .string(String(locale.identifier(.bcp47).prefix(35))),
            "timezone": .string(TimeZone.current.identifier),
        ]
        attributes["app_version"] = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { .string(String($0.prefix(50))) } ?? .null
        attributes["country"] = locale.region.map { $0.identifier.count == 2 ? .string($0.identifier) : .null } ?? .null
        return attributes
    }

    /// As last looked (PermissionFlow); nil until then.
    func permissions() -> JSONValue? { lock.sync { status?.json } }

    var permissionStatus: PermissionStatus? {
        get { lock.sync { status } }
        set { lock.sync { status = newValue } }
    }

    func pushToken() -> PushToken? { lock.sync { token } }

    func setPushToken(_ token: PushToken?) {
        lock.sync { self.token = token }
    }

    /// "iPhone16,2"; on the Simulator, the model it simulates.
    static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

@available(iOS 17, *)
extension JSONValue {
    /// A value an app handed Bubbl (event properties, survey answers) as JSON, or nil when it
    /// isn't text, a number, true/false, nil, or a list or dictionary of those. True and false
    /// stay booleans: on Apple platforms they arrive as NSNumber, like numbers do.
    init?(app value: Any?) {
        switch value {
        case nil, is NSNull:
            self = .null
        case let text as String:
            self = .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                guard number.doubleValue.isFinite else { return nil }
                self = .double(number.doubleValue)
            } else {
                self = .int(number.int64Value)
            }
        case let list as [Any?]:
            var items: [JSONValue] = []
            for item in list {
                guard let converted = JSONValue(app: item) else { return nil }
                items.append(converted)
            }
            self = .array(items)
        case let dictionary as [String: Any?]:
            var object: [String: JSONValue] = [:]
            for (key, item) in dictionary {
                guard let converted = JSONValue(app: item) else { return nil }
                object[key] = converted
            }
            self = .object(object)
        default:
            return nil
        }
    }
}
