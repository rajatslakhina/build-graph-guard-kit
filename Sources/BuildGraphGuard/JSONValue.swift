import Foundation

/// A decoded JSON value.
///
/// The project file is a heterogeneous tree whose shape is not fully fixed by a
/// Swift type, so it is decoded into this enum first and interpreted second.
/// Going through a typed intermediate rather than `[String: Any]` keeps the whole
/// pipeline `Sendable` under Swift 6's strict concurrency checking and removes
/// every `as!` that an `Any`-based walk would need.
public indirect enum JSONValue: Hashable, Sendable {
    case null
    case boolean(Bool)
    case number(Double)
    case integer(Int)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    /// An `Int` view of the value, never trapping.
    ///
    /// `.number` goes through `SaturatingMath.integer(clamping:)` because JSON
    /// admits `1e400` (parsed as `+infinity`) and `NaN`-producing expressions, and
    /// `Int(Double.infinity)` is a trap, not an error.
    public var intValue: Int? {
        switch self {
        case .integer(let number): return number
        case .number(let number): return SaturatingMath.integer(clamping: number)
        default: return nil
        }
    }

    /// The value as a build setting, if it can be one.
    /// A list of non-strings (say, `[1, 2]`) is rejected rather than stringified,
    /// because silently coercing it would let a malformed edit look well-formed.
    public var settingValue: SettingValue? {
        switch self {
        case .boolean(let flag):
            return .boolean(flag)
        case .string(let text):
            return SettingValue.string(text).canonicalized
        case .integer(let number):
            return .string(String(number))
        case .number(let number):
            return .string(Self.renderNumber(number))
        case .array(let items):
            var strings: [String] = []
            strings.reserveCapacity(items.count)
            for item in items {
                switch item {
                case .string(let text): strings.append(text)
                case .integer(let number): strings.append(String(number))
                case .number(let number): strings.append(Self.renderNumber(number))
                case .boolean(let flag): strings.append(flag ? "YES" : "NO")
                case .null, .array, .object: return nil
                }
            }
            return .list(strings)
        case .null, .object:
            return nil
        }
    }

    /// Renders a JSON number as a setting value.
    ///
    /// Swift's own `String(Double)` is exactly right here and an earlier draft was
    /// exactly wrong: it collapsed integral doubles to `Int`, so JSON
    /// `IPHONEOS_DEPLOYMENT_TARGET: 17.0` became `"17"` and diffed forever against
    /// the string `"17.0"` — precisely the migration-day noise this library exists
    /// to suppress. `String(17.0)` is `"17.0"`, which matches.
    ///
    /// Very large magnitudes still render in exponent form (`String(1e30)` is
    /// `"1e+30"`). That is not pretty, but a build setting is never legitimately
    /// 1e30, and inventing a digit expansion for it would be making up data.
    private static func renderNumber(_ number: Double) -> String {
        guard number.isFinite else { return number > 0 ? "inf" : "-inf" }
        return String(number)
    }
}

extension JSONValue: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let flag = try? container.decode(Bool.self) {
            self = .boolean(flag)
        } else if let number = try? container.decode(Int.self) {
            self = .integer(number)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else if let items = try? container.decode([JSONValue].self) {
            self = .array(items)
        } else if let fields = try? container.decode([String: JSONValue].self) {
            self = .object(fields)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not a JSON primitive, array or object."
            )
        }
    }
}
