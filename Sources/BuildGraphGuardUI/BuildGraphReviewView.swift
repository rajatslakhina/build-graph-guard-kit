#if canImport(SwiftUI)
import SwiftUI
import BuildGraphGuard

/// A review screen for one proposed build-graph change.
///
/// The view owns no fixtures. It is handed the scenarios it should show, which is
/// what lets the demo app supply its own compiled-in policy and sample files while
/// the library stays free of app-specific content.
public struct BuildGraphReviewView: View {

    private let scenarios: [ReviewScenario]
    /// Outcomes are computed once, at init, rather than inside `body`.
    ///
    /// `body` runs on every state change, and parsing both project files each time
    /// would make an O(file size) cost look like a rendering cost. Scenarios are
    /// immutable after init, so there is nothing to invalidate.
    private let outcomes: [String: ScenarioOutcome]
    @State private var selectedID: String?

    public init(scenarios: [ReviewScenario]) {
        self.scenarios = scenarios
        self.outcomes = Dictionary(
            scenarios.map { ($0.id, ScenarioOutcome(running: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        // Seeding from the array rather than defaulting to index 0 means an empty
        // array produces the empty state instead of an out-of-range read.
        _selectedID = State(initialValue: scenarios.first?.id)
    }

    private var selectedScenario: ReviewScenario? {
        guard let selectedID else { return scenarios.first }
        return scenarios.first { $0.id == selectedID } ?? scenarios.first
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let scenario = selectedScenario {
                    content(for: scenario)
                } else {
                    ContentUnavailableView(
                        "No scenarios",
                        systemImage: "tray",
                        description: Text("This build of the demo shipped without any sample project files.")
                    )
                }
            }
            .navigationTitle("Build Graph Guard")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

    @ViewBuilder
    private func content(for scenario: ReviewScenario) -> some View {
        // A scenario always has an entry, but the fallback keeps the view total
        // rather than force-unwrapping a dictionary lookup on the render path.
        let outcome = outcomes[scenario.id] ?? ScenarioOutcome(running: scenario)

        List {
            Section {
                scenarioPicker
            }

            Section {
                Text(scenario.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text(scenario.title)
            } footer: {
                Text("\(scenario.baseline.formatName) → \(scenario.proposed.formatName)")
                    .font(.caption2)
                    .monospaced()
            }

            switch outcome {
            case .failed(let reason):
                Section("Could not read the project file") {
                    Label(reason, systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            case .assessed(let assessment):
                verdictSection(assessment)
                findingsSection(assessment)
                changesSection(assessment)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    // MARK: - Scenario picker

    private var scenarioPicker: some View {
        Picker("Scenario", selection: Binding(
            get: { selectedScenario?.id ?? "" },
            set: { selectedID = $0 }
        )) {
            ForEach(scenarios) { scenario in
                Text(scenario.title).tag(scenario.id)
            }
        }
        .pickerStyle(.menu)
    }

    // MARK: - Verdict

    @ViewBuilder
    private func verdictSection(_ assessment: PolicyAssessment) -> some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: verdictSymbol(assessment.verdict))
                    .font(.system(size: 30))
                    .foregroundStyle(verdictColor(assessment.verdict))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(assessment.verdict.label)
                        .font(.headline)
                    Text(countsLine(assessment))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(assessment.riskScore)")
                        .font(.title2.weight(.semibold).monospacedDigit())
                    Text(RiskScorer.band(assessment.riskScore))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(assessment.verdict.label). \(countsLine(assessment)). Risk score \(assessment.riskScore) out of 100."
            )
        }
    }

    /// Counts every severity, advisories included.
    ///
    /// Omitting advisories here produced a screen that said "no findings" directly
    /// above a section headed "Policy findings" with an advisory row in it — on the
    /// migration scenario, which is the one where the advisory is the whole point.
    private func countsLine(_ assessment: PolicyAssessment) -> String {
        let changeCount = assessment.diff.changes.count
        let blockingCount = assessment.blockingViolations.count
        let warningCount = assessment.warnings.count
        let advisoryCount = assessment.advisories.count
        let changes = "\(changeCount) semantic change\(changeCount == 1 ? "" : "s")"

        var parts: [String] = []
        if blockingCount > 0 { parts.append("\(blockingCount) blocking") }
        if warningCount > 0 { parts.append("\(warningCount) warning\(warningCount == 1 ? "" : "s")") }
        if advisoryCount > 0 { parts.append("\(advisoryCount) advisory") }
        guard !parts.isEmpty else { return "\(changes), no findings" }
        return "\(changes), " + parts.joined(separator: ", ")
    }

    private func verdictSymbol(_ verdict: PolicyVerdict) -> String {
        switch verdict {
        case .blocked: return "hand.raised.fill"
        case .needsReview: return "exclamationmark.triangle.fill"
        case .clean: return "checkmark.seal.fill"
        }
    }

    private func verdictColor(_ verdict: PolicyVerdict) -> Color {
        switch verdict {
        case .blocked: return .red
        case .needsReview: return .orange
        case .clean: return .green
        }
    }

    private func severityColor(_ severity: ViolationSeverity) -> Color {
        switch severity {
        case .blocking: return .red
        case .warning: return .orange
        case .advisory: return .secondary
        }
    }

    // MARK: - Findings

    @ViewBuilder
    private func findingsSection(_ assessment: PolicyAssessment) -> some View {
        if assessment.violations.isEmpty {
            Section("Policy findings") {
                Label(
                    "Nothing frozen by the policy moved.",
                    systemImage: "checkmark.circle"
                )
                .foregroundStyle(.green)
            }
        } else {
            Section("Policy findings") {
                ForEach(assessment.violations) { violation in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(violation.severity.label.uppercased())
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(severityColor(violation.severity).opacity(0.15), in: Capsule())
                                .foregroundStyle(severityColor(violation.severity))
                            Text(violation.ruleID)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if let summary = violation.change?.summary {
                            Text(summary)
                                .font(.callout.weight(.medium))
                        }
                        Text(violation.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    // MARK: - Changes

    @ViewBuilder
    private func changesSection(_ assessment: PolicyAssessment) -> some View {
        if assessment.diff.isEmpty {
            Section("Semantic changes") {
                Label(
                    "No structural difference between the two files.",
                    systemImage: "equal.circle"
                )
                .foregroundStyle(.secondary)
            }
        } else {
            ForEach(assessment.diff.touchedScopes, id: \.self) { scope in
                Section(scope ?? "Project-wide") {
                    ForEach(assessment.diff.changes(forTarget: scope), id: \.self) { change in
                        Text(change.summary)
                            .font(.footnote.monospaced())
                            .foregroundStyle(
                                RiskScorer.isNoteworthy(change) ? Color.primary : Color.secondary
                            )
                    }
                }
            }
        }
    }
}

#Preview("Blocked") {
    BuildGraphReviewView(scenarios: ReviewScenario.samples)
}

#Preview("Empty") {
    BuildGraphReviewView(scenarios: [])
}
#endif
