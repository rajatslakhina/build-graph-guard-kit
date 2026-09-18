import XCTest
@testable import BuildGraphGuard

final class PolicyEngineTests: XCTestCase {

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

    func testViolationsAreOrderedBySeverityThenDeterministically() throws {
        let assessment = try assess(
            SampleProjects.storefrontBaseline, SampleProjects.storefrontSupplyChainEdit
        )
        let severities = assessment.violations.map(\.severity)
        XCTAssertEqual(severities, severities.sorted(by: >), "severities must be non-increasing")

        // Running the same assessment twice must produce identical ordering; a
        // dictionary-order leak would show up here and nowhere else.
        let again = try assess(
            SampleProjects.storefrontBaseline, SampleProjects.storefrontSupplyChainEdit
        )
        XCTAssertEqual(assessment.violations.map(\.id), again.violations.map(\.id))
    }

    func testPolicyRoundTripsThroughJSON() throws {
        let encoded = try BuildGraphPolicy.baseline.encoded()
        let decoded = try BuildGraphPolicy.decode(encoded)
        XCTAssertEqual(decoded, .baseline)
    }

    /// `Examples/buildgraph-policy.json` is the baseline serialised, and the README
    /// says so. Pinning the baseline's contents here means changing it without
    /// updating that file fails CI rather than quietly making the README wrong.
    func testBaselinePolicyContentsArePinned() {
        let baseline = BuildGraphPolicy.baseline
        XCTAssertEqual(baseline.version, 1)
        XCTAssertEqual(
            baseline.frozenSettingNames,
            [
                "ENABLE_USER_SCRIPT_SANDBOXING", "ENABLE_HARDENED_RUNTIME",
                "ENABLE_APP_SANDBOX", "SWIFT_STRICT_CONCURRENCY", "OTHER_LDFLAGS"
            ]
        )
        XCTAssertEqual(
            baseline.frozenSettingPrefixes.sorted(),
            ["CODE_SIGN", "DEVELOPMENT_TEAM", "ENTITLEMENTS", "PROVISIONING_PROFILE"]
        )
        XCTAssertEqual(
            baseline.deploymentFloors,
            ["IPHONEOS_DEPLOYMENT_TARGET": "17.0", "MACOSX_DEPLOYMENT_TARGET": "14.0"]
        )
        XCTAssertTrue(baseline.frozenTargets.isEmpty)
        XCTAssertEqual(baseline.packagePins, .pinnedVersionsOnly)
        XCTAssertTrue(baseline.allowTargetCreation)
        XCTAssertFalse(baseline.allowTargetRemoval)
        XCTAssertEqual(baseline.maximumMembershipChanges, 40)
    }

    /// The README lists every rule id in a table. A rule the engine can emit but the
    /// table omits is a rule nobody can look up when CI blocks them.
    func testEveryRuleIDTheEngineCanEmitIsDocumented() throws {
        let documented: Set<String> = [
            "setting.frozen", "setting.deployment-floor", "setting.deployment-floor-unreadable",
            "policy.malformed-floor", "target.frozen", "target.creation", "target.removal",
            "target.product-type", "membership.escapes-project", "package.repointed",
            "package.floating-pin", "package.pin-frozen", "volume.membership",
            "format.cross-format-comparison"
        ]

        var observed: Set<String> = []
        for sample in ReviewScenario.samples {
            observed.formUnion(try sample.assess().violations.map(\.ruleID))
        }
        // Rules the sample scenarios do not reach, exercised directly above in this
        // file, are added here so the set is the engine's full vocabulary.
        observed.formUnion([
            "setting.deployment-floor-unreadable", "policy.malformed-floor", "target.frozen",
            "target.creation", "target.removal", "target.product-type", "package.pin-frozen",
            "volume.membership"
        ])

        XCTAssertTrue(
            observed.isSubset(of: documented),
            "undocumented rule ids: \(observed.subtracting(documented))"
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
