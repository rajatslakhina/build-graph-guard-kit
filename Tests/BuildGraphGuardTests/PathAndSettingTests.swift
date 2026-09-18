import XCTest
@testable import BuildGraphGuard

final class PathNormalizerTests: XCTestCase {

    func testCollapsesRedundantComponents() {
        XCTAssertEqual(PathNormalizer.normalize("a/./b"), "a/b")
        XCTAssertEqual(PathNormalizer.normalize("a//b///c"), "a/b/c")
        XCTAssertEqual(PathNormalizer.normalize("a/b/"), "a/b")
        XCTAssertEqual(PathNormalizer.normalize("./a"), "a")
        XCTAssertEqual(PathNormalizer.normalize("a/b/../c"), "a/c")
        XCTAssertEqual(PathNormalizer.normalize(""), "")
    }

    func testAbsolutePathsKeepTheirRoot() {
        XCTAssertEqual(PathNormalizer.normalize("/a/../b"), "/b")
        XCTAssertEqual(PathNormalizer.normalize("/../a"), "/a")
        XCTAssertEqual(PathNormalizer.normalize("/a/./b/"), "/a/b")
    }

    /// The security-relevant case. A normaliser that pops `..` off an empty stack
    /// maps `../../secrets/keys.plist` onto `secrets/keys.plist`, and an escape out
    /// of the repository then renders as an ordinary in-tree file. Both halves are
    /// asserted: the path keeps its prefix, *and* the escape check still fires.
    func testEscapingPrefixesSurviveNormalization() {
        XCTAssertEqual(PathNormalizer.normalize("../x"), "../x")
        XCTAssertEqual(PathNormalizer.normalize("a/../../b"), "../b")
        XCTAssertEqual(PathNormalizer.normalize("../../a/b"), "../../a/b")
        XCTAssertEqual(PathNormalizer.normalize("../a/../b"), "../b")

        XCTAssertTrue(PathNormalizer.escapesProjectDirectory(PathNormalizer.normalize("../x")))
        XCTAssertTrue(PathNormalizer.escapesProjectDirectory(PathNormalizer.normalize("a/../../b")))
        XCTAssertTrue(PathNormalizer.escapesProjectDirectory(PathNormalizer.normalize("/etc/passwd")))
        XCTAssertFalse(PathNormalizer.escapesProjectDirectory(PathNormalizer.normalize("a/../b")))
        XCTAssertFalse(PathNormalizer.escapesProjectDirectory("Storefront/App.swift"))
    }

    /// A pinned `..` must never be consumed by a later `..`, or the count of levels
    /// escaped would silently shrink.
    func testPinnedEscapePrefixIsNotConsumedByLaterDotDot() {
        XCTAssertEqual(PathNormalizer.normalize("../../.."), "../../..")
        XCTAssertEqual(PathNormalizer.normalize("../a/../../b"), "../../b")
    }

    func testJoinHandlesEmptyAndDecoratedInputs() {
        XCTAssertEqual(PathNormalizer.join("", "a"), "a")
        XCTAssertEqual(PathNormalizer.join("a", ""), "a")
        XCTAssertEqual(PathNormalizer.join("a/", "b"), "a/b")
        XCTAssertEqual(PathNormalizer.join("a", "b"), "a/b")
        XCTAssertEqual(PathNormalizer.join("", ""), "")
    }

    func testPackageIdentityMatchesSwiftPMRules() {
        XCTAssertEqual(
            PathNormalizer.packageIdentity(fromURL: "https://github.com/example-org/Checkout-Kit.git"),
            "checkout-kit"
        )
        XCTAssertEqual(
            PathNormalizer.packageIdentity(fromURL: "https://github.com/example-org/checkout-kit/"),
            "checkout-kit"
        )
        XCTAssertEqual(
            PathNormalizer.packageIdentity(fromURL: "git@github.com:example-org/checkout-kit.git"),
            "checkout-kit"
        )
        XCTAssertEqual(PathNormalizer.packageIdentity(fromURL: "checkout-kit"), "checkout-kit")
        XCTAssertEqual(PathNormalizer.packageIdentity(fromURL: ""), "")
    }
}

final class SettingKeyTests: XCTestCase {

    func testParsesConditionsAndSortsThem() {
        let key = SettingKey.parse("OTHER_SWIFT_FLAGS[sdk=iphoneos*][config=Debug]")
        XCTAssertEqual(key.name, "OTHER_SWIFT_FLAGS")
        XCTAssertEqual(
            key.conditions,
            [
                SettingCondition(dimension: "config", value: "Debug"),
                SettingCondition(dimension: "sdk", value: "iphoneos*")
            ]
        )
        XCTAssertEqual(key.canonicalText, "OTHER_SWIFT_FLAGS[config=Debug][sdk=iphoneos*]")
        XCTAssertFalse(key.isUnconditioned)
    }

    func testQualifierOrderDoesNotChangeIdentity() {
        XCTAssertEqual(
            SettingKey.parse("A[config=Debug][sdk=iphoneos*]"),
            SettingKey.parse("A[sdk=iphoneos*][config=Debug]")
        )
    }

    /// A key the parser cannot fully understand keeps its whole raw text as the
    /// name. Dropping the part it could not read would turn
    /// `CODE_SIGN_IDENTITY[config=Release` into plain `CODE_SIGN_IDENTITY`, and the
    /// half that got dropped is exactly where a hostile edit would hide.
    func testMalformedQualifiersArePreservedNotDiscarded() {
        for raw in [
            "A[config",
            "A[config=Debug",
            "A[=Debug]",
            "A[config=]",
            "A[config=Debug]trailing",
            "A[nocolon]"
        ] {
            let key = SettingKey.parse(raw)
            XCTAssertEqual(key.name, raw, "lost information parsing \(raw)")
            XCTAssertTrue(key.conditions.isEmpty)
        }
    }

    func testUnconditionedKeyRoundTrips() {
        let key = SettingKey.parse("SWIFT_VERSION")
        XCTAssertTrue(key.isUnconditioned)
        XCTAssertEqual(key.canonicalText, "SWIFT_VERSION")
    }
}

final class SettingTableTests: XCTestCase {

    func testBooleanSpellingsCanonicalizeTogether() {
        XCTAssertEqual(SettingValue.string("YES").canonicalized, .boolean(true))
        XCTAssertEqual(SettingValue.string("yes").canonicalized, .boolean(true))
        XCTAssertEqual(SettingValue.string("true").canonicalized, .boolean(true))
        XCTAssertEqual(SettingValue.string("NO").canonicalized, .boolean(false))
        XCTAssertEqual(SettingValue.string("false").canonicalized, .boolean(false))
        XCTAssertEqual(SettingValue.string("MAYBE").canonicalized, .string("MAYBE"))
        // A one-element list stays a list; collapsing it would make a later append
        // read as a type change rather than as an added flag.
        XCTAssertEqual(SettingValue.list(["-lz"]).canonicalized, .list(["-lz"]))
    }

    func testResolutionPrefersTheMoreQualifiedKey() {
        var table = SettingTable()
        table.set(.string("Apple Development"), for: SettingKey(name: "CODE_SIGN_IDENTITY"))
        table.set(
            .string("-"),
            for: SettingKey(
                name: "CODE_SIGN_IDENTITY",
                conditions: [SettingCondition(dimension: "config", value: "Release")]
            )
        )

        XCTAssertEqual(table.resolved(for: "Release")["CODE_SIGN_IDENTITY"], .string("-"))
        XCTAssertEqual(
            table.resolved(for: "Debug")["CODE_SIGN_IDENTITY"], .string("Apple Development")
        )
    }

    /// Conditions on dimensions other than `config` must not be treated as
    /// unconditional. Resolving an `sdk`-qualified value for every SDK would make
    /// the resolved view claim more than the file says.
    func testNonConfigConditionsDoNotParticipateInConfigResolution() {
        var table = SettingTable()
        table.set(.string("base"), for: SettingKey(name: "OTHER_LDFLAGS"))
        table.set(
            .string("sdk-only"),
            for: SettingKey(
                name: "OTHER_LDFLAGS",
                conditions: [SettingCondition(dimension: "sdk", value: "iphoneos*")]
            )
        )
        XCTAssertEqual(table.resolved(for: "Release")["OTHER_LDFLAGS"], .string("base"))
        XCTAssertEqual(table.resolved(for: "Debug")["OTHER_LDFLAGS"], .string("base"))
    }

    func testConfigMatchIsCaseInsensitive() {
        var table = SettingTable()
        table.set(
            .string("on"),
            for: SettingKey(
                name: "FLAG", conditions: [SettingCondition(dimension: "config", value: "debug")]
            )
        )
        XCTAssertEqual(table.resolved(for: "Debug")["FLAG"], .string("on"))
        XCTAssertNil(table.resolved(for: "Release")["FLAG"])
    }

    func testMentionedConfigurationsAreCollected() {
        var table = SettingTable()
        table.set(
            .string("x"),
            for: SettingKey(
                name: "A", conditions: [SettingCondition(dimension: "config", value: "Staging")]
            )
        )
        table.set(
            .string("y"),
            for: SettingKey(
                name: "B", conditions: [SettingCondition(dimension: "sdk", value: "iphoneos*")]
            )
        )
        XCTAssertEqual(table.mentionedConfigurations, ["Staging"])
    }

    func testEmptyTableResolvesToNothingRatherThanCrashing() {
        let table = SettingTable()
        XCTAssertTrue(table.isEmpty)
        XCTAssertTrue(table.resolved(for: "Debug").isEmpty)
        XCTAssertTrue(table.sortedKeys.isEmpty)
        XCTAssertTrue(table.mentionedConfigurations.isEmpty)
    }
}
