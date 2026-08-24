import Darwin
import Foundation
import PulsePhoneBackendAdapters
@testable import PulsePhoneGUI
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions
import XCTest

final class ProductionGUIHostAssemblyTelemetryTests: XCTestCase {
    func testControlReadinessUsesPhysicalPresenceAndMonotonicEpochs() {
        var tracker = ProductionControlReadinessTracker()

        var state = tracker.observe(connected: nil, runtimeReady: true)
        XCTAssertNil(state.connectionEpoch)
        XCTAssertFalse(state.controlReady)

        state = tracker.observe(connected: true, runtimeReady: false)
        XCTAssertEqual(state.connectionEpoch, 1)
        XCTAssertFalse(state.controlReady)

        state = tracker.observe(connected: true, runtimeReady: true)
        XCTAssertEqual(state.connectionEpoch, 1)
        XCTAssertTrue(state.controlReady)

        state = tracker.observe(connected: false, runtimeReady: true)
        XCTAssertNil(state.connectionEpoch)
        XCTAssertFalse(state.controlReady)

        state = tracker.observe(connected: true, runtimeReady: true)
        XCTAssertEqual(state.connectionEpoch, 2)
        XCTAssertTrue(state.controlReady)
        XCTAssertEqual(tracker.connectionEpochs, [1, 2])
    }

    func testAcceptedPointerObserverFeedsBoundedRuntimeBuffer() throws {
        let buffer = try RuntimePointerDeliveryTelemetryBuffer()
        let observer = ProductionAcceptedPointerDeliveryTelemetryObserver(
            buffer: buffer
        )
        observer.recordAcceptedDelivery(PointerAcceptedDeliveryObservation(
            sessionID: try CanonicalUUID(
                "11111111-1111-4111-8111-111111111111"
            ),
            interactionID: try CanonicalUUID(
                "22222222-2222-4222-8222-222222222222"
            ),
            sequence: 7,
            frameKind: .move,
            expectedConnectionEpoch: 3,
            expectedGeometryRevision: 5,
            clientSubmittedMonotonicNanoseconds: 10_000,
            acceptedMonotonicNanoseconds: 34_000
        ))

        let batch = buffer.drain()
        XCTAssertEqual(batch.droppedObservationCount, 0)
        XCTAssertEqual(batch.observations.count, 1)
        let observation = try XCTUnwrap(batch.observations.first)
        XCTAssertEqual(observation.sequence, 7)
        XCTAssertEqual(observation.frameKind, .move)
        XCTAssertEqual(observation.connectionEpoch, 3)
        XCTAssertEqual(observation.geometryRevision, 5)
        XCTAssertEqual(observation.clientSubmittedMonotonicNanoseconds, 10_000)
        XCTAssertEqual(observation.acceptedMonotonicNanoseconds, 34_000)
    }

    func testProcessSamplerUsesPostWarmupExactProcessSetBuckets() {
        let sampler = ProductionProcessSetSampler()
        let identity = ProductionProcessIdentity(
            executablePath: "/Applications/PulsePhone.app/Contents/MacOS/PulsePhone",
            pid: 101,
            startMicroseconds: 20,
            startSeconds: 10
        )
        for second in 0...11 {
            sampler.record(
                ProductionProcessSetSnapshot(
                    connectionEpoch: 1,
                    controlReady: true,
                    processes: [ProductionProcessResource(
                        identity: identity,
                        residentBytes: 100 * 1_024 * 1_024,
                        totalCPUNanoseconds: UInt64(second) * 100_000_000
                    )],
                    runtimeEpoch: 9
                ),
                atMonotonicNanoseconds: UInt64(second) * 1_000_000_000
            )
        }

        let summary = sampler.summary()
        XCTAssertEqual(summary.gapCount, 0)
        XCTAssertEqual(summary.runtimeEpochs, [9])
        XCTAssertEqual(summary.cpuMilliPercent, [10_000, 10_000])
        XCTAssertEqual(summary.rssKibibytes, [102_400, 102_400])
        XCTAssertEqual(summary.wholeRunCPUMaximumMilliPercent, 10_000)
        XCTAssertEqual(summary.wholeRunRSSMaximumKibibytes, 102_400)
        XCTAssertTrue(summary.hasCompleteSteadySamples)
    }

    func testSessionDrainsPointerBufferBetweenSamplingTicks() throws {
        let buffer = try RuntimePointerDeliveryTelemetryBuffer(
            maximumObservations: 2
        )
        let observer = ProductionAcceptedPointerDeliveryTelemetryObserver(
            buffer: buffer
        )
        let session = ProductionPerformanceTelemetrySession(
            requiredReconnectCount: 0,
            pointerBuffer: buffer,
            processSnapshotProvider: nil,
            devicePresenceProvider: nil
        )
        session.begin(atMonotonicNanoseconds: 0, video: nil)
        for sequence in 0..<2 {
            observer.recordAcceptedDelivery(try pointerObservation(
                sequence: UInt64(sequence)
            ))
        }
        session.observe(atMonotonicNanoseconds: 1_000_000_000, video: nil)
        for sequence in 2..<4 {
            observer.recordAcceptedDelivery(try pointerObservation(
                sequence: UInt64(sequence)
            ))
        }

        let summary = session.finish().pointer
        XCTAssertEqual(summary.count, 4)
        XCTAssertEqual(summary.dropped, 0)
        XCTAssertEqual(summary.byFrameKind["move"], 4)
    }

    func testGUIHostSocketProbeDistinguishesActiveFromStaleNode() throws {
        let path = "/tmp/pulsephone-\(geteuid())/probe-\(UUID().uuidString).sock"
        var descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            _ = unlink(path)
        }
        var address = try ProductionGUIHostSocketActivityProbe.socketAddress(path)
        let addressLength = socklen_t(address.sun_len)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, addressLength)
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(descriptor, 1), 0)
        XCTAssertTrue(try ProductionGUIHostSocketActivityProbe.isActive(path: path))
        XCTAssertEqual(Darwin.close(descriptor), 0)
        descriptor = -1
        XCTAssertFalse(try ProductionGUIHostSocketActivityProbe.isActive(path: path))
    }

    func testReconnectTrackerRequiresNewControlAndSourceEpochs() throws {
        var tracker = ProductionReconnectTracker(requiredAttemptCount: 1)
        tracker.observe(
            atMonotonicNanoseconds: 0,
            connected: true,
            controlReady: true,
            connectionEpoch: 1,
            sourceEpoch: 1,
            latestVideoEnqueueMonotonicNanoseconds: 0
        )
        tracker.observe(
            atMonotonicNanoseconds: 1_000_000_000,
            connected: false,
            controlReady: false,
            connectionEpoch: 1,
            sourceEpoch: 1,
            latestVideoEnqueueMonotonicNanoseconds: nil
        )
        tracker.observe(
            atMonotonicNanoseconds: 2_000_000_000,
            connected: true,
            controlReady: false,
            connectionEpoch: 1,
            sourceEpoch: 1,
            latestVideoEnqueueMonotonicNanoseconds: nil
        )
        tracker.observe(
            atMonotonicNanoseconds: 2_500_000_000,
            connected: true,
            controlReady: true,
            connectionEpoch: 2,
            sourceEpoch: 2,
            latestVideoEnqueueMonotonicNanoseconds: 2_400_000_000
        )

        let attempt = try XCTUnwrap(tracker.finish().first)
        XCTAssertEqual(attempt.attemptID, "physical-reconnect-0001")
        if case .recovered(let milliseconds) = attempt.control {
            XCTAssertEqual(milliseconds, 500)
        } else {
            XCTFail("control recovery was not recorded")
        }
        if case .recovered(let milliseconds) = attempt.video {
            XCTAssertEqual(milliseconds, 400)
        } else {
            XCTFail("video recovery was not recorded")
        }
    }

    private func pointerObservation(
        sequence: UInt64
    ) throws -> PointerAcceptedDeliveryObservation {
        PointerAcceptedDeliveryObservation(
            sessionID: try CanonicalUUID(
                "11111111-1111-4111-8111-111111111111"
            ),
            interactionID: try CanonicalUUID(
                "22222222-2222-4222-8222-222222222222"
            ),
            sequence: sequence,
            frameKind: .move,
            expectedConnectionEpoch: 3,
            expectedGeometryRevision: 5,
            clientSubmittedMonotonicNanoseconds: 10_000 + sequence * 1_000,
            acceptedMonotonicNanoseconds: 30_000 + sequence * 1_000
        )
    }
}
