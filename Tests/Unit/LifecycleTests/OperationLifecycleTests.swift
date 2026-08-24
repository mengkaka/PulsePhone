import Foundation
import XCTest
@testable import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions

final class OperationLifecycleTests: XCTestCase {
    func testOneShotFullLifecycleReleasesOwnershipOnlyAfterCleanup() throws {
        var lifecycle = OperationLifecycle(
            requestID: try uuid(1),
            executionKind: .oneShot
        )
        XCTAssertEqual(lifecycle.snapshot.phase, .received)
        try lifecycle.beginPlanning(actionID: uuid(2))
        try lifecycle.awaitCapability()
        try lifecycle.resumePlanning()
        try lifecycle.acceptPending(inhibitorTokenID: "inhibitor.oneshot.1")
        XCTAssertEqual(lifecycle.snapshot.acceptedBoundary, .pending)
        try lifecycle.startRunning(
            bindings: OperationRuntimeBindings(
                attemptID: "attempt.1",
                executorGeneration: 3,
                leaseIDs: ["lease.app-state", "lease.oneshot-slot"]
            )
        )
        XCTAssertEqual(lifecycle.snapshot.phase, .running)
        XCTAssertNotNil(lifecycle.snapshot.inhibitorTokenID)
        XCTAssertNotNil(lifecycle.snapshot.runtimeBindings)

        let first = try lifecycle.beginCleaning(
            commitState: .committed,
            terminalCause: .backendResult
        )
        guard case .started(let context) = first else {
            return XCTFail("expected cleanup start")
        }
        XCTAssertEqual(context.commitState, .committed)
        XCTAssertEqual(lifecycle.snapshot.phase, .cleaning)
        XCTAssertNotNil(lifecycle.snapshot.inhibitorTokenID)
        XCTAssertNotNil(lifecycle.snapshot.runtimeBindings)

        XCTAssertEqual(
            try lifecycle.beginCleaning(
                commitState: .unknown,
                terminalCause: .runtimeAbort
            ),
            .joined(context)
        )
        XCTAssertThrowsError(
            try lifecycle.commitPreRunningTerminal(
                outcome: .failed,
                terminalCause: .runtimeAbort,
                resultDelivery: .reliableEnqueued
            )
        ) { error in
            XCTAssertEqual(error as? OperationLifecycleError, .cleanupRequired)
        }

        let terminal = try lifecycle.completeCleanup(
            outcome: .succeeded,
            resultDelivery: .reliableEnqueued,
            cleanupDisposition: .acknowledged
        )
        guard case .committed(let bundle) = terminal else {
            return XCTFail("expected terminal commit")
        }
        XCTAssertTrue(bundle.accepted)
        XCTAssertEqual(bundle.commitState, .committed)
        XCTAssertEqual(bundle.cleanupDisposition, .acknowledged)
        XCTAssertEqual(
            bundle.releasedLeaseIDs,
            ["lease.app-state", "lease.oneshot-slot"]
        )
        XCTAssertEqual(
            bundle.releasedInhibitorTokenID,
            "inhibitor.oneshot.1"
        )
        XCTAssertNil(lifecycle.snapshot.runtimeBindings)
        XCTAssertNil(lifecycle.snapshot.inhibitorTokenID)

        XCTAssertEqual(
            try lifecycle.completeCleanup(
                outcome: .failed,
                resultDelivery: .clientGone,
                cleanupDisposition: .fenced
            ),
            .alreadyTerminal(bundle)
        )
    }

    func testPreRunningAndPendingTerminalBundlesNeedNoCleanup() throws {
        var received = OperationLifecycle(
            requestID: try uuid(10),
            executionKind: .oneShot
        )
        XCTAssertThrowsError(
            try received.commitPreRunningTerminal(
                outcome: .succeeded,
                terminalCause: .rejected,
                resultDelivery: .reliableEnqueued,
                actionIDIfNeeded: uuid(11)
            )
        ) { error in
            XCTAssertEqual(
                error as? OperationLifecycleError,
                .invalidPreRunningOutcome
            )
        }
        let rejected = try received.commitPreRunningTerminal(
            outcome: .failed,
            terminalCause: .rejected,
            resultDelivery: .reliableEnqueued,
            actionIDIfNeeded: uuid(11)
        )
        guard case .committed(let rejectedBundle) = rejected else {
            return XCTFail("expected rejection terminal")
        }
        XCTAssertFalse(rejectedBundle.accepted)
        XCTAssertEqual(rejectedBundle.commitState, .notCommitted)
        XCTAssertEqual(rejectedBundle.cleanupDisposition, .notRequired)
        XCTAssertTrue(rejectedBundle.releasedLeaseIDs.isEmpty)
        XCTAssertNil(rejectedBundle.releasedInhibitorTokenID)

        var pending = OperationLifecycle(
            requestID: try uuid(12),
            executionKind: .oneShot
        )
        try pending.beginPlanning(actionID: uuid(13))
        try pending.acceptPending(inhibitorTokenID: "inhibitor.pending.1")
        let cancelled = try pending.commitPreRunningTerminal(
            outcome: .cancelled,
            terminalCause: .clientCancelled,
            resultDelivery: .reliableEnqueued
        )
        guard case .committed(let pendingBundle) = cancelled else {
            return XCTFail("expected pending terminal")
        }
        XCTAssertTrue(pendingBundle.accepted)
        XCTAssertEqual(pendingBundle.cleanupDisposition, .notRequired)
        XCTAssertEqual(
            pendingBundle.releasedInhibitorTokenID,
            "inhibitor.pending.1"
        )
        XCTAssertTrue(pendingBundle.releasedLeaseIDs.isEmpty)
    }

    func testStreamOpeningOpenClosingAndFirstWinsJoin() throws {
        var stream = OperationLifecycle(
            requestID: try uuid(20),
            executionKind: .stream
        )
        try stream.beginPlanning(actionID: uuid(21))
        try stream.acceptRunning(
            inhibitorTokenID: "inhibitor.stream.1",
            bindings: OperationRuntimeBindings(
                attemptID: "stream-attempt.1",
                executorGeneration: 4,
                leaseIDs: ["lease.input"]
            )
        )
        XCTAssertEqual(stream.snapshot.streamSubstate, .opening)
        try stream.markStreamOpen()
        XCTAssertEqual(stream.snapshot.streamSubstate, .open)

        let first = try stream.beginCleaning(
            commitState: .notCommitted,
            terminalCause: .ownerDisconnected
        )
        guard case .started(let context) = first else {
            return XCTFail("expected stream close start")
        }
        XCTAssertEqual(stream.snapshot.streamSubstate, .closing)
        XCTAssertEqual(
            try stream.beginCleaning(
                commitState: .unknown,
                terminalCause: .deadlineExceeded
            ),
            .joined(context)
        )
        let terminal = try stream.completeCleanup(
            outcome: .cancelled,
            resultDelivery: .clientGone,
            cleanupDisposition: .fenced
        )
        guard case .committed(let bundle) = terminal else {
            return XCTFail("expected stream terminal")
        }
        XCTAssertEqual(bundle.terminalCause, .ownerDisconnected)
        XCTAssertEqual(bundle.resultDelivery, .clientGone)
        XCTAssertEqual(bundle.cleanupDisposition, .fenced)
        XCTAssertNil(stream.snapshot.streamSubstate)
    }

    func testInvalidTransitionsFailClosed() throws {
        var oneShot = OperationLifecycle(
            requestID: try uuid(30),
            executionKind: .oneShot
        )
        XCTAssertThrowsError(try oneShot.awaitCapability())
        try oneShot.beginPlanning(actionID: uuid(31))
        XCTAssertThrowsError(try oneShot.markStreamOpen()) { error in
            XCTAssertEqual(
                error as? OperationLifecycleError,
                .streamSubstateRequired
            )
        }
        try oneShot.acceptRunning(
            inhibitorTokenID: "inhibitor.1",
            bindings: OperationRuntimeBindings(
                attemptID: "attempt.1",
                executorGeneration: 1,
                leaseIDs: ["lease.1"]
            )
        )
        XCTAssertThrowsError(
            try oneShot.completeCleanup(
                outcome: .failed,
                resultDelivery: .reliableEnqueued,
                cleanupDisposition: .acknowledged
            )
        )

        var stream = OperationLifecycle(
            requestID: try uuid(32),
            executionKind: .stream
        )
        try stream.beginPlanning(actionID: uuid(33))
        XCTAssertThrowsError(try stream.awaitCapability()) { error in
            XCTAssertEqual(
                error as? OperationLifecycleError,
                .streamSubstateForbidden
            )
        }
        XCTAssertThrowsError(
            try OperationRuntimeBindings(
                attemptID: "attempt.2",
                executorGeneration: 1,
                leaseIDs: ["lease.b", "lease.a"]
            )
        )
    }

    func testFixtureTokenModelAndNoReplay() throws {
        let tokenExpected = try loadExpected(
            "T-015/operation-lifecycle-token-model-l1"
        )
        let replayExpected = try loadExpected(
            "T-007/accepted-work-terminal-no-replay-l3"
        )

        var lifecycle = OperationLifecycle(
            requestID: try uuid(40),
            executionKind: .oneShot
        )
        try lifecycle.beginPlanning(actionID: uuid(41))
        try lifecycle.acceptRunning(
            inhibitorTokenID: "inhibitor.accepted.1",
            bindings: OperationRuntimeBindings(
                attemptID: "attempt.accepted.1",
                executorGeneration: 2,
                leaseIDs: ["lease.accepted.1"]
            )
        )
        _ = try lifecycle.beginCleaning(
            commitState: .committed,
            terminalCause: .backendResult
        )
        let first = try lifecycle.completeCleanup(
            outcome: .succeeded,
            resultDelivery: .clientGone,
            cleanupDisposition: .acknowledged
        )
        guard case .committed(let bundle) = first else {
            return XCTFail("expected first terminal")
        }
        let repeated = try lifecycle.completeCleanup(
            outcome: .failed,
            resultDelivery: .reliableEnqueued,
            cleanupDisposition: .fenced
        )
        XCTAssertEqual(repeated, .alreadyTerminal(bundle))
        XCTAssertEqual(
            bundle.resultDelivery.rawValue,
            replayExpected["resultDelivery"]?.stringValue
        )
        XCTAssertEqual(replayExpected["terminalCount"]?.uintValue, 1)
        XCTAssertEqual(replayExpected["crossConnectionReplayAllowed"]?.boolValue, false)
        XCTAssertEqual(tokenExpected["terminalExactlyOnce"]?.boolValue, true)
        XCTAssertEqual(tokenExpected["cleanupExactlyOnce"]?.boolValue, true)
        XCTAssertEqual(tokenExpected["leaseReleaseAfterBarrier"]?.boolValue, true)
        XCTAssertEqual(tokenExpected["tokenMismatchMutationAllowed"]?.boolValue, false)
    }

    private func uuid(_ value: Int) throws -> CanonicalUUID {
        try CanonicalUUID(
            String(format: "00000000-0000-0000-0000-%012x", value)
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

    var uintValue: UInt64? {
        guard let number = numberValue else { return nil }
        return try? number.requireUInt64()
    }
}
