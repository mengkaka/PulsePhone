import PulsePhoneRuntimeKernel
import XCTest

final class CleanupFenceTests: XCTestCase {
    func testFatalEpisodeOneShotRecoveryFixture() throws {
        let fixture = try faultFixture(
            "T-014/fatal-episode-one-shot-recovery-l3"
        )
        let input = try fixture.decodeInput(FatalEpisodeInput.self)
        let expected = try fixture.decodeExpected(FatalEpisodeExpected.self)
        var episode = FatalRecoveryEpisode()
        var generation = try ExecutorGenerationController(
            runtimeEpoch: input.runtimeEpoch,
            connectionEpoch: input.connectionEpoch,
            executorGeneration: input.executorGeneration,
            preparationAttemptID: "preparation.fatal"
        )
        _ = try generation.commitReady(
            callback: generation.preparationFenceToken()
        )
        let operation = try generation.bindOperation(
            operationID: "operation.live",
            attemptID: "attempt.live"
        )

        for _ in 0..<input.signalsPerEpisode {
            if episode.observeFatalSignal() {
                _ = try generation.beginCleanup(
                    callback: operation,
                    startedAtNanoseconds: input.cleanupStartedAtNanoseconds
                )
            }
        }
        XCTAssertEqual(episode.ensureRunningCallCount, 1)
        XCTAssertEqual(generation.snapshot.pendingCleanupOperationIDs, [
            "operation.live",
        ])
        let timeout = generation.evaluateCleanupTimeouts(
            at: input.cleanupStartedAtNanoseconds
                + CleanupHandoff.timeoutNanoseconds
        )
        XCTAssertTrue(timeout.fatalFailStopRequired)
        episode.finishRecoveryEpisode()

        XCTAssertTrue(episode.observeFatalSignal())
        for _ in 1..<input.signalsPerEpisode {
            XCTAssertFalse(episode.observeFatalSignal())
        }
        XCTAssertEqual(
            episode.ensureRunningCallCount,
            expected.totalEnsureRunningCalls
        )
        XCTAssertEqual(expected.ensureRunningCallsPerEpisode, 1)
        XCTAssertEqual(expected.cleanupStartCount, 1)
        XCTAssertTrue(expected.duplicateSignalsCoalesced)
        XCTAssertTrue(expected.commandAdmissionDisabled)
    }
}

private struct FatalRecoveryEpisode {
    private(set) var ensureRunningCallCount = 0
    private var active = false

    mutating func observeFatalSignal() -> Bool {
        guard !active else { return false }
        active = true
        ensureRunningCallCount += 1
        return true
    }

    mutating func finishRecoveryEpisode() {
        active = false
    }
}

private struct FatalEpisodeInput: Decodable {
    let cleanupStartedAtNanoseconds: UInt64
    let connectionEpoch: UInt64
    let executorGeneration: UInt64
    let runtimeEpoch: UInt64
    let signalsPerEpisode: Int
}

private struct FatalEpisodeExpected: Decodable {
    let cleanupStartCount: Int
    let commandAdmissionDisabled: Bool
    let duplicateSignalsCoalesced: Bool
    let ensureRunningCallsPerEpisode: Int
    let totalEnsureRunningCalls: Int
}
