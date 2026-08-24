import XCTest
@testable import PulsePhoneSharedDefinitions

final class StandardResultV1Tests: XCTestCase {
    private enum FixtureError: Error {
        case invalidExpectedError
    }
    private struct Value: Equatable, Sendable {
        let marker: Int
    }

    private struct Details: Equatable, Sendable {
        let marker: Int
    }

    private struct FixtureInput: Decodable {
        struct Case: Decodable {
            let error: Bool?
            let expected: String?
            let outcome: String
            let value: Int?
        }

        let cases: [Case]
    }

    private struct CountExpected: Decodable {
        let invalidCaseCount: Int?
        let validCaseCount: Int?
    }

    private var error: StandardErrorV1<Details> {
        StandardErrorV1(code: "registryValidatedLater", details: nil)
    }

    func testStructuralValidBootstrapCase() throws {
        let fixture = try fixture("T-016/standard-result-structural-valid-l1")
        XCTAssertEqual(fixture.manifest.level, "L1")
        XCTAssertEqual(fixture.manifest.caseClass, "positive")
        let cases = try fixture.decodeInput(FixtureInput.self).cases
        let results = try cases.map { item in
            try make(
                outcome: try XCTUnwrap(StandardOutcome(rawValue: item.outcome)),
                value: item.value.map { Value(marker: $0) },
                error: item.error == true ? error : nil
            )
        }
        XCTAssertEqual(
            results.count,
            try fixture.decodeExpected(CountExpected.self).validCaseCount,
            fixture.manifest.caseKey
        )
    }

    func testStructuralInvalidBootstrapCase() throws {
        let fixture = try fixture("T-016/standard-result-structural-invalid-l1")
        XCTAssertEqual(fixture.manifest.level, "L1")
        XCTAssertEqual(fixture.manifest.caseClass, "negative")
        let cases = try fixture.decodeInput(FixtureInput.self).cases
        XCTAssertEqual(
            cases.count,
            try fixture.decodeExpected(CountExpected.self).invalidCaseCount,
            fixture.manifest.caseKey
        )
        for item in cases {
            let outcome = try XCTUnwrap(StandardOutcome(rawValue: item.outcome))
            assertInvalid(
                expected: try expectedError(item.expected, outcome: outcome),
                outcome: outcome,
                value: item.value.map { Value(marker: $0) },
                error: item.error == true ? error : nil,
                caseKey: fixture.manifest.caseKey
            )
        }
    }

    func testDurationAndCommitStateTypedBoundaries() throws {
        XCTAssertNil(try make(outcome: .succeeded).durationMs)
        XCTAssertEqual(
            try make(outcome: .succeeded, durationMs: 0).durationMs,
            0
        )
        XCTAssertEqual(
            try make(outcome: .succeeded, durationMs: .max).durationMs,
            .max
        )

        for state in CommitState.allCases {
            XCTAssertEqual(
                try make(outcome: .succeeded, commitState: state).commitState,
                state
            )
        }
    }

    func testCodeSpecificMappingsAreDeferredToRegistryValidation() throws {
        let arbitrary = StandardErrorV1<Details>(
            code: "notPartialFailureOrOutcomeUnknown",
            details: nil
        )

        XCTAssertEqual(
            try make(outcome: .partial, error: arbitrary).error,
            arbitrary
        )
        XCTAssertEqual(
            try make(outcome: .outcomeUnknown, error: arbitrary).error,
            arbitrary
        )
    }

    private func make(
        outcome: StandardOutcome,
        commitState: CommitState? = nil,
        durationMs: UInt64? = nil,
        value: Value? = nil,
        error: StandardErrorV1<Details>? = nil
    ) throws -> StandardResultV1<Value, Details> {
        try StandardResultV1(
            outcome: outcome,
            commitState: commitState,
            durationMs: durationMs,
            value: value,
            error: error
        )
    }

    private func assertInvalid(
        expected: StandardResultValidationError,
        outcome: StandardOutcome,
        value: Value? = nil,
        error: StandardErrorV1<Details>? = nil,
        caseKey: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try make(outcome: outcome, value: value, error: error),
            caseKey,
            file: file,
            line: line
        ) { thrown in
            XCTAssertEqual(
                thrown as? StandardResultValidationError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func expectedError(
        _ value: String?,
        outcome: StandardOutcome
    ) throws -> StandardResultValidationError {
        switch value {
        case "errorForbidden":
            return .errorForbidden(outcome: outcome)
        case "errorRequired":
            return .errorRequired(outcome: outcome)
        case "valueForbidden":
            return .valueForbidden(outcome: outcome)
        case "valueRequired":
            return .valueRequired(outcome: outcome)
        default:
            XCTFail("fixture expected error is invalid")
            throw FixtureError.invalidExpectedError
        }
    }

    private func fixture(_ requirementID: String) throws -> FixtureCaseBundleV1 {
        try FixtureCaseLoaderV1.load(
            requirementID: requirementID,
            repositoryRoot: FixtureCaseLoaderV1.repositoryRoot(containing: #filePath)
        )
    }
}
