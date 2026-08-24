import Foundation
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions
import PulsePhoneWire
import XCTest

@testable import PulsePhoneRuntimeKernel

final class PrepareCapabilitiesControlTests: XCTestCase {
    func testProgressTerminalBackpressureFixture() throws {
        let expected = try loadCoordinatorExpected(
            "T-020/progress-terminal-backpressure-l3"
        )
        var buffer = PreparationOutputBuffer()
        let groupID = "prep.coredevice.v2"

        for value in 1...PreparationOutputBuffer.maximumRequestCount {
            let requestID = try coordinatorUUID(value)
            XCTAssertEqual(
                try buffer.enqueueProgress(
                    progress(value, groupID: groupID),
                    for: requestID
                ),
                .queued
            )
        }
        XCTAssertEqual(
            try buffer.enqueueProgress(
                progress(1, groupID: groupID, phaseSequence: 2),
                for: coordinatorUUID(1)
            ),
            .coalesced
        )
        XCTAssertEqual(
            try buffer.enqueueProgress(
                progress(65, groupID: groupID),
                for: coordinatorUUID(65)
            ),
            .dropped
        )

        let laterID = try coordinatorUUID(64)
        let earlierID = try coordinatorUUID(1)
        XCTAssertEqual(
            try buffer.enqueueTerminal(failureTerminal(requestID: laterID)),
            .terminalQueued(progressDiscarded: true)
        )
        XCTAssertEqual(
            try buffer.enqueueTerminal(failureTerminal(requestID: earlierID)),
            .terminalQueued(progressDiscarded: true)
        )
        XCTAssertEqual(
            try buffer.enqueueProgress(
                progress(64, groupID: groupID, phaseSequence: 3),
                for: laterID
            ),
            .dropped
        )
        XCTAssertEqual(
            buffer.drainTerminals().map(\.requestID),
            [laterID, earlierID]
        )

        var terminalBuffer = PreparationOutputBuffer()
        for value in 1...PreparationOutputBuffer.maximumRequestCount {
            _ = try terminalBuffer.enqueueTerminal(
                failureTerminal(requestID: coordinatorUUID(value))
            )
        }
        XCTAssertThrowsError(
            try terminalBuffer.enqueueTerminal(
                failureTerminal(requestID: coordinatorUUID(65))
            )
        ) { error in
            XCTAssertEqual(
                error as? PrepareCapabilitiesControlError,
                .outputCapacityExceeded
            )
        }

        XCTAssertEqual(
            expectedUInt(expected, "progressRequestCapacity"),
            UInt64(PreparationOutputBuffer.maximumRequestCount)
        )
        XCTAssertEqual(expectedString(expected, "progressOverflow"), "dropped")
        XCTAssertEqual(expectedBool(expected, "progressCoalesced"), true)
        XCTAssertEqual(expectedBool(expected, "terminalSupersedesProgress"), true)
        XCTAssertEqual(expectedString(expected, "terminalOrder"), "productionOrder")
        XCTAssertEqual(
            expectedString(expected, "terminalOverflow"),
            "outputCapacityExceeded"
        )
    }

    func testStatusProjectionBoundaryFixture() throws {
        let expected = try loadCoordinatorExpected(
            "T-020/status-projection-boundary-l3"
        )
        var control = try makeControl()
        let requestID = try coordinatorUUID(200)
        let request = PrepareCapabilitiesRequestV1(
            canonicalUDID: try targetUDID()
        )
        guard case .observing(_, let identity, let joined) =
                try control.prepareCapabilities(
                    requestID: requestID,
                    request: request,
                    allocatedActionID: coordinatorUUID(201),
                    ownerClientInstanceID: coordinatorUUID(202),
                    osMajor: 26,
                    at: controlInstant(seconds: 60),
                    newAttempt: coordinatorSeed(203),
                    alreadyReadyProjection: successProjection()
                )
        else {
            return XCTFail("expected preparation observer")
        }
        XCTAssertFalse(joined)
        try control.transitionAttempt(
            identity.key,
            to: .queryingMountedImage,
            at: controlInstant(seconds: 61)
        )
        try control.transitionAttempt(
            identity.key,
            to: .resolvingDeveloperSupport,
            at: controlInstant(seconds: 62)
        )

        let statuses = try control.statuses(stateRevision: 44)
        XCTAssertEqual(
            statuses.map(\.preparationGroupID),
            [
                "prep.coredevice.v2",
                "prep.direct.lockdown.v1",
                "prep.legacy.developer.v2",
            ]
        )
        let active = try XCTUnwrap(statuses.first)
        XCTAssertEqual(active.state, .acquiring)
        XCTAssertEqual(active.phase, .resolvingDeveloperSupport)
        XCTAssertEqual(active.preparationAttemptID, identity.preparationAttemptID)
        XCTAssertEqual(active.progress?.stateRevision, 44)
        XCTAssertTrue(statuses.allSatisfy { !$0.truncated })
        XCTAssertEqual(
            control.snapshot.idle.lastCLIActivityAt,
            controlInstant(seconds: 60)
        )

        XCTAssertEqual(
            try control.publishProgress(
                requestID: requestID,
                callbackIdentity: identity,
                phaseSequence: 3,
                stateRevision: 45,
                fraction: 0.5,
                sourceKind: .approvedRemote,
                sharedAcquisition: true
            ),
            .queued
        )
        XCTAssertEqual(
            control.snapshot.idle.lastCLIActivityAt,
            controlInstant(seconds: 60)
        )

        let terminal = try XCTUnwrap(
            control.observerDeadline(
                requestID: requestID,
                at: controlInstant(seconds: 1_260)
            )
        )
        XCTAssertEqual(terminal.result.outcome, .outcomeUnknown)
        XCTAssertEqual(terminal.result.error?.code, "outcomeUnknown")
        XCTAssertEqual(
            terminal.result.error?.details?.reason,
            "preparationObserverDeadlineExceeded"
        )
        XCTAssertEqual(terminal.result.error?.details?.runtimeMayContinue, true)
        XCTAssertEqual(
            control.snapshot.idle.lastCLIActivityAt,
            controlInstant(seconds: 60)
        )

        XCTAssertEqual(expectedUInt(expected, "groupCount"), UInt64(statuses.count))
        XCTAssertEqual(expectedUInt(expected, "maximumGroupCount"), 8)
        XCTAssertEqual(expectedString(expected, "activeState"), active.state.rawValue)
        XCTAssertEqual(expectedString(expected, "activePhase"), active.phase?.rawValue)
        XCTAssertEqual(expectedUInt(expected, "stateRevision"), 44)
        XCTAssertEqual(expectedBool(expected, "truncated"), false)
        XCTAssertEqual(
            expectedString(expected, "observerDeadlineOutcome"),
            terminal.result.outcome.rawValue
        )
        XCTAssertEqual(expectedBool(expected, "progressRefreshesIdle"), false)
        XCTAssertEqual(expectedBool(expected, "completionRefreshesIdle"), false)
    }

    func testRequestBoundaryAndAlreadyReadyResult() throws {
        let body = try RepositoryCanonicalJSON.parseDocument(
            Array(
                "{\"actionContext\":{\"actionID\":\"00000000-0000-0000-0000-000000000301\",\"parentActionID\":\"00000000-0000-0000-0000-000000000302\"},\"canonicalUDID\":\"00008110-001A2B3C4D5E601E\"}".utf8
            ),
            maximumByteCount: 8 * 1_024
        )
        let request = try PrepareCapabilitiesRequestV1.decode(body)
        XCTAssertEqual(request.canonicalUDID, try targetUDID())
        XCTAssertEqual(request.actionContext?.actionID, try coordinatorUUID(0x301))
        XCTAssertEqual(request.actionContext?.parentActionID, try coordinatorUUID(0x302))

        let forbidden = try RepositoryCanonicalJSON.parseDocument(
            Array(
                "{\"canonicalUDID\":\"00008110-001A2B3C4D5E601E\",\"preparationGroupID\":\"prep.coredevice.v2\"}".utf8
            ),
            maximumByteCount: 8 * 1_024
        )
        XCTAssertThrowsError(try PrepareCapabilitiesRequestV1.decode(forbidden))

        var control = try makeControl()
        try control.observeCapabilityReady(
            preparationGroupID: "prep.coredevice.v2"
        )
        guard case .terminal(let terminal) = try control.prepareCapabilities(
            requestID: coordinatorUUID(303),
            request: request,
            allocatedActionID: coordinatorUUID(304),
            ownerClientInstanceID: coordinatorUUID(305),
            osMajor: 26,
            at: controlInstant(seconds: 1),
            newAttempt: coordinatorSeed(306),
            alreadyReadyProjection: successProjection()
        ) else {
            return XCTFail("expected already-ready terminal")
        }
        XCTAssertEqual(terminal.actionID, try coordinatorUUID(0x301))
        XCTAssertEqual(terminal.parentActionID, try coordinatorUUID(0x302))
        XCTAssertEqual(terminal.result.outcome, .succeeded)
        XCTAssertEqual(terminal.result.value?.disposition, .alreadyReady)
        XCTAssertNil(terminal.result.value?.preparationAttemptID)
        XCTAssertTrue(control.snapshot.coordinator.attempts.isEmpty)
    }

    func testCapacityAndDuplicateErrorMapping() throws {
        var control = try makeControl()
        let request = PrepareCapabilitiesRequestV1(
            canonicalUDID: try targetUDID()
        )
        for value in 1...64 {
            guard case .observing = try control.prepareCapabilities(
                requestID: coordinatorUUID(1_000 + value),
                request: request,
                allocatedActionID: coordinatorUUID(2_000 + value),
                ownerClientInstanceID: coordinatorUUID(3_000 + value),
                osMajor: 26,
                at: controlInstant(seconds: UInt64(value)),
                newAttempt: coordinatorSeed(4_000 + value),
                alreadyReadyProjection: successProjection()
            ) else {
                return XCTFail("expected accepted observer \(value)")
            }
        }
        guard case .rejected(let terminal) = try control.prepareCapabilities(
            requestID: coordinatorUUID(1_065),
            request: request,
            allocatedActionID: coordinatorUUID(2_065),
            ownerClientInstanceID: coordinatorUUID(3_065),
            osMajor: 26,
            at: controlInstant(seconds: 1_000),
            newAttempt: coordinatorSeed(4_065),
            alreadyReadyProjection: successProjection()
        ) else {
            return XCTFail("expected wait-registry rejection")
        }
        XCTAssertEqual(terminal.result.error?.code, "admissionCapacityExceeded")
        XCTAssertEqual(
            terminal.result.error?.details?.capacityClass,
            "preparationWaitRegistry"
        )
        XCTAssertEqual(terminal.result.error?.details?.limit, 64)
        XCTAssertEqual(terminal.result.error?.details?.truncated, false)
        XCTAssertEqual(
            control.snapshot.idle.lastCLIActivityAt,
            controlInstant(seconds: 64)
        )

        let duplicate = try XCTUnwrap(
            PrepareCapabilitiesControl.mappedProtocolError(
                .requestTracking(.duplicateRequestID)
            )
        )
        XCTAssertEqual(duplicate.code, "protocolViolation")
    }

    private func makeControl() throws -> PrepareCapabilitiesControl {
        try PrepareCapabilitiesControl(
            canonicalUDID: targetUDID(),
            runtimeEpoch: 9,
            connectionEpoch: 1,
            runtimeReadyAt: controlInstant(seconds: 0),
            executionCatalog: loadCoordinatorCatalog()
        )
    }

    private func targetUDID() throws -> CanonicalUDID {
        try CanonicalUDID(canonicalString: "00008110-001A2B3C4D5E601E")
    }

    private func successProjection() -> PreparationSuccessProjection {
        PreparationSuccessProjection(
            assetDisposition: .cacheHit,
            mountDisposition: .alreadyMounted,
            provenance: "approved",
            serviceDisposition: .ready
        )
    }

    private func progress(
        _ value: Int,
        groupID: String,
        phaseSequence: UInt64 = 1
    ) throws -> PreparationProgressV1 {
        try PreparationProgressV1(
            fraction: 0.5,
            phase: .downloading,
            phaseSequence: phaseSequence,
            preparationAttemptID: coordinatorUUID(10_000 + value),
            preparationGroupID: groupID,
            stateRevision: UInt64(value)
        )
    }

    private func failureTerminal(
        requestID: CanonicalUUID
    ) throws -> PrepareCapabilitiesTerminal {
        PrepareCapabilitiesTerminal(
            actionID: try coordinatorUUID(20_000),
            parentActionID: nil,
            requestID: requestID,
            result: try StandardResultV1(
                outcome: .failed,
                commitState: .notCommitted,
                error: StandardErrorV1(
                    code: "preparationFailed",
                    details: PreparationErrorDetailsV1()
                )
            )
        )
    }

    private func controlInstant(seconds: UInt64) -> MonotonicInstant {
        MonotonicInstant(nanoseconds: seconds * 1_000_000_000)
    }
}
