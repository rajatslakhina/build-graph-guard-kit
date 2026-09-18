import XCTest
@testable import BuildGraphGuard

final class DottedVersionTests: XCTestCase {

    /// The whole reason this type exists.
    ///
    /// The assertion on the raw strings is deliberate: it proves the naive
    /// implementation really is wrong here, so the second assertion is catching
    /// something rather than restating an obvious truth. Swap `DottedVersion` for a
    /// string comparison and a deployment floor of 17.0 would happily accept 9.0.
    func testVersionOrderIsNumericNotLexical() throws {
        XCTAssertTrue("9.0" > "17.0", "string comparison really does get this backwards")

        let nine = try XCTUnwrap(DottedVersion("9.0"))
        let seventeen = try XCTUnwrap(DottedVersion("17.0"))
        XCTAssertLessThan(nine, seventeen)
        XCTAssertFalse(nine > seventeen)
    }

    func testTrailingZeroComponentsAreEqual() throws {
        let short = try XCTUnwrap(DottedVersion("17"))
        let medium = try XCTUnwrap(DottedVersion("17.0"))
        let long = try XCTUnwrap(DottedVersion("17.0.0"))
        XCTAssertEqual(short, medium)
        XCTAssertEqual(medium, long)
        XCTAssertEqual(short, long)
    }

    /// `Hashable`'s contract says equal values hash equally. Hash `components`
    /// directly and `17` and `17.0` land in different buckets while `==` calls them
    /// equal, which shows up much later as a `Set` that silently holds both.
    func testEqualVersionsHashEqually() throws {
        let short = try XCTUnwrap(DottedVersion("17"))
        let long = try XCTUnwrap(DottedVersion("17.0.0"))
        XCTAssertEqual(short.hashValue, long.hashValue)
        XCTAssertEqual(Set([short, long]).count, 1)
    }

    func testOrderingAcrossDifferentComponentCounts() throws {
        let a = try XCTUnwrap(DottedVersion("17.1"))
        let b = try XCTUnwrap(DottedVersion("17.0.9"))
        XCTAssertGreaterThan(a, b)

        let c = try XCTUnwrap(DottedVersion("18"))
        XCTAssertGreaterThan(c, a)
    }

    func testUnparseableInputsReturnNilRatherThanZero() {
        // `$(INHERITED)` is a real value to find in a deployment-target setting.
        XCTAssertNil(DottedVersion("$(INHERITED)"))
        XCTAssertNil(DottedVersion(""))
        XCTAssertNil(DottedVersion("   "))
        XCTAssertNil(DottedVersion("17.0."))
        XCTAssertNil(DottedVersion("17..0"))
        XCTAssertNil(DottedVersion("-1"))
        XCTAssertNil(DottedVersion("1.2.3.4.5"))
        XCTAssertNil(DottedVersion("17.0-beta"))
        // Overflows Int; `Int(_:)` returns nil rather than trapping, and so must we.
        XCTAssertNil(DottedVersion("99999999999999999999999"))
    }

    func testWhitespaceIsTrimmedButDescriptionIsPreserved() throws {
        let version = try XCTUnwrap(DottedVersion("  17.4  "))
        XCTAssertEqual(version.description, "17.4")
        XCTAssertEqual(version.components, [17, 4])
    }
}
