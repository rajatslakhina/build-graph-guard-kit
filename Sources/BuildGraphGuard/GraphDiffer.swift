import Foundation

/// One semantic change between two build graphs.
public enum GraphChange: Hashable, Sendable {
    case targetAdded(name: String, productType: String)
    case targetRemoved(name: String, productType: String)
    case productTypeChanged(target: String, from: String, to: String)
    case membershipAdded(target: String, path: String)
    case membershipRemoved(target: String, path: String)
    case packageProductLinked(target: String, product: String)
    case packageProductUnlinked(target: String, product: String)
    /// A literal key changed: the exact `NAME[config=…]` entry in the file.
    case settingChanged(scope: SettingScope, key: SettingKey, from: SettingValue?, to: SettingValue?)
    /// The *effective* value of a setting changed for one configuration.
    /// This is the channel that catches a Release-only override.
    case effectiveSettingChanged(
        scope: SettingScope,
        configuration: String,
        name: String,
        from: SettingValue?,
        to: SettingValue?
    )
    case packageAdded(identity: String, url: String, requirement: PackageRequirement)
    case packageRemoved(identity: String, url: String)
    case packageRepointed(identity: String, from: String, to: String)
    case packageRequirementChanged(identity: String, from: PackageRequirement, to: PackageRequirement)

    /// Which node of the graph the change happened on.
    public enum SettingScope: Hashable, Sendable {
        case project
        case target(String)

        public var displayName: String {
            switch self {
            case .project: return "project"
            case .target(let name): return name
            }
        }

        public var targetName: String? {
            if case .target(let name) = self { return name }
            return nil
        }
    }

    /// The target this change belongs to, if any. Drives the UI's grouping.
    public var targetName: String? {
        switch self {
        case .targetAdded(let name, _), .targetRemoved(let name, _):
            return name
        case .productTypeChanged(let target, _, _),
             .membershipAdded(let target, _),
             .membershipRemoved(let target, _),
             .packageProductLinked(let target, _),
             .packageProductUnlinked(let target, _):
            return target
        case .settingChanged(let scope, _, _, _), .effectiveSettingChanged(let scope, _, _, _, _):
            return scope.targetName
        case .packageAdded, .packageRemoved, .packageRepointed, .packageRequirementChanged:
            return nil
        }
    }

    /// The setting name involved, if the change is about a setting.
    public var settingName: String? {
        switch self {
        case .settingChanged(_, let key, _, _): return key.name
        case .effectiveSettingChanged(_, _, let name, _, _): return name
        default: return nil
        }
    }

    public var summary: String {
        switch self {
        case .targetAdded(let name, let productType):
            return "Target added: \(name) (\(shortProductType(productType)))"
        case .targetRemoved(let name, let productType):
            return "Target removed: \(name) (\(shortProductType(productType)))"
        case .productTypeChanged(let target, let from, let to):
            return "\(target): product type \(shortProductType(from)) → \(shortProductType(to))"
        case .membershipAdded(let target, let path):
            return "\(target): compiles \(path)"
        case .membershipRemoved(let target, let path):
            return "\(target): no longer compiles \(path)"
        case .packageProductLinked(let target, let product):
            return "\(target): links package product \(product)"
        case .packageProductUnlinked(let target, let product):
            return "\(target): unlinks package product \(product)"
        case .settingChanged(let scope, let key, let from, let to):
            return "\(scope.displayName): \(key.canonicalText) \(render(from)) → \(render(to))"
        case .effectiveSettingChanged(let scope, let configuration, let name, let from, let to):
            return "\(scope.displayName) [\(configuration)]: \(name) effectively \(render(from)) → \(render(to))"
        case .packageAdded(let identity, _, let requirement):
            return "Package added: \(identity) (\(requirement.displayText))"
        case .packageRemoved(let identity, _):
            return "Package removed: \(identity)"
        case .packageRepointed(let identity, let from, let to):
            return "Package \(identity) re-pointed: \(from) → \(to)"
        case .packageRequirementChanged(let identity, let from, let to):
            return "Package \(identity) pin: \(from.displayText) → \(to.displayText)"
        }
    }

    private func render(_ value: SettingValue?) -> String {
        value.map { "'\($0.displayText)'" } ?? "(unset)"
    }

    private func shortProductType(_ raw: String) -> String {
        raw.hasPrefix("com.apple.product-type.")
            ? String(raw.dropFirst("com.apple.product-type.".count))
            : raw
    }
}

/// The complete semantic difference between a baseline and a proposed graph.
public struct GraphDiff: Equatable, Sendable {
    public let baselineOrigin: GraphOrigin
    public let proposedOrigin: GraphOrigin
    public let changes: [GraphChange]
    /// Total source memberships in the baseline, so churn can be expressed as a
    /// share rather than as a raw count. "Touches 3 of 4 files" and "touches 3 of
    /// 4,000" are the same number and different reviews.
    public let baselineMembershipCount: Int

    public var isEmpty: Bool { changes.isEmpty }

    /// Membership edits as a percentage of the baseline's total memberships, 0…100.
    public var membershipChurnPercentage: Int {
        let edits = changes.reduce(into: 0) { total, change in
            switch change {
            case .membershipAdded, .membershipRemoved:
                total = SaturatingMath.add(total, 1)
            default:
                break
            }
        }
        return SaturatingMath.percentage(edits, of: baselineMembershipCount)
    }

    /// True when the two sides came from different on-disk formats, meaning some
    /// of the diff may be projection artefacts of the bridge rather than real edits.
    /// Surfaced so the UI can say so instead of implying a precision it lacks.
    public var isCrossFormat: Bool {
        baselineOrigin.isLegacy != proposedOrigin.isLegacy
    }

    public func changes(forTarget target: String?) -> [GraphChange] {
        changes.filter { $0.targetName == target }
    }

    /// Distinct target names touched, in stable order, plus `nil` for project-wide
    /// changes when there are any.
    public var touchedScopes: [String?] {
        var seen: Set<String> = []
        var ordered: [String?] = []
        var hasProjectScope = false
        for change in changes {
            guard let target = change.targetName else {
                hasProjectScope = true
                continue
            }
            if seen.insert(target).inserted { ordered.append(target) }
        }
        if hasProjectScope { ordered.append(nil) }
        return ordered
    }
}

/// Computes the semantic difference between two build graphs.
///
/// **Why not a textual diff.** The JSON format is machine-written, so key order,
/// whitespace and boolean spelling all move for free. A `git diff` of
/// `project.xcproj` reports those as changes and stays silent about the one thing
/// that matters — that the *meaning* of the build graph moved. Every rule in
/// `PolicyEngine` is stated against this structure rather than against text,
/// which is why canonicalisation has to run first and why it runs on both sides.
public enum GraphDiffer {

    public static func diff(baseline: ProjectGraph, proposed: ProjectGraph) -> GraphDiff {
        let left = GraphCanonicalizer.canonicalize(baseline)
        let right = GraphCanonicalizer.canonicalize(proposed)

        var changes: [GraphChange] = []
        changes.append(contentsOf: targetChanges(left: left, right: right))
        changes.append(
            contentsOf: settingChanges(
                scope: .project,
                left: left.projectSettings,
                right: right.projectSettings,
                configurations: unionConfigurations(left, right)
            )
        )
        changes.append(contentsOf: packageChanges(left: left, right: right))

        return GraphDiff(
            baselineOrigin: baseline.origin,
            proposedOrigin: proposed.origin,
            changes: changes,
            baselineMembershipCount: left.totalMembershipCount
        )
    }

    static func unionConfigurations(_ left: ProjectGraph, _ right: ProjectGraph) -> [String] {
        Array(Set(left.configurationNames).union(right.configurationNames)).sorted()
    }

    // MARK: - Targets

    static func targetChanges(left: ProjectGraph, right: ProjectGraph) -> [GraphChange] {
        let configurations = unionConfigurations(left, right)
        let leftByName = Dictionary(left.targets.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let rightByName = Dictionary(right.targets.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let names = Set(leftByName.keys).union(rightByName.keys).sorted()

        var changes: [GraphChange] = []
        for name in names {
            switch (leftByName[name], rightByName[name]) {
            case (nil, .some(let added)):
                changes.append(.targetAdded(name: name, productType: added.productType))
                // A new target's entire membership is reported, so "an agent added a
                // target that compiles a file it should not" is visible in one read
                // rather than requiring the reviewer to open the new target.
                for path in added.membership {
                    changes.append(.membershipAdded(target: name, path: path))
                }
                for product in added.packageProducts {
                    changes.append(.packageProductLinked(target: name, product: product))
                }
            case (.some(let removed), nil):
                changes.append(.targetRemoved(name: name, productType: removed.productType))
                // Mirrors the added case above, and for a sharper reason. Without
                // these, deleting a target that compiles four thousand files produces
                // exactly one change — so the policy's membership-volume ceiling never
                // fires and `membershipChurnPercentage` reads 0%. Under a policy that
                // permits target removal, the largest possible edit to a build graph
                // would sail through as the quietest.
                for path in removed.membership {
                    changes.append(.membershipRemoved(target: name, path: path))
                }
                for product in removed.packageProducts {
                    changes.append(.packageProductUnlinked(target: name, product: product))
                }
            case (.some(let before), .some(let after)):
                changes.append(
                    contentsOf: modificationChanges(
                        from: before, to: after, configurations: configurations
                    )
                )
            case (nil, nil):
                continue
            }
        }
        return changes
    }

    static func modificationChanges(
        from before: TargetNode,
        to after: TargetNode,
        configurations: [String]
    ) -> [GraphChange] {
        var changes: [GraphChange] = []
        let name = after.name

        if before.productType != after.productType {
            changes.append(
                .productTypeChanged(target: name, from: before.productType, to: after.productType)
            )
        }

        let beforePaths = Set(before.membership)
        let afterPaths = Set(after.membership)
        for path in afterPaths.subtracting(beforePaths).sorted() {
            changes.append(.membershipAdded(target: name, path: path))
        }
        for path in beforePaths.subtracting(afterPaths).sorted() {
            changes.append(.membershipRemoved(target: name, path: path))
        }

        let beforeProducts = Set(before.packageProducts)
        let afterProducts = Set(after.packageProducts)
        for product in afterProducts.subtracting(beforeProducts).sorted() {
            changes.append(.packageProductLinked(target: name, product: product))
        }
        for product in beforeProducts.subtracting(afterProducts).sorted() {
            changes.append(.packageProductUnlinked(target: name, product: product))
        }

        changes.append(
            contentsOf: settingChanges(
                scope: .target(name),
                left: before.settings,
                right: after.settings,
                configurations: configurations
            )
        )
        return changes
    }

    // MARK: - Settings

    static func settingChanges(
        scope: GraphChange.SettingScope,
        left: SettingTable,
        right: SettingTable,
        configurations: [String]
    ) -> [GraphChange] {
        var changes: [GraphChange] = []

        // Channel 1: literal keys. Catches "a new conditioned key appeared".
        let keys = Set(left.entries.keys).union(right.entries.keys).sorted()
        for key in keys {
            let before = left[key]
            let after = right[key]
            guard before != after else { continue }
            changes.append(.settingChanged(scope: scope, key: key, from: before, to: after))
        }

        // Channel 2: effective values per configuration. Catches "the value a build
        // actually sees moved", including when no literal key changed on the side a
        // reviewer happened to look at.
        for configuration in configurations {
            let before = left.resolved(for: configuration)
            let after = right.resolved(for: configuration)
            let names = Set(before.keys).union(after.keys).sorted()
            for name in names {
                let from = before[name]
                let to = after[name]
                guard from != to else { continue }
                changes.append(
                    .effectiveSettingChanged(
                        scope: scope, configuration: configuration, name: name, from: from, to: to
                    )
                )
            }
        }
        return changes
    }

    // MARK: - Packages

    static func packageChanges(left: ProjectGraph, right: ProjectGraph) -> [GraphChange] {
        let leftByIdentity = Dictionary(left.packages.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        let rightByIdentity = Dictionary(right.packages.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        let identities = Set(leftByIdentity.keys).union(rightByIdentity.keys).sorted()

        var changes: [GraphChange] = []
        for identity in identities {
            switch (leftByIdentity[identity], rightByIdentity[identity]) {
            case (nil, .some(let added)):
                changes.append(
                    .packageAdded(identity: identity, url: added.url, requirement: added.requirement)
                )
            case (.some(let removed), nil):
                changes.append(.packageRemoved(identity: identity, url: removed.url))
            case (.some(let before), .some(let after)):
                if before.url != after.url {
                    changes.append(
                        .packageRepointed(identity: identity, from: before.url, to: after.url)
                    )
                }
                if before.requirement != after.requirement {
                    changes.append(
                        .packageRequirementChanged(
                            identity: identity, from: before.requirement, to: after.requirement
                        )
                    )
                }
            case (nil, nil):
                continue
            }
        }
        return changes
    }
}
