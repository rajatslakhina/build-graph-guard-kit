import XCTest
@testable import BuildGraphGuard

final class GraphDifferTests: XCTestCase {

    private func graph(_ json: String) throws -> ProjectGraph {
        try XcprojDecoder.decode(try XCTUnwrap(json.data(using: .utf8)))
    }

    private func diffOfSamples(
        _ baseline: String, _ proposed: String
    ) throws -> GraphDiff {
        GraphDiffer.diff(baseline: try graph(baseline), proposed: try graph(proposed))
    }

    // MARK: - The central claim

    /// Formatting churn must not produce changes.
    ///
    /// The first assertion proves the two inputs really are textually different, so
    /// the second is catching something. Delete `GraphCanonicalizer` from the diff
    /// path and this test fails, which is what makes the README's "semantic, not
    /// textual" claim checkable rather than decorative.
    func testReorderedAndReformattedFileProducesNoChanges() throws {
        let reformatted = """
        {
            "name"  :  "Storefront" ,
          "package-dependencies": [
            { "requirement": { "minimum-version": "2.4.0", "kind": "upToNextMajorVersion" },
              "url": "https://github.com/example-org/checkout-kit.git",
              "identity": "CHECKOUT-KIT" }
          ],
          "targets": [
            { "product-type": "com.apple.product-type.bundle.unit-test",
              "build-settings": {}, "name": "StorefrontTests" },
            { "package-product-dependencies": ["CheckoutKit"],
              "build-settings": { "DEVELOPMENT_TEAM": "AB12CD34EF",
                                  "CODE_SIGN_IDENTITY": "Apple Development" },
              "product-type": "com.apple.product-type.application",
              "name": "Storefront" }
          ],
          "schema-version": 1,
          "files": [
            { "group": "StorefrontTests",
              "children": [ { "target-membership": ["StorefrontTests"],
                              "path": "./CartModelTests.swift" } ] },
            { "group": "Storefront",
              "children": [
                { "group": "Checkout",
                  "children": [ { "path": "CartModel.swift",
                                  "target-membership": ["StorefrontTests", "Storefront"] } ] },
                { "path": "StorefrontApp.swift", "target-membership": ["Storefront"] }
              ] }
          ],
          "build-settings": {
            "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS[config=Debug]": "DEBUG",
            "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
            "SWIFT_VERSION": "6.0"
          }
        }
        """
        XCTAssertNotEqual(
            reformatted, SampleProjects.storefrontBaseline,
            "the two files must differ textually or this test proves nothing"
        )

        let diff = try diffOfSamples(SampleProjects.storefrontBaseline, reformatted)
        XCTAssertTrue(
            diff.isEmpty,
            "expected no semantic change, got: \(diff.changes.map(\.summary))"
        )
    }

    /// A conditioned override changes what the build sees without touching the key
    /// a reviewer reads. Both halves are asserted: the literal unconditioned key is
    /// unchanged, *and* the effective Release value moved. Delete the effective
    /// channel and the second assertion fails while the first still passes — which
    /// is exactly the blind spot the channel exists to close.
    func testReleaseOnlyOverrideIsInvisibleToTheLiteralChannelAlone() throws {
        let diff = try diffOfSamples(
            SampleProjects.storefrontBaseline, SampleProjects.storefrontAgentEdit
        )

        let unconditionedSigningChanged = diff.changes.contains { change in
            guard case .settingChanged(_, let key, _, _) = change else { return false }
            return key.name == "CODE_SIGN_IDENTITY" && key.isUnconditioned
        }
        XCTAssertFalse(
            unconditionedSigningChanged,
            "the base CODE_SIGN_IDENTITY genuinely does not move in this edit"
        )

        let effectiveReleaseSigning = diff.changes.contains { change in
            guard case .effectiveSettingChanged(let scope, let configuration, let name, _, let to) = change
            else { return false }
            return scope == .target("Storefront")
                && configuration == "Release"
                && name == "CODE_SIGN_IDENTITY"
                && to == .string("-")
        }
        XCTAssertTrue(effectiveReleaseSigning, "the effective Release value must be reported")

        let debugSigningChanged = diff.changes.contains { change in
            guard case .effectiveSettingChanged(_, let configuration, let name, _, _) = change
            else { return false }
            return configuration == "Debug" && name == "CODE_SIGN_IDENTITY"
        }
        XCTAssertFalse(debugSigningChanged, "Debug signing is untouched and must not be reported")
    }

    /// The migration case: same project, two formats, no structural difference.
    /// This is the assertion that would fail if the bridge or the hoist regressed.
    func testCrossFormatMigrationProducesNoStructuralChanges() throws {
        let legacy = try PbxprojBridge.decode(SampleProjects.storefrontLegacy)
        let modern = try graph(SampleProjects.storefrontBaseline)
        let diff = GraphDiffer.diff(baseline: legacy, proposed: modern)

        XCTAssertTrue(
            diff.isEmpty,
            "expected a clean migration, got: \(diff.changes.map(\.summary))"
        )
        XCTAssertTrue(diff.isCrossFormat)
        XCTAssertEqual(diff.baselineOrigin, .pbxproj(objectVersion: 56))
        XCTAssertEqual(diff.proposedOrigin, .xcproj(schemaVersion: 1))
    }

    /// The hoist is what earns the previous test's `isEmpty`, and this proves it by
    /// running the **real bridge with hoisting switched off** rather than by
    /// rebuilding an un-hoisted table inline.
    ///
    /// The distinction matters: an inline reconstruction asserts that the test's own
    /// arithmetic works and would keep passing if `PbxprojBridge.settings` lost its
    /// hoist entirely. This version calls the production code path, so deleting the
    /// hoist makes `testCrossFormatMigrationProducesNoStructuralChanges` fail and
    /// this test's `XCTAssertNotEqual` fail too — which is the point of having both.
    func testWithoutHoistingTheSameMigrationWouldBeNoisy() throws {
        let modern = try graph(SampleProjects.storefrontBaseline)

        let hoisted = try PbxprojBridge.decode(SampleProjects.storefrontLegacy)
        let unhoisted = try PbxprojBridge.decode(
            SampleProjects.storefrontLegacy, hoistUniformSettings: false
        )
        XCTAssertNotEqual(
            hoisted.projectSettings, unhoisted.projectSettings,
            "the flag must actually change the projection, or this test proves nothing"
        )

        let quiet = GraphDiffer.diff(baseline: hoisted, proposed: modern)
        let noisy = GraphDiffer.diff(baseline: unhoisted, proposed: modern)

        XCTAssertTrue(quiet.isEmpty)
        XCTAssertFalse(noisy.isEmpty)

        // Every setting that is uniform across Debug and Release in the legacy file
        // — SWIFT_VERSION, IPHONEOS_DEPLOYMENT_TARGET, ENABLE_USER_SCRIPT_SANDBOXING,
        // CODE_SIGN_IDENTITY, DEVELOPMENT_TEAM — appears as a spurious change.
        let spuriousNames = Set(noisy.changes.compactMap(\.settingName))
        XCTAssertTrue(spuriousNames.contains("SWIFT_VERSION"), "got \(spuriousNames.sorted())")
        XCTAssertTrue(spuriousNames.contains("IPHONEOS_DEPLOYMENT_TARGET"))
        XCTAssertTrue(spuriousNames.contains("ENABLE_USER_SCRIPT_SANDBOXING"))
        XCTAssertTrue(spuriousNames.contains("CODE_SIGN_IDENTITY"))
    }

    // MARK: - Change coverage

    func testMembershipAdditionIsReportedPerTarget() throws {
        let diff = try diffOfSamples(
            SampleProjects.storefrontBaseline, SampleProjects.storefrontRoutineEdit
        )
        XCTAssertTrue(
            diff.changes.contains(
                .membershipAdded(target: "Storefront", path: "Storefront/Checkout/PromoCodeView.swift")
            )
        )
        XCTAssertTrue(
            diff.changes.contains(
                .membershipAdded(target: "StorefrontTests", path: "StorefrontTests/PromoCodeTests.swift")
            )
        )
    }

    func testPackageRepointAndPinChangeAreBothReported() throws {
        let diff = try diffOfSamples(
            SampleProjects.storefrontBaseline, SampleProjects.storefrontSupplyChainEdit
        )
        XCTAssertTrue(
            diff.changes.contains { change in
                guard case .packageRepointed(let identity, _, let to) = change else { return false }
                return identity == "checkout-kit" && to.contains("example-0rg")
            }
        )
        XCTAssertTrue(
            diff.changes.contains { change in
                guard case .packageRequirementChanged(_, _, let to) = change else { return false }
                return to == .branch("main")
            }
        )
    }

    func testAddedTargetReportsItsWholeMembership() throws {
        let baseline = #"{"schema-version":1,"name":"X"}"#
        let proposed = """
        {"schema-version":1,"name":"X",
         "targets":[{"name":"New","product-type":"p","package-product-dependencies":["Lib"]}],
         "files":[{"path":"a.swift","target-membership":["New"]}]}
        """
        let diff = try diffOfSamples(baseline, proposed)
        XCTAssertTrue(diff.changes.contains(.targetAdded(name: "New", productType: "p")))
        XCTAssertTrue(diff.changes.contains(.membershipAdded(target: "New", path: "a.swift")))
        XCTAssertTrue(diff.changes.contains(.packageProductLinked(target: "New", product: "Lib")))
    }

    func testIdenticalGraphsProduceAnEmptyDiff() throws {
        let diff = try diffOfSamples(
            SampleProjects.storefrontBaseline, SampleProjects.storefrontBaseline
        )
        XCTAssertTrue(diff.isEmpty)
        XCTAssertFalse(diff.isCrossFormat)
        XCTAssertEqual(diff.membershipChurnPercentage, 0)
        XCTAssertTrue(diff.touchedScopes.isEmpty)
    }

    func testChurnPercentageIsRelativeToBaselineSize() throws {
        let diff = try diffOfSamples(
            SampleProjects.storefrontBaseline, SampleProjects.storefrontRoutineEdit
        )
        // Baseline has 4 memberships (CartModel counted in both targets); the edit
        // adds 2, which is 50%.
        XCTAssertEqual(diff.baselineMembershipCount, 4)
        XCTAssertEqual(diff.membershipChurnPercentage, 50)
    }

    func testChurnPercentageHandlesAnEmptyBaseline() throws {
        let diff = try diffOfSamples(
            #"{"schema-version":1,"name":"X"}"#,
            """
            {"schema-version":1,"name":"X",
             "targets":[{"name":"T","product-type":"p"}],
             "files":[{"path":"a.swift","target-membership":["T"]}]}
            """
        )
        XCTAssertEqual(diff.baselineMembershipCount, 0)
        XCTAssertEqual(diff.membershipChurnPercentage, 0)
    }
}

final class GraphCanonicalizerTests: XCTestCase {

    /// Idempotence asserted on a *deliberately non-canonical* input.
    ///
    /// Run on an already-canonical graph, `canonicalize(canonicalize(x)) ==
    /// canonicalize(x)` is satisfied by the identity function and proves nothing.
    /// Starting from unsorted, duplicated, `.git`-suffixed input forces the first
    /// application to change something — asserted explicitly — before the second is
    /// required to change nothing.
    func testCanonicalizationIsIdempotentStartingFromMessyInput() {
        let messy = ProjectGraph(
            origin: .xcproj(schemaVersion: 1),
            name: "X",
            targets: [
                TargetNode(
                    name: "Zeta", productType: "p",
                    membership: ["b/./x.swift", "a.swift", "b/x.swift"],
                    packageProducts: ["Two", "One", "Two"]
                ),
                TargetNode(name: "Alpha", productType: "p", membership: ["./c.swift"])
            ],
            packages: [
                PackageDependency(
                    identity: "ZED", url: "https://example.com/z.git/",
                    requirement: .exact("1.0.0")
                ),
                PackageDependency(
                    identity: "ACE", url: "https://example.com/a",
                    requirement: .exact("2.0.0")
                )
            ]
        )
        XCTAssertFalse(
            GraphCanonicalizer.isCanonical(messy),
            "the input must be non-canonical or this test is satisfied by the identity function"
        )

        let once = GraphCanonicalizer.canonicalize(messy)
        XCTAssertNotEqual(once, messy, "the first application must actually change something")

        let twice = GraphCanonicalizer.canonicalize(once)
        XCTAssertEqual(once, twice)
        XCTAssertTrue(GraphCanonicalizer.isCanonical(once))

        XCTAssertEqual(once.targets.map(\.name), ["Alpha", "Zeta"])
        XCTAssertEqual(once.packages.map(\.identity), ["ace", "zed"])
        XCTAssertEqual(once.packages.map(\.url), ["https://example.com/a", "https://example.com/z"])
    }

    func testCanonicalizationSortsAndDeduplicates() {
        let target = TargetNode(
            name: "T",
            productType: "p",
            membership: ["b/./x.swift", "a.swift", "b/x.swift", ""],
            packageProducts: ["Two", "One", "Two"]
        )
        let graph = ProjectGraph(origin: .xcproj(schemaVersion: 1), name: "X", targets: [target])
        let canonical = GraphCanonicalizer.canonicalize(graph)
        let canonicalTarget = canonical.targets.first

        XCTAssertEqual(canonicalTarget?.membership, ["a.swift", "b/x.swift"])
        XCTAssertEqual(canonicalTarget?.packageProducts, ["One", "Two"])
    }

    /// A trailing slash or a `.git` suffix is the same repository. Leaving them
    /// distinct would let a dependency be re-pointed at a look-alike and read as
    /// "unchanged, plus one new package" rather than as a substitution.
    func testRepositoryURLsCanonicalizeToTheSameForm() {
        XCTAssertEqual(
            GraphCanonicalizer.normalizeRepositoryURL("https://example.com/a.git"),
            GraphCanonicalizer.normalizeRepositoryURL("https://example.com/a/")
        )
        XCTAssertEqual(
            GraphCanonicalizer.normalizeRepositoryURL("https://example.com/a"),
            "https://example.com/a"
        )
        // A different host must stay different.
        XCTAssertNotEqual(
            GraphCanonicalizer.normalizeRepositoryURL("https://example.com/a.git"),
            GraphCanonicalizer.normalizeRepositoryURL("https://exampl3.com/a.git")
        )
    }

    func testEmptyGraphCanonicalizesWithoutCrashing() {
        let empty = ProjectGraph(origin: .xcproj(schemaVersion: 1), name: "")
        let canonical = GraphCanonicalizer.canonicalize(empty)
        XCTAssertTrue(canonical.targets.isEmpty)
        XCTAssertTrue(canonical.packages.isEmpty)
        XCTAssertEqual(canonical.totalMembershipCount, 0)
        XCTAssertEqual(canonical.configurationNames, ["Debug", "Release"])
    }
}
