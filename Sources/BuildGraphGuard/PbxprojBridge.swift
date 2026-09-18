import Foundation

/// Projects a legacy `project.pbxproj` into the same `ProjectGraph` the JSON
/// decoder produces, so a migration branch can be compared against `main`.
///
/// **Scope, stated plainly.** This is a *projection*, not a general-purpose
/// `pbxproj` reader. It recovers exactly the five things the policy engine
/// reasons about — target names, product types, compiled-source membership,
/// build settings, and remote package pins. It deliberately does not model
/// aggregate targets' dependency edges, copy-files or shell-script phases,
/// variant groups, or localised resource fan-out. A field the bridge does not
/// model is a field the gate cannot protect, so the omissions are listed rather
/// than hidden: see `BridgeCoverage`.
///
/// **The hoist is the load-bearing part.** `pbxproj` stores settings as N separate
/// `XCBuildConfiguration` objects, so a setting with the same value in Debug and
/// Release appears twice; `xcproj` stores it once, unconditioned. Without hoisting,
/// every single setting in the file would diff on the day of the migration and the
/// signal-to-noise ratio of the gate would be zero on precisely the change that
/// most needs review.
public enum PbxprojBridge {

    /// What this bridge does and does not recover, surfaced so a README claim can
    /// be checked against the code rather than taken on trust.
    public enum BridgeCoverage {
        public static let modelled = [
            "target names", "product types", "compiled-source membership",
            "build settings (per configuration, hoisted where uniform)",
            "remote Swift package pins"
        ]
        public static let notModelled = [
            "aggregate target dependency edges", "copy-files phases",
            "shell-script phases", "variant groups and localised resource fan-out",
            "per-file compiler flags"
        ]
    }

    /// - Parameter hoistUniformSettings: whether to collapse a setting that has the
    ///   same value in every configuration onto one unconditioned key. Always `true`
    ///   in production; the parameter exists so the test suite can run the *real*
    ///   bridge with hoisting off and assert that the migration diff really is noisy
    ///   without it. A test that rebuilds the un-hoisted table inline would prove
    ///   only that the test's own arithmetic works.
    public static func decode(
        _ text: String,
        hoistUniformSettings: Bool = true
    ) throws -> ProjectGraph {
        let root = try OpenStepPlist.parse(text)
        guard let fields = root.dictionaryValue else {
            throw GraphDecodingError.malformedPlist(reason: "root is not a dictionary")
        }
        guard let objects = fields["objects"]?.dictionaryValue else {
            throw GraphDecodingError.missingField("objects")
        }
        guard let rootObjectID = fields["rootObject"]?.stringValue else {
            throw GraphDecodingError.missingField("rootObject")
        }
        guard let project = objects[rootObjectID]?.dictionaryValue else {
            throw GraphDecodingError.malformedPlist(
                reason: "rootObject '\(rootObjectID)' is not present in 'objects'"
            )
        }
        let objectVersion = fields["objectVersion"]?.stringValue.flatMap(Int.init) ?? 0

        let pathIndex = filePathIndex(objects: objects, project: project)
        let projectSettings = settings(
            configurationListID: project["buildConfigurationList"]?.stringValue,
            objects: objects,
            hoistUniformSettings: hoistUniformSettings
        )
        let packages = packageDependencies(objects: objects, project: project)

        var targets: [TargetNode] = []
        for targetID in project["targets"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            guard let target = objects[targetID]?.dictionaryValue else { continue }
            // Only native targets carry compiled sources and product types.
            guard target["isa"]?.stringValue == "PBXNativeTarget" else { continue }
            guard let name = target["name"]?.stringValue else { continue }
            let productType = target["productType"]?.stringValue ?? "unknown"

            let membership = compiledSources(
                of: target, objects: objects, pathIndex: pathIndex
            )
            let targetSettings = settings(
                configurationListID: target["buildConfigurationList"]?.stringValue,
                objects: objects,
                hoistUniformSettings: hoistUniformSettings
            )
            let packageProducts = (target["packageProductDependencies"]?.arrayValue ?? [])
                .compactMap(\.stringValue)
                .compactMap { objects[$0]?.dictionaryValue?["productName"]?.stringValue }
                .sorted()

            targets.append(
                TargetNode(
                    name: name,
                    productType: productType,
                    membership: membership,
                    settings: targetSettings,
                    packageProducts: packageProducts
                )
            )
        }

        // `pbxproj` does not reliably record the project's name — it lives in the
        // enclosing `.xcodeproj` bundle's directory name, which the file cannot see.
        // The fallback is honest rather than guessed; `GraphDiffer` does not compare
        // names for exactly this reason.
        let name = project["name"]?.stringValue ?? "Project"

        return ProjectGraph(
            origin: .pbxproj(objectVersion: objectVersion),
            name: name,
            targets: targets.sorted { $0.name < $1.name },
            projectSettings: projectSettings,
            packages: packages
        )
    }

    // MARK: - File paths

    struct PathIndex {
        var pathsByID: [String: String] = [:]
    }

    /// Walks the group tree from `mainGroup`, accumulating each file reference's
    /// path. Iterative with a visited set, because a `pbxproj` that a bad merge or
    /// a bad agent produced can contain a cycle, and recursion on a cycle is a
    /// hang followed by a stack overflow rather than an error message.
    static func filePathIndex(
        objects: [String: PlistValue],
        project: [String: PlistValue]
    ) -> PathIndex {
        var index = PathIndex()
        guard let mainGroupID = project["mainGroup"]?.stringValue else { return index }

        struct Frame {
            let id: String
            let prefix: String
            let depth: Int
        }
        var stack = [Frame(id: mainGroupID, prefix: "", depth: 0)]
        var visited: Set<String> = []

        while let frame = stack.popLast() {
            guard frame.depth <= OpenStepPlist.maximumDepth else { continue }
            guard visited.insert(frame.id).inserted else { continue }
            guard let node = objects[frame.id]?.dictionaryValue else { continue }

            let sourceTree = node["sourceTree"]?.stringValue ?? "<group>"
            let ownPath = node["path"]?.stringValue ?? ""
            // A group anchored to SOURCE_ROOT restarts the path; one anchored to an
            // SDK or build directory is outside the project and is recorded with an
            // explicit marker so the policy engine can refuse it rather than treat
            // an SDK framework as a project-local file.
            let resolvedPrefix: String
            switch sourceTree {
            case "SOURCE_ROOT", "<absolute>":
                resolvedPrefix = PathNormalizer.normalize(ownPath)
            case "BUILT_PRODUCTS_DIR", "SDKROOT", "DEVELOPER_DIR":
                resolvedPrefix = PathNormalizer.join("$(\(sourceTree))", ownPath)
            default:
                resolvedPrefix = PathNormalizer.normalize(
                    PathNormalizer.join(frame.prefix, ownPath)
                )
            }

            if let children = node["children"]?.arrayValue {
                for child in children {
                    guard let childID = child.stringValue else { continue }
                    stack.append(
                        Frame(
                            id: childID,
                            prefix: resolvedPrefix,
                            depth: SaturatingMath.add(frame.depth, 1)
                        )
                    )
                }
            } else {
                index.pathsByID[frame.id] = resolvedPrefix
            }
        }
        return index
    }

    static func compiledSources(
        of target: [String: PlistValue],
        objects: [String: PlistValue],
        pathIndex: PathIndex
    ) -> [String] {
        var paths: Set<String> = []
        for phaseID in target["buildPhases"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            guard let phase = objects[phaseID]?.dictionaryValue,
                  phase["isa"]?.stringValue == "PBXSourcesBuildPhase" else { continue }
            for buildFileID in phase["files"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                guard let buildFile = objects[buildFileID]?.dictionaryValue,
                      let fileRefID = buildFile["fileRef"]?.stringValue,
                      let path = pathIndex.pathsByID[fileRefID],
                      !path.isEmpty else { continue }
                paths.insert(path)
            }
        }
        return paths.sorted()
    }

    // MARK: - Settings

    /// Reads an `XCConfigurationList` and folds its `XCBuildConfiguration` objects
    /// into one conditioned `SettingTable`, hoisting values that are identical in
    /// every configuration to an unconditioned key.
    static func settings(
        configurationListID: String?,
        objects: [String: PlistValue],
        hoistUniformSettings: Bool = true
    ) -> SettingTable {
        guard let configurationListID,
              let list = objects[configurationListID]?.dictionaryValue,
              let configurationIDs = list["buildConfigurations"]?.arrayValue?.compactMap(\.stringValue)
        else { return SettingTable() }

        var perConfiguration: [String: [String: SettingValue]] = [:]
        for configurationID in configurationIDs {
            guard let configuration = objects[configurationID]?.dictionaryValue,
                  let configurationName = configuration["name"]?.stringValue else { continue }
            let raw = configuration["buildSettings"]?.dictionaryValue ?? [:]
            var values: [String: SettingValue] = [:]
            for (key, value) in raw {
                guard let setting = settingValue(from: value) else { continue }
                values[key] = setting
            }
            perConfiguration[configurationName] = values
        }

        let configurationNames = perConfiguration.keys.sorted()
        guard !configurationNames.isEmpty else { return SettingTable() }

        var everySettingName: Set<String> = []
        for values in perConfiguration.values {
            everySettingName.formUnion(values.keys)
        }

        var table = SettingTable()
        for settingName in everySettingName.sorted() {
            let present = configurationNames.compactMap { perConfiguration[$0]?[settingName] }
            let isUniform = hoistUniformSettings
                && present.count == configurationNames.count
                && Set(present).count == 1
            if isUniform, let shared = present.first {
                table.set(shared, for: SettingKey(name: settingName))
            } else {
                for configurationName in configurationNames {
                    guard let value = perConfiguration[configurationName]?[settingName] else { continue }
                    table.set(
                        value,
                        for: SettingKey(
                            name: settingName,
                            conditions: [SettingCondition(dimension: "config", value: configurationName)]
                        )
                    )
                }
            }
        }
        return table.canonicalized()
    }

    static func settingValue(from value: PlistValue) -> SettingValue? {
        switch value {
        case .string(let text):
            return SettingValue.string(text).canonicalized
        case .array(let items):
            let strings = items.compactMap(\.stringValue)
            guard strings.count == items.count else { return nil }
            return .list(strings)
        case .dictionary:
            return nil
        }
    }

    // MARK: - Packages

    static func packageDependencies(
        objects: [String: PlistValue],
        project: [String: PlistValue]
    ) -> [PackageDependency] {
        var packages: [PackageDependency] = []
        for referenceID in project["packageReferences"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            guard let reference = objects[referenceID]?.dictionaryValue,
                  reference["isa"]?.stringValue == "XCRemoteSwiftPackageReference",
                  let url = reference["repositoryURL"]?.stringValue,
                  let requirement = reference["requirement"]?.dictionaryValue,
                  let parsed = self.requirement(from: requirement)
            else { continue }
            packages.append(
                PackageDependency(
                    identity: PathNormalizer.packageIdentity(fromURL: url),
                    url: url,
                    requirement: parsed
                )
            )
        }
        return packages.sorted { $0.identity < $1.identity }
    }

    static func requirement(from fields: [String: PlistValue]) -> PackageRequirement? {
        guard let kind = fields["kind"]?.stringValue else { return nil }
        let minimum = fields["minimumVersion"]?.stringValue ?? fields["version"]?.stringValue
        switch kind {
        case "upToNextMajorVersion":
            guard let minimum else { return nil }
            return .upToNextMajor(minimum: minimum)
        case "upToNextMinorVersion":
            guard let minimum else { return nil }
            return .upToNextMinor(minimum: minimum)
        case "exactVersion":
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
