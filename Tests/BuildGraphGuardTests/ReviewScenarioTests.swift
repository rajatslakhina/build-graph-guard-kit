import XCTest
@testable import BuildGraphGuard

/// The demo app renders exactly these scenarios. Asserting their outcomes here is
/// what keeps the demo honest: if a scenario stops producing the finding its title
/// advertises, CI fails rather than the app quietly rendering an empty list.
final class ReviewScenarioTests: XCTestCase {

    private func scenario(_ id: String) throws -> ReviewScenario {
        try XCTUnwrap(ReviewScenario.samples.first { $0.id == id }, "no scenario '\(id)'")
    }

    func testEveryShippedScenarioParsesAndAssesses() throws {
        XCTAssertFalse(ReviewScenario.samples.isEmpty)
        for sample in ReviewScenario.samples {
            XCTAssertNoThrow(try sample.assess(), "scenario '\(sample.id)' failed to assess")
            XCTAssertFalse(sample.title.isEmpty)
            XCTAssertFalse(sample.detail.isEmpty)
        }
    }

    func testScenarioIdentifiersAreUnique() {
        let ids = ReviewScenario.samples.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    /// The app's default state is the first scenario. It must show the gate doing
    /// its job, so a reader who opens the app and touches nothing sees findings.
    func testDefaultScenarioIsBlockedAndHasVisibleFindings() throws {
        let first = try XCTUnwrap(ReviewScenario.samples.first)
        XCTAssertEqual(first.id, "agent-edit")

        let assessment = try first.assess()
        XCTAssertEqual(assessment.verdict, .blocked)
        XCTAssertGreaterThanOrEqual(assessment.blockingViolations.count, 2)
        XCTAssertGreaterThan(assessment.riskScore, 0)
        XCTAssertFalse(assessment.diff.isEmpty)
        XCTAssertFalse(assessment.diff.touchedScopes.isEmpty)

        // Every violation must render with a rule and an explanation, or the UI has
        // a row with nothing in it.
        for violation in assessment.violations {
            XCTAssertFalse(violation.ruleID.isEmpty)
            XCTAssertFalse(violation.explanation.isEmpty)
            XCTAssertFalse(violation.id.isEmpty)
        }
    }

    func testSupplyChainScenarioIsBlocked() throws {
        let assessment = try scenario("supply-chain").assess()
        XCTAssertEqual(assessment.verdict, .blocked)
        XCTAssertGreaterThanOrEqual(assessment.riskScore, 60)
    }

    func testRoutineScenarioIsClean() throws {
        let assessment = try scenario("routine").assess()
        XCTAssertEqual(
            assessment.verdict, .clean,
            "unexpected findings: \(assessment.violations.map(\.ruleID))"
        )
    }

    func testMigrationScenarioIsCleanWithOneAdvisory() throws {
        let assessment = try scenario("migration").assess()
        XCTAssertTrue(assessment.diff.isEmpty)
        XCTAssertEqual(assessment.verdict, .clean)
        XCTAssertEqual(assessment.violations.map(\.severity), [.advisory])
    }

    /// Every change the UI lists renders through `summary`, and every scope header
    /// through `touchedScopes`. Empty strings there are blank rows on screen.
    func testEveryChangeRendersANonEmptySummary() throws {
        for sample in ReviewScenario.samples {
            let assessment = try sample.assess()
            for change in assessment.diff.changes {
                XCTAssertFalse(
                    change.summary.isEmpty,
                    "empty summary for a change in '\(sample.id)'"
                )
            }
            // Grouping must be total: every change belongs to exactly one section.
            let grouped = assessment.diff.touchedScopes
                .flatMap { assessment.diff.changes(forTarget: $0) }
            XCTAssertEqual(
                Set(grouped).count, Set(assessment.diff.changes).count,
                "some changes would not appear under any section header in '\(sample.id)'"
            )
        }
    }

    func testDecodingFailureIsSurfacedRatherThanRenderedAsNoChanges() {
        let broken = ReviewScenario(
            id: "broken",
            title: "Broken",
            detail: "A file that is not a project.",
            baseline: .xcproj("{ not json"),
            proposed: .xcproj(SampleProjects.storefrontBaseline)
        )
        XCTAssertThrowsError(try broken.assess())

        switch ScenarioOutcome(running: broken) {
        case .assessed:
            XCTFail("a malformed file must not read as a successful assessment")
        case .failed(let reason):
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testOutcomeCarriesTheAssessmentOnSuccess() throws {
        let outcome = ScenarioOutcome(running: try scenario("routine"))
        XCTAssertEqual(outcome.assessment?.verdict, .clean)
    }

    func testProjectSourceReportsItsFormatName() {
        XCTAssertEqual(ProjectSource.xcproj("{}").formatName, "project.xcproj")
        XCTAssertEqual(ProjectSource.pbxproj("{}").formatName, "project.pbxproj")
    }

    /// Every `GraphDecodingError` must produce a sentence a human can act on; a
    /// case added later without one would show up as an empty red row.
    func testEveryDecodingErrorExplainsItself() {
        let errors: [GraphDecodingError] = [
            .notAnObject,
            .missingField("x"),
            .unsupportedSchemaVersion(found: 2, supported: 1...1),
            .fileTreeTooDeep(limit: 64),
            .fileTreeTooLarge(limit: 10),
            .malformedNode(path: "p", reason: "r"),
            .malformedPlist(reason: "r")
        ]
        for error in errors {
            XCTAssertFalse(error.explanation.isEmpty)
            XCTAssertGreaterThan(error.explanation.count, 10)
        }
    }
}
