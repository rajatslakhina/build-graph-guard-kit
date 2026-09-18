import Foundation

/// A 0…100 heuristic for how much attention a diff deserves.
///
/// **This number is deliberately not an input to the verdict.** A score that can
/// block is a score people tune until it stops blocking, and a threshold in a
/// config file is a much softer thing to argue down than a named rule that says
/// "`CODE_SIGN_IDENTITY` changed." The score exists for one job: ordering a
/// review queue when forty pull requests all say "Needs review". `PolicyEngine`
/// reads it only to put it in the report.
///
/// Every operation here saturates. The weights are small and the inputs are
/// bounded in practice, but "in practice" is doing no work when the input is a
/// file an agent wrote — `Int.max` memberships is a file, not an impossibility.
public enum RiskScorer {

    /// Weight per change kind. Signing and pin changes are worth more than a file
    /// moving between targets because their blast radius is not local to the build.
    static func weight(of change: GraphChange) -> Int {
        switch change {
        case .targetRemoved: return 30
        case .productTypeChanged: return 30
        case .packageRepointed: return 30
        case .packageRequirementChanged: return 12
        case .packageAdded: return 12
        case .packageRemoved: return 10
        case .targetAdded: return 10
        case .packageProductLinked, .packageProductUnlinked: return 6
        case .membershipRemoved: return 3
        case .membershipAdded(_, let path):
            return PathNormalizer.escapesProjectDirectory(path) ? 30 : 2
        case .settingChanged(_, let key, _, _):
            return isSensitive(settingName: key.name) ? 25 : 4
        case .effectiveSettingChanged(_, _, let name, _, _):
            // The effective channel re-reports what the literal channel already
            // saw, so it scores lower to avoid double-counting one edit twice.
            return isSensitive(settingName: name) ? 12 : 2
        }
    }

    /// Setting names whose change is never incidental. Kept separate from
    /// `BuildGraphPolicy.baseline` on purpose: the policy decides what is *allowed*
    /// and is expected to be edited per repository, while this decides what is
    /// *interesting* and should stay stable so scores are comparable across repos.
    static func isSensitive(settingName: String) -> Bool {
        let sensitivePrefixes = [
            "CODE_SIGN", "PROVISIONING", "DEVELOPMENT_TEAM", "ENTITLEMENTS",
            "ENABLE_USER_SCRIPT_SANDBOXING", "ENABLE_HARDENED_RUNTIME",
            "ENABLE_APP_SANDBOX", "OTHER_LDFLAGS", "SWIFT_STRICT_CONCURRENCY"
        ]
        if settingName.hasSuffix("_DEPLOYMENT_TARGET") { return true }
        return sensitivePrefixes.contains { settingName.hasPrefix($0) }
    }

    /// Whether a change is one a reader should not skim past. Drives emphasis in
    /// the UI, and is public so that emphasis is a property of the model rather
    /// than a string match re-implemented in a view.
    public static func isNoteworthy(_ change: GraphChange) -> Bool {
        weight(of: change) >= 10
    }

    public static func score(_ diff: GraphDiff) -> Int {
        guard !diff.changes.isEmpty else { return 0 }
        var total = 0
        for change in diff.changes {
            total = SaturatingMath.add(total, weight(of: change))
        }
        return min(100, max(0, total))
    }

    /// A short label for the score, for UI that needs a word rather than a number.
    public static func band(_ score: Int) -> String {
        switch score {
        case ..<1: return "None"
        case ..<25: return "Low"
        case ..<60: return "Elevated"
        default: return "High"
        }
    }
}
