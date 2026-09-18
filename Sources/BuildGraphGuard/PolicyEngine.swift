import Foundation

/// How serious a policy finding is.
public enum ViolationSeverity: Int, Comparable, Sendable, CaseIterable {
    /// Informational; never affects the verdict.
    case advisory = 0
    /// Merits a human read before merge.
    case warning = 1
    /// The change must not land as proposed.
    case blocking = 2

    public static func < (lhs: ViolationSeverity, rhs: ViolationSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .advisory: return "Advisory"
        case .warning: return "Warning"
        case .blocking: return "Blocking"
        }
    }
}

/// A single policy finding, traceable back to the rule that produced it and the
/// change that triggered it.
///
/// Both halves are required. A finding without a rule id cannot be suppressed or
/// argued with, and a finding without its change cannot be checked — either one
/// on its own produces a gate people learn to route around.
public struct PolicyViolation: Hashable, Sendable, Identifiable {
    public let ruleID: String
    public let severity: ViolationSeverity
    /// The change that triggered this finding, or `nil` for a finding about the
    /// review as a whole rather than about one edit.
    ///
    /// Optional rather than "attach it to the first change in the list", which is
    /// what an earlier draft did: the cross-format advisory has to survive a diff
    /// with *zero* changes, and that is precisely the successful-migration case
    /// the advisory exists to caveat.
    public let change: GraphChange?
    public let explanation: String

    public var id: String { "\(ruleID)|\(change?.summary ?? explanation)" }

    public init(
        ruleID: String,
        severity: ViolationSeverity,
        change: GraphChange?,
        explanation: String
    ) {
        self.ruleID = ruleID
        self.severity = severity
        self.change = change
        self.explanation = explanation
    }
}

/// The overall outcome of evaluating a diff against a policy.
public enum PolicyVerdict: Sendable, Equatable {
    case clean
    case needsReview
    case blocked

    public var label: String {
        switch self {
        case .clean: return "No policy findings"
        case .needsReview: return "Needs review"
        case .blocked: return "Blocked"
        }
    }

    /// Process exit code for a CI gate: non-zero only when the change must not land.
    public var exitCode: Int32 {
        self == .blocked ? 1 : 0
    }
}

/// The complete result of a review.
public struct PolicyAssessment: Sendable, Equatable {
    public let verdict: PolicyVerdict
    public let violations: [PolicyViolation]
    public let diff: GraphDiff
    /// 0…100. A heuristic ordering aid, deliberately not a gate input — see
    /// `RiskScorer` for why the verdict does not read this number.
    public let riskScore: Int

    public var blockingViolations: [PolicyViolation] {
        violations.filter { $0.severity == .blocking }
    }

    public var warnings: [PolicyViolation] {
        violations.filter { $0.severity == .warning }
    }

    public func violations(forTarget target: String?) -> [PolicyViolation] {
        violations.filter { $0.change?.targetName == target }
    }
}

/// Evaluates a semantic diff against a policy.
public struct PolicyEngine: Sendable {
    public let policy: BuildGraphPolicy

    public init(policy: BuildGraphPolicy = .baseline) {
        self.policy = policy
    }

    public func assess(_ diff: GraphDiff) -> PolicyAssessment {
        var violations: [PolicyViolation] = []
        var membershipEdits = 0

        for change in diff.changes {
            switch change {
            case .membershipAdded, .membershipRemoved:
                membershipEdits = SaturatingMath.add(membershipEdits, 1)
            default:
                break
            }
            violations.append(contentsOf: evaluate(change))
        }

        if membershipEdits > policy.maximumMembershipChanges {
            violations.append(
                PolicyViolation(
                    ruleID: "volume.membership",
                    severity: .warning,
                    change: nil,
                    explanation: """
                        \(membershipEdits) membership edits in one change \
                        (\(diff.membershipChurnPercentage)% of the project's \
                        \(diff.baselineMembershipCount) source memberships), above the \
                        ceiling of \(policy.maximumMembershipChanges). Large refactors \
                        are legitimate but should be announced, not inferred.
                        """
                )
            )
        }

        if diff.isCrossFormat {
            violations.append(
                PolicyViolation(
                    ruleID: "format.cross-format-comparison",
                    severity: .advisory,
                    change: nil,
                    explanation: """
                        Baseline is \(diff.baselineOrigin.displayName) and proposal is \
                        \(diff.proposedOrigin.displayName). Fields PbxprojBridge does not \
                        model (\(PbxprojBridge.BridgeCoverage.notModelled.joined(separator: ", "))) \
                        cannot be compared across formats.
                        """
                )
            )
        }

        // The differ deliberately reports a setting on two channels — the literal
        // key and the effective per-configuration value — because each catches
        // something the other misses. For a *finding*, that is pure redundancy
        // whenever both fired on the same rule, scope and setting: the effective
        // line says everything the literal line says and names the configuration
        // as well. Three rows for one edit is how a reviewer learns to scroll past
        // findings, so the literal one is dropped where the effective one covers it.
        //
        // Per-configuration findings are kept separate rather than merged: Debug
        // dropping to 15.0 and Release dropping to 14.0 are two different problems.
        let effectiveSubjects: Set<String> = Set(
            violations.compactMap { violation in
                guard case .effectiveSettingChanged(let scope, _, let name, _, _)? = violation.change
                else { return nil }
                return "\(violation.ruleID)|\(scope.displayName)|\(name)"
            }
        )
        violations.removeAll { violation in
            guard case .settingChanged(let scope, let key, _, _)? = violation.change else {
                return false
            }
            return effectiveSubjects.contains("\(violation.ruleID)|\(scope.displayName)|\(key.name)")
        }

        let ordered = violations.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if $0.ruleID != $1.ruleID { return $0.ruleID < $1.ruleID }
            return ($0.change?.summary ?? "") < ($1.change?.summary ?? "")
        }

        let verdict: PolicyVerdict
        if ordered.contains(where: { $0.severity == .blocking }) {
            verdict = .blocked
        } else if ordered.contains(where: { $0.severity == .warning }) {
            verdict = .needsReview
        } else {
            verdict = .clean
        }

        return PolicyAssessment(
            verdict: verdict,
            violations: ordered,
            diff: diff,
            riskScore: RiskScorer.score(diff)
        )
    }

    // MARK: - Per-change rules

    func evaluate(_ change: GraphChange) -> [PolicyViolation] {
        var found: [PolicyViolation] = []

        if let target = change.targetName, policy.frozenTargets.contains(target) {
            found.append(
                PolicyViolation(
                    ruleID: "target.frozen",
                    severity: .blocking,
                    change: change,
                    explanation: "Target '\(target)' is frozen by policy; no automated edits are permitted."
                )
            )
        }

        switch change {
        case .targetAdded(let name, _):
            if !policy.allowTargetCreation {
                found.append(
                    PolicyViolation(
                        ruleID: "target.creation",
                        severity: .blocking,
                        change: change,
                        explanation: "Policy forbids creating targets; '\(name)' is new."
                    )
                )
            }

        case .targetRemoved(let name, _):
            if !policy.allowTargetRemoval {
                found.append(
                    PolicyViolation(
                        ruleID: "target.removal",
                        severity: .blocking,
                        change: change,
                        explanation: """
                            Policy forbids removing targets; '\(name)' disappeared. A target \
                            that stops existing also stops being built, tested and signed, \
                            and nothing downstream reports its absence.
                            """
                    )
                )
            }

        case .productTypeChanged(let target, let from, let to):
            found.append(
                PolicyViolation(
                    ruleID: "target.product-type",
                    severity: .blocking,
                    change: change,
                    explanation: """
                        '\(target)' changed product type (\(from) → \(to)). Product type \
                        determines signing, packaging and entitlement handling; it is never \
                        an incidental edit.
                        """
                )
            )

        case .membershipAdded(let target, let path):
            if PathNormalizer.escapesProjectDirectory(path) {
                found.append(
                    PolicyViolation(
                        ruleID: "membership.escapes-project",
                        severity: .blocking,
                        change: change,
                        explanation: """
                            '\(target)' now compiles '\(path)', which resolves outside the \
                            project directory. Source that is not in the repository is not \
                            reviewed, not versioned, and not reproducible on another machine.
                            """
                    )
                )
            }

        case .settingChanged(let scope, let key, let from, let to):
            found.append(
                contentsOf: settingViolations(
                    change: change, scope: scope, name: key.name, from: from, to: to,
                    qualifier: key.isUnconditioned ? nil : key.canonicalText
                )
            )

        case .effectiveSettingChanged(let scope, let configuration, let name, let from, let to):
            found.append(
                contentsOf: settingViolations(
                    change: change, scope: scope, name: name, from: from, to: to,
                    qualifier: "configuration \(configuration)"
                )
            )

        case .packageRepointed(let identity, let from, let to):
            if policy.packagePins != .unrestricted {
                found.append(
                    PolicyViolation(
                        ruleID: "package.repointed",
                        severity: .blocking,
                        change: change,
                        explanation: """
                            Dependency '\(identity)' now resolves from a different repository \
                            (\(from) → \(to)). Re-pointing a dependency URL substitutes the code \
                            itself while every version number in the file stays the same.
                            """
                    )
                )
            }

        case .packageRequirementChanged(let identity, _, let to):
            found.append(
                contentsOf: pinViolations(change: change, identity: identity, requirement: to)
            )

        case .packageAdded(let identity, _, let requirement):
            found.append(
                contentsOf: pinViolations(change: change, identity: identity, requirement: requirement)
            )

        case .membershipRemoved, .packageProductLinked, .packageProductUnlinked, .packageRemoved:
            break
        }

        return found
    }

    func pinViolations(
        change: GraphChange,
        identity: String,
        requirement: PackageRequirement
    ) -> [PolicyViolation] {
        switch policy.packagePins {
        case .unrestricted:
            return []
        case .frozen:
            return [
                PolicyViolation(
                    ruleID: "package.pin-frozen",
                    severity: .blocking,
                    change: change,
                    explanation: """
                        Policy freezes dependency pins; '\(identity)' would move to \
                        \(requirement.displayText).
                        """
                )
            ]
        case .pinnedVersionsOnly:
            guard requirement.isFloating else { return [] }
            return [
                PolicyViolation(
                    ruleID: "package.floating-pin",
                    severity: .blocking,
                    change: change,
                    explanation: """
                        '\(identity)' would resolve from \(requirement.displayText). A branch \
                        pin means every clone and every CI run gets whatever that branch happens \
                        to be that day — the build is no longer reproducible from the commit.
                        """
                )
            ]
        }
    }

    func settingViolations(
        change: GraphChange,
        scope: GraphChange.SettingScope,
        name: String,
        from: SettingValue?,
        to: SettingValue?,
        qualifier: String?
    ) -> [PolicyViolation] {
        var found: [PolicyViolation] = []
        let where_ = qualifier.map { " (\($0))" } ?? ""

        if policy.isFrozen(settingName: name) {
            found.append(
                PolicyViolation(
                    ruleID: "setting.frozen",
                    severity: .blocking,
                    change: change,
                    explanation: """
                        '\(name)' is frozen by policy but changed on \(scope.displayName)\(where_): \
                        \(from?.displayText ?? "(unset)") → \(to?.displayText ?? "(unset)").
                        """
                )
            )
        }

        if let floorText = policy.deploymentFloors[name] {
            found.append(
                contentsOf: deploymentFloorViolations(
                    change: change, scope: scope, name: name,
                    floorText: floorText, to: to, where_: where_
                )
            )
        }

        return found
    }

    func deploymentFloorViolations(
        change: GraphChange,
        scope: GraphChange.SettingScope,
        name: String,
        floorText: String,
        to: SettingValue?,
        where_: String
    ) -> [PolicyViolation] {
        guard let floor = DottedVersion(floorText) else {
            // A policy file with an unparseable floor is a policy bug, and the gate
            // says so rather than silently skipping the rule it was asked to enforce.
            return [
                PolicyViolation(
                    ruleID: "policy.malformed-floor",
                    severity: .warning,
                    change: change,
                    explanation: "Policy declares floor '\(floorText)' for \(name), which is not a version."
                )
            ]
        }
        guard let to else {
            return [
                PolicyViolation(
                    ruleID: "setting.deployment-floor",
                    severity: .blocking,
                    change: change,
                    explanation: """
                        \(name) was removed from \(scope.displayName)\(where_); the policy floor \
                        of \(floor) can no longer be enforced from the project file.
                        """
                )
            ]
        }
        guard let proposed = DottedVersion(to.displayText) else {
            return [
                PolicyViolation(
                    ruleID: "setting.deployment-floor-unreadable",
                    severity: .warning,
                    change: change,
                    explanation: """
                        \(name) on \(scope.displayName)\(where_) became '\(to.displayText)', which \
                        is not a plain version, so it cannot be checked against the \(floor) floor.
                        """
                )
            ]
        }
        guard proposed < floor else { return [] }
        return [
            PolicyViolation(
                ruleID: "setting.deployment-floor",
                severity: .blocking,
                change: change,
                explanation: """
                    \(name) on \(scope.displayName)\(where_) dropped to \(proposed), below the \
                    policy floor of \(floor). Lowering a deployment target silently widens the \
                    API surface the compiler will accept and the device matrix QA must cover.
                    """
            )
        ]
    }
}
