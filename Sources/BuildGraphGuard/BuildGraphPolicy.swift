import Foundation

/// How package pins may move.
public enum PackagePinPolicy: String, Codable, Sendable {
    /// Repository URLs and requirements are both frozen.
    case frozen
    /// Requirements may move, but never to a branch or a floating ref, and the
    /// repository URL may not change.
    case pinnedVersionsOnly = "pinned-versions-only"
    /// Anything goes. Present so a repository can opt out explicitly rather than
    /// by deleting the policy file, which would also silently disable every other rule.
    case unrestricted
}

/// The rules an automated writer must obey when it edits the build graph.
///
/// **Why the default is allow-with-a-frozen-list rather than deny-by-default.**
/// A deny-by-default policy for build settings sounds safer and is, in practice,
/// abandoned: an agent adding a source file legitimately touches membership and
/// often `SWIFT_VERSION` or a warning flag, so a deny-all policy fires on every
/// commit, and a gate that fires on every commit gets `--no-verify`'d within a
/// week. The design instead freezes the settings whose change is never routine —
/// signing, entitlements, sandboxing, deployment floor, dependency pins — and
/// leaves the rest to the diff, which a human still reads. Security that survives
/// contact with a sprint beats security that is theoretically tighter.
public struct BuildGraphPolicy: Codable, Equatable, Sendable {
    public var version: Int
    /// Exact setting names that may never change.
    public var frozenSettingNames: Set<String>
    /// Setting-name prefixes that may never change. Cheaper to maintain than an
    /// exhaustive name list against an SDK that adds keys every year.
    ///
    /// A `Set` rather than an `Array` so that two policies listing the same
    /// prefixes in different orders compare equal — order carries no meaning for
    /// prefix matching, and order-sensitive equality would make a round-tripped
    /// policy file unequal to the policy it came from.
    public var frozenSettingPrefixes: Set<String>
    /// Targets no automated writer may modify at all.
    public var frozenTargets: Set<String>
    /// Minimum acceptable value for deployment-target settings.
    public var deploymentFloors: [String: String]
    public var packagePins: PackagePinPolicy
    public var allowTargetCreation: Bool
    public var allowTargetRemoval: Bool
    /// Volume ceiling for membership edits in a single change. Exceeding it is a
    /// warning, not a block: a legitimate refactor can move a hundred files, but it
    /// should not arrive unannounced.
    public var maximumMembershipChanges: Int

    public init(
        version: Int = 1,
        frozenSettingNames: Set<String> = [],
        frozenSettingPrefixes: Set<String> = [],
        frozenTargets: Set<String> = [],
        deploymentFloors: [String: String] = [:],
        packagePins: PackagePinPolicy = .pinnedVersionsOnly,
        allowTargetCreation: Bool = true,
        allowTargetRemoval: Bool = false,
        maximumMembershipChanges: Int = 40
    ) {
        self.version = version
        self.frozenSettingNames = frozenSettingNames
        self.frozenSettingPrefixes = frozenSettingPrefixes
        self.frozenTargets = frozenTargets
        self.deploymentFloors = deploymentFloors
        self.packagePins = packagePins
        self.allowTargetCreation = allowTargetCreation
        self.allowTargetRemoval = allowTargetRemoval
        self.maximumMembershipChanges = maximumMembershipChanges
    }

    /// The policy that ships with the library: freeze the things whose change is
    /// never an incidental side effect of adding a file.
    ///
    /// `ENABLE_USER_SCRIPT_SANDBOXING` is on the list because turning it off is a
    /// one-word edit that re-enables arbitrary script execution during the build,
    /// and it reads, in a diff, exactly like a warning-flag tweak.
    public static let baseline = BuildGraphPolicy(
        version: 1,
        frozenSettingNames: [
            "ENABLE_USER_SCRIPT_SANDBOXING",
            "ENABLE_HARDENED_RUNTIME",
            "ENABLE_APP_SANDBOX",
            "SWIFT_STRICT_CONCURRENCY",
            "OTHER_LDFLAGS"
        ],
        frozenSettingPrefixes: [
            "CODE_SIGN",
            "PROVISIONING_PROFILE",
            "DEVELOPMENT_TEAM",
            "ENTITLEMENTS"
        ],
        frozenTargets: [],
        deploymentFloors: [
            "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
            "MACOSX_DEPLOYMENT_TARGET": "14.0"
        ],
        packagePins: .pinnedVersionsOnly,
        allowTargetCreation: true,
        allowTargetRemoval: false,
        maximumMembershipChanges: 40
    )

    /// Whether a setting name is frozen by this policy.
    public func isFrozen(settingName: String) -> Bool {
        if frozenSettingNames.contains(settingName) { return true }
        return frozenSettingPrefixes.contains { !$0.isEmpty && settingName.hasPrefix($0) }
    }

    public static func decode(_ data: Data) throws -> BuildGraphPolicy {
        try JSONDecoder().decode(BuildGraphPolicy.self, from: data)
    }

    /// Encodes to stable bytes.
    ///
    /// `.sortedKeys` orders object *keys*; it does nothing for the elements of an
    /// array, and `Set`'s own iteration order is seeded per process. So a policy
    /// encoded twice in two processes would differ, a committed policy file could
    /// never be checked against `baseline`, and the diff of a policy change would
    /// be full of reordering noise — in a tool whose entire thesis is that
    /// reordering noise hides real change. The custom `encode(to:)` below sorts
    /// every collection so the bytes are a function of the value alone.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

extension BuildGraphPolicy {

    private enum CodingKeys: String, CodingKey {
        case version
        case frozenSettingNames
        case frozenSettingPrefixes
        case frozenTargets
        case deploymentFloors
        case packagePins
        case allowTargetCreation
        case allowTargetRemoval
        case maximumMembershipChanges
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(frozenSettingNames.sorted(), forKey: .frozenSettingNames)
        try container.encode(frozenSettingPrefixes.sorted(), forKey: .frozenSettingPrefixes)
        try container.encode(frozenTargets.sorted(), forKey: .frozenTargets)
        try container.encode(deploymentFloors, forKey: .deploymentFloors)
        try container.encode(packagePins, forKey: .packagePins)
        try container.encode(allowTargetCreation, forKey: .allowTargetCreation)
        try container.encode(allowTargetRemoval, forKey: .allowTargetRemoval)
        try container.encode(maximumMembershipChanges, forKey: .maximumMembershipChanges)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            version: try container.decode(Int.self, forKey: .version),
            frozenSettingNames: Set(try container.decode([String].self, forKey: .frozenSettingNames)),
            frozenSettingPrefixes: Set(try container.decode([String].self, forKey: .frozenSettingPrefixes)),
            frozenTargets: Set(try container.decode([String].self, forKey: .frozenTargets)),
            deploymentFloors: try container.decode([String: String].self, forKey: .deploymentFloors),
            packagePins: try container.decode(PackagePinPolicy.self, forKey: .packagePins),
            allowTargetCreation: try container.decode(Bool.self, forKey: .allowTargetCreation),
            allowTargetRemoval: try container.decode(Bool.self, forKey: .allowTargetRemoval),
            maximumMembershipChanges: try container.decode(Int.self, forKey: .maximumMembershipChanges)
        )
    }
}
