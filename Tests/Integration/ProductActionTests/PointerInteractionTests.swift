import Foundation
import PulsePhoneBackendAdapters
import PulsePhoneCommandPlanner
import PulsePhoneGUI
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions
import XCTest

final class PointerInteractionTests: XCTestCase {
    func testControllerEdgeSlopSnapAndFixtureConstants() throws {
        let expected = try loadFixture()
        XCTAssertEqual(
            PointerInteractionController.edgeSlopPoints,
            expected.edgeSlopPoints
        )
        XCTAssertEqual(
            PointerInteractionController.edgeSnapPoints,
            expected.edgeSnapPoints
        )
        XCTAssertEqual(PointerStreamAction.absoluteMaximumMilliseconds, 30_000)
        XCTAssertEqual(PointerStreamAction.cleanupMilliseconds, 2_000)
        let plan = try PointerStreamAction.bufferPlan()
        XCTAssertEqual(plan.maximumOpeningFrames, 3)
        XCTAssertEqual(plan.maximumOrderedFrames, 64)
        XCTAssertEqual(plan.maximumOrderedBytes, 256 * 1_024)

        let rect = PointerVisibleImageRect(x: 0, y: 0, width: 100, height: 100)
        for sample in expected.samples {
            var controller = PointerInteractionController()
            let frame = try controller.begin(
                at: PointerViewPoint(x: sample.point.x, y: sample.point.y),
                visibleImageRect: rect,
                geometry: geometry()
            )
            XCTAssertEqual(frame.edge.rawValue, sample.edge)
            XCTAssertEqual(frame.point.x, sample.result.x)
            XCTAssertEqual(frame.point.y, sample.result.y)
        }

        let outsidePoints = [
            PointerViewPoint(x: -29, y: 50),
            PointerViewPoint(x: 129, y: 50),
            PointerViewPoint(x: 50, y: -29),
            PointerViewPoint(x: 50, y: 129),
        ]
        for point in outsidePoints {
            var outside = PointerInteractionController()
            XCTAssertThrowsError(try outside.begin(
                at: point,
                visibleImageRect: rect,
                geometry: geometry()
            )) { error in
                XCTAssertEqual(
                    error as? PointerInteractionControllerError,
                    .outsideInteractionRegion
                )
            }
            XCTAssertFalse(outside.isActive)
        }
    }

    func testOpeningRetainsBeginLatestMoveEndAndClosesAfterAck() throws {
        let transport = RecordingPointerTransport()
        var backend = try makeBackend(transport: transport)
        try beginOpening(&backend)
        var controller = PointerInteractionController()
        let rect = PointerVisibleImageRect(x: 0, y: 0, width: 100, height: 100)
        let frames = [
            try controller.begin(
                at: PointerViewPoint(x: 50, y: 50),
                visibleImageRect: rect,
                geometry: geometry()
            ),
            try controller.move(
                to: PointerViewPoint(x: 60, y: 50),
                visibleImageRect: rect
            ),
            try controller.move(
                to: PointerViewPoint(x: 70, y: 50),
                visibleImageRect: rect
            ),
            try controller.end(
                at: PointerViewPoint(x: 80, y: 50),
                visibleImageRect: rect
            ),
        ]
        for frame in frames {
            try backend.submit(input(frame))
        }
        XCTAssertEqual(backend.snapshot.buffer.pendingFrameCount, 3)
        try backend.completeOpen()
        let delivered = try backend.drainAvailableFrames(
            atMonotonicNanoseconds: 100
        )
        XCTAssertEqual(delivered.map(\.sequence), [0, 2, 3])
        XCTAssertEqual(delivered.map(\.kind), [.begin, .move, .end])
        XCTAssertEqual(delivered[0].x, 32_768)
        XCTAssertEqual(delivered[1].x, 45_875)
        XCTAssertEqual(delivered[2].x, 52_428)
        let response = try backend.finish(requestID: uuid(20))
        XCTAssertEqual(response.disposition, .closed)
        XCTAssertEqual(response.terminal.terminalBundle.outcome, .succeeded)
        XCTAssertEqual(response.terminal.lastAcceptedSequence, 3)
        XCTAssertEqual(transport.cleanupCount, 1)
        XCTAssertEqual(PointerStreamAction.routeID, "coredevice.pointerStream")
        XCTAssertEqual(PointerStreamAction.preparationGroupID, "prep.coredevice.v2")
    }

    func testAcceptedDeliveryTelemetryUsesFrozenMonotonicBoundaries() throws {
        let observer = RecordingAcceptedDeliveryObserver()
        let transport = RecordingPointerTransport(
            acceptedMonotonicNanoseconds: 175
        )
        var backend = try makeBackend(
            transport: transport,
            acceptedDeliveryObserver: observer
        )
        try beginOpening(&backend)
        try backend.completeOpen()
        var controller = PointerInteractionController()
        try backend.submit(
            input(controller.begin(
                at: PointerViewPoint(x: 50, y: 50),
                visibleImageRect: PointerVisibleImageRect(
                    x: 0,
                    y: 0,
                    width: 100,
                    height: 100
                ),
                geometry: geometry()
            )),
            clientSubmittedMonotonicNanoseconds: 125
        )

        _ = try backend.drainAvailableFrames(atMonotonicNanoseconds: 150)

        XCTAssertEqual(observer.observations, [
            PointerAcceptedDeliveryObservation(
                sessionID: try uuid(3),
                interactionID: try uuid(4),
                sequence: 0,
                frameKind: .begin,
                expectedConnectionEpoch: 8,
                expectedGeometryRevision: 3,
                clientSubmittedMonotonicNanoseconds: 125,
                acceptedMonotonicNanoseconds: 175
            ),
        ])
        XCTAssertEqual(backend.snapshot.buffer.lastAcceptedSequence, 0)
    }

    func testUnconfirmedDeliveryDoesNotPublishAcceptedTelemetry() throws {
        let observer = RecordingAcceptedDeliveryObserver()
        let transport = RecordingPointerTransport(acceptsFrames: false)
        var backend = try makeBackend(
            transport: transport,
            acceptedDeliveryObserver: observer
        )
        try beginOpening(&backend)
        try backend.completeOpen()
        var controller = PointerInteractionController()
        try backend.submit(
            input(controller.begin(
                at: PointerViewPoint(x: 50, y: 50),
                visibleImageRect: PointerVisibleImageRect(
                    x: 0,
                    y: 0,
                    width: 100,
                    height: 100
                ),
                geometry: geometry()
            )),
            clientSubmittedMonotonicNanoseconds: 125
        )

        _ = try backend.drainAvailableFrames(atMonotonicNanoseconds: 150)

        XCTAssertTrue(observer.observations.isEmpty)
        XCTAssertNil(backend.snapshot.buffer.lastAcceptedSequence)
    }

    func testLatestMoveTelemetryUsesOnlyDeliveredSubmission() throws {
        let observer = RecordingAcceptedDeliveryObserver()
        let transport = RecordingPointerTransport(
            acceptedMonotonicNanoseconds: 200
        )
        var backend = try makeBackend(
            transport: transport,
            acceptedDeliveryObserver: observer
        )
        try beginOpening(&backend)
        var controller = PointerInteractionController()
        let rect = PointerVisibleImageRect(x: 0, y: 0, width: 100, height: 100)
        try backend.submit(
            input(controller.begin(
                at: PointerViewPoint(x: 50, y: 50),
                visibleImageRect: rect,
                geometry: geometry()
            )),
            clientSubmittedMonotonicNanoseconds: 100
        )
        try backend.submit(
            input(controller.move(
                to: PointerViewPoint(x: 60, y: 50),
                visibleImageRect: rect
            )),
            clientSubmittedMonotonicNanoseconds: 110
        )
        try backend.submit(
            input(controller.move(
                to: PointerViewPoint(x: 70, y: 50),
                visibleImageRect: rect
            )),
            clientSubmittedMonotonicNanoseconds: 120
        )
        try backend.completeOpen()

        let delivered = try backend.drainAvailableFrames(
            atMonotonicNanoseconds: 150
        )

        XCTAssertEqual(delivered.map(\.sequence), [0, 2])
        XCTAssertEqual(observer.observations.map(\.sequence), [0, 2])
        XCTAssertEqual(
            observer.observations.map(\.clientSubmittedMonotonicNanoseconds),
            [100, 120]
        )
    }

    func testGeometryRevisionChangeProducesOrderedCancelAndCleanup() throws {
        let transport = RecordingPointerTransport()
        var backend = try makeBackend(transport: transport)
        try beginOpening(&backend)
        try backend.completeOpen()
        var controller = PointerInteractionController()
        let rect = PointerVisibleImageRect(x: 0, y: 0, width: 100, height: 100)
        try backend.submit(input(controller.begin(
            at: PointerViewPoint(x: 50, y: 50),
            visibleImageRect: rect,
            geometry: geometry()
        )))
        _ = try backend.drainAvailableFrames(atMonotonicNanoseconds: 0)

        let changed = try geometry(revision: 4)
        let cancel = try XCTUnwrap(controller.geometryDidChange(to: changed))
        XCTAssertEqual(cancel.kind, .cancel)
        XCTAssertEqual(cancel.sequence, 1)
        XCTAssertFalse(controller.isActive)
        XCTAssertNil(try controller.geometryDidChange(to: changed))
        backend.updateGeometry(changed)
        try backend.submit(input(cancel))
        let delivered = try backend.drainAvailableFrames(
            atMonotonicNanoseconds: 1
        )
        XCTAssertEqual(delivered.map(\.kind), [.cancel])
        let response = try backend.finish(requestID: uuid(21))
        XCTAssertEqual(response.disposition, .cancelled)
        XCTAssertEqual(response.terminal.terminalBundle.outcome, .cancelled)
        XCTAssertEqual(transport.cleanupCount, 1)
    }

    func testSlowFrameAckWatchdogCancelsAndFencesOnce() throws {
        let transport = RecordingPointerTransport(
            acceptsFrames: false,
            cleanupDisposition: .fenced
        )
        var backend = try makeBackend(transport: transport)
        try beginOpening(&backend)
        try backend.completeOpen()
        var controller = PointerInteractionController()
        try backend.submit(input(controller.begin(
            at: PointerViewPoint(x: 50, y: 50),
            visibleImageRect: PointerVisibleImageRect(
                x: 0,
                y: 0,
                width: 100,
                height: 100
            ),
            geometry: geometry()
        )))
        _ = try backend.drainAvailableFrames(atMonotonicNanoseconds: 10)
        XCTAssertNil(try backend.evaluateFrameAcceptedWatchdog(
            atMonotonicNanoseconds: 10
                + StreamSessionPlan.frameAcceptedWatchdogNanoseconds - 1
        ))
        let terminal = try XCTUnwrap(backend.evaluateFrameAcceptedWatchdog(
            atMonotonicNanoseconds: 10
                + StreamSessionPlan.frameAcceptedWatchdogNanoseconds
        ))
        XCTAssertEqual(terminal.cleanupDisposition, .fenced)
        XCTAssertEqual(terminal.closingCause, .deadlineExceeded)
        XCTAssertEqual(terminal.terminalBundle.outcome, .cancelled)
        XCTAssertEqual(transport.cleanupCount, 1)
        XCTAssertNil(try backend.evaluateFrameAcceptedWatchdog(
            atMonotonicNanoseconds: UInt64.max
        ))
        XCTAssertEqual(transport.cleanupCount, 1)
    }

    func testFrameOrderAndGeometryFailBeforeTransport() throws {
        let orderTransport = RecordingPointerTransport()
        var orderBackend = try makeBackend(transport: orderTransport)
        try beginOpening(&orderBackend)
        let assertion = GeometryAssertionDTO(
            expectedConnectionEpoch: 8,
            expectedGeometryRevision: 3
        )
        XCTAssertThrowsError(try orderBackend.submit(PointerStreamInputFrame(
            sequence: 0,
            kind: .move,
            point: NormalizedPointV1(x: "0.5", y: "0.5"),
            edge: .none,
            expectedGeometry: assertion
        ))) { error in
            XCTAssertEqual(error as? PointerStreamError, .invalidFrameOrder)
        }
        XCTAssertEqual(orderTransport.cleanupCount, 1)
        XCTAssertFalse(orderTransport.events.contains { event in
            if case .send = event { return true }
            return false
        })

        let geometryTransport = RecordingPointerTransport()
        var geometryBackend = try makeBackend(transport: geometryTransport)
        try beginOpening(&geometryBackend)
        XCTAssertThrowsError(try geometryBackend.submit(PointerStreamInputFrame(
            sequence: 0,
            kind: .begin,
            point: NormalizedPointV1(x: "0.5", y: "0.5"),
            edge: .none,
            expectedGeometry: GeometryAssertionDTO(
                expectedConnectionEpoch: 8,
                expectedGeometryRevision: 2
            )
        ))) { error in
            XCTAssertEqual(
                error as? GeometryDTOValidationError,
                .geometryRevisionMismatch(expected: 2, actual: 3)
            )
        }
        XCTAssertEqual(geometryTransport.cleanupCount, 1)
        XCTAssertFalse(geometryTransport.events.contains { event in
            if case .send = event { return true }
            return false
        })

        let coordinateTransport = RecordingPointerTransport()
        var coordinateBackend = try makeBackend(transport: coordinateTransport)
        try beginOpening(&coordinateBackend)
        XCTAssertThrowsError(try coordinateBackend.submit(PointerStreamInputFrame(
            sequence: 0,
            kind: .begin,
            point: NormalizedPointV1(x: "1.50", y: "0.5"),
            edge: .none,
            expectedGeometry: assertion
        ))) { error in
            XCTAssertEqual(error as? PointerStreamError, .invalidCoordinate)
        }
        XCTAssertEqual(coordinateTransport.cleanupCount, 1)
    }

    func testTransportSendFailureCancelsAndCleansSession() throws {
        let transport = RecordingPointerTransport(failSend: true)
        var backend = try makeBackend(transport: transport)
        try beginOpening(&backend)
        try backend.completeOpen()
        var controller = PointerInteractionController()
        try backend.submit(input(controller.begin(
            at: PointerViewPoint(x: 50, y: 50),
            visibleImageRect: PointerVisibleImageRect(
                x: 0,
                y: 0,
                width: 100,
                height: 100
            ),
            geometry: geometry()
        )))
        XCTAssertThrowsError(try backend.drainAvailableFrames(
            atMonotonicNanoseconds: 0
        )) { error in
            XCTAssertEqual(error as? PointerStreamError, .transportFailure)
        }
        XCTAssertEqual(transport.cleanupCount, 1)
        XCTAssertEqual(backend.snapshot.lifecycle.phase, .terminal)
        XCTAssertEqual(
            backend.snapshot.terminal?.terminalBundle.outcome,
            .outcomeUnknown
        )
    }

    private func makeBackend(
        transport: RecordingPointerTransport,
        acceptedDeliveryObserver: (any PointerAcceptedDeliveryObserver)? = nil
    ) throws -> PointerStreamAction {
        try PointerStreamAction(
            openRequestID: uuid(1),
            actionID: uuid(2),
            sessionID: uuid(3),
            interactionID: uuid(4),
            currentGeometry: geometry(),
            transport: transport,
            acceptedDeliveryObserver: acceptedDeliveryObserver
        )
    }

    private func beginOpening(_ backend: inout PointerStreamAction) throws {
        try backend.beginOpening(
            inhibitorTokenID: "inhibitor.pointer.test",
            bindings: OperationRuntimeBindings(
                attemptID: "attempt.pointer.test",
                executorGeneration: 1,
                leaseIDs: [
                    "lease.app-state",
                    "lease.display-geometry",
                    "lease.input-channel",
                    "lease.input-touch",
                ]
            )
        )
    }

    private func input(
        _ frame: PointerInteractionFrame
    ) throws -> PointerStreamInputFrame {
        PointerStreamInputFrame(
            sequence: frame.sequence,
            kind: try XCTUnwrap(PointerStreamFrameKind(
                rawValue: frame.kind.rawValue
            )),
            point: frame.point,
            edge: try XCTUnwrap(PointerStreamEdge(
                rawValue: frame.edge.rawValue
            )),
            expectedGeometry: frame.expectedGeometry
        )
    }

    private func geometry(
        revision: UInt64 = 3
    ) throws -> DisplayGeometryDTO {
        try DisplayGeometryDTO(
            connectionEpoch: 8,
            geometryRevision: revision,
            logicalHeight: 2_556,
            logicalWidth: 1_179,
            orientation: .portrait
        )
    }

    private func uuid(_ value: Int) throws -> CanonicalUUID {
        try CanonicalUUID(String(
            format: "00000000-0000-0000-0000-%012x",
            value
        ))
    }

    private func loadFixture() throws -> PointerInteractionFixture {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try JSONDecoder().decode(
            PointerInteractionFixture.self,
            from: Data(contentsOf: root.appendingPathComponent(
                "Fixtures/product-actions/pointer-interaction/cases.v1.json"
            ))
        )
    }
}

private struct PointerInteractionFixture: Decodable {
    struct Sample: Decodable {
        struct Point: Decodable { let x: Double; let y: Double }
        struct Result: Decodable { let x: String; let y: String }
        let edge: String
        let point: Point
        let result: Result
    }

    let edgeSlopPoints: Double
    let edgeSnapPoints: Double
    let samples: [Sample]
}

private enum PointerTransportEvent: Equatable {
    case cleanup(timeoutMilliseconds: UInt64)
    case open(routeID: String)
    case send(sequence: UInt64, kind: PointerStreamFrameKind)
}

private final class RecordingPointerTransport: PointerStreamTransport,
    @unchecked Sendable
{
    private let acceptedMonotonicNanoseconds: UInt64?
    private let acceptsFrames: Bool
    private let cleanupDisposition: OperationCleanupDisposition
    private let failSend: Bool
    private(set) var cleanupCount = 0
    private(set) var events = [PointerTransportEvent]()

    init(
        acceptsFrames: Bool = true,
        acceptedMonotonicNanoseconds: UInt64? = nil,
        cleanupDisposition: OperationCleanupDisposition = .acknowledged,
        failSend: Bool = false
    ) {
        self.acceptsFrames = acceptsFrames
        self.acceptedMonotonicNanoseconds = acceptedMonotonicNanoseconds
        self.cleanupDisposition = cleanupDisposition
        self.failSend = failSend
    }

    func open(
        sessionID: CanonicalUUID,
        interactionID: CanonicalUUID,
        routeID: String
    ) throws {
        events.append(.open(routeID: routeID))
    }

    func send(
        frame: PointerDeviceFrame,
        deliveryAttemptID: String
    ) throws -> PointerFrameTransportDisposition {
        events.append(.send(sequence: frame.sequence, kind: frame.kind))
        if failSend {
            throw PointerStreamError.transportFailure
        }
        return acceptsFrames
            ? .accepted(
                acceptedMonotonicNanoseconds: acceptedMonotonicNanoseconds
            )
            : .unconfirmed
    }

    func cancelAndClean(
        timeoutMilliseconds: UInt64
    ) throws -> OperationCleanupDisposition {
        cleanupCount += 1
        events.append(.cleanup(timeoutMilliseconds: timeoutMilliseconds))
        return cleanupDisposition
    }
}

private final class RecordingAcceptedDeliveryObserver:
    PointerAcceptedDeliveryObserver,
    @unchecked Sendable
{
    private(set) var observations = [PointerAcceptedDeliveryObservation]()

    func recordAcceptedDelivery(
        _ observation: PointerAcceptedDeliveryObservation
    ) {
        observations.append(observation)
    }
}
