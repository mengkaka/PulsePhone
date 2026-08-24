import AppKit
import Foundation
@testable import PulsePhoneGUI
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions
import XCTest

final class RuntimeObservationTests: XCTestCase {
    func testAcceptedPointerTelemetryBufferDrainsExactIdentityAndTimestamps() throws {
        let buffer = try RuntimePointerDeliveryTelemetryBuffer()
        let complete = RuntimeAcceptedPointerDeliveryTelemetry(
            sessionID: try uuid(1),
            interactionID: try uuid(2),
            sequence: 3,
            frameKind: .move,
            connectionEpoch: 4,
            geometryRevision: 5,
            clientSubmittedMonotonicNanoseconds: 100,
            acceptedMonotonicNanoseconds: 175
        )
        let missingTimestamp = RuntimeAcceptedPointerDeliveryTelemetry(
            sessionID: try uuid(6),
            interactionID: try uuid(7),
            sequence: 8,
            frameKind: .end,
            connectionEpoch: 9,
            geometryRevision: 10,
            clientSubmittedMonotonicNanoseconds: nil,
            acceptedMonotonicNanoseconds: 200
        )
        buffer.record(complete)
        buffer.record(missingTimestamp)

        let batch = buffer.drain()

        XCTAssertEqual(batch.droppedObservationCount, 0)
        XCTAssertEqual(batch.observations, [complete, missingTimestamp])
        XCTAssertEqual(buffer.queuedObservationCount, 0)
        let empty = buffer.drain()
        XCTAssertEqual(empty.droppedObservationCount, 0)
        XCTAssertTrue(empty.observations.isEmpty)
    }

    func testAcceptedPointerTelemetrySaturationNeverBackpressuresPublisher() throws {
        let buffer = try RuntimePointerDeliveryTelemetryBuffer(
            maximumObservations: 1
        )
        let first = RuntimeAcceptedPointerDeliveryTelemetry(
            sessionID: try uuid(11),
            interactionID: try uuid(12),
            sequence: 0,
            frameKind: .begin,
            connectionEpoch: 13,
            geometryRevision: 14,
            clientSubmittedMonotonicNanoseconds: 100,
            acceptedMonotonicNanoseconds: 110
        )
        let dropped = RuntimeAcceptedPointerDeliveryTelemetry(
            sessionID: try uuid(11),
            interactionID: try uuid(12),
            sequence: 1,
            frameKind: .move,
            connectionEpoch: 13,
            geometryRevision: 14,
            clientSubmittedMonotonicNanoseconds: 120,
            acceptedMonotonicNanoseconds: 130
        )
        buffer.record(first)
        buffer.record(dropped)

        let batch = buffer.drain()

        XCTAssertEqual(batch.observations, [first])
        XCTAssertEqual(batch.droppedObservationCount, 1)
        XCTAssertEqual(buffer.queuedObservationCount, 0)
    }

    func testAcceptedPointerTelemetryCapacityIsBounded() throws {
        XCTAssertThrowsError(try RuntimePointerDeliveryTelemetryBuffer(
            maximumObservations: 0
        )) { error in
            XCTAssertEqual(
                error as? RuntimeObservationError,
                .invalidCapacity
            )
        }
        XCTAssertThrowsError(try RuntimePointerDeliveryTelemetryBuffer(
            maximumObservations:
                RuntimePointerDeliveryTelemetryBuffer.hardMaximumObservations
                + 1
        )) { error in
            XCTAssertEqual(
                error as? RuntimeObservationError,
                .invalidCapacity
            )
        }
    }

    func testAcceptedBoundaryAndSlowSubscriberDoNotBackpressurePublisher() throws {
        var publisher = try RuntimeObservationPublisher(
            maximumFrames: 2,
            maximumBytes: RuntimeObservationPublisher.hardMaximumBytes
        )
        let slow = try uuid(10)
        let fast = try uuid(11)
        try publisher.attach(clientInstanceID: uuid(1), subscriptionID: slow)
        try publisher.attach(clientInstanceID: uuid(2), subscriptionID: fast)

        let submitted = try publisher.publishPointerProjection(
            deliveryBoundary: .submitted,
            clientInstanceID: uuid(1),
            interactionID: uuid(20),
            projection: projection("0.1")
        )
        XCTAssertFalse(submitted.eligible)
        XCTAssertEqual(submitted.enqueuedSubscriberCount, 0)

        for index in 0..<2 {
            let report = try publisher.publishPointerProjection(
                deliveryBoundary: .acceptedForDelivery,
                clientInstanceID: uuid(1),
                interactionID: uuid(20 + index),
                projection: projection("0.\(index + 2)")
            )
            XCTAssertEqual(report.enqueuedSubscriberCount, 2)
            XCTAssertEqual(
                try publisher.drain(subscriptionID: fast).observations.count,
                1
            )
        }
        let saturated = try publisher.publishPointerProjection(
            deliveryBoundary: .acceptedForDelivery,
            clientInstanceID: uuid(1),
            interactionID: uuid(30),
            projection: projection("0.8")
        )
        XCTAssertEqual(saturated.resetSubscriberCount, 1)
        XCTAssertEqual(saturated.enqueuedSubscriberCount, 1)
        XCTAssertEqual(publisher.subscriberCount, 2)

        let disconnected = try publisher.publishPointerProjection(
            deliveryBoundary: .acceptedForDelivery,
            clientInstanceID: uuid(1),
            interactionID: uuid(31),
            projection: projection("0.9")
        )
        XCTAssertEqual(disconnected.disconnectedSubscriberCount, 1)
        XCTAssertEqual(disconnected.enqueuedSubscriberCount, 1)
        XCTAssertEqual(publisher.subscriberCount, 1)
    }

    func testObservationStreamStopBarrierFixture() throws {
        let fixture = try loadFixture()
        let expected = try loadExpected()
        var publisher = try RuntimeObservationPublisher(
            maximumFrames: fixture.maximumFrames,
            maximumBytes: fixture.maximumBytes
        )
        let subscriptionID = try uuid(40)
        try publisher.attach(
            clientInstanceID: uuid(41),
            subscriptionID: subscriptionID
        )
        let submitted = try publisher.publishPointerProjection(
            deliveryBoundary: .submitted,
            clientInstanceID: uuid(41),
            interactionID: uuid(42),
            projection: projection("0.1")
        )
        XCTAssertEqual(
            submitted.enqueuedSubscriberCount,
            expected.submittedProjectionCount
        )
        for index in 0..<fixture.acceptedBeforeReset {
            _ = try publisher.publishPointerProjection(
                deliveryBoundary: .acceptedForDelivery,
                clientInstanceID: uuid(41),
                interactionID: uuid(50 + index),
                projection: projection("0.2")
            )
        }
        let saturated = try publisher.publishPointerProjection(
            deliveryBoundary: .acceptedForDelivery,
            clientInstanceID: uuid(41),
            interactionID: uuid(60),
            projection: projection("0.3")
        )
        XCTAssertEqual(saturated.resetSubscriberCount, 1)
        let reset = try XCTUnwrap(
            publisher.drain(subscriptionID: subscriptionID).reset
        )
        XCTAssertEqual(reset.nextSequence, expected.resetNextSequence)

        _ = try publisher.publishPointerProjection(
            deliveryBoundary: .acceptedForDelivery,
            clientInstanceID: uuid(41),
            interactionID: uuid(61),
            projection: projection("0.4")
        )
        let resumed = try publisher.drain(subscriptionID: subscriptionID)
        XCTAssertEqual(
            resumed.observations.map(\.observationSequence),
            [expected.resumedSequence]
        )
        let stopped = try publisher.stop(subscriptionID: subscriptionID)
        XCTAssertEqual(stopped.nextSequence, expected.stopNextSequence)
        let afterStop = try publisher.publishPointerProjection(
            deliveryBoundary: .acceptedForDelivery,
            clientInstanceID: uuid(41),
            interactionID: uuid(62),
            projection: projection("0.5")
        )
        XCTAssertEqual(
            afterStop.enqueuedSubscriberCount,
            expected.projectionsAfterStop
        )
        XCTAssertEqual(publisher.subscriberCount, 0)
    }

    func testOverlayDeduplicatesLocalEchoAndResetsForGap() throws {
        let client = try uuid(70)
        let interaction = try uuid(71)
        let subscription = try uuid(72)
        var overlay = InputObservationOverlay()
        overlay.showOptimistic(
            clientInstanceID: client,
            interactionID: interaction,
            projection: projection("0.1")
        )
        XCTAssertEqual(overlay.entryCount, 1)
        let echo = RuntimeObservation(
            subscriptionID: subscription,
            clientInstanceID: client,
            interactionID: interaction,
            observationSequence: 0,
            presentationPayload: projection("0.2")
        )
        XCTAssertEqual(
            overlay.receive(observation: echo),
            .deduplicatedEcho
        )
        XCTAssertEqual(overlay.entryCount, 1)
        XCTAssertEqual(
            overlay.entry(
                clientInstanceID: client,
                interactionID: interaction
            )?.source,
            .optimistic
        )

        let gap = RuntimeObservation(
            subscriptionID: subscription,
            clientInstanceID: client,
            interactionID: try uuid(73),
            observationSequence: 3,
            presentationPayload: projection("0.3")
        )
        XCTAssertEqual(
            overlay.receive(observation: gap),
            .resetForSequenceGap
        )
        XCTAssertEqual(overlay.entryCount, 1)
        XCTAssertEqual(
            overlay.receive(observation: echo),
            .ignoredStale
        )
        overlay.applyReset(ObservationStreamReset(
            subscriptionID: subscription,
            nextSequence: 4,
            reason: "queueSaturated"
        ))
        XCTAssertEqual(overlay.entryCount, 0)
        overlay.stop(subscriptionID: subscription)
        XCTAssertEqual(overlay.entryCount, 0)
    }

    func testQueueResetCanResumeAfterResetIsDrained() throws {
        var publisher = try RuntimeObservationPublisher(
            maximumFrames: 1,
            maximumBytes: RuntimeObservationPublisher.hardMaximumBytes
        )
        let subscription = try uuid(80)
        try publisher.attach(
            clientInstanceID: uuid(81),
            subscriptionID: subscription
        )
        _ = try publisher.publishPointerProjection(
            deliveryBoundary: .acceptedForDelivery,
            clientInstanceID: uuid(81),
            interactionID: uuid(82),
            projection: projection("0.1")
        )
        _ = try publisher.publishPointerProjection(
            deliveryBoundary: .acceptedForDelivery,
            clientInstanceID: uuid(81),
            interactionID: uuid(83),
            projection: projection("0.2")
        )
        let reset = try XCTUnwrap(
            publisher.drain(subscriptionID: subscription).reset
        )
        XCTAssertEqual(reset.nextSequence, 2)
        _ = try publisher.publishPointerProjection(
            deliveryBoundary: .acceptedForDelivery,
            clientInstanceID: uuid(81),
            interactionID: uuid(84),
            projection: projection("0.3")
        )
        let resumed = try publisher.drain(subscriptionID: subscription)
        XCTAssertEqual(resumed.observations.map(\.observationSequence), [2])
    }

    func testMoveCoalescingPreservesBoundariesOriginAndResetSequence() throws {
        var publisher = try RuntimeObservationPublisher(maximumFrames: 4)
        let subscriber = try uuid(85)
        let origin = try uuid(86)
        let interaction = try uuid(87)
        try publisher.attach(
            clientInstanceID: uuid(88),
            subscriptionID: subscriber
        )
        for (kind, x) in [
            (RuntimePointerFrameKind.begin, "0.1"),
            (.move, "0.2"),
            (.move, "0.3"),
            (.end, "0.4"),
        ] {
            let report = try publisher.publishPointerProjection(
                deliveryBoundary: .acceptedForDelivery,
                clientInstanceID: origin,
                interactionID: interaction,
                projection: projection(x, frameKind: kind)
            )
            XCTAssertEqual(
                report.coalescedSubscriberCount,
                kind == .move && x == "0.3" ? 1 : 0
            )
        }
        let batch = try publisher.drain(subscriptionID: subscriber)
        XCTAssertEqual(
            batch.observations.map(\.presentationPayload.frameKind),
            [.begin, .move, .end]
        )
        XCTAssertEqual(
            batch.observations.map(\.presentationPayload.x),
            ["0.1", "0.3", "0.4"]
        )
        XCTAssertEqual(
            batch.observations.map(\.observationSequence),
            [0, 1, 2]
        )
        XCTAssertTrue(batch.observations.allSatisfy {
            $0.clientInstanceID == origin
        })
        let reset = try publisher.reset(
            subscriptionID: subscriber,
            reason: "projectionInvalidated"
        )
        XCTAssertEqual(reset.nextSequence, 3)
        XCTAssertEqual(
            try publisher.drain(subscriptionID: subscriber).reset,
            reset
        )
    }

    func testInvalidProjectionAndDuplicateSubscriptionFailClosed() throws {
        XCTAssertThrowsError(try RuntimeObservationPublisher(
            maximumFrames: 65,
            maximumBytes: 1
        ))
        var publisher = try RuntimeObservationPublisher()
        let subscription = try uuid(90)
        try publisher.attach(
            clientInstanceID: uuid(91),
            subscriptionID: subscription
        )
        XCTAssertThrowsError(try publisher.attach(
            clientInstanceID: uuid(92),
            subscriptionID: subscription
        )) { error in
            XCTAssertEqual(
                error as? RuntimeObservationError,
                .duplicateSubscription
            )
        }
        XCTAssertThrowsError(try publisher.publishPointerProjection(
            deliveryBoundary: .acceptedForDelivery,
            clientInstanceID: uuid(91),
            interactionID: uuid(93),
            projection: RuntimePointerProjection(
                edge: "",
                frameKind: .move,
                x: "0",
                y: "0"
            )
        )) { error in
            XCTAssertEqual(
                error as? RuntimeObservationError,
                .invalidProjection
            )
        }
    }

    @MainActor
    func testInteractionViewMapsNormalizedExternalProjectionAndCancel() {
        let view = ProductionGUIHostInteractionView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 400)
        )
        XCTAssertTrue(view.showPointerOverlay(projection:
            RuntimePointerProjection(
                edge: "none",
                frameKind: .begin,
                x: "0.25",
                y: "0.75"
            )
        ))
        XCTAssertEqual(view.pointerOverlayPoint, NSPoint(x: 50, y: 300))
        XCTAssertFalse(view.showPointerOverlay(projection:
            RuntimePointerProjection(
                edge: "none",
                frameKind: .move,
                x: "1.1",
                y: "0.5"
            )
        ))
        XCTAssertTrue(view.showPointerOverlay(projection:
            RuntimePointerProjection(
                edge: "none",
                frameKind: .cancel,
                x: "0.25",
                y: "0.75"
            )
        ))
        XCTAssertFalse(view.hasPointerOverlay)
    }

    private func projection(
        _ x: String,
        frameKind: RuntimePointerFrameKind = .move
    ) -> RuntimePointerProjection {
        RuntimePointerProjection(
            edge: "none",
            frameKind: frameKind,
            x: x,
            y: "0.5"
        )
    }

    private func uuid(_ value: Int) throws -> CanonicalUUID {
        try CanonicalUUID(String(
            format: "00000000-0000-0000-0000-%012x",
            value
        ))
    }

    private func fixtureURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Fixtures/requirements/T-014/observation-stream-stop-barrier-l3/\(relativePath)"
            )
    }

    private func loadFixture() throws -> ObservationFixture {
        try JSONDecoder().decode(
            ObservationFixture.self,
            from: Data(contentsOf: fixtureURL("input/input.v1.json"))
        )
    }

    private func loadExpected() throws -> ObservationExpected {
        try JSONDecoder().decode(
            ObservationExpected.self,
            from: Data(contentsOf: fixtureURL("expected.v1.json"))
        )
    }
}

private struct ObservationFixture: Decodable {
    let acceptedBeforeReset: Int
    let maximumBytes: Int
    let maximumFrames: Int
}

private struct ObservationExpected: Decodable {
    let projectionsAfterStop: Int
    let resetNextSequence: UInt64
    let resumedSequence: UInt64
    let stopNextSequence: UInt64
    let submittedProjectionCount: Int
}
