import XCTest
@testable import BuildGraphGuard

final class PolicyEngineTests: XCTestCase {

    /// The package root, derived from this file's own path.
    ///
    /// The alternative — declaring `Examples/` and `README.md` as test-bundle
    /// resources — would copy them, and a test that reads a *copy* cannot tell you
    /// the committed file is right. This reads the file a reviewer would open.
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // BuildGraphGuardTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root

    /// Drives one real assessment per rule the engine can emit, and returns the
    /// ids that actually fired. Nothing is hardcoded: if a rule stops being
    /// reachable, its id disappears from this set and the README comparison fails.
    static func everyRuleIDReachableThroughRealAssessments() throws -> Set<String> {
        func decode(_ json: String) throws -> ProjectGraph {
            try XcprojDecoder.decode(XCTUnwrap(json.data(using: .utf8)))
        }
        func ids(
            _ baseline: String, _ proposed: String, policy: BuildGraphPolicy = .baseline
        ) throws -> [String] {
            let diff = GraphDiffer.diff(
                baseline: try decode(baseline), proposed: try decode(proposed)
            )
            return PolicyEngine(policy: policy).assess(diff).violations.map(\.ruleID)
        }

        let empty = #"{"schema-version":1,"name":"X"}"#
        let oneTarget = #"{"schema-version":1,"name":"X","targets":[{"name":"T","product-type":"a"}]}"#
        let retypedTarget = #"{"schema-version":1,"name":"X","targets":[{"name":"T","product-type":"b"}]}"#
        let floor17 = #"{"schema-version":1,"name":"X","build-settings":{"IPHONEOS_DEPLOYMENT_TARGET":"17.0"}}"#
        let floorInherited = #"{"schema-version":1,"name":"X","build-settings":{"IPHONEOS_DEPLOYMENT_TARGET":"$(INHERITED)"}}"#
        let floor9 = #"{"schema-version":1,"name":"X","build-settings":{"IPHONEOS_DEPLOYMENT_TARGET":"9.0"}}"#
        let pinned = """
        {"schema-version":1,"name":"X","package-dependencies":[
          {"url":"https://github.com/o/k.git","requirement":{"kind":"upToNextMajorVersion","minimum-version":"1.0.0"}}]}
        """
        let bumped = """
        {"schema-version":1,"name":"X","package-dependencies":[
          {"url":"https://github.com/o/k.git","requirement":{"kind":"upToNextMajorVersion","minimum-version":"1.1.0"}}]}
        """
        let manyFiles = #"{"schema-version":1,"name":"X","targets":[{"name":"T","product-type":"a"}],"files":["#
            + (0..<5).map { #"{"path":"f\#($0).swift","target-membership":["T"]}"# }.joined(separator: ",")
            + "]}"

        var frozenTarget = BuildGraphPolicy.baseline
        frozenTarget.frozenTargets = ["T"]
        var noCreation = BuildGraphPolicy.baseline
        noCreation.allowTargetCreation = false
        var frozenPins = BuildGraphPolicy.baseline
        frozenPins.packagePins = .frozen
        var brokenFloor = BuildGraphPolicy.baseline
        brokenFloor.deploymentFloors = ["IPHONEOS_DEPLOYMENT_TARGET": "not-a-version"]
        var lowCeiling = BuildGraphPolicy.baseline
        lowCeiling.maximumMembershipChanges = 1

        var observed: Set<String> = []
        for sample in ReviewScenario.samples {
            observed.formUnion(try sample.assess().violations.map(\.ruleID))
        }
        observed.formUnion(try ids(floor17, floorInherited))
        observed.formUnion(try ids(floor17, floor9, policy: brokenFloor))
        observed.formUnion(try ids(oneTarget, retypedTarget, policy: frozenTarget))
        observed.formUnion(try ids(empty, oneTarget, policy: noCreation))
        observed.formUnion(try ids(oneTarget, empty))
        observed.formUnion(try ids(oneTarget, retypedTarget))
        observed.formUnion(try ids(pinned, bumped, policy: frozenPins))
        observed.formUnion(try ids(oneTarget, manyFiles, policy: lowCeiling))
        return observed
    }

    private func graph(_ json: String) throws -> ProjectGraph {
        try XcprojDecoder.decode(try XCTUnwrap(json.data(using: .utf8)))
    }

    private func assess(
        _ baseline: String,
        _ proposed: String,
        policy: BuildGraphPolicy = .baseline
    ) throws -> PolicyAssessment {
        let diff = GraphDiffer.diff(baseline: try graph(baseline), proposed: try graph(proposed))
        return PolicyEngine(policy: policy).assess(diff)
    }

    // MARK: - The headline cases

    func testAgentEditIsBlockedForBothBuriedChanges() throws {
        let assessment = try assess(
            SampleProjects.storefrontBaseline, SampleProjects.storefrontAgentEdit
        )
        XCTAssertEqual(assessment.verdict, .blocked)
        XCTAssertEqual(assessment.verdict.exitCode, 1)

        let frozenNames = Set(
            assessment.blockingViolations
                .filter { $0.ruleID == "setting.frozen" }
                .compactMap { $0.change?.settingName }
        )
        XCTAssertTrue(frozenNames.contains("ENABLE_USER_SCRIPT_SANDBOXING"))
        XCTAssertTrue(frozenNames.contains("CODE_SIGN_IDENTITY"))
    }

    /// Proves the block came from the *policy* rather than from something hardcoded
    /// in the engine. Hand the same diff a policy that freezes nothing and the same
    /// edit must sail through — otherwise the policy file is decoration.
    func testSameEditPassesUnderAPolicyThatFreezesNothing() throws {
        let permissive = BuildGraphPolicy(
            frozenSettingNames: [],
            frozenSettingPrefixes: [],
            deploymentFloors: [:],
            packagePins: .unrestricted,
            allowTargetCreation: true,
            allowTargetRemoval: true
        )
        let assessment = try assess(
            SampleProjects.storefrontBaseline,
            SampleProjects.storefrontAgentEdit,
            policy: permissive
        )
        XCTAssertEqual(assessment.verdict, .clean)
        XCTAssertTrue(assessment.violations.isEmpty)
        // The diff itself is unchanged; only the judgement of it moved.
        XCTAssertFalse(assessment.diff.isEmpty)
    }

    func testSupplyChainEditTripsEveryRelevantRule() throws {
        let assessment = try assess(
            SampleProjects.storefrontBaseline, SampleProjects.storefrontSupplyChainEdit
        )
        XCTAssertEqual(assessment.verdict, .blocked)

        let rules = Set(assessment.blockingViolations.map(\.ruleID))
        XCTAssertTrue(rules.contains("package.repointed"), "rules were \(rules)")
        XCTAssertTrue(rules.contains("package.floating-pin"), "rules were \(rules)")
        XCTAssertTrue(rules.contains("setting.deployment-floor"), "rules were \(rules)")
        XCTAssertTrue(rules.contains("membership.escapes-project"), "rules were \(rules)")
    }

    /// The control case. A gate that fires on ordinary work is a gate that gets
    /// disabled, so "stays quiet" is a tested property, not an aspiration.
    func testRoutineFeatureWorkIsNotFlagged() throws {
        let assessment = try assess(
            SampleProjects.storefrontBaseline, SampleProjects.storefrontRoutineEdit
        )
        XCTAssertEqual(
            assessment.verdict, .clean,
            "unexpected findings: \(assessment.violations.map { "\($0.ruleID): \($0.explanation)" })"
        )
        XCTAssertEqual(assessment.verdict.exitCode, 0)
        XCTAssertFalse(assessment.diff.isEmpty, "there really are changes; they are just benign")
    }

    /// The advisory has to survive a diff with zero changes, because a clean
    /// migration is exactly the case it exists to caveat.
    func testCrossFormatAdvisorySurvivesAnEmptyDiff() throws {
        let legacy = try PbxprojBridge.decode(SampleProjects.storefrontLegacy)
        let modern = try graph(SampleProjects.storefrontBaseline)
        let assessment = PolicyEngine().assess(
            GraphDiffer.diff(baseline: legacy, proposed: modern)
        )

        XCTAssertTrue(assessment.diff.isEmpty)
        XCTAssertEqual(assessment.verdict, .clean, "an advisory must never change the verdict")
        XCTAssertEqual(assessment.violations.count, 1)
        XCTAssertEqual(assessment.violations.first?.ruleID, "format.cross-format-comparison")
        XCTAssertEqual(assessment.violations.first?.severity, .advisory)
        XCTAssertNil(assessment.violations.first?.change)
    }

    // MARK: - Deployment floor

    func testDeploymentFloorBlocksOnlyWhenTheTargetDrops() throws {
        func floorAssessment(_ value: String) throws -> PolicyAssessment {
            let baseline = #"{"schema-version":1,"name":"X","build-settings":{"IPHONEOS_DEPLOYMENT_TARGET":"17.0"}}"#
            let proposed = #"{"schema-version":1,"name":"X","build-settings":{"IPHONEOS_DEPLOYMENT_TARGET":"\#(value)"}}"#
            return try assess(baseline, proposed)
        }

        XCTAssertEqual(try floorAssessment("15.0").verdict, .blocked)
        XCTAssertEqual(try floorAssessment("16.9.9").verdict, .blocked)
        XCTAssertEqual(try floorAssessment("18.0").verdict, .clean)
        // 17.0 is the floor itself, not below it.
        XCTAssertEqual(try floorAssessment("17.0.0").verdict, .clean)

        // A value that is not a plain version cannot be checked, and the gate says
        // so rather than pretending the rule ran. One finding per configuration —
        // the literal-channel duplicate is collapsed away, the per-configuration
        // detail is not.
        let inherited = try floorAssessment("$(INHERITED)")
        XCTAssertEqual(inherited.verdict, .needsReview)
        XCTAssertEqual(
            Set(inherited.warnings.map(\.ruleID)), ["setting.deployment-floor-unreadable"]
        )
        XCTAssertEqual(inherited.warnings.count, 2, "one per configuration: Debug and Release")
    }

    /// The differ reports a setting on two channels on purpose; a *finding* must
    /// not. Without the collapse, the single `ENABLE_USER_SCRIPT_SANDBOXING` edit
    /// below produces three identical-sounding rows — literal, Debug, Release — and
    /// a reviewer learns to scroll past findings.
    func testLiteralAndEffectiveChannelsDoNotBothReportTheSameEdit() throws {
        let baseline = #"{"schema-version":1,"name":"X","build-settings":{"ENABLE_USER_SCRIPT_SANDBOXING":true}}"#
        let proposed = #"{"schema-version":1,"name":"X","build-settings":{"ENABLE_USER_SCRIPT_SANDBOXING":false}}"#
        let assessment = try assess(baseline, proposed)

        // The diff itself still carries all three changes — the collapse is a
        // reporting decision, not a loss of analysis.
        XCTAssertEqual(assessment.diff.changes.count, 3)

        let frozen = assessment.violations.filter { $0.ruleID == "setting.frozen" }
        XCTAssertEqual(frozen.count, 2, "one per configuration, not one per channel")
        let configurations = frozen.compactMap { violation -> String? in
            guard case .effectiveSettingChanged(_, let configuration, _, _, _)? = violation.change
            else { return nil }
            return configuration
        }
        XCTAssertEqual(Set(configurations), ["Debug", "Release"])
    }

    /// The collapse must never delete a finding the effective channel cannot cover.
    ///
    /// `SettingTable.resolved` deliberately declines to resolve non-`config`
    /// dimensions rather than guess which SDK a build will use, so no effective
    /// finding exists for an `[sdk=...]` key. A collapse keyed only on
    /// rule/scope/name — which an earlier version was — silently deleted the
    /// `sdk`-qualified `setting.frozen` finding whenever the unconditioned key moved
    /// too, which is the one case where an attacker gets both edits for the price of
    /// having one of them reported.
    func testSdkQualifiedFindingSurvivesTheChannelCollapse() throws {
        let baseline = #"{"schema-version":1,"name":"X","build-settings":{"OTHER_LDFLAGS":"-lz"}}"#
        let proposed = """
        {"schema-version":1,"name":"X","build-settings":{
          "OTHER_LDFLAGS": "-lz -lcurl",
          "OTHER_LDFLAGS[sdk=iphoneos*]": "-lz -levil"
        }}
        """
        let assessment = try assess(baseline, proposed)
        let frozen = assessment.violations.filter { $0.ruleID == "setting.frozen" }

        let sdkFinding = frozen.first { violation in
            guard case .settingChanged(_, let key, _, _)? = violation.change else { return false }
            return key.conditions.contains(SettingCondition(dimension: "sdk", value: "iphoneos*"))
        }
        XCTAssertNotNil(sdkFinding, "the sdk-qualified edit must still be reported")
        XCTAssertEqual(assessment.verdict, .blocked)

        // And the redundant literal finding for the *unconditioned* key is still
        // collapsed, so the fix did not simply disable the de-duplication.
        let unconditionedLiteral = frozen.contains { violation in
            guard case .settingChanged(_, let key, _, _)? = violation.change else { return false }
            return key.isUnconditioned
        }
        XCTAssertFalse(unconditionedLiteral)
    }

    /// Coverage is decided on the resulting **value**, not on the key's shape.
    ///
    /// When a per-configuration override masks the base key, the effective channel
    /// reports the *override's* new value. Keying coverage on "an effective finding
    /// exists for this setting" therefore deleted the base edit while reporting a
    /// different one — here, `-levil` vanished from every violation while `-lcurl`
    /// was the only thing on screen.
    func testBaseKeyEditIsNotCoveredByAnOverridesEffectiveFinding() throws {
        let baseline = """
        {"schema-version":1,"name":"X","build-settings":{
          "OTHER_LDFLAGS": "-lz",
          "OTHER_LDFLAGS[config=Debug]": "-lz",
          "OTHER_LDFLAGS[config=Release]": "-lz"
        }}
        """
        let proposed = """
        {"schema-version":1,"name":"X","build-settings":{
          "OTHER_LDFLAGS": "-lz -levil",
          "OTHER_LDFLAGS[config=Debug]": "-lz",
          "OTHER_LDFLAGS[config=Release]": "-lz -lcurl"
        }}
        """
        let assessment = try assess(baseline, proposed)
        let frozen = assessment.violations.filter { $0.ruleID == "setting.frozen" }

        let reportsEvil = frozen.contains { violation in
            switch violation.change {
            case .settingChanged(_, _, _, let to)?, .effectiveSettingChanged(_, _, _, _, let to)?:
                return to == .string("-lz -levil")
            default:
                return false
            }
        }
        XCTAssertTrue(reportsEvil, "the edit to the base key must appear in some violation")

        let reportsCurl = frozen.contains { violation in
            switch violation.change {
            case .settingChanged(_, _, _, let to)?, .effectiveSettingChanged(_, _, _, _, let to)?:
                return to == .string("-lz -lcurl")
            default:
                return false
            }
        }
        XCTAssertTrue(reportsCurl, "the Release override must also be reported")
        XCTAssertEqual(assessment.verdict, .blocked)
    }

    /// A key qualified on two configurations at once can never be selected by
    /// `SettingTable.resolved` — `allSatisfy` cannot hold for two different
    /// configuration names — so nothing the effective channel produces derives from
    /// it, and it must never be collapsed away.
    func testDoublyConfigQualifiedKeyIsNeverCollapsed() throws {
        let baseline = #"{"schema-version":1,"name":"X","build-settings":{"OTHER_LDFLAGS":"-lz"}}"#
        let proposed = """
        {"schema-version":1,"name":"X","build-settings":{
          "OTHER_LDFLAGS": "-lz -lcurl",
          "OTHER_LDFLAGS[config=Debug][config=Release]": "-lz -lcurl"
        }}
        """
        let assessment = try assess(baseline, proposed)
        let doublyQualified = assessment.violations.contains { violation in
            guard case .settingChanged(_, let key, _, _)? = violation.change else { return false }
            return key.conditions.count == 2
        }
        XCTAssertTrue(doublyQualified, "an unresolvable key must still be reported")
    }

    /// When only a conditioned key moves there is no literal unconditioned finding
    /// to collapse, and the surviving finding must be the one that names Release.
    func testConditionedOverrideReportsTheAffectedConfiguration() throws {
        let assessment = try assess(
            SampleProjects.storefrontBaseline, SampleProjects.storefrontAgentEdit
        )
        let signing = assessment.violations.filter {
            $0.ruleID == "setting.frozen" && $0.change?.settingName == "CODE_SIGN_IDENTITY"
        }
        XCTAssertEqual(signing.count, 1)
        guard case .effectiveSettingChanged(_, let configuration, _, _, let to)? = signing.first?.change
        else {
            return XCTFail("expected the effective channel to be the surviving finding")
        }
        XCTAssertEqual(configuration, "Release")
        XCTAssertEqual(to, .string("-"))
    }

    func testRemovingTheDeploymentTargetEntirelyIsBlocked() throws {
        let baseline = #"{"schema-version":1,"name":"X","build-settings":{"IPHONEOS_DEPLOYMENT_TARGET":"17.0"}}"#
        let proposed = #"{"schema-version":1,"name":"X","build-settings":{}}"#
        let assessment = try assess(baseline, proposed)
        XCTAssertEqual(assessment.verdict, .blocked)
        XCTAssertTrue(assessment.blockingViolations.contains { $0.ruleID == "setting.deployment-floor" })
    }

    func testAMalformedFloorInThePolicyIsReportedNotSilentlySkipped() throws {
        let broken = BuildGraphPolicy(deploymentFloors: ["IPHONEOS_DEPLOYMENT_TARGET": "not-a-version"])
        let baseline = #"{"schema-version":1,"name":"X","build-settings":{"IPHONEOS_DEPLOYMENT_TARGET":"17.0"}}"#
        let proposed = #"{"schema-version":1,"name":"X","build-settings":{"IPHONEOS_DEPLOYMENT_TARGET":"9.0"}}"#
        let assessment = try assess(baseline, proposed, policy: broken)
        XCTAssertEqual(assessment.verdict, .needsReview)
        XCTAssertTrue(assessment.warnings.contains { $0.ruleID == "policy.malformed-floor" })
    }

    // MARK: - Targets and pins

    func testTargetRemovalIsBlockedByDefaultAndAllowedWhenConfigured() throws {
        let baseline = #"{"schema-version":1,"name":"X","targets":[{"name":"T","product-type":"p"}]}"#
        let proposed = #"{"schema-version":1,"name":"X"}"#

        XCTAssertEqual(try assess(baseline, proposed).verdict, .blocked)

        var permissive = BuildGraphPolicy.baseline
        permissive.allowTargetRemoval = true
        XCTAssertEqual(try assess(baseline, proposed, policy: permissive).verdict, .clean)
    }

    func testProductTypeChangeIsAlwaysBlocking() throws {
        let baseline = #"{"schema-version":1,"name":"X","targets":[{"name":"T","product-type":"com.apple.product-type.bundle.unit-test"}]}"#
        let proposed = #"{"schema-version":1,"name":"X","targets":[{"name":"T","product-type":"com.apple.product-type.application"}]}"#
        let assessment = try assess(baseline, proposed)
        XCTAssertEqual(assessment.verdict, .blocked)
        XCTAssertTrue(assessment.blockingViolations.contains { $0.ruleID == "target.product-type" })
    }

    func testFrozenTargetRejectsEvenABenignEdit() throws {
        var policy = BuildGraphPolicy.baseline
        policy.frozenTargets = ["Storefront"]
        let assessment = try assess(
            SampleProjects.storefrontBaseline,
            SampleProjects.storefrontRoutineEdit,
            policy: policy
        )
        XCTAssertEqual(assessment.verdict, .blocked)
        XCTAssertTrue(assessment.blockingViolations.contains { $0.ruleID == "target.frozen" })
    }

    func testPinPolicies() throws {
        let baseline = """
        {"schema-version":1,"name":"X","package-dependencies":[
          {"url":"https://github.com/o/k.git","requirement":{"kind":"upToNextMajorVersion","minimum-version":"1.0.0"}}]}
        """
        let bumped = """
        {"schema-version":1,"name":"X","package-dependencies":[
          {"url":"https://github.com/o/k.git","requirement":{"kind":"upToNextMajorVersion","minimum-version":"1.1.0"}}]}
        """
        let branched = """
        {"schema-version":1,"name":"X","package-dependencies":[
          {"url":"https://github.com/o/k.git","requirement":{"kind":"branch","branch":"main"}}]}
        """

        var frozen = BuildGraphPolicy.baseline
        frozen.packagePins = .frozen
        XCTAssertEqual(try assess(baseline, bumped, policy: frozen).verdict, .blocked)

        // The default allows a version bump but never a branch.
        XCTAssertEqual(try assess(baseline, bumped).verdict, .clean)
        XCTAssertEqual(try assess(baseline, branched).verdict, .blocked)

        var unrestricted = BuildGraphPolicy.baseline
        unrestricted.packagePins = .unrestricted
        XCTAssertEqual(try assess(baseline, branched, policy: unrestricted).verdict, .clean)
    }

    // MARK: - Volume

    func testMembershipVolumeCeilingWarnsWithoutBlocking() throws {
        var policy = BuildGraphPolicy.baseline
        policy.maximumMembershipChanges = 2

        let files = (0..<5).map { #"{"path":"f\#($0).swift","target-membership":["T"]}"# }
        let baseline = #"{"schema-version":1,"name":"X","targets":[{"name":"T","product-type":"p"}]}"#
        let proposed = #"{"schema-version":1,"name":"X","targets":[{"name":"T","product-type":"p"}],"files":["#
            + files.joined(separator: ",") + "]}"

        let assessment = try assess(baseline, proposed, policy: policy)
        XCTAssertEqual(assessment.verdict, .needsReview)
        let warning = try XCTUnwrap(assessment.warnings.first { $0.ruleID == "volume.membership" })
        XCTAssertNil(warning.change, "a volume finding is about the change set, not one edit")
        XCTAssertTrue(warning.explanation.contains("5 membership edits"))
    }

    // MARK: - Ordering and policy round-trip

    /// Ordering must not depend on the order the *input file* happened to list
    /// things in.
    ///
    /// Running the same assessment twice in one process proves nothing: Swift's
    /// hash seed is fixed per process, so two dictionaries built by the same code
    /// path with the same data iterate identically, and a genuine ordering leak
    /// would produce matching output on both runs. Feeding the same project with
    /// its keys, targets and files written in a different order is what actually
    /// varies the dictionary insertion order.
    /// Severity ordering, asserted on a diff that actually produces all three.
    ///
    /// The supply-chain fixture alone yields only `.blocking` findings, and a list
    /// where every element has the same severity is "sorted" under any permutation —
    /// so an earlier version of this test stayed green with the `sorted` call in
    /// `assess` deleted outright. This one crosses formats (for the advisory) and
    /// drops the membership ceiling to zero (for the warning), so blocking, warning
    /// and advisory are all present and their relative order is pinned.
    func testViolationsAreOrderedBlockingThenWarningThenAdvisory() throws {
        var policy = BuildGraphPolicy.baseline
        policy.maximumMembershipChanges = 0

        let legacy = try PbxprojBridge.decode(SampleProjects.storefrontLegacy)
        let hostile = try graph(SampleProjects.storefrontSupplyChainEdit)
        let assessment = PolicyEngine(policy: policy).assess(
            GraphDiffer.diff(baseline: legacy, proposed: hostile)
        )

        let severities = assessment.violations.map(\.severity)
        XCTAssertTrue(severities.contains(.blocking), "fixture must produce a blocking finding")
        XCTAssertTrue(severities.contains(.warning), "fixture must produce a warning")
        XCTAssertTrue(severities.contains(.advisory), "fixture must produce an advisory")
        XCTAssertEqual(
            severities, severities.sorted(by: >),
            "findings must run blocking → warning → advisory, got \(severities.map(\.label))"
        )
        XCTAssertEqual(severities.last, .advisory)
        XCTAssertEqual(severities.first, .blocking)
    }

    func testViolationOrderIsIndependentOfInputOrder() throws {
        let assessment = try assess(
            SampleProjects.storefrontBaseline, SampleProjects.storefrontSupplyChainEdit
        )
        XCTAssertFalse(assessment.violations.isEmpty)

        let reordered = """
        {
          "package-dependencies": [
            { "requirement": { "branch": "main", "kind": "branch" },
              "identity": "checkout-kit",
              "url": "https://github.com/example-0rg/checkout-kit.git" }
          ],
          "files": [
            { "group": "StorefrontTests",
              "children": [ { "target-membership": ["StorefrontTests"],
                              "path": "CartModelTests.swift" } ] },
            { "group": "Storefront",
              "children": [
                { "group": "Checkout",
                  "children": [ { "target-membership": ["StorefrontTests", "Storefront"],
                                  "path": "CartModel.swift" } ] },
                { "path": "../../shared-tools/Telemetry.swift", "target-membership": ["Storefront"] },
                { "path": "StorefrontApp.swift", "target-membership": ["Storefront"] }
              ] }
          ],
          "targets": [
            { "build-settings": {}, "name": "StorefrontTests",
              "product-type": "com.apple.product-type.bundle.unit-test" },
            { "package-product-dependencies": ["CheckoutKit"],
              "name": "Storefront",
              "build-settings": { "DEVELOPMENT_TEAM": "AB12CD34EF",
                                  "CODE_SIGN_IDENTITY": "Apple Development" },
              "product-type": "com.apple.product-type.application" }
          ],
          "build-settings": {
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS[config=Debug]": "DEBUG",
            "ENABLE_USER_SCRIPT_SANDBOXING": true,
            "SWIFT_VERSION": "6.0",
            "IPHONEOS_DEPLOYMENT_TARGET": "15.0"
          },
          "name": "Storefront",
          "schema-version": 1
        }
        """
        XCTAssertNotEqual(reordered, SampleProjects.storefrontSupplyChainEdit)

        let fromReordered = try assess(SampleProjects.storefrontBaseline, reordered)
        XCTAssertEqual(
            assessment.violations.map(\.id), fromReordered.violations.map(\.id),
            "finding order must be a function of the graph, not of the file's key order"
        )
    }

    func testPolicyRoundTripsThroughJSON() throws {
        let encoded = try BuildGraphPolicy.baseline.encoded()
        let decoded = try BuildGraphPolicy.decode(encoded)
        XCTAssertEqual(decoded, .baseline)
    }

    /// `Examples/buildgraph-policy.json` is the baseline serialised, and the README
    /// says so. This test opens the committed file and decodes it, so the claim is
    /// checked rather than asserted — an earlier version pinned the baseline's
    /// fields in Swift and never touched the file, which let the two drift apart.
    func testCommittedExamplePolicyIsExactlyTheBaseline() throws {
        let url = Self.repositoryRoot
            .appendingPathComponent("Examples")
            .appendingPathComponent("buildgraph-policy.json")
        let data = try Data(contentsOf: url)

        XCTAssertEqual(try BuildGraphPolicy.decode(data), .baseline)

        // Byte equality, not just value equality: the file must be regenerable with
        // `baseline.encoded()`, or "it is the baseline serialised" is still a
        // half-truth and the next edit reintroduces reordering noise.
        let regenerated = try BuildGraphPolicy.baseline.encoded()
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            String(decoding: regenerated, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Encoding must be a function of the value alone.
    ///
    /// `.sortedKeys` orders object keys but not array elements, and `Set` iteration
    /// is hash-seeded, so without explicit sorting a policy re-encoded in another
    /// process produces different bytes — reordering noise, in a tool whose thesis
    /// is that reordering noise hides real change.
    func testPolicyEncodingIsStableAcrossSetOrdering() throws {
        var shuffled = BuildGraphPolicy.baseline
        shuffled.frozenSettingNames = Set(BuildGraphPolicy.baseline.frozenSettingNames.shuffled())
        shuffled.frozenSettingPrefixes = Set(BuildGraphPolicy.baseline.frozenSettingPrefixes.shuffled())
        XCTAssertEqual(shuffled, .baseline)
        XCTAssertEqual(try shuffled.encoded(), try BuildGraphPolicy.baseline.encoded())
    }

    /// The README lists every rule id in a table. A rule the engine can emit but the
    /// table omits is a rule nobody can look up when CI blocks them — and a row in
    /// the table for a rule that no longer exists is worse.
    ///
    /// Both sides are read from reality: the documented set is parsed out of the
    /// committed `README.md`, and the observed set comes only from real assessments.
    /// An earlier version hardcoded both sides and asserted a subset, which stayed
    /// green with `PolicyEngine.assess` gutted to return nothing.
    func testReadmeRuleTableMatchesTheEnginesVocabularyExactly() throws {
        let readme = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("README.md"),
            encoding: .utf8
        )
        // Scoped to the "### Rules" section: the README has other tables whose first
        // column is also a backticked identifier, and a parser that swept the whole
        // file would compare the engine's rules against test names.
        var documented: Set<String> = []
        var insideRuleTable = false
        for line in readme.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("### Rules") {
                insideRuleTable = true
                continue
            }
            if insideRuleTable, line.hasPrefix("#") || line.hasPrefix("---") {
                break
            }
            guard insideRuleTable, line.hasPrefix("| `") else { continue }
            // Take every backticked token in the row's first cell, so a row that
            // documents two related rules (`target.creation` / `target.removal`)
            // contributes both rather than only the first.
            guard let firstCellEnd = line.dropFirst().firstIndex(of: "|") else { continue }
            let cell = line[line.startIndex..<firstCellEnd]
            for token in cell.split(separator: "`").enumerated() where token.offset % 2 == 1 {
                documented.insert(String(token.element).trimmingCharacters(in: .whitespaces))
            }
        }
        XCTAssertTrue(insideRuleTable, "README.md no longer has a '### Rules' section")
        XCTAssertFalse(documented.isEmpty, "could not parse the rule table out of README.md")

        let observed = try Self.everyRuleIDReachableThroughRealAssessments()
        XCTAssertEqual(
            observed, documented,
            """
            README rule table is out of sync.
            Only in the engine: \(observed.subtracting(documented).sorted())
            Only in the README: \(documented.subtracting(observed).sorted())
            """
        )
    }

    func testFrozenPrefixMatchingIsPrefixNotSubstring() {
        let policy = BuildGraphPolicy.baseline
        XCTAssertTrue(policy.isFrozen(settingName: "CODE_SIGN_IDENTITY"))
        XCTAssertTrue(policy.isFrozen(settingName: "CODE_SIGN_ENTITLEMENTS"))
        XCTAssertTrue(policy.isFrozen(settingName: "ENABLE_USER_SCRIPT_SANDBOXING"))
        XCTAssertFalse(policy.isFrozen(settingName: "MY_CODE_SIGN_HELPER"))
        XCTAssertFalse(policy.isFrozen(settingName: "SWIFT_VERSION"))
        // An empty prefix would match everything; it is ignored rather than honoured.
        var sloppy = BuildGraphPolicy.baseline
        sloppy.frozenSettingPrefixes = [""]
        XCTAssertFalse(sloppy.isFrozen(settingName: "SWIFT_VERSION"))
    }
}

final class RiskScorerTests: XCTestCase {

    private func diff(_ changes: [GraphChange], baselineMemberships: Int = 10) -> GraphDiff {
        GraphDiff(
            baselineOrigin: .xcproj(schemaVersion: 1),
            proposedOrigin: .xcproj(schemaVersion: 1),
            changes: changes,
            baselineMembershipCount: baselineMemberships
        )
    }

    func testEmptyDiffScoresZero() {
        XCTAssertEqual(RiskScorer.score(diff([])), 0)
        XCTAssertEqual(RiskScorer.band(0), "None")
    }

    func testScoreIsClampedAndNeverOverflows() {
        let many = Array(
            repeating: GraphChange.targetRemoved(name: "T", productType: "p"), count: 100_000
        )
        XCTAssertEqual(RiskScorer.score(diff(many)), 100)
        XCTAssertEqual(RiskScorer.band(100), "High")
    }

    func testSensitiveSettingsOutweighOrdinaryOnes() {
        let ordinary = diff([
            .settingChanged(
                scope: .project, key: SettingKey(name: "SWIFT_VERSION"),
                from: .string("5.9"), to: .string("6.0")
            )
        ])
        let sensitive = diff([
            .settingChanged(
                scope: .project, key: SettingKey(name: "CODE_SIGN_IDENTITY"),
                from: .string("a"), to: .string("b")
            )
        ])
        XCTAssertGreaterThan(RiskScorer.score(sensitive), RiskScorer.score(ordinary))
        XCTAssertTrue(RiskScorer.isNoteworthy(
            .settingChanged(
                scope: .project, key: SettingKey(name: "CODE_SIGN_IDENTITY"),
                from: nil, to: .string("-")
            )
        ))
        XCTAssertFalse(RiskScorer.isNoteworthy(.membershipAdded(target: "T", path: "a.swift")))
    }

    func testAnEscapingMembershipScoresLikeASigningChangeNotLikeAFileAdd() {
        let inTree = diff([.membershipAdded(target: "T", path: "a.swift")])
        let escaping = diff([.membershipAdded(target: "T", path: "../a.swift")])
        XCTAssertGreaterThan(RiskScorer.score(escaping), RiskScorer.score(inTree))
        XCTAssertTrue(RiskScorer.isNoteworthy(.membershipAdded(target: "T", path: "../a.swift")))
    }

    func testDeploymentTargetIsTreatedAsSensitiveBySuffix() {
        XCTAssertTrue(RiskScorer.isSensitive(settingName: "IPHONEOS_DEPLOYMENT_TARGET"))
        XCTAssertTrue(RiskScorer.isSensitive(settingName: "WATCHOS_DEPLOYMENT_TARGET"))
        XCTAssertFalse(RiskScorer.isSensitive(settingName: "SWIFT_VERSION"))
    }

    func testBandBoundaries() {
        XCTAssertEqual(RiskScorer.band(0), "None")
        XCTAssertEqual(RiskScorer.band(1), "Low")
        XCTAssertEqual(RiskScorer.band(24), "Low")
        XCTAssertEqual(RiskScorer.band(25), "Elevated")
        XCTAssertEqual(RiskScorer.band(59), "Elevated")
        XCTAssertEqual(RiskScorer.band(60), "High")
        // Defensive: the band function must not trap on a value outside 0…100.
        XCTAssertEqual(RiskScorer.band(-1), "None")
        XCTAssertEqual(RiskScorer.band(Int.max), "High")
    }
}
