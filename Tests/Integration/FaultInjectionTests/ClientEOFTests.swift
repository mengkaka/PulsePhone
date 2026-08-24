import PulsePhoneRuntimeState
import XCTest

final class ClientEOFTests: XCTestCase {
    func testAcceptedWorkTerminalNoReplayFixture() throws {
        let fixture = try faultFixture(
            "T-007/accepted-work-terminal-no-replay-l3"
        )
        let input = try fixture.decodeInput(ClientEOFInput.self)
        let expected = try fixture.decodeExpected(ClientEOFExpected.self)
        var lifecycle = OperationLifecycle(
            requestID: try faultUUID(600),
            executionKind: .oneShot
        )
        try lifecycle.beginPlanning(actionID: faultUUID(601))
        try lifecycle.acceptRunning(
            inhibitorTokenID: "inhibitor.client-eof",
            bindings: try OperationRuntimeBindings(
                attemptID: "attempt.client-eof",
                executorGeneration: 3,
                leaseIDs: ["lease.device"]
            )
        )
        XCTAssertTrue(input.accepted)
        XCTAssertTrue(input.clientDisconnectBeforeTerminal)
        guard case .started = try lifecycle.beginCleaning(
            commitState: .committed,
            terminalCause: .ownerDisconnected
        ) else {
            return XCTFail("expected first cleanup owner")
        }
        let first = try lifecycle.completeCleanup(
            outcome: .succeeded,
            resultDelivery: .clientGone,
            cleanupDisposition: .fenced
        )
        guard case .committed(let terminal) = first else {
            return XCTFail("expected terminal commit")
        }
        XCTAssertEqual(terminal.resultDelivery.rawValue, expected.resultDelivery)
        XCTAssertEqual(terminal.terminalCause, .ownerDisconnected)
        XCTAssertEqual(terminal.releasedLeaseIDs, ["lease.device"])
        XCTAssertEqual(
            try lifecycle.completeCleanup(
                outcome: .failed,
                resultDelivery: .reliableEnqueued,
                cleanupDisposition: .acknowledged
            ),
            .alreadyTerminal(terminal)
        )
        XCTAssertEqual(expected.terminalCount, 1)
        XCTAssertFalse(expected.crossConnectionReplayAllowed)
        XCTAssertFalse(input.reconnectReplayRequested)
        XCTAssertTrue(expected.actionLogPreservesTerminal)
    }
}

private struct ClientEOFInput: Decodable {
    let accepted: Bool
    let clientDisconnectBeforeTerminal: Bool
    let reconnectReplayRequested: Bool
}

private struct ClientEOFExpected: Decodable {
    let actionLogPreservesTerminal: Bool
    let crossConnectionReplayAllowed: Bool
    let resultDelivery: String
    let terminalCount: Int
}
