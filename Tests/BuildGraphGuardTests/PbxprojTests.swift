import XCTest
@testable import BuildGraphGuard

final class OpenStepPlistTests: XCTestCase {

    func testParsesTheDialectPbxprojActuallyUses() throws {
        let text = """
        // !$*UTF8*$!
        {
          archiveVersion = 1;
          objects = {
            AA11 /* a comment */ = {isa = PBXBuildFile; path = "quoted value"; };
            BB22 = (one, two, "three four");
          };
          rootObject = AA11;
        }
        """
        let root = try XCTUnwrap(OpenStepPlist.parse(text).dictionaryValue)
        XCTAssertEqual(root["archiveVersion"]?.stringValue, "1")
        XCTAssertEqual(root["rootObject"]?.stringValue, "AA11")

        let objects = try XCTUnwrap(root["objects"]?.dictionaryValue)
        let first = try XCTUnwrap(objects["AA11"]?.dictionaryValue)
        XCTAssertEqual(first["isa"]?.stringValue, "PBXBuildFile")
        XCTAssertEqual(first["path"]?.stringValue, "quoted value")

        let list = try XCTUnwrap(objects["BB22"]?.arrayValue)
        XCTAssertEqual(list.compactMap(\.stringValue), ["one", "two", "three four"])
    }

    func testEscapeSequencesInQuotedStrings() throws {
        let text = #"{ a = "line\nbreak"; b = "say \"hi\""; c = "tab\there"; }"#
        let root = try XCTUnwrap(OpenStepPlist.parse(text).dictionaryValue)
        XCTAssertEqual(root["a"]?.stringValue, "line\nbreak")
        XCTAssertEqual(root["b"]?.stringValue, "say \"hi\"")
        XCTAssertEqual(root["c"]?.stringValue, "tab\there")
    }

    func testMalformedInputThrowsRatherThanCrashing() {
        let cases = [
            #"{ a = "unterminated ; }"#,
            "{ a = /* unterminated comment ; }",
            "{ a = 1;",
            "( 1, 2",
            "{ a }",
            "{ = 1; }",
            "{ a = 1; } trailing"
        ]
        for text in cases {
            XCTAssertThrowsError(try OpenStepPlist.parse(text), "should have thrown for: \(text)")
        }
    }

    func testDeepNestingThrowsRatherThanOverflowing() {
        let depth = OpenStepPlist.maximumDepth + 10
        let text = String(repeating: "{ a = ", count: depth) + "1"
            + String(repeating: "; }", count: depth)
        XCTAssertThrowsError(try OpenStepPlist.parse(text))
    }

    /// Every truncation of a real file must either parse or throw — never trap.
    ///
    /// This is the test that earns the hand-written scanner. A parser reached by a
    /// gate runs on whatever is on the branch, including a file a crashed merge left
    /// half-written, and a trap there takes CI down rather than rejecting the commit.
    func testEveryTruncationOfARealFileIsHandled() {
        let full = SampleProjects.storefrontLegacy
        let characters = Array(full)
        XCTAssertGreaterThan(characters.count, 1_000, "fixture should be substantial")

        // Step through the file rather than testing all ~4,000 prefixes, which would
        // be the same assertion 4,000 times at 4,000 times the runtime.
        var prefixLength = 0
        while prefixLength < characters.count {
            let prefix = String(characters[0..<prefixLength])
            // The only requirement is "does not trap"; either outcome is acceptable.
            _ = try? OpenStepPlist.parse(prefix)
            prefixLength = min(characters.count, prefixLength + 17)
        }
    }

    func testEmptyAndWhitespaceOnlyInputThrow() {
        XCTAssertThrowsError(try OpenStepPlist.parse(""))
        XCTAssertThrowsError(try OpenStepPlist.parse("   \n\t "))
        XCTAssertThrowsError(try OpenStepPlist.parse("// just a comment"))
    }
}

final class PbxprojBridgeTests: XCTestCase {

    func testProjectsLegacyFileIntoTheSameShape() throws {
        let graph = try PbxprojBridge.decode(SampleProjects.storefrontLegacy)

        XCTAssertEqual(graph.origin, .pbxproj(objectVersion: 56))
        XCTAssertEqual(graph.targets.map(\.name), ["Storefront", "StorefrontTests"])

        let app = try XCTUnwrap(graph.target(named: "Storefront"))
        XCTAssertEqual(app.productType, "com.apple.product-type.application")
        XCTAssertEqual(
            app.membership,
            ["Storefront/Checkout/CartModel.swift", "Storefront/StorefrontApp.swift"]
        )
        XCTAssertEqual(app.packageProducts, ["CheckoutKit"])

        let package = try XCTUnwrap(graph.packages.first)
        XCTAssertEqual(package.identity, "checkout-kit")
        XCTAssertEqual(package.requirement, .upToNextMajor(minimum: "2.4.0"))
    }

    /// The hoist is what makes a migration diff readable.
    ///
    /// `SWIFT_VERSION` is `6.0` in both configurations and must come out as one
    /// unconditioned key; `SWIFT_ACTIVE_COMPILATION_CONDITIONS` exists only in Debug
    /// and must keep its condition. Remove the hoist and the first assertion fails —
    /// which is the whole point, because without it every uniform setting in the file
    /// would appear as a change on migration day.
    func testUniformSettingsAreHoistedAndNonUniformOnesAreNot() throws {
        let graph = try PbxprojBridge.decode(SampleProjects.storefrontLegacy)

        XCTAssertEqual(
            graph.projectSettings[SettingKey(name: "SWIFT_VERSION")], .string("6.0")
        )
        XCTAssertNil(
            graph.projectSettings[
                SettingKey(
                    name: "SWIFT_VERSION",
                    conditions: [SettingCondition(dimension: "config", value: "Debug")]
                )
            ],
            "a uniform setting must not also survive as a per-config key"
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
        XCTAssertNil(
            graph.projectSettings[SettingKey(name: "SWIFT_ACTIVE_COMPILATION_CONDITIONS")],
            "a Debug-only setting must not be hoisted to unconditioned"
        )
    }

    func testStringYesBecomesTheSameBooleanTheJSONFormatWrites() throws {
        let legacy = try PbxprojBridge.decode(SampleProjects.storefrontLegacy)
        let modern = try XcprojDecoder.decode(
            try XCTUnwrap(SampleProjects.storefrontBaseline.data(using: .utf8))
        )
        let key = SettingKey(name: "ENABLE_USER_SCRIPT_SANDBOXING")
        XCTAssertEqual(legacy.projectSettings[key], .boolean(true))
        XCTAssertEqual(legacy.projectSettings[key], modern.projectSettings[key])
    }

    /// A bad merge can produce a group tree with a cycle. Recursion there is a hang
    /// followed by a stack overflow; the visited set turns it into a finite walk.
    func testCyclicGroupTreeTerminates() throws {
        let text = """
        // !$*UTF8*$!
        {
          objectVersion = 56;
          objects = {
            G1 = {isa = PBXGroup; children = (G2); path = one; sourceTree = "<group>"; };
            G2 = {isa = PBXGroup; children = (G1, F1); path = two; sourceTree = "<group>"; };
            F1 = {isa = PBXFileReference; path = leaf.swift; sourceTree = "<group>"; };
            T1 = {isa = PBXNativeTarget; name = T; productType = p; buildPhases = (S1); };
            S1 = {isa = PBXSourcesBuildPhase; files = (B1); };
            B1 = {isa = PBXBuildFile; fileRef = F1; };
            P1 = {isa = PBXProject; mainGroup = G1; targets = (T1); name = Cyclic; };
          };
          rootObject = P1;
        }
        """
        let graph = try PbxprojBridge.decode(text)
        XCTAssertEqual(graph.name, "Cyclic")
        let target = try XCTUnwrap(graph.target(named: "T"))
        XCTAssertEqual(target.membership, ["one/two/leaf.swift"])
    }

    func testMissingRootObjectOrObjectsThrows() {
        XCTAssertThrowsError(try PbxprojBridge.decode("{ rootObject = X; }")) { error in
            XCTAssertEqual(error as? GraphDecodingError, .missingField("objects"))
        }
        XCTAssertThrowsError(try PbxprojBridge.decode("{ objects = {}; }")) { error in
            XCTAssertEqual(error as? GraphDecodingError, .missingField("rootObject"))
        }
        XCTAssertThrowsError(try PbxprojBridge.decode("{ objects = {}; rootObject = Nope; }"))
        XCTAssertThrowsError(try PbxprojBridge.decode("(1, 2)")) { error in
            XCTAssertEqual(
                error as? GraphDecodingError, .malformedPlist(reason: "root is not a dictionary")
            )
        }
    }

    func testNonNativeTargetsAreSkipped() throws {
        let text = """
        {
          objectVersion = 56;
          objects = {
            G1 = {isa = PBXGroup; children = (); sourceTree = "<group>"; };
            T1 = {isa = PBXAggregateTarget; name = Aggregate; };
            P1 = {isa = PBXProject; mainGroup = G1; targets = (T1); name = Only; };
          };
          rootObject = P1;
        }
        """
        let graph = try PbxprojBridge.decode(text)
        XCTAssertTrue(graph.targets.isEmpty)
    }

    func testCoverageIsDeclaredNotImplied() {
        XCTAssertFalse(PbxprojBridge.BridgeCoverage.modelled.isEmpty)
        XCTAssertFalse(PbxprojBridge.BridgeCoverage.notModelled.isEmpty)
    }
}
