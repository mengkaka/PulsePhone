import Foundation
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions
import XCTest

final class StreamSessionTests: XCTestCase {
    func testFailFastRejectDoesNotAcquireCleanupOwnership() throws {
        var session = try makeSession(plan: orderedPlan())
        let terminal = try session.rejectOpen()
        XCTAssertFalse(terminal.accepted)
        XCTAssertEqual(terminal.cleanupDisposition, .notRequired)
        XCTAssertTrue(terminal.releasedLeaseIDs.isEmpty)
        XCTAssertEqual(session.snapshot.cleanupStartCount, 0)
        XCTAssertEqual(session.snapshot.lifecycle.phase, .terminal)
    }

    func testOpeningCoalescesLatestMoveAndPreservesBoundaries() throws {
        let plan = try StreamBufferPlan(
            frameRules: [
                StreamFrameRule(frameKind: "begin", deliveryClass: .ordered),
                StreamFrameRule(
                    frameKind: "move",
                    deliveryClass: .latestWins(slotID: "pointer.move")
                ),
                StreamFrameRule(frameKind: "end", deliveryClass: .ordered),
            ],
            maximumOpeningFrames: 3
        )
        var session = try makeSession(plan: plan)
        try beginOpening(&session)
        try session.submitFrame(frame(sequence: 0, kind: "begin"))
        try session.submitFrame(frame(sequence: 1, kind: "move"))
        try session.submitFrame(frame(sequence: 2, kind: "move"))
        try session.submitFrame(frame(sequence: 3, kind: "end"))
        XCTAssertEqual(session.snapshot.buffer.pendingFrameCount, 3)

        try session.markBackendOpen()
        var delivered = [UInt64]()
        for index in 0..<3 {
            let attemptID = "delivery.\(index)"
            let attempt = try XCTUnwrap(session.dequeueFrameForDelivery(
                deliveryAttemptID: attemptID,
                atMonotonicNanoseconds: UInt64(index)
            ))
            delivered.append(attempt.frame.sequence)
            try session.acceptFrame(
                sequence: attempt.frame.sequence,
                deliveryAttemptID: attemptID
            )
        }
        XCTAssertEqual(delivered, [0, 2, 3])
        XCTAssertNil(try session.dequeueFrameForDelivery(
            deliveryAttemptID: "delivery.empty",
            atMonotonicNanoseconds: 4
        ))
        XCTAssertEqual(session.snapshot.buffer.lastAcceptedSequence, 3)
    }

    func testOpeningOverflowAutomaticallyStartsOneCleanup() throws {
        let plan = try StreamBufferPlan(
            frameRules: [StreamFrameRule(
                frameKind: "key",
                deliveryClass: .ordered
            )],
            maximumOpeningFrames: 2
        )
        var session = try makeSession(plan: plan)
        try beginOpening(&session)
        try session.submitFrame(frame(sequence: 0, kind: "key"))
        try session.submitFrame(frame(sequence: 1, kind: "key"))
        XCTAssertThrowsError(
            try session.submitFrame(frame(sequence: 2, kind: "key"))
        ) { error in
            XCTAssertEqual(
                error as? StreamSessionError,
                .buffer(.openingCapacityExceeded)
            )
        }
        XCTAssertEqual(session.snapshot.lifecycle.streamSubstate, .closing)
        XCTAssertEqual(session.snapshot.cleanupStartCount, 1)
        XCTAssertEqual(session.snapshot.cleanupCommand?.droppedFrameCount, 2)
    }

    func testLatestWinsKeepsOnePendingWhilePreviousFrameIsInFlight() throws {
        let plan = try StreamBufferPlan(
            frameRules: [StreamFrameRule(
                frameKind: "move",
                deliveryClass: .latestWins(slotID: "pointer.move")
            )],
            maximumOpeningFrames: 1
        )
        var session = try makeSession(plan: plan)
        try beginOpening(&session)
        try session.markBackendOpen()
        try session.submitFrame(frame(sequence: 0, kind: "move"))
        _ = try XCTUnwrap(session.dequeueFrameForDelivery(
            deliveryAttemptID: "delivery.move.0",
            atMonotonicNanoseconds: 0
        ))
        try session.submitFrame(frame(sequence: 1, kind: "move"))
        try session.submitFrame(frame(sequence: 2, kind: "move"))
        XCTAssertNil(try session.dequeueFrameForDelivery(
            deliveryAttemptID: "delivery.move.blocked",
            atMonotonicNanoseconds: 1
        ))
        XCTAssertEqual(session.snapshot.buffer.pendingFrameCount, 1)
        XCTAssertEqual(session.snapshot.buffer.inFlightFrameCount, 1)
        try session.acceptFrame(
            sequence: 0,
            deliveryAttemptID: "delivery.move.0"
        )
        let latest = try XCTUnwrap(session.dequeueFrameForDelivery(
            deliveryAttemptID: "delivery.move.2",
            atMonotonicNanoseconds: 2
        ))
        XCTAssertEqual(latest.frame.sequence, 2)
    }

    func testFirstWinsCloseCancelJoinsOneImmutableBarrier() throws {
        var session = try makeSession(plan: orderedPlan())
        try beginOpening(&session)
        try session.markBackendOpen()
        try session.submitFrame(frame(sequence: 0, kind: "ordered"))
        let firstRequest = try uuid(10)
        let joinRequest = try uuid(11)
        let first = try session.requestClose(
            requestID: firstRequest,
            mode: .close,
            cause: .clientCancelled
        )
        guard case .started(let command) = first else {
            return XCTFail("expected first cleanup")
        }
        XCTAssertEqual(command.mode, .close)
        XCTAssertEqual(command.droppedFrameCount, 1)
        XCTAssertEqual(
            try session.requestClose(
                requestID: joinRequest,
                mode: .cancel,
                cause: .runtimeAbort
            ),
            .joined(command)
        )
        XCTAssertEqual(session.snapshot.cleanupStartCount, 1)
        XCTAssertThrowsError(try session.closeResponse(for: firstRequest)) {
            error in
            XCTAssertEqual(error as? StreamCleanupError, .barrierIncomplete)
        }
        let terminal = try session.completeCleanup(
            outcome: .succeeded,
            resultDelivery: .reliableEnqueued,
            disposition: .acknowledged
        )
        XCTAssertEqual(terminal.closingCause, .clientCancelled)
        XCTAssertEqual(terminal.cleanupDisposition, .acknowledged)
        XCTAssertEqual(
            try session.closeResponse(for: firstRequest).disposition,
            .closed
        )
        XCTAssertEqual(
            try session.closeResponse(for: joinRequest).disposition,
            .alreadyClosing
        )
        XCTAssertEqual(
            try session.closeResponse(for: uuid(12)).disposition,
            .alreadyClosed
        )
    }

    func testFrameAcceptedIdentityAndWatchdogCancelSession() throws {
        var session = try makeSession(plan: orderedPlan())
        try beginOpening(&session)
        try session.markBackendOpen()
        try session.submitFrame(frame(sequence: 0, kind: "ordered"))
        _ = try XCTUnwrap(session.dequeueFrameForDelivery(
            deliveryAttemptID: "delivery.watchdog",
            atMonotonicNanoseconds: 100
        ))
        XCTAssertThrowsError(try session.acceptFrame(
            sequence: 0,
            deliveryAttemptID: "delivery.wrong"
        )) { error in
            XCTAssertEqual(
                error as? StreamSessionError,
                .buffer(.deliveryAttemptMismatch)
            )
        }
        XCTAssertNil(try session.evaluateFrameAcceptedWatchdog(
            atMonotonicNanoseconds: 100
                + StreamSessionPlan.frameAcceptedWatchdogNanoseconds - 1
        ))
        let timeout = try XCTUnwrap(session.evaluateFrameAcceptedWatchdog(
            atMonotonicNanoseconds: 100
                + StreamSessionPlan.frameAcceptedWatchdogNanoseconds
        ))
        guard case .started(let command) = timeout else {
            return XCTFail("expected watchdog cleanup")
        }
        XCTAssertEqual(command.closingCause, .deadlineExceeded)
        XCTAssertEqual(command.droppedFrameCount, 1)
        XCTAssertEqual(session.snapshot.cleanupStartCount, 1)
    }

    func testStreamBackpressureCleanupFixture() throws {
        let fixture = repositoryRoot().appendingPathComponent(
            "Fixtures/requirements/T-015/stream-backpressure-cleanup-l3"
        )
        let input = try JSONDecoder().decode(
            StreamBackpressureFixtureInput.self,
            from: Data(contentsOf: fixture.appendingPathComponent(
                "input/input.v1.json"
            ))
        )
        let expected = try JSONDecoder().decode(
            StreamBackpressureFixtureExpected.self,
            from: Data(contentsOf: fixture.appendingPathComponent(
                "expected.v1.json"
            ))
        )
        let plan = try StreamBufferPlan(
            frameRules: [StreamFrameRule(
                frameKind: "key",
                deliveryClass: .ordered
            )],
            maximumOpeningFrames: 32,
            maximumOrderedFrames: input.maximumOrderedFrames
        )
        var session = try makeSession(plan: plan)
        try beginOpening(&session)
        try session.markBackendOpen()

        var observedError: String?
        for fixtureFrame in input.frames {
            do {
                try session.submitFrame(StreamFrameEnvelope(
                    sessionID: try uuid(3),
                    interactionID: try uuid(4),
                    sequence: fixtureFrame.sequence,
                    frameKind: fixtureFrame.frameKind,
                    encodedBytes: Array(
                        repeating: 0x61,
                        count: fixtureFrame.encodedByteCount
                    )
                ))
            } catch StreamSessionError.buffer(let error) {
                observedError = String(describing: error)
                break
            }
        }
        XCTAssertEqual(observedError, expected.error)
        XCTAssertEqual(
            session.snapshot.cleanupStartCount,
            expected.cleanupStarts
        )
        XCTAssertEqual(
            session.snapshot.cleanupCommand?.droppedFrameCount,
            expected.droppedFrameCount
        )
        let terminal = try session.completeCleanup(
            outcome: .cancelled,
            resultDelivery: .reliableEnqueued,
            disposition: .fenced
        )
        XCTAssertEqual(
            terminal.cleanupDisposition.rawValue,
            expected.cleanupDisposition
        )
        XCTAssertEqual(
            terminal.terminalBundle.outcome.rawValue,
            expected.terminalOutcome
        )
    }

    private func orderedPlan() throws -> StreamBufferPlan {
        try StreamBufferPlan(
            frameRules: [StreamFrameRule(
                frameKind: "ordered",
                deliveryClass: .ordered
            )],
            maximumOpeningFrames: 32
        )
    }

    private func makeSession(plan: StreamBufferPlan) throws -> StreamSession {
        try StreamSession(
            openRequestID: uuid(1),
            actionID: uuid(2),
            sessionID: uuid(3),
            interactionID: uuid(4),
            plan: StreamSessionPlan(bufferPlan: plan)
        )
    }

    private func beginOpening(_ session: inout StreamSession) throws {
        try session.beginOpening(
            inhibitorTokenID: "inhibitor.stream.test",
            bindings: OperationRuntimeBindings(
                attemptID: "attempt.stream.test",
                executorGeneration: 1,
                leaseIDs: ["lease.stream.test"]
            )
        )
    }

    private func frame(
        sequence: UInt64,
        kind: String,
        byteCount: Int = 16
    ) throws -> StreamFrameEnvelope {
        StreamFrameEnvelope(
            sessionID: try uuid(3),
            interactionID: try uuid(4),
            sequence: sequence,
            frameKind: kind,
            encodedBytes: Array(repeating: 0x61, count: byteCount)
        )
    }

    private func uuid(_ suffix: Int) throws -> CanonicalUUID {
        try CanonicalUUID(String(
            format: "00000000-0000-0000-0000-%012d",
            suffix
        ))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct StreamBackpressureFixtureInput: Decodable {
    struct Frame: Decodable {
        let encodedByteCount: Int
        let frameKind: String
        let sequence: UInt64
    }

    let frames: [Frame]
    let maximumOrderedFrames: Int
}

private struct StreamBackpressureFixtureExpected: Decodable {
    let cleanupDisposition: String
    let cleanupStarts: Int
    let droppedFrameCount: Int
    let error: String
    let terminalOutcome: String
}
