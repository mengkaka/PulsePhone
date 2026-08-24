import PulsePhoneRuntimeState
import XCTest

final class PrepareObserverRaceTests: XCTestCase {
    func testTerminalRaceFenceFixture() throws {
        let fixture = try faultFixture("T-015/terminal-race-fence-l3")
        let input = try fixture.decodeInput(TerminalRaceInput.self)
        let expected = try fixture.decodeExpected(TerminalRaceExpected.self)
        XCTAssertEqual(input.raceInputs, [
            "observerDeadline", "sigint", "helperTerminal",
        ])

        var deadlineWinner = try observer(value: 700)
        let deadline = deadlineWinner.deadline
        XCTAssertNotNil(try deadlineWinner.checkDeadline(at: deadline))
        XCTAssertThrowsError(try deadlineWinner.finish(
            .released(.interrupted),
            at: deadline
        )) { error in
            XCTAssertEqual(error as? PrepareObserverError, .alreadyTerminal)
        }

        var signalWinner = try observer(value: 710)
        let signalTerminal = try signalWinner.finish(
            .released(.interrupted),
            at: signalWinner.startedAt
        )
        XCTAssertEqual(signalTerminal, .released(.interrupted))
        XCTAssertNil(try signalWinner.checkDeadline(at: signalWinner.deadline))
        XCTAssertThrowsError(try signalWinner.finish(
            .attempt(.ready),
            at: signalWinner.deadline
        )) { error in
            XCTAssertEqual(error as? PrepareObserverError, .alreadyTerminal)
        }

        XCTAssertTrue(expected.firstWins)
        XCTAssertTrue(expected.lateTerminalRejected)
        XCTAssertEqual(expected.terminalCountPerObserver, 1)
        XCTAssertTrue(expected.exitProjectionStable)
    }

    func testObserverReleaseAndAttemptDeadlineRemainIndependent() throws {
        let release = try faultFixture(
            "T-020/observer-reference-release-l3"
        ).decodeExpected(ObserverReleaseExpected.self)
        let timeout = try faultFixture(
            "T-020/observer-attempt-timeout-l3"
        ).decodeExpected(ObserverTimeoutExpected.self)
        var observer = try self.observer(value: 720)
        XCTAssertEqual(
            try observer.finish(.released(.clientGone), at: observer.startedAt),
            .released(.clientGone)
        )
        XCTAssertNil(try observer.checkDeadline(at: observer.deadline))
        XCTAssertFalse(release.acquisitionRolledBack)
        XCTAssertTrue(release.attemptContinuesAfterLastReference)
        XCTAssertFalse(release.automaticRetryAfterTerminal)
        XCTAssertEqual(timeout.observerMinutes, 20)
        XCTAssertEqual(timeout.attemptMinutes, 40)
        XCTAssertEqual(timeout.observerOutcome, "outcomeUnknown")
        XCTAssertTrue(timeout.runtimeMayContinue)
    }

    private func observer(value: Int) throws -> PrepareObserver {
        try PrepareObserver(
            identity: PrepareObserverIdentity(
                requestID: faultUUID(value),
                actionID: faultUUID(value + 1),
                observerID: faultUUID(value + 2),
                ownerClientInstanceID: faultUUID(value + 3)
            ),
            startedAt: faultInstant(1_000)
        )
    }
}

private struct TerminalRaceInput: Decodable {
    let raceInputs: [String]
}

private struct TerminalRaceExpected: Decodable {
    let exitProjectionStable: Bool
    let firstWins: Bool
    let lateTerminalRejected: Bool
    let terminalCountPerObserver: Int
}

private struct ObserverReleaseExpected: Decodable {
    let acquisitionRolledBack: Bool
    let attemptContinuesAfterLastReference: Bool
    let automaticRetryAfterTerminal: Bool
}

private struct ObserverTimeoutExpected: Decodable {
    let attemptMinutes: Int
    let observerMinutes: Int
    let observerOutcome: String
    let runtimeMayContinue: Bool
}
