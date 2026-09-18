import Foundation

/// One side of a review: the raw text of a project file plus which format it is.
public enum ProjectSource: Hashable, Sendable {
    case xcproj(String)
    case pbxproj(String)

    public var formatName: String {
        switch self {
        case .xcproj: return "project.xcproj"
        case .pbxproj: return "project.pbxproj"
        }
    }

    public func decoded() throws -> ProjectGraph {
        switch self {
        case .xcproj(let json):
            guard let data = json.data(using: .utf8) else {
                throw GraphDecodingError.malformedNode(path: "<source>", reason: "not valid UTF-8")
            }
            return try XcprojDecoder.decode(data)
        case .pbxproj(let text):
            return try PbxprojBridge.decode(text)
        }
    }
}

/// A baseline/proposal pair plus the policy to judge it by.
///
/// The scenario carries *file text*, not pre-built graphs, so running one
/// exercises the real pipeline end to end — decode, canonicalise, diff, assess.
/// A demo that hands the UI a hand-built `GraphDiff` would look identical on
/// screen while proving nothing about the parsers, which is the failure mode this
/// type exists to avoid.
public struct ReviewScenario: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let baseline: ProjectSource
    public let proposed: ProjectSource
    public let policy: BuildGraphPolicy

    public init(
        id: String,
        title: String,
        detail: String,
        baseline: ProjectSource,
        proposed: ProjectSource,
        policy: BuildGraphPolicy = .baseline
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.baseline = baseline
        self.proposed = proposed
        self.policy = policy
    }

    /// Runs the full pipeline. Throws rather than returning an empty assessment on
    /// a bad file: "nothing changed" and "I could not read the file" must never
    /// render the same way in a gate.
    public func assess() throws -> PolicyAssessment {
        let before = try baseline.decoded()
        let after = try proposed.decoded()
        let diff = GraphDiffer.diff(baseline: before, proposed: after)
        return PolicyEngine(policy: policy).assess(diff)
    }
}

/// The outcome of running a scenario, with the failure case kept rather than
/// swallowed, so a UI can render it.
public enum ScenarioOutcome: Sendable {
    case assessed(PolicyAssessment)
    case failed(String)

    public init(running scenario: ReviewScenario) {
        do {
            self = .assessed(try scenario.assess())
        } catch let error as GraphDecodingError {
            self = .failed(error.explanation)
        } catch {
            self = .failed(String(describing: error))
        }
    }

    public var assessment: PolicyAssessment? {
        if case .assessed(let assessment) = self { return assessment }
        return nil
    }
}
