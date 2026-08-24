import PulsePhoneRuntimeKernel
import XCTest

final class HelperCrashTests: XCTestCase {
    func testRuntimeFatalIsolationFixture() throws {
        let fixture = try faultFixture("T-007/runtime-fatal-isolation-l3")
        let input = try fixture.decodeInput(RuntimeFatalInput.self)
        let expected = try fixture.decodeExpected(RuntimeFatalExpected.self)
        var failed = try controller(
            input: input,
            generation: input.failedExecutorGeneration,
            preparationID: "preparation.failed"
        )
        _ = try failed.commitReady(callback: failed.preparationFenceToken())
        let operation = try failed.bindOperation(
            operationID: "operation.failed",
            attemptID: "attempt.failed"
        )
        let cleanup = try failed.beginCleanup(
            callback: operation,
            startedAtNanoseconds: input.cleanupStartedAtNanoseconds
        )

        var healthy = try controller(
            input: input,
            generation: input.healthyExecutorGeneration,
            preparationID: "preparation.healthy"
        )
        _ = try healthy.commitReady(callback: healthy.preparationFenceToken())
        let healthyBefore = healthy.snapshot

        XCTAssertFalse(failed.evaluateCleanupTimeouts(
            at: cleanup.deadlineNanoseconds - 1
        ).fatalFailStopRequired)
        let fatal = failed.evaluateCleanupTimeouts(
            at: cleanup.deadlineNanoseconds
        )
        XCTAssertTrue(fatal.fatalFailStopRequired)
        XCTAssertEqual(fatal.timedOutOperationIDs, ["operation.failed"])
        XCTAssertEqual(fatal.fencedOperationIDs, ["operation.failed"])
        XCTAssertEqual(fatal.snapshot.state.rawValue, expected.failedState)
        XCTAssertEqual(fatal.snapshot.failure?.rawValue, expected.failure)
        XCTAssertEqual(healthy.snapshot, healthyBefore)
        XCTAssertEqual(healthy.snapshot.state.rawValue, expected.healthyState)
        guard case .staleIgnored = failed.settleOperation(
            callback: operation
        ) else {
            return XCTFail("expected post-fatal callback fence")
        }
        XCTAssertTrue(expected.lateCallbackIgnored)
        XCTAssertTrue(expected.otherRuntimeUnaffected)
    }

    private func controller(
        input: RuntimeFatalInput,
        generation: UInt64,
        preparationID: String
    ) throws -> ExecutorGenerationController {
        try ExecutorGenerationController(
            runtimeEpoch: input.runtimeEpoch,
            connectionEpoch: input.connectionEpoch,
            executorGeneration: generation,
            preparationAttemptID: preparationID
        )
    }
}

private struct RuntimeFatalInput: Decodable {
    let cleanupStartedAtNanoseconds: UInt64
    let connectionEpoch: UInt64
    let failedExecutorGeneration: UInt64
    let healthyExecutorGeneration: UInt64
    let runtimeEpoch: UInt64
}

private struct RuntimeFatalExpected: Decodable {
    let failedState: String
    let failure: String
    let healthyState: String
    let lateCallbackIgnored: Bool
    let otherRuntimeUnaffected: Bool
}
