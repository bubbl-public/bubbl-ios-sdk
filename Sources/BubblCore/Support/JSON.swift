import Foundation

/// JSON as the device API speaks it, read loosely: a body that isn't the expected shape is nil
/// rather than an error, since a proxy's error page or an empty 304 must not throw.
package enum JSON {
    /// The object in `text`, or nil when it isn't a JSON object.
    package static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A JSON number as Int64, however the platform's JSONSerialization boxed it (NSNumber on
    /// Apple platforms, Swift numbers elsewhere); nil when it isn't a number.
    package static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let value as Int: Int64(value)
        case let value as Int64: value
        case let value as Double: Int64(exactly: value.rounded(.towardZero))
        case let value as NSNumber: value.int64Value
        default: nil
        }
    }

    /// `value` (a dictionary or array of JSON values) as compact JSON text.
    package static func string(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
