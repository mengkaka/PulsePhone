import Foundation
import PulsePhoneBackendAdapters
import PulsePhoneCLI
import PulsePhoneClientCore
import PulsePhoneCommandPlanner
import PulsePhoneSharedDefinitions
import XCTest

final class LinearGestureTests: XCTestCase {
    func testCanonicalFixtureCoversDurationAndFrameBounds() throws {
        for fixture in try loadFixtures() {
            let plan = try LinearGesturePlanner().plan(
                commandID: "touch.drag",
                rawArguments: [
                    "durationMs": fixture.durationMs,
                    "from": fixture.from,
                    "to": fixture.to,
                ]
            )
            XCTAssertEqual(plan.frames.count, fixture.expectedFrameCount)
            XCTAssertEqual(plan.frames.first?.kind, .begin)
            XCTAssertEqual(plan.frames.last?.kind, .end)
            XCTAssertEqual(plan.frames.first?.sequence, 0)
            XCTAssertEqual(
                plan.frames.last?.elapsedMilliseconds,
                UInt64(fixture.durationMs)
            )
            XCTAssertLessThanOrEqual(plan.frames.count, 4_096)
            XCTAssertLessThanOrEqual(plan.encodedPayload.count, 512 * 1_024)
            if let expected = fixture.expectedMiddle {
                let middle = try XCTUnwrap(plan.frames.dropFirst().first)
                XCTAssertEqual("\(middle.point.x),\(middle.point.y)", expected)
            }
            _ = try RepositoryCanonicalJSON.parseDocument(
                plan.encodedPayload,
                maximumByteCount: 512 * 1_024
            )
        }
    }

    func testInvalidArgumentsAndAdmissionCapsFailBeforePlanDelivery() {
        XCTAssertThrowsError(try LinearGesturePlanner().plan(
            commandID: "touch.drag",
            rawArguments: [
                "durationMs": "0",
                "from": "0,0",
                "to": "1,1",
            ]
        )) { error in
            XCTAssertEqual(error as? LinearGesturePlannerError, .invalidArguments)
        }

        let frameLimited = LinearGesturePlanner(limits: LinearGestureLimits(
            maximumFrames: 2
        ))
        XCTAssertThrowsError(try frameLimited.plan(
            commandID: "touch.drag",
            rawArguments: arguments()
        )) { error in
            XCTAssertEqual(
                error as? LinearGesturePlannerError,
                .planTooLarge(maximumFrames: 2, actualFrames: 33)
            )
        }

        let payloadLimited = LinearGesturePlanner(limits: LinearGestureLimits(
            maximumPayloadBytes: 64
        ))
        XCTAssertThrowsError(try payloadLimited.plan(
            commandID: "touch.drag",
            rawArguments: arguments(duration: "1")
        )) { error in
            guard case .payloadTooLarge(let maximum, let actual)? =
                error as? LinearGesturePlannerError
            else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(maximum, 64)
            XCTAssertGreaterThan(actual, maximum)
        }
    }

    func testDragAndSwipeShareFramesButPreserveCommandIdentity() throws {
        let planner = LinearGesturePlanner()
        let drag = try planner.plan(
            commandID: "touch.drag",
            rawArguments: arguments(duration: "32")
        )
        let swipe = try planner.plan(
            commandID: "touch.swipe",
            rawArguments: arguments(duration: "32")
        )
        XCTAssertEqual(drag.frames, swipe.frames)
        XCTAssertNotEqual(drag.encodedPayload, swipe.encodedPayload)

        let dragTransport = RecordingLinearGestureTransport()
        let dragExecution = try DragAction(transport: dragTransport).execute(
            request(plan: drag)
        )
        XCTAssertEqual(dragExecution.semanticLog.commandID, "touch.drag")
        XCTAssertEqual(dragExecution.semanticLog.routeID, "coredevice.normalTouch")
        XCTAssertEqual(dragTransport.frameKinds, [.begin, .move, .end])

        let swipeTransport = RecordingLinearGestureTransport()
        let swipeExecution = try SwipeAction(transport: swipeTransport).execute(
            request(plan: swipe)
        )
        XCTAssertEqual(swipeExecution.semanticLog.commandID, "touch.swipe")
        XCTAssertEqual(swipeTransport.frameKinds, [.begin, .move, .end])
    }

    func testGeometryMismatchAndCommandMismatchDoNotTouchTransport() throws {
        let plan = try LinearGesturePlanner().plan(
            commandID: "touch.drag",
            rawArguments: arguments(duration: "32")
        )
        let transport = RecordingLinearGestureTransport()
        let mismatch = LinearGestureExecutionRequest(
            plan: plan,
            expectedGeometry: GeometryAssertionDTO(
                expectedConnectionEpoch: 9,
                expectedGeometryRevision: 3
            ),
            currentGeometry: try geometry()
        )
        XCTAssertThrowsError(try DragAction(transport: transport).execute(mismatch)) {
            XCTAssertEqual(
                $0 as? GeometryDTOValidationError,
                .connectionEpochMismatch(expected: 9, actual: 8)
            )
        }
        XCTAssertTrue(transport.events.isEmpty)

        XCTAssertThrowsError(try SwipeAction(transport: transport).execute(
            request(plan: plan)
        )) { error in
            XCTAssertEqual(
                error as? LinearGestureActionError,
                .commandMismatch
            )
        }
        XCTAssertTrue(transport.events.isEmpty)
    }

    func testPostBeginFailureSendsEndAndWaitsForCleanupOnce() throws {
        let plan = try LinearGesturePlanner().plan(
            commandID: "touch.drag",
            rawArguments: arguments(duration: "32")
        )
        let transport = RecordingLinearGestureTransport(failSequence: 1)
        XCTAssertThrowsError(try DragAction(transport: transport).execute(
            request(plan: plan)
        )) { error in
            XCTAssertEqual(
                error as? LinearGestureActionError,
                .transportFailure
            )
        }
        XCTAssertEqual(transport.frameKinds, [.begin, .move, .end])
        XCTAssertEqual(transport.cleanupCount, 1)
    }

    func testCLIDragAndSwipeSubmitCanonicalArguments() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let drag = try DragCommand(submitter: CommandSubmitter(runtime:
            LinearGestureRuntime(commandID: "touch.drag")
        )).run(
            from: "0.1,0.2",
            to: "0.9,0.8",
            durationMilliseconds: "032",
            requestID: uuid(1),
            actionID: uuid(2),
            canonicalUDID: target,
            outputMode: .human
        )
        XCTAssertEqual(drag.exitCode, 0)
        XCTAssertEqual(
            drag.chunk.stdout,
            ["Dragged from 0.1,0.2 to 0.9,0.8 in 32 ms"]
        )

        let swipe = try SwipeCommand(submitter: CommandSubmitter(runtime:
            LinearGestureRuntime(commandID: "touch.swipe")
        )).run(
            from: "0.1,0.2",
            to: "0.9,0.8",
            durationMilliseconds: "32",
            requestID: uuid(3),
            actionID: uuid(4),
            canonicalUDID: target,
            outputMode: .json
        )
        XCTAssertEqual(swipe.exitCode, 0)
        XCTAssertTrue(swipe.chunk.stdout[0].contains("\"disposition\":\"acknowledged\""))
    }

    private func arguments(duration: String = "500") -> [String: String] {
        [
            "durationMs": duration,
            "from": "0.1,0.2",
            "to": "0.9,0.8",
        ]
    }

    private func request(
        plan: LinearGesturePlan
    ) -> LinearGestureExecutionRequest {
        LinearGestureExecutionRequest(
            plan: plan,
            expectedGeometry: GeometryAssertionDTO(
                expectedConnectionEpoch: 8,
                expectedGeometryRevision: 3
            ),
            currentGeometry: try! geometry()
        )
    }

    private func geometry() throws -> DisplayGeometryDTO {
        try DisplayGeometryDTO(
            connectionEpoch: 8,
            geometryRevision: 3,
            logicalHeight: 2_556,
            logicalWidth: 1_179,
            orientation: .portrait
        )
    }

    private func loadFixtures() throws -> [LinearGestureFixture] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/product-actions/linear-gesture/cases.v1.json")
        let bytes = [UInt8](try Data(contentsOf: url))
        _ = try RepositoryCanonicalJSON.parseDocument(
            bytes,
            maximumByteCount: 64 * 1_024
        )
        return try JSONDecoder().decode(
            LinearGestureFixtureDocument.self,
            from: Data(bytes)
        ).cases
    }

    private func uuid(_ value: Int) throws -> CanonicalUUID {
        try CanonicalUUID(
            String(format: "00000000-0000-0000-0000-%012x", value)
        )
    }
}

private struct LinearGestureFixtureDocument: Decodable {
    let cases: [LinearGestureFixture]
    let schemaVersion: Int
}

private struct LinearGestureFixture: Decodable {
    let caseID: String
    let durationMs: String
    let expectedFrameCount: Int
    let expectedMiddle: String?
    let from: String
    let to: String
}

private enum LinearGestureTransportEvent: Equatable {
    case cleanup
    case frame(LinearGestureFrameKind)
}

private final class RecordingLinearGestureTransport: LinearGestureTransport,
    @unchecked Sendable
{
    private(set) var events = [LinearGestureTransportEvent]()
    private let failSequence: UInt64?

    init(failSequence: UInt64? = nil) {
        self.failSequence = failSequence
    }

    var cleanupCount: Int {
        events.filter { $0 == .cleanup }.count
    }

    var frameKinds: [LinearGestureFrameKind] {
        events.compactMap {
            guard case .frame(let kind) = $0 else { return nil }
            return kind
        }
    }

    func sendFrame(_ frame: LinearGestureFrame) throws {
        events.append(.frame(frame.kind))
        if frame.sequence == failSequence {
            throw LinearGestureActionError.transportFailure
        }
    }

    func waitForCleanupAcknowledgement(
        timeoutMilliseconds: UInt64
    ) throws {
        XCTAssertEqual(timeoutMilliseconds, 2_000)
        events.append(.cleanup)
    }
}

private struct LinearGestureRuntime: CommandSubmissionRuntime {
    let commandID: String

    func submit(
        _ intent: CommandSubmissionIntent
    ) throws -> [CommandSubmissionEvent] {
        XCTAssertEqual(intent.commandID, commandID)
        XCTAssertEqual(intent.rawArguments, [
            "durationMs": "32",
            "from": "0.1,0.2",
            "to": "0.9,0.8",
        ])
        let terminal = try CommandSubmissionTerminal(
            outcome: .succeeded,
            commitState: .committed,
            routeID: "coredevice.normalTouch"
        )
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
