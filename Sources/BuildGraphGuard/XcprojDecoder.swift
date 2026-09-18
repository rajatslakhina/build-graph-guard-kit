import Foundation

/// Why a project file could not be turned into a graph.
public enum GraphDecodingError: Error, Equatable, Sendable {
    case notAnObject
    case missingField(String)
    case unsupportedSchemaVersion(found: Int, supported: ClosedRange<Int>)
    case fileTreeTooDeep(limit: Int)
    case fileTreeTooLarge(limit: Int)
    case malformedNode(path: String, reason: String)
    case malformedPlist(reason: String)

    public var explanation: String {
        switch self {
        case .notAnObject:
            return "The project file's root is not a JSON object."
        case .missingField(let name):
            return "Required field '\(name)' is missing."
        case .unsupportedSchemaVersion(let found, let supported):
            return "schema-version \(found) is outside the supported range \(supported.lowerBound)…\(supported.upperBound)."
        case .fileTreeTooDeep(let limit):
            return "The file tree nests deeper than \(limit) levels."
        case .fileTreeTooLarge(let limit):
            return "The file tree has more than \(limit) nodes."
        case .malformedNode(let path, let reason):
            return "Node at '\(path)' is malformed: \(reason)"
        case .malformedPlist(let reason):
            return "The legacy project file could not be parsed: \(reason)"
        }
    }
}

/// Decodes Xcode 27.2's JSON `project.xcproj` into a `ProjectGraph`.
///
/// The shape below follows the structure Apple's `xcode-project-format` spec and
/// the 27.2 beta describe: a `schema-version`, a single `build-settings` block
/// whose keys carry their own `[config=…]` conditions, targets addressed by name
/// rather than by 24-character hex id, and a navigator-shaped `files` tree where
/// each leaf declares its own `target-membership`.
///
/// It is deliberately a *tolerant* reader and a *strict* validator: unknown fields
/// are ignored so a point release that adds a key does not brick the gate, but
/// anything that would change the meaning of a known field is an error rather
/// than a default.
public enum XcprojDecoder {

    /// Schema versions this decoder claims to understand. A file outside the range
    /// is refused rather than best-guessed — a guard layer that misreads a format
    /// it does not know is worse than one that admits it does not know it.
    public static let supportedSchemaVersions: ClosedRange<Int> = 1...1

    /// Ceilings on the navigator tree.
    ///
    /// The tree is walked with an explicit stack rather than recursion precisely
    /// so a pathological file cannot exhaust the call stack — a stack overflow is
    /// an uncatchable crash, and "the guard job crashed" reads to a reviewer like
    /// flaky infrastructure rather than like a rejected change.
    ///
    /// The limits are a parameter rather than a constant so the tests can drive
    /// them to small values. A ceiling that can only be exercised by materialising
    /// a 200,000-node fixture is a ceiling nobody tests, and an untested ceiling is
    /// indistinguishable from an absent one.
    public struct DecodingLimits: Equatable, Sendable {
        public var maximumTreeDepth: Int
        public var maximumTreeNodes: Int

        public init(maximumTreeDepth: Int = 64, maximumTreeNodes: Int = 200_000) {
            self.maximumTreeDepth = max(1, maximumTreeDepth)
            self.maximumTreeNodes = max(1, maximumTreeNodes)
        }

        public static let `default` = DecodingLimits()
    }

    public static func decode(
        _ data: Data,
        limits: DecodingLimits = .default
    ) throws -> ProjectGraph {
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        return try decode(root, limits: limits)
    }

    public static func decode(
        _ root: JSONValue,
        limits: DecodingLimits = .default
    ) throws -> ProjectGraph {
        guard let fields = root.objectValue else { throw GraphDecodingError.notAnObject }

        guard let schemaVersion = fields["schema-version"]?.intValue else {
            throw GraphDecodingError.missingField("schema-version")
        }
        guard supportedSchemaVersions.contains(schemaVersion) else {
            throw GraphDecodingError.unsupportedSchemaVersion(
                found: schemaVersion, supported: supportedSchemaVersions
            )
        }
        guard let name = fields["name"]?.stringValue, !name.isEmpty else {
            throw GraphDecodingError.missingField("name")
        }

        let projectSettings = settingTable(from: fields["build-settings"])
        let membershipIndex = try membership(from: fields["files"], limits: limits)
        let packages = try packageDependencies(from: fields["package-dependencies"])

        var targets: [TargetNode] = []
        if let rawTargets = fields["targets"]?.arrayValue {
            targets.reserveCapacity(rawTargets.count)
            for (index, rawTarget) in rawTargets.enumerated() {
                targets.append(
                    try target(from: rawTarget, index: index, membershipIndex: membershipIndex)
                )
            }
        }

        return ProjectGraph(
            origin: .xcproj(schemaVersion: schemaVersion),
            name: name,
            targets: targets,
            projectSettings: projectSettings,
            packages: packages
        )
    }

    // MARK: - Targets

    private static func target(
        from raw: JSONValue,
        index: Int,
        membershipIndex: [String: [String]]
    ) throws -> TargetNode {
        guard let fields = raw.objectValue else {
            throw GraphDecodingError.malformedNode(
                path: "targets[\(index)]", reason: "not an object"
            )
        }
        guard let name = fields["name"]?.stringValue, !name.isEmpty else {
            throw GraphDecodingError.malformedNode(
                path: "targets[\(index)]", reason: "missing 'name'"
            )
        }
        guard let productType = fields["product-type"]?.stringValue, !productType.isEmpty else {
            throw GraphDecodingError.malformedNode(
                path: "targets[\(index)] (\(name))", reason: "missing 'product-type'"
            )
        }

        var packageProducts: [String] = []
        if let raw = fields["package-product-dependencies"]?.arrayValue {
            packageProducts = raw.compactMap(\.stringValue).sorted()
        }

        return TargetNode(
            name: name,
            productType: productType,
            membership: membershipIndex[name] ?? [],
            settings: settingTable(from: fields["build-settings"]),
            packageProducts: packageProducts
        )
    }

    // MARK: - Settings

    static func settingTable(from raw: JSONValue?) -> SettingTable {
        guard let fields = raw?.objectValue else { return SettingTable() }
        var table = SettingTable()
        for (rawKey, rawValue) in fields {
            guard let value = rawValue.settingValue else { continue }
            table.set(value, for: SettingKey.parse(rawKey))
        }
        return table.canonicalized()
    }

    // MARK: - File tree

    /// Walks the navigator tree iteratively and inverts it into `target → [path]`.
    ///
    /// Inversion is the point. The file says "this file belongs to these targets";
    /// review needs "this target gained these files", and only one of those two is
    /// a sentence a human can check against intent.
    static func membership(
        from raw: JSONValue?,
        limits: DecodingLimits = .default
    ) throws -> [String: [String]] {
        guard let roots = raw?.arrayValue else { return [:] }

        struct Frame {
            let node: JSONValue
            let prefix: String
            let depth: Int
        }

        var index: [String: [String]] = [:]
        var stack: [Frame] = roots.reversed().map { Frame(node: $0, prefix: "", depth: 1) }
        var visited = 0

        while let frame = stack.popLast() {
            visited = SaturatingMath.add(visited, 1)
            guard visited <= limits.maximumTreeNodes else {
                throw GraphDecodingError.fileTreeTooLarge(limit: limits.maximumTreeNodes)
            }
            guard frame.depth <= limits.maximumTreeDepth else {
                throw GraphDecodingError.fileTreeTooDeep(limit: limits.maximumTreeDepth)
            }
            guard let fields = frame.node.objectValue else {
                throw GraphDecodingError.malformedNode(
                    path: frame.prefix.isEmpty ? "files" : frame.prefix,
                    reason: "not an object"
                )
            }

            if let group = fields["group"]?.stringValue {
                let childPrefix = PathNormalizer.join(frame.prefix, group)
                let children = fields["children"]?.arrayValue ?? []
                // Pushed in reverse so the stack pops them in declaration order,
                // which keeps error messages pointing at the first bad node.
                for child in children.reversed() {
                    stack.append(
                        Frame(node: child, prefix: childPrefix, depth: SaturatingMath.add(frame.depth, 1))
                    )
                }
                continue
            }

            guard let path = fields["path"]?.stringValue, !path.isEmpty else {
                throw GraphDecodingError.malformedNode(
                    path: frame.prefix.isEmpty ? "files" : frame.prefix,
                    reason: "node is neither a group (no 'group') nor a file (no 'path')"
                )
            }
            let fullPath = PathNormalizer.normalize(PathNormalizer.join(frame.prefix, path))
            let memberships = fields["target-membership"]?.arrayValue ?? []
            for membership in memberships {
                guard let targetName = membership.stringValue, !targetName.isEmpty else { continue }
                index[targetName, default: []].append(fullPath)
            }
        }

        // Deduplicate and order. A file listed twice for the same target is a real
        // thing an agent does when it re-registers an existing file; it must not
        // read as a membership change on the next run.
        for (targetName, paths) in index {
            index[targetName] = Array(Set(paths)).sorted()
        }
        return index
    }

    // MARK: - Packages

    static func packageDependencies(from raw: JSONValue?) throws -> [PackageDependency] {
        guard let items = raw?.arrayValue else { return [] }
        var packages: [PackageDependency] = []
        packages.reserveCapacity(items.count)

        for (index, item) in items.enumerated() {
            guard let fields = item.objectValue else {
                throw GraphDecodingError.malformedNode(
                    path: "package-dependencies[\(index)]", reason: "not an object"
                )
            }
            guard let url = fields["url"]?.stringValue, !url.isEmpty else {
                throw GraphDecodingError.malformedNode(
                    path: "package-dependencies[\(index)]", reason: "missing 'url'"
                )
            }
            let identity = fields["identity"]?.stringValue ?? PathNormalizer.packageIdentity(fromURL: url)
            guard let requirement = requirement(from: fields["requirement"]) else {
                throw GraphDecodingError.malformedNode(
                    path: "package-dependencies[\(index)] (\(identity))",
                    reason: "missing or unrecognised 'requirement'"
                )
            }
            packages.append(
                PackageDependency(identity: identity, url: url, requirement: requirement)
            )
        }
        return packages.sorted { $0.identity < $1.identity }
    }

    static func requirement(from raw: JSONValue?) -> PackageRequirement? {
        guard let fields = raw?.objectValue, let kind = fields["kind"]?.stringValue else {
            return nil
        }
        let minimum = fields["minimum-version"]?.stringValue ?? fields["version"]?.stringValue
        switch kind {
        case "upToNextMajorVersion", "up-to-next-major-version":
            guard let minimum else { return nil }
            return .upToNextMajor(minimum: minimum)
        case "upToNextMinorVersion", "up-to-next-minor-version":
            guard let minimum else { return nil }
            return .upToNextMinor(minimum: minimum)
        case "exactVersion", "exact-version":
            guard let minimum else { return nil }
            return .exact(minimum)
        case "branch":
            guard let branch = fields["branch"]?.stringValue else { return nil }
            return .branch(branch)
        case "revision":
            guard let revision = fields["revision"]?.stringValue else { return nil }
            return .revision(revision)
        default:
            return nil
        }
    }
}
