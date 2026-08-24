import Foundation
import PulsePhoneBackendAdapters
import PulsePhoneCLI
import PulsePhoneClientCore
import PulsePhoneSharedDefinitions
import XCTest

final class RotateActionTests: XCTestCase {
    func testAckAndMatchingNewRevisionRestoreCoordinateInput() throws {
        let state = RotationGeometryState(currentGeometry: try geometry())
        let transport = RecordingRotateTransport(candidate: try geometry(
            revision: 4,
            orientation: .landscapeLeft
        ))
        let execution = try RotateAction(
            geometryState: state,
            transport: transport
        ).execute(
            direction: .left,
            expectedGeometry: assertion()
        )
        XCTAssertEqual(transport.events, [
            .rotate(.left),
            .wait(afterRevision: 3, timeoutMilliseconds: 10_000),
        ])
        XCTAssertEqual(execution.result.direction, .left)
        XCTAssertEqual(execution.result.orientation, .landscapeLeft)
        XCTAssertEqual(execution.semanticLog.geometryRevision, 4)
        XCTAssertEqual(execution.semanticLog.orientation, .landscapeLeft)
        XCTAssertTrue(state.coordinateInputAvailable)
        XCTAssertEqual(state.currentGeometry?.orientation, .landscapeLeft)
    }

    func testAckWithoutNewRevisionLeavesCoordinatesUnavailable() throws {
        let state = RotationGeometryState(currentGeometry: try geometry())
        let transport = RecordingRotateTransport(candidate: nil)
        XCTAssertThrowsError(try RotateAction(
            geometryState: state,
            transport: transport
        ).execute(direction: .right, expectedGeometry: assertion())) { error in
            XCTAssertEqual(
                error as? RotateActionError,
                .geometryOutcomeUnknown
            )
        }
        XCTAssertFalse(state.coordinateInputAvailable)
        XCTAssertNil(state.currentGeometry)
    }

    func testStaleWrongEpochAndWrongOrientationNeverRestoreGeometry() throws {
        let candidates = [
            try geometry(revision: 3, orientation: .landscapeRight),
            try geometry(epoch: 9, revision: 4, orientation: .landscapeRight),
            try geometry(revision: 4, orientation: .portrait),
        ]
        for candidate in candidates {
            let state = RotationGeometryState(currentGeometry: try geometry())
            XCTAssertThrowsError(try RotateAction(
                geometryState: state,
                transport: RecordingRotateTransport(candidate: candidate)
            ).execute(
                direction: .right,
                expectedGeometry: assertion()
            )) { error in
                XCTAssertEqual(
                    error as? RotateActionError,
                    .geometryOutcomeUnknown
                )
            }
            XCTAssertFalse(state.coordinateInputAvailable)
        }
    }

    func testInitialGeometryAssertionFailsBeforeInvalidationOrTransport() throws {
        let state = RotationGeometryState(currentGeometry: try geometry())
        let transport = RecordingRotateTransport(candidate: nil)
        XCTAssertThrowsError(try RotateAction(
            geometryState: state,
            transport: transport
        ).execute(
            direction: .left,
            expectedGeometry: GeometryAssertionDTO(
                expectedConnectionEpoch: 8,
                expectedGeometryRevision: 2
            )
        )) { error in
            XCTAssertEqual(
                error as? GeometryDTOValidationError,
                .geometryRevisionMismatch(expected: 2, actual: 3)
            )
        }
        XCTAssertTrue(state.coordinateInputAvailable)
        XCTAssertTrue(transport.events.isEmpty)
    }

    func testCLIValidatesDirectionAndProjectsUnknownOutcome() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let command = RotateCommand(submitter: CommandSubmitter(runtime:
            RotateRuntime(outcome: .outcomeUnknown)
        ))
        let output = try command.run(
            direction: "right",
            requestID: uuid(1),
            actionID: uuid(2),
            canonicalUDID: target,
            outputMode: .json
        )
        XCTAssertEqual(output.exitCode, 7)
        XCTAssertTrue(output.chunk.stdout[0].contains("\"runtimeMayContinue\":true"))

        XCTAssertThrowsError(try command.run(
            direction: "upsideDown",
            requestID: uuid(3),
            actionID: uuid(4),
            canonicalUDID: target,
            outputMode: .human
        ))
    }

    private func assertion() -> GeometryAssertionDTO {
        GeometryAssertionDTO(
            expectedConnectionEpoch: 8,
            expectedGeometryRevision: 3
        )
    }

    private func geometry(
        epoch: UInt64 = 8,
        revision: UInt64 = 3,
        orientation: DisplayOrientationDTO = .portrait
    ) throws -> DisplayGeometryDTO {
        try DisplayGeometryDTO(
            connectionEpoch: epoch,
            geometryRevision: revision,
            logicalHeight: 2_556,
            logicalWidth: 1_179,
            orientation: orientation
        )
    }

    private func uuid(_ value: Int) throws -> CanonicalUUID {
        try CanonicalUUID(
            String(format: "00000000-0000-0000-0000-%012x", value)
        )
    }
}

private enum RotateTransportEvent: Equatable {
    case rotate(RotateDirection)
    case wait(afterRevision: UInt64, timeoutMilliseconds: UInt64)
}

private final class RecordingRotateTransport: RotateTransport, @unchecked Sendable {
    private(set) var events = [RotateTransportEvent]()
    private let candidate: DisplayGeometryDTO?

    init(candidate: DisplayGeometryDTO?) {
        self.candidate = candidate
    }

    func sendRotation(_ direction: RotateDirection) throws {
        events.append(.rotate(direction))
    }

    func waitForGeometry(
        afterRevision: UInt64,
        timeoutMilliseconds: UInt64
    ) throws -> DisplayGeometryDTO? {
        events.append(.wait(
            afterRevision: afterRevision,
            timeoutMilliseconds: timeoutMilliseconds
        ))
        return candidate
    }
}

private struct RotateRuntime: CommandSubmissionRuntime {
    let outcome: StandardOutcome

    func submit(
        _ intent: CommandSubmissionIntent
    ) throws -> [CommandSubmissionEvent] {
        XCTAssertEqual(intent.commandID, "device.rotate")
        XCTAssertEqual(intent.rawArguments, ["direction": "right"])
        let terminal = try CommandSubmissionTerminal(
            outcome: outcome,
            commitState: outcome == .succeeded ? .committed : .unknown,
            routeID: outcome == .succeeded ? "coredevice.orientation.rotate" : nil,
            errorCode: outcome == .succeeded ? nil : "outcomeUnknown"
        )
        return [
            .accepted,
            .authoritativePlan(
                routeID: "coredevice.orientation.rotate",
                sourceRevision: 1,
                resumedAfterPreparation: false
            ),
            .queued,
            .started(routeID: "coredevice.orientation.rotate"),
            .terminal(terminal),
        ]
    }
}
