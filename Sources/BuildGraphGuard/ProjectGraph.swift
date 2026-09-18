import Foundation

/// Which on-disk format a graph was recovered from.
///
/// The bridge exists so a `pbxproj` branch and an `xcproj` branch of the same
/// repository produce comparable graphs during a migration. The provenance is
/// kept because a diff whose two sides came from different formats needs a louder
/// caveat than one where both sides are the same format.
public enum GraphOrigin: Hashable, Sendable {
    /// Xcode 27.2's JSON project format.
    case xcproj(schemaVersion: Int)
    /// The legacy OpenStep-plist format, projected through `PbxprojBridge`.
    case pbxproj(objectVersion: Int)

    public var displayName: String {
        switch self {
        case .xcproj(let schema): return "project.xcproj (schema \(schema))"
        case .pbxproj(let objectVersion): return "project.pbxproj (objectVersion \(objectVersion))"
        }
    }

    public var isLegacy: Bool {
        if case .pbxproj = self { return true }
        return false
    }
}

/// How a remote Swift package dependency is pinned.
public enum PackageRequirement: Hashable, Sendable {
    case upToNextMajor(minimum: String)
    case upToNextMinor(minimum: String)
    case exact(String)
    case branch(String)
    case revision(String)

    public var displayText: String {
        switch self {
        case .upToNextMajor(let minimum): return "from \(minimum)"
        case .upToNextMinor(let minimum): return "up-to-next-minor from \(minimum)"
        case .exact(let version): return "exactly \(version)"
        case .branch(let name): return "branch \(name)"
        case .revision(let sha): return "revision \(sha)"
        }
    }

    /// Whether this pin resolves to a moving target.
    ///
    /// A branch pin means every clone and every CI run resolves whatever the
    /// branch happened to be that day. That is a supply-chain property, not a
    /// style preference, which is why the policy engine can refuse it outright.
    public var isFloating: Bool {
        switch self {
        case .branch: return true
        case .upToNextMajor, .upToNextMinor, .exact, .revision: return false
        }
    }
}

/// A remote Swift package dependency of the project.
public struct PackageDependency: Hashable, Sendable {
    public let identity: String
    public let url: String
    public let requirement: PackageRequirement

    public init(identity: String, url: String, requirement: PackageRequirement) {
        self.identity = identity
        self.url = url
        self.requirement = requirement
    }
}

/// One build target in the graph.
public struct TargetNode: Equatable, Sendable {
    public let name: String
    public let productType: String
    /// Source paths compiled into this target, canonically ordered and deduplicated.
    public let membership: [String]
    public let settings: SettingTable
    /// Names of package products linked by this target.
    public let packageProducts: [String]

    public init(
        name: String,
        productType: String,
        membership: [String] = [],
        settings: SettingTable = SettingTable(),
        packageProducts: [String] = []
    ) {
        self.name = name
        self.productType = productType
        self.membership = membership
        self.settings = settings
        self.packageProducts = packageProducts
    }
}

/// The parsed, format-independent build graph of an Xcode project.
public struct ProjectGraph: Equatable, Sendable {
    public let origin: GraphOrigin
    public let name: String
    public let targets: [TargetNode]
    /// Project-level build settings, inherited by every target.
    public let projectSettings: SettingTable
    public let packages: [PackageDependency]

    public init(
        origin: GraphOrigin,
        name: String,
        targets: [TargetNode] = [],
        projectSettings: SettingTable = SettingTable(),
        packages: [PackageDependency] = []
    ) {
        self.origin = origin
        self.name = name
        self.targets = targets
        self.projectSettings = projectSettings
        self.packages = packages
    }

    public func target(named name: String) -> TargetNode? {
        targets.first { $0.name == name }
    }

    /// Every configuration name the file mentions anywhere, plus the two Xcode
    /// always creates. Resolution has to run against a known set of configuration
    /// names; inferring them from the file alone would mean a setting that only
    /// appears in one branch of the diff never gets resolved on the other side.
    public var configurationNames: [String] {
        var names: Set<String> = ["Debug", "Release"]
        names.formUnion(projectSettings.mentionedConfigurations)
        for target in targets {
            names.formUnion(target.settings.mentionedConfigurations)
        }
        return names.sorted()
    }

    /// Total source-file memberships across all targets. Used by the policy
    /// engine's change-volume ceiling.
    public var totalMembershipCount: Int {
        targets.reduce(into: 0) { total, target in
            total = SaturatingMath.add(total, target.membership.count)
        }
    }
}
