import Foundation

// MARK: - Setting conditions

/// One `[dimension=value]` qualifier on a build setting key.
///
/// Xcode 27.2's `project.xcproj` collapses what used to be N separate
/// `XCBuildConfiguration` objects into a single `build-settings` block whose keys
/// carry their own conditions: `SWIFT_ACTIVE_COMPILATION_CONDITIONS[config=Debug]`.
/// Modelling the condition as structured data rather than leaving it inside the
/// key string is what makes a *resolved* diff possible (see `SettingTable.resolved`).
public struct SettingCondition: Hashable, Comparable, Sendable {
    /// The qualifier dimension: `config`, `sdk`, `arch`.
    public let dimension: String
    /// The qualifier value: `Debug`, `iphoneos*`, `arm64`.
    public let value: String

    public init(dimension: String, value: String) {
        self.dimension = dimension
        self.value = value
    }

    public static func < (lhs: SettingCondition, rhs: SettingCondition) -> Bool {
        if lhs.dimension != rhs.dimension { return lhs.dimension < rhs.dimension }
        return lhs.value < rhs.value
    }

    /// Whether this condition is satisfied by a configuration name.
    ///
    /// Only the `config` dimension participates in configuration resolution.
    /// Conditions on other dimensions (`sdk`, `arch`) are treated as
    /// *non-matching* during resolution rather than silently ignored, because
    /// pretending an `sdk`-qualified value applies to every SDK would produce a
    /// resolved view that claims more than the file says. `GraphDiffer` still
    /// reports those keys through the literal (unresolved) change channel, so
    /// they are never dropped — they are reported honestly instead of guessed at.
    func matches(configuration: String) -> Bool {
        guard dimension == "config" else { return false }
        return value.caseInsensitiveCompare(configuration) == .orderedSame
    }
}

/// A fully qualified build setting key: a name plus its (canonically ordered) conditions.
public struct SettingKey: Hashable, Comparable, Sendable {
    public let name: String
    public let conditions: [SettingCondition]

    public init(name: String, conditions: [SettingCondition] = []) {
        self.name = name
        self.conditions = conditions.sorted()
    }

    /// Whether this key applies unconditionally (the base value).
    public var isUnconditioned: Bool { conditions.isEmpty }

    public static func < (lhs: SettingKey, rhs: SettingKey) -> Bool {
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        if lhs.conditions.count != rhs.conditions.count {
            return lhs.conditions.count < rhs.conditions.count
        }
        for (a, b) in zip(lhs.conditions, rhs.conditions) where a != b {
            return a < b
        }
        return false
    }

    /// The canonical textual form, e.g. `OTHER_SWIFT_FLAGS[config=Debug][sdk=iphoneos*]`.
    public var canonicalText: String {
        conditions.reduce(into: name) { text, condition in
            text += "[\(condition.dimension)=\(condition.value)]"
        }
    }

    /// Parses `NAME[config=Debug][sdk=iphoneos*]` into a structured key.
    ///
    /// Malformed qualifiers are preserved verbatim in the *name* rather than
    /// discarded. A guard layer that quietly drops the part of a key it cannot
    /// understand is worse than one that reports an unfamiliar key, because the
    /// dropped half is exactly where a hostile edit would hide.
    public static func parse(_ raw: String) -> SettingKey {
        guard let firstBracket = raw.firstIndex(of: "[") else {
            return SettingKey(name: raw)
        }
        let name = String(raw[raw.startIndex..<firstBracket])
        var conditions: [SettingCondition] = []
        var remainder = Substring(raw[firstBracket...])

        while remainder.first == "[" {
            guard let close = remainder.firstIndex(of: "]") else {
                // Unbalanced qualifier — keep the whole raw string as the name.
                return SettingKey(name: raw)
            }
            let openIndex = remainder.index(after: remainder.startIndex)
            let body = remainder[openIndex..<close]
            guard let equals = body.firstIndex(of: "=") else {
                return SettingKey(name: raw)
            }
            let dimension = String(body[body.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(body[body.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            guard !dimension.isEmpty, !value.isEmpty else {
                return SettingKey(name: raw)
            }
            conditions.append(SettingCondition(dimension: dimension, value: value))
            remainder = remainder[remainder.index(after: close)...]
        }

        // Trailing junk after the last qualifier means we did not understand the
        // key; fall back to treating the whole thing as an opaque name.
        guard remainder.isEmpty else { return SettingKey(name: raw) }
        return SettingKey(name: name, conditions: conditions)
    }
}

// MARK: - Setting values

/// A build setting value, normalised to one of three shapes.
public enum SettingValue: Hashable, Sendable {
    case boolean(Bool)
    case string(String)
    case list([String])

    /// A stable, human-readable rendering used in diff output and policy messages.
    public var displayText: String {
        switch self {
        case .boolean(let flag): return flag ? "YES" : "NO"
        case .string(let text): return text
        case .list(let items): return "[" + items.joined(separator: ", ") + "]"
        }
    }

    /// Collapses the equivalent spellings Xcode accepts for the same value.
    ///
    /// `ENABLE_USER_SCRIPT_SANDBOXING: "YES"` and `ENABLE_USER_SCRIPT_SANDBOXING: true`
    /// are the same setting. Without this, migrating a project from `pbxproj`
    /// (strings only) to `xcproj` (real JSON booleans) would report every boolean
    /// setting in the file as changed, and a reviewer would learn to skip the diff.
    /// A single-element list is *not* collapsed to a scalar: `OTHER_LDFLAGS` with one
    /// flag is semantically a list and appending to it later must not read as a type change.
    public var canonicalized: SettingValue {
        switch self {
        case .boolean:
            return self
        case .list(let items):
            return .list(items)
        case .string(let text):
            switch text.uppercased() {
            case "YES", "TRUE": return .boolean(true)
            case "NO", "FALSE": return .boolean(false)
            default: return .string(text)
            }
        }
    }
}

// MARK: - Setting table

/// The build settings attached to one node of the graph (a target, or the project).
public struct SettingTable: Equatable, Sendable {
    public private(set) var entries: [SettingKey: SettingValue]

    public init(_ entries: [SettingKey: SettingValue] = [:]) {
        self.entries = entries
    }

    public init(unconditioned pairs: [String: SettingValue]) {
        var built: [SettingKey: SettingValue] = [:]
        for (name, value) in pairs {
            built[SettingKey(name: name)] = value
        }
        self.entries = built
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    public subscript(key: SettingKey) -> SettingValue? { entries[key] }

    public mutating func set(_ value: SettingValue, for key: SettingKey) {
        entries[key] = value
    }

    /// Keys in a deterministic order. Dictionary iteration order is not stable
    /// across processes in Swift, so every public ordering goes through here.
    public var sortedKeys: [SettingKey] { entries.keys.sorted() }

    /// Every distinct setting *name*, ignoring conditions.
    public var settingNames: Set<String> { Set(entries.keys.map(\.name)) }

    /// Every configuration name mentioned by any `[config=...]` qualifier.
    public var mentionedConfigurations: Set<String> {
        var names: Set<String> = []
        for key in entries.keys {
            for condition in key.conditions where condition.dimension == "config" {
                names.insert(condition.value)
            }
        }
        return names
    }

    /// Normalises every value and re-parses every key into canonical order.
    public func canonicalized() -> SettingTable {
        var built: [SettingKey: SettingValue] = [:]
        // `SettingKey.init` re-sorts conditions, so two keys that differ only in
        // qualifier order collapse onto each other here. When they carry different
        // values the survivor must be deterministic rather than whichever the
        // dictionary happened to yield last, so ties resolve to the lexically
        // smaller rendering.
        for (key, value) in entries {
            let canonicalKey = SettingKey(name: key.name, conditions: key.conditions)
            let canonicalValue = value.canonicalized
            if let existing = built[canonicalKey], existing != canonicalValue {
                built[canonicalKey] = min(
                    existing.displayText, canonicalValue.displayText
                ) == existing.displayText ? existing : canonicalValue
            } else {
                built[canonicalKey] = canonicalValue
            }
        }
        return SettingTable(built)
    }

    /// The effective value of every setting name for one build configuration.
    ///
    /// This is the view that matters for review. An agent that adds
    /// `CODE_SIGN_IDENTITY[config=Release]` has not touched the unconditioned key
    /// at all — a key-level diff shows only "an unfamiliar key appeared", which is
    /// easy to wave through. The resolved view shows
    /// `Release: CODE_SIGN_IDENTITY "Apple Development" → "-"`, which is not.
    ///
    /// More-qualified keys win over less-qualified ones, matching Xcode's own
    /// precedence. Ties between equally-qualified keys resolve by canonical key
    /// order so the result never depends on dictionary iteration order.
    public func resolved(for configuration: String) -> [String: SettingValue] {
        var winners: [String: (key: SettingKey, value: SettingValue)] = [:]
        for key in sortedKeys {
            guard let value = entries[key] else { continue }
            let applies = key.conditions.allSatisfy { $0.matches(configuration: configuration) }
            guard applies else { continue }
            if let current = winners[key.name] {
                let isMoreSpecific = key.conditions.count > current.key.conditions.count
                let isTieBrokenByOrder = key.conditions.count == current.key.conditions.count
                    && current.key < key
                guard isMoreSpecific || isTieBrokenByOrder else { continue }
            }
            winners[key.name] = (key, value)
        }
        return winners.mapValues(\.value)
    }
}
