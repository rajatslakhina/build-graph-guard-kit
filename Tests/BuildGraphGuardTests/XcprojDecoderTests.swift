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

    /// `IPHONEOS_DEPLOYMENT_TARGET: 17.0` as a JSON number and `"17.0"` as a JSON
    /// string are the same setting, and must canonicalise to the same value.
    ///
    /// An earlier version collapsed integral doubles to `Int`, so `17.0` became
    /// `"17"` and diffed against `"17.0"` on every single run — exactly the
    /// migration-day noise this library exists to suppress. The assertion below is
    /// the regression test for that, which is why it compares against the string
    /// spelling rather than against a hand-written expectation.
    func testIntegralJSONNumbersKeepTheirDecimalSpelling() {
        XCTAssertEqual(
            JSONValue.number(17.0).settingValue,
            SettingValue.string("17.0").canonicalized
        )
        XCTAssertEqual(JSONValue.number(6.5).settingValue, .string("6.5"))
        // A JSON integer has no decimal spelling to preserve.
        XCTAssertEqual(JSONValue.integer(17).settingValue, .string("17"))
    }
}
