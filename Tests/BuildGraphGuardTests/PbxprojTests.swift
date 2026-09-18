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

    /// **Every** truncation of a real file must be rejected — never trap, and never
    /// be mistaken for a valid project.
    ///
    /// This is the test that earns the hand-written scanner. A parser reached by a
    /// gate runs on whatever is on the branch, including a file a crashed merge left
    /// half-written, and a trap there takes CI down rather than rejecting the commit.
    ///
    /// The assertion is on `PbxprojBridge.decode`, not on `OpenStepPlist.parse`, and
    /// that is deliberate rather than a weakening. A one-character prefix of this
    /// fixture is `/`, which is a perfectly legal *bare token* in the OpenStep
    /// dialect, so demanding that the scanner reject it would be demanding wrong
    /// behaviour. What must never happen is that a truncated file yields a usable
    /// build graph — that is what this asserts, for all 6,055 prefixes.
    ///
    /// An earlier draft wrote `_ = try? OpenStepPlist.parse(prefix)` with no
    /// assertion at all; a `parse` gutted to `return .string("")` would have kept it
    /// green, and the README nonetheless claimed it proved "throws rather than traps".
    func testEveryTruncationOfARealFileIsRejected() throws {
        let characters = Array(SampleProjects.storefrontLegacy)
        // Pinned, not approximate: the README quotes this number, and "~5,000" was
        // wrong by 20% in a document whose thesis is that claims get checked.
        XCTAssertEqual(characters.count, 6_055, "fixture size changed; update the README")

        for prefixLength in 0..<characters.count {
            let prefix = String(characters[0..<prefixLength])
            XCTAssertThrowsError(
                try PbxprojBridge.decode(prefix),
                "prefix of length \(prefixLength) produced a build graph"
            )
        }

        // The untruncated file must still decode, or the loop above would be
        // satisfied by a bridge that rejects everything.
        XCTAssertNoThrow(try PbxprojBridge.decode(SampleProjects.storefrontLegacy))
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

        // `6`, not `6.0`: `SWIFT_VERSION` is version-valued, so canonicalisation
        // strips trailing zeros (see `SettingTable.isVersionValued`). That is what
        // lets the legacy file's `6.0` and a JSON file's bare `6` compare equal.
        XCTAssertEqual(
            graph.projectSettings[SettingKey(name: "SWIFT_VERSION")], .string("6")
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

    /// The bridge's declared coverage has to reach the reviewer, not just the
    /// source file. A previous version of this test asserted only that the two
    /// arrays were non-empty — a tautology over two literals that passed with the
    /// whole bridge gutted. This asserts the advisory a reviewer actually reads
    /// names both halves.
    func testCoverageLimitsReachTheAdvisoryAReviewerSees() throws {
        let legacy = try PbxprojBridge.decode(SampleProjects.storefrontLegacy)
        let modern = try XcprojDecoder.decode(
            try XCTUnwrap(SampleProjects.storefrontBaseline.data(using: .utf8))
        )
        let assessment = PolicyEngine().assess(
            GraphDiffer.diff(baseline: legacy, proposed: modern)
        )
        let advisory = try XCTUnwrap(
            assessment.violations.first { $0.ruleID == "format.cross-format-comparison" }
        )

        // Non-emptiness first. A bare `for item in …` loop over an empty array is
        // vacuously true, so emptying `BridgeCoverage` would otherwise degrade the
        // advisory to "PbxprojBridge models ; it does not model ," with nothing red.
        XCTAssertFalse(PbxprojBridge.BridgeCoverage.modelled.isEmpty)
        XCTAssertFalse(PbxprojBridge.BridgeCoverage.notModelled.isEmpty)
        XCTAssertTrue(
            advisory.explanation.contains("shell-script phases"),
            "a named limitation must survive into the text a reviewer reads"
        )
        XCTAssertTrue(advisory.explanation.contains("target names"))

        for item in PbxprojBridge.BridgeCoverage.notModelled {
            XCTAssertTrue(
                advisory.explanation.contains(item),
                "advisory does not mention the unmodelled field '\(item)'"
            )
        }
        for item in PbxprojBridge.BridgeCoverage.modelled {
            XCTAssertTrue(
                advisory.explanation.contains(item),
                "advisory does not mention the modelled field '\(item)'"
            )
        }
    }
}
