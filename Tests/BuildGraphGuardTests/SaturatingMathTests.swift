import XCTest
@testable import BuildGraphGuard

/// Every operation here is one Swift would trap on. A trap in a CI gate is not a
/// caught bug, it is an outage — so each case asserts the clamped answer rather
/// than merely asserting "it didn't crash", which any no-op would also satisfy.
final class SaturatingMathTests: XCTestCase {

    func testAdditionSaturatesRatherThanOverflowing() {
        XCTAssertEqual(SaturatingMath.add(Int.max, 1), Int.max)
        XCTAssertEqual(SaturatingMath.add(Int.max, Int.max), Int.max)
        XCTAssertEqual(SaturatingMath.add(Int.min, -1), Int.min)
        XCTAssertEqual(SaturatingMath.add(Int.min, Int.min), Int.min)
        XCTAssertEqual(SaturatingMath.add(7, 5), 12)
        XCTAssertEqual(SaturatingMath.add(Int.max, Int.min), -1)
    }

    func testMultiplicationSaturatesWithCorrectSign() {
        XCTAssertEqual(SaturatingMath.multiply(Int.max, 2), Int.max)
        XCTAssertEqual(SaturatingMath.multiply(Int.max, -2), Int.min)
        XCTAssertEqual(SaturatingMath.multiply(Int.min, -1), Int.max)
        XCTAssertEqual(SaturatingMath.multiply(Int.min, 2), Int.min)
        XCTAssertEqual(SaturatingMath.multiply(0, Int.max), 0)
        XCTAssertEqual(SaturatingMath.multiply(6, 7), 42)
    }

    func testDivisionHandlesBothTrappingCases() {
        XCTAssertEqual(SaturatingMath.divide(10, by: 0), 0)
        XCTAssertEqual(SaturatingMath.divide(10, by: 0, fallback: -1), -1)
        // Int.min / -1 has no representable result; Swift traps, we saturate.
        XCTAssertEqual(SaturatingMath.divide(Int.min, by: -1), Int.max)
        XCTAssertEqual(SaturatingMath.divide(9, by: 2), 4)
    }

    func testDoubleToIntegerHandlesEveryTrappingInput() {
        XCTAssertEqual(SaturatingMath.integer(clamping: .nan), 0)
        XCTAssertEqual(SaturatingMath.integer(clamping: .infinity), Int.max)
        XCTAssertEqual(SaturatingMath.integer(clamping: -.infinity), Int.min)
        XCTAssertEqual(SaturatingMath.integer(clamping: 1e300), Int.max)
        XCTAssertEqual(SaturatingMath.integer(clamping: -1e300), Int.min)
        XCTAssertEqual(SaturatingMath.integer(clamping: 42.9), 42)
        XCTAssertEqual(SaturatingMath.integer(clamping: -42.9), -42)
    }

    /// `Double(Int.max)` rounds *up* past `Int.max`, so a naive `value <= Double(Int.max)`
    /// bound would admit a value that `Int(_:)` then traps on. This pins the strict
    /// upper bound and the inclusive lower bound, which is exactly the asymmetry a
    /// rewrite would get wrong.
    func testDoubleToIntegerBoundaryAsymmetryIsCorrect() {
        XCTAssertEqual(SaturatingMath.integer(clamping: Double(Int.max)), Int.max)
        XCTAssertEqual(SaturatingMath.integer(clamping: Double(Int.min)), Int.min)
        XCTAssertEqual(SaturatingMath.integer(clamping: Double(Int.min) - 1024), Int.min)
        // One ULP below 2^63 is representable and must round-trip, not clamp.
        let justBelow = Double(Int.max).nextDown
        XCTAssertLessThan(SaturatingMath.integer(clamping: justBelow), Int.max)
        XCTAssertGreaterThan(SaturatingMath.integer(clamping: justBelow), 0)
    }

    func testPercentageNeverDividesByZero() {
        XCTAssertEqual(SaturatingMath.percentage(5, of: 0), 0)
        XCTAssertEqual(SaturatingMath.percentage(0, of: 10), 0)
        XCTAssertEqual(SaturatingMath.percentage(5, of: 10), 50)
        XCTAssertEqual(SaturatingMath.percentage(1, of: 3), 33)
    }

    /// Catches a specific wrong answer, not a crash.
    ///
    /// Drop the `part >= total` shortcut and `part * 100` saturates at `Int.max`,
    /// after which `Int.max / Int.max` is 1 — the function would report **1%** for
    /// a change that touched every file. Saturation that yields a plausible-looking
    /// small number is more dangerous than an overflow that yells.
    func testLargePercentageDoesNotCollapseToOnePercent() {
        XCTAssertEqual(SaturatingMath.percentage(Int.max, of: Int.max), 100)
        XCTAssertEqual(SaturatingMath.percentage(Int.max, of: 4), 100)

        // The `part >= total` shortcut alone does not save this one: `part < total`
        // here, but `part * 100` still saturates, and dividing the saturated product
        // by `total` reports 1% for what is 50%.
        XCTAssertEqual(SaturatingMath.percentage(Int.max / 2, of: Int.max), 50)
        XCTAssertEqual(SaturatingMath.percentage(Int.max / 4, of: Int.max), 25)

        let naiveSaturatedAnswer = SaturatingMath.divide(
            SaturatingMath.multiply(Int.max / 2, 100), by: Int.max
        )
        XCTAssertEqual(naiveSaturatedAnswer, 1, "the broken formula really does return 1%")
        XCTAssertNotEqual(
            SaturatingMath.percentage(Int.max / 2, of: Int.max), naiveSaturatedAnswer
        )
    }
}
