import Foundation

/// Arithmetic that cannot trap.
///
/// Every number in this library ultimately comes from a file an untrusted writer
/// produced — a coding agent, or whatever edited the branch before it. A guard
/// layer that crashes on a hostile input has not failed safe, it has failed open:
/// the CI job dies, someone reruns it, and eventually someone merges past it.
/// So every operation that Swift would trap on is routed through here.
///
/// Note that `Int` is not 64-bit everywhere (it is 32-bit on watchOS), so every
/// ceiling below is derived from `Int.max` rather than written as a literal.
public enum SaturatingMath {

    /// `a + b`, clamped to the representable range instead of overflowing.
    public static func add(_ a: Int, _ b: Int) -> Int {
        let (sum, overflowed) = a.addingReportingOverflow(b)
        guard overflowed else { return sum }
        return b > 0 ? Int.max : Int.min
    }

    /// `a * b`, clamped to the representable range instead of overflowing.
    public static func multiply(_ a: Int, _ b: Int) -> Int {
        let (product, overflowed) = a.multipliedReportingOverflow(by: b)
        guard overflowed else { return product }
        // Sign of the true product decides which end we clamp to. Zero cannot
        // overflow, so neither operand is zero here.
        let isNegative = (a < 0) != (b < 0)
        return isNegative ? Int.min : Int.max
    }

    /// `numerator / denominator`, returning `fallback` for the two cases Swift traps on:
    /// division by zero, and `Int.min / -1` (whose true value is not representable).
    public static func divide(_ numerator: Int, by denominator: Int, fallback: Int = 0) -> Int {
        guard denominator != 0 else { return fallback }
        guard !(numerator == Int.min && denominator == -1) else { return Int.max }
        return numerator / denominator
    }

    /// `Int(value)` without the four ways that initialiser traps: NaN, +infinity,
    /// -infinity, and any finite magnitude outside `Int`'s range.
    ///
    /// The range test is deliberately written against `Double(Int.max)` rather than
    /// a literal. `Double(Int.max)` rounds *up* to 2^63 on a 64-bit platform, which
    /// is one past the last representable `Int`, so the comparison must be strict
    /// (`<`) on the upper bound and inclusive (`>=`) on the lower — `Double(Int.min)`
    /// is exactly -2^63 and is representable.
    public static func integer(clamping value: Double) -> Int {
        guard !value.isNaN else { return 0 }
        guard value.isFinite else { return value > 0 ? Int.max : Int.min }
        let upperExclusive = Double(Int.max)
        let lowerInclusive = Double(Int.min)
        guard value < upperExclusive else { return Int.max }
        guard value >= lowerInclusive else { return Int.min }
        return Int(value)
    }

    /// A percentage of `total`, with no division-by-zero and no overflow.
    ///
    /// Returns 0 when `total` is zero, which is the honest answer for "what share
    /// of nothing is this" and keeps callers from having to special-case it.
    ///
    /// Saturation is the hazard to design around, not overflow: `part * 100`
    /// clamping at `Int.max` and then dividing produces a small, plausible-looking
    /// *wrong* number rather than an obviously broken one. `percentage(Int.max, of:
    /// Int.max)` would read 1%, and so would `percentage(Int.max / 2, of: Int.max)`,
    /// which is 50%. Both are handled: the `part >= total` shortcut covers the
    /// first, and scaling the denominator instead of the numerator covers every
    /// case where `part * 100` would not fit.
    public static func percentage(_ part: Int, of total: Int) -> Int {
        guard total > 0, part > 0 else { return 0 }
        guard part < total else { return 100 }
        guard part > Int.max / 100 else {
            return min(100, divide(multiply(part, 100), by: total))
        }
        // Divide first. `total / 100` is at least 1 here, because `total > part >
        // Int.max / 100`, so the fallback can never be reached — it is present only
        // so the expression is total.
        return min(100, divide(part, by: divide(total, by: 100, fallback: 1), fallback: 0))
    }
}

/// A dotted version string (`17.0`, `18.2.1`) compared component-wise.
///
/// String comparison is wrong here in a way that matters: `"9.0" > "17.0"`
/// lexically, so a policy that enforces a deployment floor with `<` on raw strings
/// would wave through exactly the regression it exists to catch.
public struct DottedVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]
    public let description: String

    /// Parses a dotted version. Returns `nil` rather than a partial parse when any
    /// component is absent, non-numeric, negative, or too large for `Int` —
    /// a build setting like `IPHONEOS_DEPLOYMENT_TARGET = $(INHERITED)` is a real
    /// thing to encounter and must not be silently read as version zero.
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let pieces = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.count <= 4 else { return nil }
        var parsed: [Int] = []
        parsed.reserveCapacity(pieces.count)
        for piece in pieces {
            // `Int(_:)` returns nil on overflow rather than trapping, which is the
            // behaviour we want for an absurd component like "99999999999999999999".
            guard let number = Int(piece), number >= 0 else { return nil }
            parsed.append(number)
        }
        self.components = parsed
        self.description = trimmed
    }

    public static func < (lhs: DottedVersion, rhs: DottedVersion) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        for index in 0..<width {
            // Missing trailing components read as zero: 17 == 17.0 == 17.0.0.
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: DottedVersion, rhs: DottedVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        // Must agree with `==`, which ignores trailing zeros, so hash the
        // zero-stripped form. Hashing `components` directly would give 17 and 17.0
        // different hashes while `==` calls them equal — a Hashable contract break
        // that shows up as silent lookup misses in a Set or Dictionary.
        var significant = components
        while significant.count > 1, significant.last == 0 {
            significant.removeLast()
        }
        hasher.combine(significant)
    }
}
