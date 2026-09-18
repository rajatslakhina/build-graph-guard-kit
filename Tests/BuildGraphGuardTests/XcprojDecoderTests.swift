import XCTest
@testable import BuildGraphGuard

final class XcprojDecoderTests: XCTestCase {

    private func decode(
        _ json: String,
        limits: XcprojDecoder.DecodingLimits = .default
    ) throws -> ProjectGraph {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XcprojDecoder.decode(data, limits: limits)
    }

    /// Builds `files` nested `depth` groups deep with one leaf at the bottom.
    private func nestedTreeJSON(depth: Int) -> String {
        var json = #"{"schema-version":1,"name":"X","targets":[{"name":"T","product-type":"p"}],"files":["#
        for index in 0..<depth {
            json += #"{"group":"g\#(index)","children":["#
        }
        json += #"{"path":"leaf.swift","target-membership":["T"]}"#
        json += String(repeating: "]}", count: depth)
        json += "]}"
        return json
    }

    func testDecodesTheBaselineProject() throws {
        let graph = try decode(SampleProjects.storefrontBaseline)

        XCTAssertEqual(graph.name, "Storefront")
        XCTAssertEqual(graph.origin, .xcproj(schemaVersion: 1))
        XCTAssertEqual(graph.targets.map(\.name).sorted(), ["Storefront", "StorefrontTests"])

        let app = try XCTUnwrap(graph.target(named: "Storefront"))
        XCTAssertEqual(app.productType, "com.apple.product-type.application")
        XCTAssertEqual(
            app.membership,
            ["Storefront/Checkout/CartModel.swift", "Storefront/StorefrontApp.swift"]
        )
        XCTAssertEqual(app.packageProducts, ["CheckoutKit"])

        let tests = try XCTUnwrap(graph.target(named: "StorefrontTests"))
        XCTAssertEqual(
            tests.membership,
            ["Storefront/Checkout/CartModel.swift", "StorefrontTests/CartModelTests.swift"]
        )
        XCTAssertTrue(tests.settings.isEmpty)

        XCTAssertEqual(
            graph.projectSettings[SettingKey(name: "ENABLE_USER_SCRIPT_SANDBOXING")],
            .boolean(true)
        )
        XCTAssertEqual(
            graph.projectSettings[
                SettingKey(
                    name: "SWIFT_ACTIVE_COMPILATION_CONDITIONS",
                    conditions: [SettingCondition(dimension: "config", value: "Debug")]
                )
            ],
            .string("DEBUG")
        )

        XCTAssertEqual(graph.packages.count, 1)
        let package = try XCTUnwrap(graph.packages.first)
        XCTAssertEqual(package.identity, "checkout-kit")
        XCTAssertEqual(package.requirement, .upToNextMajor(minimum: "2.4.0"))
        XCTAssertFalse(package.requirement.isFloating)
    }

    /// Group nesting has to compose into a real path, or membership diffs point at
    /// filenames that exist in three directories at once.
    func testNestedGroupsComposeIntoFullPaths() throws {
        let graph = try decode(SampleProjects.storefrontBaseline)
        let app = try XCTUnwrap(graph.target(named: "Storefront"))
        XCTAssertTrue(app.membership.contains("Storefront/Checkout/CartModel.swift"))
        XCTAssertFalse(app.membership.contains("CartModel.swift"))
    }

    func testUnsupportedSchemaVersionIsRefusedNotGuessedAt() {
        let json = #"{"schema-version": 99, "name": "X"}"#
        XCTAssertThrowsError(try decode(json)) { error in
            XCTAssertEqual(
                error as? GraphDecodingError,
                .unsupportedSchemaVersion(found: 99, supported: 1...1)
            )
        }
    }

    func testMissingRequiredFieldsThrow() {
        XCTAssertThrowsError(try decode(#"{"name": "X"}"#)) { error in
            XCTAssertEqual(error as? GraphDecodingError, .missingField("schema-version"))
        }
        XCTAssertThrowsError(try decode(#"{"schema-version": 1}"#)) { error in
            XCTAssertEqual(error as? GraphDecodingError, .missingField("name"))
        }
        XCTAssertThrowsError(try decode(#"{"schema-version": 1, "name": ""}"#)) { error in
            XCTAssertEqual(error as? GraphDecodingError, .missingField("name"))
        }
        XCTAssertThrowsError(try decode("[1, 2, 3]")) { error in
            XCTAssertEqual(error as? GraphDecodingError, .notAnObject)
        }
    }

    func testTargetWithoutNameOrProductTypeThrows() {
        let noName = #"{"schema-version":1,"name":"X","targets":[{"product-type":"app"}]}"#
        XCTAssertThrowsError(try decode(noName))

        let noType = #"{"schema-version":1,"name":"X","targets":[{"name":"T"}]}"#
        XCTAssertThrowsError(try decode(noType))
    }

    func testFileNodeThatIsNeitherGroupNorFileThrows() {
        let json = #"{"schema-version":1,"name":"X","files":[{"target-membership":["T"]}]}"#
        XCTAssertThrowsError(try decode(json)) { error in
            guard case .malformedNode = error as? GraphDecodingError else {
                return XCTFail("expected .malformedNode, got \(error)")
            }
        }
    }

    /// The tree is walked with an explicit stack precisely so this throws instead of
    /// overflowing the call stack — a stack overflow is uncatchable, a thrown error
    /// names the file. Both sides of the boundary are asserted, so a limit that is
    /// off by one, or absent, fails rather than passing by accident.
    func testDepthCeilingIsEnforcedAtExactlyTheStatedBoundary() throws {
        let limits = XcprojDecoder.DecodingLimits(maximumTreeDepth: 8, maximumTreeNodes: 1_000)

        // Depth counts every node, leaf included: 7 nested groups put the leaf at
        // depth 8, which is the last accepted level.
        let atLimit = try decode(nestedTreeJSON(depth: 7), limits: limits)
        XCTAssertEqual(try XCTUnwrap(atLimit.target(named: "T")).membership.count, 1)

        XCTAssertThrowsError(try decode(nestedTreeJSON(depth: 8), limits: limits)) { error in
            XCTAssertEqual(error as? GraphDecodingError, .fileTreeTooDeep(limit: 8))
        }
    }

    func testNodeCeilingIsEnforcedAtExactlyTheStatedBoundary() throws {
        let limits = XcprojDecoder.DecodingLimits(maximumTreeDepth: 64, maximumTreeNodes: 5)

        func flatTree(fileCount: Int) -> String {
            let pieces = (0..<fileCount).map {
                #"{"path":"f\#($0).swift","target-membership":["T"]}"#
            }
            return #"{"schema-version":1,"name":"X","targets":[{"name":"T","product-type":"p"}],"files":["#
                + pieces.joined(separator: ",") + "]}"
        }

        let atLimit = try decode(flatTree(fileCount: 5), limits: limits)
        XCTAssertEqual(try XCTUnwrap(atLimit.target(named: "T")).membership.count, 5)

        XCTAssertThrowsError(try decode(flatTree(fileCount: 6), limits: limits)) { error in
            XCTAssertEqual(error as? GraphDecodingError, .fileTreeTooLarge(limit: 5))
        }
    }

    /// The shipped defaults must be the ones the README quotes.
    func testDefaultLimitsAreTheDocumentedOnes() {
        XCTAssertEqual(XcprojDecoder.DecodingLimits.default.maximumTreeDepth, 64)
        XCTAssertEqual(XcprojDecoder.DecodingLimits.default.maximumTreeNodes, 200_000)
        // A zero or negative limit would make the walk reject every file; the
        // initialiser floors it at 1 rather than producing that surprise.
        XCTAssertEqual(
            XcprojDecoder.DecodingLimits(maximumTreeDepth: 0, maximumTreeNodes: -5).maximumTreeDepth, 1
        )
        XCTAssertEqual(
            XcprojDecoder.DecodingLimits(maximumTreeDepth: 0, maximumTreeNodes: -5).maximumTreeNodes, 1
        )
    }

    func testDuplicateMembershipIsDeduplicated() throws {
        let json = """
        {"schema-version":1,"name":"X",
         "targets":[{"name":"T","product-type":"p"}],
         "files":[
           {"path":"a.swift","target-membership":["T","T"]},
           {"path":"./a.swift","target-membership":["T"]}
         ]}
        """
        let graph = try decode(json)
        let target = try XCTUnwrap(graph.target(named: "T"))
        XCTAssertEqual(target.membership, ["a.swift"])
    }

    func testPackageWithUnrecognisedRequirementThrows() {
        let json = """
        {"schema-version":1,"name":"X",
         "package-dependencies":[{"url":"https://example.com/p.git",
                                  "requirement":{"kind":"vibes"}}]}
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testPackageIdentityIsDerivedWhenAbsent() throws {
        let json = """
        {"schema-version":1,"name":"X",
         "package-dependencies":[{"url":"https://github.com/o/Some-Kit.git",
                                  "requirement":{"kind":"exactVersion","minimum-version":"1.2.3"}}]}
        """
        let graph = try decode(json)
        XCTAssertEqual(graph.packages.first?.identity, "some-kit")
        XCTAssertEqual(graph.packages.first?.requirement, .exact("1.2.3"))
    }

    func testBranchRequirementIsRecognisedAsFloating() throws {
        let json = """
        {"schema-version":1,"name":"X",
         "package-dependencies":[{"url":"https://github.com/o/k.git",
                                  "requirement":{"kind":"branch","branch":"main"}}]}
        """
        let graph = try decode(json)
        XCTAssertEqual(graph.packages.first?.requirement, .branch("main"))
        XCTAssertEqual(graph.packages.first?.requirement.isFloating, true)
    }
}

final class JSONValueTests: XCTestCase {

    /// `Int(Double.infinity)` traps. JSON can produce an infinity, so the `Int`
    /// view has to go through the clamping conversion rather than `Int(_:)`.
    func testNonFiniteNumbersDoNotTrap() {
        XCTAssertEqual(JSONValue.number(.infinity).intValue, Int.max)
        XCTAssertEqual(JSONValue.number(-.infinity).intValue, Int.min)
        XCTAssertEqual(JSONValue.number(.nan).intValue, 0)
        XCTAssertEqual(JSONValue.number(1e300).intValue, Int.max)
        XCTAssertEqual(JSONValue.integer(7).intValue, 7)
        XCTAssertNil(JSONValue.string("7").intValue)
    }

    func testSettingValueRejectsShapesItCannotRepresent() {
        XCTAssertNil(JSONValue.null.settingValue)
        XCTAssertNil(JSONValue.object(["a": .string("b")]).settingValue)
        XCTAssertNil(JSONValue.array([.integer(1), .object([:])]).settingValue)
        XCTAssertEqual(JSONValue.array([.string("-lz")]).settingValue, .list(["-lz"]))
        XCTAssertEqual(JSONValue.boolean(true).settingValue, .boolean(true))
        XCTAssertEqual(JSONValue.string("YES").settingValue, .boolean(true))
    }

    /// A version-valued setting written as a JSON **number** must canonicalise to the
    /// same value as the same setting written as a JSON **string**.
    ///
    /// This goes through `XcprojDecoder.decode` on purpose. A hand-built
    /// `JSONValue.number(17.0)` proves nothing here, because the decoder never
    /// produces one for that input: Foundation round-trips `17.0` through `Double`
    /// and back losslessly, so JSON `17.0` arrives as `Int(17)` and the original
    /// spelling is already gone. Two earlier attempts at this fix — collapsing
    /// integral doubles to `Int`, then preserving the `Double` spelling — both failed
    /// for that reason. The working fix is `SettingTable.canonicalized` stripping
    /// trailing zeros for version-valued names, and only a decoder-level test can
    /// tell you it works.
    func testVersionSettingsCompareEqualAcrossJSONNumberAndStringSpellings() throws {
        func floorValue(_ literal: String) throws -> SettingValue? {
            let json = #"{"schema-version":1,"name":"X","build-settings":{"IPHONEOS_DEPLOYMENT_TARGET":\#(literal)}}"#
            let data = try XCTUnwrap(json.data(using: .utf8))
            let graph = GraphCanonicalizer.canonicalize(try XcprojDecoder.decode(data))
            return graph.projectSettings[SettingKey(name: "IPHONEOS_DEPLOYMENT_TARGET")]
        }

        let asNumber = try floorValue("17.0")
        let asString = try floorValue(#""17.0""#)
        let asBareInt = try floorValue("17")
        let asPatch = try floorValue(#""17.0.0""#)

        XCTAssertNotNil(asNumber)
        XCTAssertEqual(asNumber, asString, "a JSON number and string must not diff forever")
        XCTAssertEqual(asString, asBareInt)
        XCTAssertEqual(asBareInt, asPatch)

        // A genuine version change must still be reported.
        XCTAssertNotEqual(asString, try floorValue(#""15.0""#))
        XCTAssertNotEqual(asString, try floorValue(#""17.4""#))
    }

    /// The narrowing matters: a marketing version is a display string, so `1.0.0`
    /// and `1` are different edits and must not be collapsed.
    func testNonVersionSettingsKeepTheirExactSpelling() throws {
        func marketingValue(_ literal: String) throws -> SettingValue? {
            let json = #"{"schema-version":1,"name":"X","build-settings":{"MARKETING_VERSION":\#(literal)}}"#
            let data = try XCTUnwrap(json.data(using: .utf8))
            return GraphCanonicalizer.canonicalize(try XcprojDecoder.decode(data))
                .projectSettings[SettingKey(name: "MARKETING_VERSION")]
        }
        XCTAssertEqual(try marketingValue(#""1.0.0""#), .string("1.0.0"))
        XCTAssertNotEqual(try marketingValue(#""1.0.0""#), try marketingValue(#""1""#))
        XCTAssertFalse(SettingTable.isVersionValued(settingName: "MARKETING_VERSION"))
        XCTAssertTrue(SettingTable.isVersionValued(settingName: "SWIFT_VERSION"))
        XCTAssertTrue(SettingTable.isVersionValued(settingName: "IPHONEOS_DEPLOYMENT_TARGET"))
        XCTAssertTrue(SettingTable.isVersionValued(settingName: "MACOSX_DEPLOYMENT_TARGET"))
    }

    func testNonIntegralNumbersStillRenderAsThemselves() {
        XCTAssertEqual(JSONValue.number(6.5).settingValue, .string("6.5"))
        XCTAssertEqual(JSONValue.integer(17).settingValue, .string("17"))
    }
}
