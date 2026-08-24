import PulsePhoneSharedDefinitions
import XCTest

@testable import PulsePhoneRuntimeState

final class PreparationAttemptTests: XCTestCase {
    func testPhaseDeadlineMatrixFixture() throws {
        let expected = try loadCoordinatorExpected(
            "T-020/phase-deadline-matrix-l3"
        )
        let durations = try XCTUnwrap(expectedObject(expected, "milliseconds"))
        for phase in PreparationDeadlinePhase.allCases {
            XCTAssertEqual(
                PreparationDeadlinePolicy.duration(for: phase).wholeMilliseconds,
                expectedUInt(durations, phase.rawValue),
                phase.rawValue
            )
        }
        XCTAssertEqual(
            PrepareObserver.observationTimeout.wholeMilliseconds,
            expectedUInt(expected, "observerMilliseconds")
        )

        let startedAt = MonotonicInstant(nanoseconds: 100)
        var attempt = try PreparationAttempt(
            identity: try identity(connectionEpoch: 1, attemptID: 1),
            startedAt: startedAt
        )
        let first = try attempt.beginDeadline(
            .assetAcquisition,
            at: startedAt
        )
        let reentered = try attempt.beginDeadline(
            .assetAcquisition,
            at: try startedAt.advanced(
                by: MonotonicDuration(nanoseconds: 5)
            )
        )
        XCTAssertEqual(first, reentered)
        XCTAssertEqual(expectedBool(expected, "progressResetsDeadline"), false)
        XCTAssertEqual(expectedBool(expected, "observerChangesAttemptDeadline"), false)
    }

    func testFullAttemptIdentityFencesLateCallbacks() throws {
        var attempt = try PreparationAttempt(
            identity: try identity(connectionEpoch: 4, attemptID: 10),
            startedAt: MonotonicInstant(nanoseconds: 0)
        )
        try attempt.setExecutorGeneration(8)
        let exact = try identity(
            connectionEpoch: 4,
            attemptID: 10,
            executorGeneration: 8
        )
        XCTAssertTrue(attempt.accepts(exact, requiresExecutorGeneration: true))
        XCTAssertFalse(
            attempt.accepts(
                try identity(
                    connectionEpoch: 3,
                    attemptID: 10,
                    executorGeneration: 8
                ),
                requiresExecutorGeneration: true
            )
        )
        XCTAssertFalse(
            attempt.accepts(
                try identity(
                    connectionEpoch: 4,
                    attemptID: 10,
                    executorGeneration: 9
                ),
                requiresExecutorGeneration: true
            )
        )
    }

    private func identity(
        connectionEpoch: UInt64,
        attemptID: Int,
        executorGeneration: UInt64? = nil
    ) throws -> PreparationAttemptIdentity {
        try PreparationAttemptIdentity(
            runtimeEpoch: 7,
            connectionEpoch: connectionEpoch,
            preparationGroupID: "prep.coredevice.v2",
            preparationAttemptID: coordinatorUUID(attemptID),
            executorGeneration: executorGeneration
        )
    }
}
