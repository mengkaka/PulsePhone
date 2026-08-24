@testable import PulsePhoneBackendAdapters
import XCTest

final class DirectGenerationTests: XCTestCase {
    func testProcessSlotAdmitsOneGenerationAndRejectsConcurrentClaim() throws {
        var slot = try DirectProcessSlotController(runtimeEpoch: 7)
        _ = slot.observeAttach(connectionEpoch: 11)
        guard case .claimed(let command, _) = try slot.claim(
            operationKind: .lockdownCommand,
            requestID: "request.one",
            attemptID: "attempt.one",
            connectionEpoch: 11
        ) else {
            return XCTFail("expected claim")
        }
        XCTAssertEqual(command.action, .spawnHelper)
        XCTAssertEqual(
            slot.snapshot.activeGeneration?.exclusiveClaimIDs,
            ["executor.direct.process-slot"]
        )

        guard case .busy(let active, _) = try slot.claim(
            operationKind: .legacyMountedQuery,
            requestID: "request.two",
            attemptID: "attempt.two",
            connectionEpoch: 11
        ) else {
            return XCTFail("expected busy slot")
        }
        XCTAssertEqual(active.requestID, "request.one")
        XCTAssertEqual(slot.snapshot.nextExecutorGeneration, 2)
    }

    func testOneProcessRunsOneRequestThenCleansAndReaps() throws {
        var slot = try claimedSlot(connectionEpoch: 12)
        let identity = try XCTUnwrap(
            slot.snapshot.activeGeneration?.identity
        )
        guard case .advance(let hello, _) = try slot.receiveHello(
            identity: identity
        ) else {
            return XCTFail("expected HelloAccepted")
        }
        XCTAssertEqual(hello.action, .sendHelloAccepted)
        guard case .advance(let request, _) = try slot.receiveReady(
            identity: identity
        ) else {
            return XCTFail("expected Request")
        }
        XCTAssertEqual(request.action, .sendRequest)
        guard case .advance(let cleanup, _) = try slot.receiveResult(
            identity: identity,
            requestID: "request.initial"
        ) else {
            return XCTFail("expected cleanup")
        }
        XCTAssertEqual(cleanup.action, .beginCleanup)
        guard case .advance(let reap, _) = try slot.completeCleanup(
            identity: identity,
            requestID: "request.initial"
        ) else {
            return XCTFail("expected reap")
        }
        XCTAssertEqual(reap.action, .reapHelper)
        guard case .completed(let retired, let idle) = try slot.completeReap(
            identity: identity,
            requestID: "request.initial"
        ) else {
            return XCTFail("expected retired generation")
        }
        XCTAssertEqual(retired.state, .retired)
        XCTAssertNil(idle.activeGeneration)

        guard case .claimed(let replacement, _) = try slot.claim(
            operationKind: .lockdownCommand,
            requestID: "request.replacement",
            attemptID: "attempt.replacement",
            connectionEpoch: 12
        ) else {
            return XCTFail("expected new process")
        }
        XCTAssertEqual(replacement.identity.executorGeneration, 2)
        XCTAssertNotEqual(replacement.identity, identity)
    }

    func testPhaseClaimSetsAreExactAndShareOneSlot() {
        XCTAssertEqual(
            DirectGenerationOperationKind.lockdownCommand.exclusiveClaimIDs,
            ["executor.direct.process-slot"]
        )
        XCTAssertEqual(
            DirectGenerationOperationKind.legacyMountedQuery.exclusiveClaimIDs,
            [
                "executor.direct.process-slot",
                "service.mobile-image-mounter",
            ]
        )
        XCTAssertEqual(
            DirectGenerationOperationKind.legacyMountGeneration.exclusiveClaimIDs,
            [
                "device.developer-environment",
                "executor.direct.process-slot",
                "service.mobile-image-mounter",
            ]
        )
    }

    func testDetachFencesOldGenerationBeforeReconnect() throws {
        var slot = try claimedSlot(connectionEpoch: 13)
        let oldIdentity = try XCTUnwrap(
            slot.snapshot.activeGeneration?.identity
        )
        guard case .advance(let cleanup, _) = slot.observeDetach(
            connectionEpoch: 13
        ) else {
            return XCTFail("expected detach cleanup")
        }
        XCTAssertEqual(cleanup.action, .beginCleanup)
        guard case .staleIgnored = try slot.receiveHello(identity: oldIdentity) else {
            return XCTFail("expected late Hello to be stale")
        }
        _ = slot.observeAttach(connectionEpoch: 14)
        guard case .staleIgnored = try slot.receiveResult(
            identity: DirectGenerationIdentity(
                runtimeEpoch: 7,
                connectionEpoch: 13,
                executorGeneration: oldIdentity.executorGeneration + 1
            ),
            requestID: "request.initial"
        ) else {
            return XCTFail("expected stale callback")
        }
        guard case .busy(let draining, _) = try slot.claim(
            operationKind: .lockdownCommand,
            requestID: "request.reconnect",
            attemptID: "attempt.reconnect",
            connectionEpoch: 14
        ) else {
            return XCTFail("expected old process cleanup to hold slot")
        }
        XCTAssertEqual(draining.state, .cleaning)
        _ = try slot.completeCleanup(
            identity: oldIdentity,
            requestID: "request.initial"
        )
        _ = try slot.completeReap(
            identity: oldIdentity,
            requestID: "request.initial"
        )
        guard case .claimed(let replacement, _) = try slot.claim(
            operationKind: .lockdownCommand,
            requestID: "request.reconnect",
            attemptID: "attempt.reconnect",
            connectionEpoch: 14
        ) else {
            return XCTFail("expected new connection process")
        }
        XCTAssertEqual(replacement.identity.connectionEpoch, 14)
        XCTAssertNotEqual(replacement.identity, oldIdentity)
    }

    func testFatalShutdownClosesAdmission() throws {
        var slot = try claimedSlot(connectionEpoch: 15)
        guard case .advance(let cleanup, let snapshot) = slot
            .beginFatalShutdown()
        else {
            return XCTFail("expected fatal cleanup")
        }
        XCTAssertEqual(cleanup.action, .beginCleanup)
        XCTAssertFalse(snapshot.acceptingWork)
        XCTAssertThrowsError(
            try slot.claim(
                operationKind: .lockdownCommand,
                requestID: "request.after-fatal",
                attemptID: "attempt.after-fatal",
                connectionEpoch: 15
            )
        ) { error in
            XCTAssertEqual(
                error as? DirectGenerationControllerError,
                .runtimeNotAcceptingWork
            )
        }
    }

    private func claimedSlot(
        connectionEpoch: UInt64
    ) throws -> DirectProcessSlotController {
        var slot = try DirectProcessSlotController(runtimeEpoch: 7)
        _ = slot.observeAttach(connectionEpoch: connectionEpoch)
        _ = try slot.claim(
            operationKind: .legacyMountedQuery,
            requestID: "request.initial",
            attemptID: "attempt.initial",
            connectionEpoch: connectionEpoch
        )
        return slot
    }
}
