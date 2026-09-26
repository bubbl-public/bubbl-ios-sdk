/// Any JSON value, as Codable: for the parts of the device API that carry free-form JSON (an
/// event's `data`, a rejection's `errors`). JSONEncoder and JSONDecoder read and write it the same
/// way on every platform the core runs on, unlike JSONSerialization's boxed numbers.
package enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// The value at `key`, when this is an object.
    package subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    package var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    /// A number as a whole Int64, never trapping: fractions are cut, and values beyond Int64
    /// (1e30 from a server) are clamped. Nil for anything that isn't a finite number.
    package var int64: Int64? {
        switch self {
        case .int(let value): return value
        case .double(let value):
            guard value.isFinite else { return nil }
            let whole = value.rounded(.towardZero)
            if let exact = Int64(exactly: whole) { return exact }
            return whole > 0 ? .max : .min
        default: return nil
        }
    }

    /// int64, clamped to `range`: for a server number that sets a limit or an interval.
    package func int64(in range: ClosedRange<Int64>) -> Int64? {
        int64.map { min(max($0, range.lowerBound), range.upperBound) }
    }

    /// Whether every number in it is finite: JSON has no NaN or infinity, so JSONEncoder refuses
    /// them (Android's JSONObject does too).
    package var isEncodable: Bool {
        switch self {
        case .double(let value): value.isFinite
        case .array(let values): values.allSatisfy(\.isEncodable)
        case .object(let values): values.values.allSatisfy(\.isEncodable)
        case .null, .bool, .int, .string: true
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByFloatLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByNilLiteral {
    package init(stringLiteral value: String) { self = .string(value) }
    package init(integerLiteral value: Int64) { self = .int(value) }
    package init(booleanLiteral value: Bool) { self = .bool(value) }
    package init(floatLiteral value: Double) { self = .double(value) }
    package init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
    package init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    package init(nilLiteral: ()) { self = .null }
}
