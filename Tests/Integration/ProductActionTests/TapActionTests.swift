import Foundation
import PulsePhoneBackendAdapters
import PulsePhoneCLI
import PulsePhoneClientCore
import PulsePhoneCommandPlanner
import PulsePhoneSharedDefinitions
import XCTest

final class TapActionTests: XCTestCase {
    func testValidTapProjectsCoordinateAndWaitsForCleanupAck() throws {
        let transport = RecordingTapTransport()
        let execution = try TapAction(transport: transport).execute(
            request(point: NormalizedPointV1(x: "0.5", y: "0.25"))
        )

        XCTAssertEqual(transport.events, [
            .touch(x: 32_768, y: 16_384, touching: true),
            .touch(x: 32_768, y: 16_384, touching: false),
            .cleanupAck(timeoutMilliseconds: 2_000),
        ])
        XCTAssertEqual(TapAction.commandID, "touch.tap")
        XCTAssertEqual(TapAction.routeID, "coredevice.normalTouch")
        XCTAssertEqual(TapAction.preparationGroupID, "prep.coredevice.v2")
        XCTAssertEqual(TapAction.deadlineMilliseconds, 5_000)
        XCTAssertEqual(execution.result.disposition, "acknowledged")
        XCTAssertEqual(execution.semanticLog.normalizedX, "0.5")
        XCTAssertEqual(execution.semanticLog.normalizedY, "0.25")
        XCTAssertTrue(execution.semanticLog.inputReleased)
    }

    func testBoundaryCoordinatesMapWithoutOrientationRotation() throws {
        let transport = RecordingTapTransport()
        _ = try TapAction(transport: transport).execute(
            request(point: NormalizedPointV1(x: "0", y: "1"))
        )
        XCTAssertEqual(transport.events.first, .touch(
            x: 0,
            y: UInt16.max,
            touching: true
        ))
    }

    func testInvalidCoordinateFailsBeforeTransport() {
        let transport = RecordingTapTransport()
        XCTAssertThrowsError(try TapAction(transport: transport).execute(
            request(point: NormalizedPointV1(x: "1.50", y: "0.25"))
        )) { error in
            XCTAssertEqual(error as? TapActionError, .invalidCoordinate)
        }
        XCTAssertTrue(transport.events.isEmpty)
    }

    func testConnectionEpochMismatchFailsBeforeTransport() throws {
        let transport = RecordingTapTransport()
        let request = TapExecutionRequest(
            point: NormalizedPointV1(x: "0.5", y: "0.25"),
            expectedGeometry: GeometryAssertionDTO(
                expectedConnectionEpoch: 8,
                expectedGeometryRevision: 3
            ),
            currentGeometry: try geometry(connectionEpoch: 9)
        )
        XCTAssertThrowsError(try TapAction(transport: transport).execute(request)) {
            XCTAssertEqual(
                $0 as? GeometryDTOValidationError,
                .connectionEpochMismatch(expected: 8, actual: 9)
            )
        }
        XCTAssertTrue(transport.events.isEmpty)
    }

    func testGeometryRevisionMismatchFailsBeforeTransport() throws {
        let transport = RecordingTapTransport()
        let request = TapExecutionRequest(
            point: NormalizedPointV1(x: "0.5", y: "0.25"),
            expectedGeometry: GeometryAssertionDTO(
                expectedConnectionEpoch: 8,
                expectedGeometryRevision: 4
            ),
            currentGeometry: try geometry()
        )
        XCTAssertThrowsError(try TapAction(transport: transport).execute(request)) {
            XCTAssertEqual(
                $0 as? GeometryDTOValidationError,
                .geometryRevisionMismatch(expected: 4, actual: 3)
            )
        }
        XCTAssertTrue(transport.events.isEmpty)
    }

    func testFailureAfterDownReleasesAndCleanupAckFailureStaysDistinct() {
        let transport = RecordingTapTransport(failUp: true)
        XCTAssertThrowsError(try TapAction(transport: transport).execute(
            request(point: NormalizedPointV1(x: "0.5", y: "0.25"))
        )) { error in
            XCTAssertEqual(error as? TapActionError, .transportFailure)
        }
        XCTAssertEqual(transport.events, [
            .touch(x: 32_768, y: 16_384, touching: true),
            .touch(x: 32_768, y: 16_384, touching: false),
            .touch(x: 32_768, y: 16_384, touching: false),
            .cleanupAck(timeoutMilliseconds: 2_000),
        ])

        let cleanupFailure = RecordingTapTransport(failCleanup: true)
        XCTAssertThrowsError(try TapAction(transport: cleanupFailure).execute(
            request(point: NormalizedPointV1(x: "0.5", y: "0.25"))
        )) { error in
            XCTAssertEqual(
                error as? TapActionError,
                .cleanupAcknowledgementMissing
            )
        }
    }

    func testCLIUsesCanonicalNormalizerAndProjectsTerminal() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let runtime = TapRuntime(terminal: try CommandSubmissionTerminal(
            outcome: .succeeded,
            commitState: .committed,
            routeID: "coredevice.normalTouch"
        ))
        let output = try TapCommand(
            submitter: CommandSubmitter(runtime: runtime)
        ).run(
            point: "0.5,0.25",
            requestID: uuid(1),
            actionID: uuid(2),
            canonicalUDID: target,
            outputMode: .human
        )
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.chunk.stdout, ["Tapped at 0.5,0.25"])

        let trailingZeroOutput = try TapCommand(
            submitter: CommandSubmitter(runtime: runtime)
        ).run(
            point: "0.50,0.25",
            requestID: uuid(3),
            actionID: uuid(4),
            canonicalUDID: target,
            outputMode: .json
        )
        XCTAssertEqual(trailingZeroOutput.exitCode, 0)
        XCTAssertTrue(trailingZeroOutput.chunk.stdout[0].contains("\"ok\":true"))
    }

    func testCLIProjectsUnknownOutcome() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let output = try TapCommand(
            submitter: CommandSubmitter(runtime: TapRuntime(
                terminal: try CommandSubmissionTerminal(
                    outcome: .outcomeUnknown,
                    commitState: .unknown,
                    errorCode: "outcomeUnknown"
                )
            ))
        ).run(
            point: "0.5,0.25",
            requestID: uuid(5),
            actionID: uuid(6),
            canonicalUDID: target,
            outputMode: .json
        )
        XCTAssertEqual(output.exitCode, 7)
        XCTAssertTrue(output.chunk.stdout[0].contains("\"runtimeMayContinue\":true"))
    }

    private func request(point: NormalizedPointV1) -> TapExecutionRequest {
        TapExecutionRequest(
            point: point,
            expectedGeometry: GeometryAssertionDTO(
                expectedConnectionEpoch: 8,
                expectedGeometryRevision: 3
            ),
            currentGeometry: try! geometry()
        )
    }

    private func geometry(
        connectionEpoch: UInt64 = 8
    ) throws -> DisplayGeometryDTO {
        try DisplayGeometryDTO(
            connectionEpoch: connectionEpoch,
            geometryRevision: 3,
            logicalHeight: 2_556,
            logicalWidth: 1_179,
            orientation: .portrait
        )
    }

    private func uuid(_ value: Int) throws -> CanonicalUUID {
        try CanonicalUUID(
            String(format: "00000000-0000-0000-0000-%012x", value)
        )
    }
}

private enum TapTransportEvent: Equatable {
    case touch(x: UInt16, y: UInt16, touching: Bool)
    case cleanupAck(timeoutMilliseconds: UInt64)
}

private final class RecordingTapTransport: TapTransport, @unchecked Sendable {
    private(set) var events = [TapTransportEvent]()
    private let failCleanup: Bool
    private let failUp: Bool

    init(failUp: Bool = false, failCleanup: Bool = false) {
        self.failUp = failUp
        self.failCleanup = failCleanup
    }

    func sendTouch(
        coordinate: HIDCoordinateDTO,
        touching: Bool
    ) throws {
        events.append(.touch(
            x: coordinate.x,
            y: coordinate.y,
            touching: touching
        ))
        if failUp, !touching, events.count == 2 {
            throw TapActionError.transportFailure
        }
    }

    func waitForCleanupAcknowledgement(
        timeoutMilliseconds: UInt64
    ) throws {
        events.append(.cleanupAck(timeoutMilliseconds: timeoutMilliseconds))
        if failCleanup {
            throw TapActionError.cleanupAcknowledgementMissing
        }
    }
}

private struct TapRuntime: CommandSubmissionRuntime {
    let terminal: CommandSubmissionTerminal

    func submit(
        _ intent: CommandSubmissionIntent
    ) throws -> [CommandSubmissionEvent] {
        XCTAssertEqual(intent.commandID, "touch.tap")
        XCTAssertEqual(intent.rawArguments, ["point": "0.5,0.25"])
        return [
            .accepted,
            .authoritativePlan(
                routeID: "coredevice.normalTouch",
                sourceRevision: 1,
                resumedAfterPreparation: false
            ),
            .queued,
            .started(routeID: "coredevice.normalTouch"),
            .terminal(terminal),
        ]
    }
}
