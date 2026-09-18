import Foundation

/// Reduces a graph to a single canonical form.
///
/// This is a separate phase from decoding on purpose. The gate's whole claim is
/// that it reports *semantic* change and not formatting churn, and that claim is
/// only checkable if canonicalisation is a function you can call twice and
/// compare — which is what `GraphCanonicalizerTests` does. Folding it into the
/// decoders would make it untestable in isolation and would mean the `pbxproj`
/// and `xcproj` paths could drift apart silently.
public enum GraphCanonicalizer {

    public static func canonicalize(_ graph: ProjectGraph) -> ProjectGraph {
        ProjectGraph(
            origin: graph.origin,
            name: graph.name,
            targets: graph.targets
                .map(canonicalize(_:))
                .sorted { $0.name < $1.name },
            projectSettings: graph.projectSettings.canonicalized(),
            packages: graph.packages
                .map(canonicalize(_:))
                .sorted { $0.identity < $1.identity }
        )
    }

    static func canonicalize(_ target: TargetNode) -> TargetNode {
        // `Set` then `sorted` rather than `sorted` then a linear dedupe, because a
        // membership list from a bad merge can contain the same path hundreds of
        // times and the quadratic version is a CI timeout waiting to happen.
        let normalizedPaths = Set(target.membership.map(PathNormalizer.normalize))
            .filter { !$0.isEmpty }
            .sorted()
        return TargetNode(
            name: target.name,
            productType: target.productType,
            membership: normalizedPaths,
            settings: target.settings.canonicalized(),
            packageProducts: Array(Set(target.packageProducts)).sorted()
        )
    }

    static func canonicalize(_ package: PackageDependency) -> PackageDependency {
        PackageDependency(
            identity: package.identity.lowercased(),
            // Trailing slashes and a `.git` suffix are the same repository. Leaving
            // them distinct would let a dependency be re-pointed at a look-alike URL
            // and diff as "unchanged plus one new package" instead of "re-pointed".
            url: normalizeRepositoryURL(package.url),
            requirement: package.requirement
        )
    }

    static func normalizeRepositoryURL(_ url: String) -> String {
        var trimmed = url.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix(".git") { trimmed.removeLast(4) }
        return trimmed
    }

    /// Whether canonicalisation is idempotent for this graph.
    ///
    /// Exposed rather than kept private because it is the property the README
    /// claims, and a claim a reader can execute is worth more than one they cannot.
    public static func isCanonical(_ graph: ProjectGraph) -> Bool {
        canonicalize(graph) == graph
    }
}
