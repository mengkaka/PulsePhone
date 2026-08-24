import Foundation
import XCTest
@testable import PulsePhoneRuntimeKernel
import PulsePhoneSharedDefinitions

final class ExecutorGenerationTests: XCTestCase {
    func testGenerationRetentionFixture() throws {
        let expected = try loadExpected("T-020/generation-retention-l3")
        var oldGeneration = try controller(
            connectionEpoch: 11,
            generation: 4,
            preparationAttemptID: "preparation.old"
        )
        _ = try oldGeneration.commitReady(
            callback: oldGeneration.preparationFenceToken()
        )
        let oldOperation = try oldGeneration.bindOperation(
            operationID: "operation.old",
            attemptID: "attempt.old"
        )
        _ = try oldGeneration.markSuspectDisconnect()
        _ = try oldGeneration.confirmDeviceDisconnected()
        _ = try oldGeneration.beginTermination()

        var newGeneration = try controller(
            connectionEpoch: 12,
            generation: 5,
            preparationAttemptID: "preparation.new"
        )
        let newReady = try newGeneration.commitReady(
            callback: newGeneration.preparationFenceToken()
        )
        guard case .stateCommitted(let newSnapshot) = newReady else {
            return XCTFail("expected new generation readiness")
        }

        let settled = oldGeneration.settleOperation(callback: oldOperation)
        guard case .operationSettled(let operationID, let oldSnapshot) = settled else {
            return XCTFail("expected old generation operation settlement")
        }
        XCTAssertEqual(operationID, "operation.old")
        XCTAssertTrue(oldSnapshot.boundOperationIDs.isEmpty)
        XCTAssertEqual(newGeneration.snapshot, newSnapshot)
        XCTAssertEqual(newGeneration.snapshot.state, .ready)
        XCTAssertEqual(
            newGeneration.snapshot.preparationAttemptID,
            "preparation.new"
        )
        XCTAssertEqual(
            expected["oldGenerationSettlementAllowed"]?.boolValue,
            true
        )
        XCTAssertEqual(
            expected["newGenerationMutationAllowed"]?.boolValue,
            false
        )

        _ = try oldGeneration.retire()
        XCTAssertEqual(oldGeneration.snapshot.state.rawValue, expected["oldTerminalState"]?.stringValue)
        XCTAssertThrowsError(try oldGeneration.beginTermination())
    }

    func testLateCallbackFenceFixture() throws {
        let expected = try loadExpected("T-020/late-callback-fence-l3")
        var generation = try controller(
            connectionEpoch: 21,
            generation: 8,
            preparationAttemptID: "preparation.current"
        )
        let stalePreparation = try FenceToken(
            runtimeEpoch: 7,
            connectionEpoch: 21,
            executorGeneration: 8,
            preparationAttemptID: "preparation.old"
        )
        guard case .staleIgnored(let preparing) = try generation.commitReady(
            callback: stalePreparation
        ) else {
            return XCTFail("expected stale preparation callback")
        }
        XCTAssertEqual(preparing.state, .preparing)

        _ = try generation.commitReady(
            callback: generation.preparationFenceToken()
        )
        let exactOperation = try generation.bindOperation(
            operationID: "operation.cleanup",
            attemptID: "attempt.current"
        )
        let staleOperation = try FenceToken(
            runtimeEpoch: 7,
            connectionEpoch: 21,
            executorGeneration: 8,
            operationID: "operation.cleanup",
            attemptID: "attempt.old"
        )
        guard case .staleIgnored(let stillBound) = generation.settleOperation(
            callback: staleOperation
        ) else {
            return XCTFail("expected stale operation callback")
        }
        XCTAssertEqual(stillBound.boundOperationIDs, ["operation.cleanup"])

        let handoff = try generation.beginCleanup(
            callback: exactOperation,
            startedAtNanoseconds: 100
        )
        let beforeDeadline = generation.evaluateCleanupTimeouts(
            at: handoff.deadlineNanoseconds - 1
        )
        XCTAssertFalse(beforeDeadline.fatalFailStopRequired)
        let timeout = generation.evaluateCleanupTimeouts(
            at: handoff.deadlineNanoseconds
        )
        XCTAssertTrue(timeout.fatalFailStopRequired)
        XCTAssertEqual(timeout.timedOutOperationIDs, ["operation.cleanup"])
        XCTAssertEqual(timeout.fencedOperationIDs, ["operation.cleanup"])
        XCTAssertEqual(timeout.snapshot.state, .retired)
        XCTAssertEqual(timeout.snapshot.failure, .cleanupTimeout)
        XCTAssertEqual(
            CleanupHandoff.timeoutNanoseconds,
            expected["cleanupTimeoutNanoseconds"]?.uintValue
        )
        XCTAssertEqual(
            expected["fatalFailStopRequired"]?.boolValue,
            timeout.fatalFailStopRequired
        )

        guard case .staleIgnored(let retired) = generation.settleOperation(
            callback: exactOperation
        ) else {
            return XCTFail("expected post-fence callback to be stale")
        }
        XCTAssertEqual(retired.state.rawValue, expected["terminalState"]?.stringValue)
        XCTAssertTrue(retired.boundOperationIDs.isEmpty)
    }

    func testCleanupAcknowledgementSettlesExactlyOnce() throws {
        var generation = try controller(
            connectionEpoch: 31,
            generation: 9,
            preparationAttemptID: "preparation.ack"
        )
        _ = try generation.commitReady(
            callback: generation.preparationFenceToken()
        )
        let operation = try generation.bindOperation(
            operationID: "operation.ack",
            attemptID: "attempt.ack"
        )
        _ = try generation.beginCleanup(
            callback: operation,
            startedAtNanoseconds: 1_000
        )
        guard case .operationSettled = try generation.acknowledgeCleanup(
            callback: operation
        ) else {
            return XCTFail("expected cleanup acknowledgement")
        }
        guard case .staleIgnored = try generation.acknowledgeCleanup(
            callback: operation
        ) else {
            return XCTFail("expected duplicate cleanup callback to be stale")
        }
        let timeout = generation.evaluateCleanupTimeouts(at: UInt64.max)
        XCTAssertFalse(timeout.fatalFailStopRequired)
    }

    func testStateMachineRejectsReuseAfterRetirement() throws {
        var generation = try controller(
            connectionEpoch: 41,
            generation: 10,
            preparationAttemptID: "preparation.retire"
        )
        _ = try generation.beginTermination()
        _ = try generation.retire()
        XCTAssertThrowsError(
            try generation.bindOperation(
                operationID: "operation.reuse",
                attemptID: "attempt.reuse"
            )
        ) { error in
            XCTAssertEqual(
                error as? ExecutorGenerationError,
                .invalidTransition
            )
        }
        guard case .staleIgnored = try generation.commitReady(
            callback: FenceToken(
                runtimeEpoch: 7,
                connectionEpoch: 41,
                executorGeneration: 10,
                preparationAttemptID: "preparation.retire"
            )
        ) else {
            return XCTFail("expected retired generation callback to be stale")
        }
    }

    private func controller(
        connectionEpoch: UInt64,
        generation: UInt64,
        preparationAttemptID: String
    ) throws -> ExecutorGenerationController {
        try ExecutorGenerationController(
            runtimeEpoch: 7,
            connectionEpoch: connectionEpoch,
            executorGeneration: generation,
            preparationAttemptID: preparationAttemptID
        )
    }

    private func loadExpected(_ requirement: String) throws -> RepositoryJSONObject {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: root.appendingPathComponent(
                "Fixtures/requirements/\(requirement)/expected.v1.json"
            )
        )
        return try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](data),
            maximumByteCount: 16 * 1_024
        ).root
    }
}

private extension RepositoryJSONValue {
    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var uintValue: UInt64? {
        guard let number = numberValue else { return nil }
        return try? number.requireUInt64()
    }
}
