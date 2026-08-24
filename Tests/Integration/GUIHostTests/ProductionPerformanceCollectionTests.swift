import Darwin
import Foundation
@testable import PulsePhoneGUI
import PulsePhoneMedia
import PulsePhoneSharedDefinitions
import XCTest

final class ProductionPerformanceCollectionTests: XCTestCase {
    func testPerformanceVideoLineageUsesCurrentCatalogEpochsAcrossReconnect() throws {
        let sourceID = String(repeating: "a", count: 64)
        var lineage = ProductionPerformanceVideoLineage(
            mapping: ProductionVideoSourceMapping(
                connectionEpoch: 7,
                geometry: try DisplayGeometryDTO(
                    connectionEpoch: 7,
                    geometryRevision: 13,
                    logicalHeight: 2_532,
                    logicalWidth: 1_170,
                    orientation: .portrait
                ),
                mappingProofID: "operator-confirmed.test",
                sourceEpoch: 99,
                sourceID: sourceID
            )
        )

        let first = try XCTUnwrap(lineage.mapping(for: try VideoSourceDescriptor(
            sourceID: sourceID,
            sourceEpoch: 2,
            activeFormatWidth: 0,
            activeFormatHeight: 0
        )))
        XCTAssertEqual(first.sourceEpoch, 2)
        XCTAssertEqual(first.connectionEpoch, 7)
        XCTAssertEqual(first.geometry.geometryRevision, 13)

        lineage.recordSourceAbsent()
        let recovered = try XCTUnwrap(lineage.mapping(for: try VideoSourceDescriptor(
            sourceID: sourceID,
            sourceEpoch: 3,
            activeFormatWidth: 1_170,
            activeFormatHeight: 2_532
        )))
        XCTAssertEqual(recovered.sourceEpoch, 3)
        XCTAssertEqual(recovered.connectionEpoch, 8)
        XCTAssertEqual(recovered.geometry.connectionEpoch, 8)
        XCTAssertEqual(recovered.geometry.geometryRevision, 14)
        XCTAssertEqual(lineage.connectionEpochs, [7, 8])
        XCTAssertEqual(lineage.sourceEpochs, [2, 3])

        XCTAssertNil(try lineage.mapping(for: VideoSourceDescriptor(
            sourceID: String(repeating: "b", count: 64),
            sourceEpoch: 4,
            activeFormatWidth: 1_170,
            activeFormatHeight: 2_532
        )))
    }

    func testProductionVideoObservationCollectorAcceptsOnlyBoundFrames() throws {
        let target = try CanonicalUDID(canonicalString: "M2031-VIDEO-COLLECTOR")
        let binding = VideoBindingIdentity(
            canonicalUDID: target,
            connectionEpoch: 7,
            sourceID: String(repeating: "a", count: 64),
            sourceEpoch: 11,
            geometryRevision: 13
        )
        let collector = ProductionVideoObservationCollector(
            binding: binding,
            sourceWidth: 1_920,
            sourceHeight: 1_080
        )
        var enqueueCount = 0
        collector.receive(
            sourceID: binding.sourceID,
            sourceEpoch: binding.sourceEpoch,
            frameSequence: 1,
            activeFormatWidth: 1_920,
            activeFormatHeight: 1_080,
            delegateMonotonicNanoseconds: 10_000
        ) { _ in
            enqueueCount += 1
            return 13_000
        }
        collector.receive(
            sourceID: binding.sourceID,
            sourceEpoch: binding.sourceEpoch,
            frameSequence: 2,
            activeFormatWidth: 1_280,
            activeFormatHeight: 720,
            delegateMonotonicNanoseconds: 20_000
        ) { _ in
            enqueueCount += 1
            return 25_000
        }
        collector.receive(
            sourceID: String(repeating: "b", count: 64),
            sourceEpoch: binding.sourceEpoch,
            frameSequence: 3,
            activeFormatWidth: 1_920,
            activeFormatHeight: 1_080,
            delegateMonotonicNanoseconds: 30_000
        ) { _ in
            XCTFail("wrong source must remain fail closed")
            return 35_000
        }
        collector.receive(
            sourceID: binding.sourceID,
            sourceEpoch: binding.sourceEpoch,
            frameSequence: 4,
            activeFormatWidth: 0,
            activeFormatHeight: 1_080,
            delegateMonotonicNanoseconds: 40_000
        ) { _ in
            XCTFail("invalid format must remain fail closed")
            return 45_000
        }
        collector.stop()
        collector.receive(
            sourceID: binding.sourceID,
            sourceEpoch: binding.sourceEpoch,
            frameSequence: 5,
            activeFormatWidth: 1_920,
            activeFormatHeight: 1_080,
            delegateMonotonicNanoseconds: 30_000
        ) { _ in
            enqueueCount += 1
            return 35_000
        }

        let snapshot = collector.snapshot()
        XCTAssertEqual(enqueueCount, 2)
        XCTAssertEqual(snapshot.receivedFrameCount, 4)
        XCTAssertEqual(snapshot.enqueuedFrameCount, 2)
        XCTAssertEqual(snapshot.droppedFrameCount, 2)
        XCTAssertEqual(snapshot.enqueueMonotonicNanoseconds, [13_000, 25_000])
        XCTAssertEqual(snapshot.latencyMicroseconds, [3, 5])
    }

    func testVideoCollectorEstablishesFormatFromFirstBoundSample() throws {
        let target = try CanonicalUDID(canonicalString: "M2031-VIDEO-FORMAT")
        let binding = VideoBindingIdentity(
            canonicalUDID: target,
            connectionEpoch: 7,
            sourceID: String(repeating: "a", count: 64),
            sourceEpoch: 11,
            geometryRevision: 13
        )
        let collector = ProductionVideoObservationCollector(
            binding: binding,
            sourceWidth: 2_532,
            sourceHeight: 1_170
        )
        var enqueueCount = 0
        let base = DispatchTime.now().uptimeNanoseconds
        collector.receive(
            sourceID: binding.sourceID,
            sourceEpoch: binding.sourceEpoch,
            frameSequence: 1,
            activeFormatWidth: 1_170,
            activeFormatHeight: 2_532,
            delegateMonotonicNanoseconds: base
        ) { _ in
            enqueueCount += 1
            return base + 3_000
        }
        for sequence in 2...4 {
            collector.receive(
                sourceID: binding.sourceID,
                sourceEpoch: binding.sourceEpoch,
                frameSequence: UInt64(sequence),
                activeFormatWidth: 2_532,
                activeFormatHeight: 1_170,
                delegateMonotonicNanoseconds: base + UInt64(sequence) * 1_000
            ) { _ in
                enqueueCount += 1
                return base + UInt64(sequence) * 1_000 + 3_000
            }
        }

        let snapshot = collector.snapshot()
        XCTAssertEqual(enqueueCount, 4)
        XCTAssertEqual(snapshot.activeFormatWidth, 2_532)
        XCTAssertEqual(snapshot.activeFormatHeight, 1_170)
        XCTAssertEqual(snapshot.formatRevision, 2)
        XCTAssertEqual(snapshot.receivedFrameCount, 4)
        XCTAssertEqual(snapshot.enqueuedFrameCount, 4)
        XCTAssertEqual(snapshot.droppedFrameCount, 0)
    }

    func testVideoCollectorWithholdsRotatedFramesWithoutStoppingFormatTracking() throws {
        let target = try CanonicalUDID(canonicalString: "M2031-VIDEO-RESIZE-GATE")
        let binding = VideoBindingIdentity(
            canonicalUDID: target,
            connectionEpoch: 7,
            sourceID: String(repeating: "a", count: 64),
            sourceEpoch: 11,
            geometryRevision: 13
        )
        let observations = LockedVideoResizeGateObservations()
        let collector = ProductionVideoObservationCollector(
            binding: binding,
            sourceWidth: 1_170,
            sourceHeight: 2_532,
            presentationHandler: { observations.append(presentation: $0) },
            displayGateHandler: { observations.append(gateTransition: $0) }
        )
        let base = DispatchTime.now().uptimeNanoseconds
        var enqueueCount = 0
        func receive(_ sequence: UInt64, width: UInt64, height: UInt64) {
            collector.receive(
                sourceID: binding.sourceID,
                sourceEpoch: binding.sourceEpoch,
                frameSequence: sequence,
                activeFormatWidth: width,
                activeFormatHeight: height,
                delegateMonotonicNanoseconds: base + sequence * 1_000
            ) { _ in
                enqueueCount += 1
                return base + sequence * 1_000 + 100
            }
        }

        receive(1, width: 1_170, height: 2_532)
        let portrait = try XCTUnwrap(collector.currentPresentation)
        collector.beginLiveResize(frozenPresentation: portrait)
        receive(2, width: 1_170, height: 2_532)
        receive(3, width: 2_532, height: 1_170)
        receive(4, width: 2_532, height: 1_170)
        receive(5, width: 2_532, height: 1_170)

        XCTAssertEqual(enqueueCount, 2)
        XCTAssertEqual(collector.withheldLiveResizeFrameCount, 3)
        XCTAssertTrue(collector.isWithholdingLiveResizeFrames)
        XCTAssertEqual(observations.gateTransitions, [true])
        XCTAssertEqual(collector.currentPresentation?.orientation, .landscape)
        XCTAssertEqual(collector.currentPresentation?.formatRevision, 2)
        XCTAssertEqual(observations.presentations.last?.orientation, .landscape)

        collector.endLiveResize()
        receive(6, width: 2_532, height: 1_170)
        XCTAssertEqual(observations.gateTransitions, [true, false])
        XCTAssertFalse(collector.isWithholdingLiveResizeFrames)
        XCTAssertEqual(enqueueCount, 3)
        let snapshot = collector.snapshot()
        XCTAssertEqual(snapshot.receivedFrameCount, 6)
        XCTAssertEqual(snapshot.enqueuedFrameCount, 3)
        XCTAssertEqual(snapshot.droppedFrameCount, 0)
    }

    func testVideoCollectorRebindsGeometryWithoutReplacingAVFormatAuthority() throws {
        let target = try CanonicalUDID(canonicalString: "M2031-VIDEO-ROTATE")
        let initialGeometry = try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 13,
            logicalHeight: 2_532,
            logicalWidth: 1_170,
            orientation: .portrait
        )
        let binding = VideoBindingIdentity(
            canonicalUDID: target,
            connectionEpoch: 7,
            sourceID: String(repeating: "a", count: 64),
            sourceEpoch: 11,
            geometryRevision: 13
        )
        let collector = ProductionVideoObservationCollector(
            binding: binding,
            geometry: initialGeometry,
            sourceWidth: 1_170,
            sourceHeight: 2_532
        )
        XCTAssertTrue(collector.rebindGeometry(initialGeometry))
        XCTAssertFalse(collector.rebindGeometry(try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 13,
            logicalHeight: 1_170,
            logicalWidth: 2_532,
            orientation: .landscapeRight
        )))
        XCTAssertFalse(collector.rebindGeometry(try DisplayGeometryDTO(
            connectionEpoch: 8,
            geometryRevision: 14,
            logicalHeight: 1_170,
            logicalWidth: 2_532,
            orientation: .landscapeRight
        )))
        XCTAssertTrue(collector.rebindGeometry(try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 14,
            logicalHeight: 1_170,
            logicalWidth: 2_532,
            orientation: .landscapeRight
        )))

        var acceptedBinding: VideoBindingIdentity?
        var enqueueCount = 0
        let base = DispatchTime.now().uptimeNanoseconds
        collector.receive(
            sourceID: binding.sourceID,
            sourceEpoch: binding.sourceEpoch,
            frameSequence: 1,
            activeFormatWidth: 1_170,
            activeFormatHeight: 2_532,
            delegateMonotonicNanoseconds: base
        ) { current in
            acceptedBinding = current
            enqueueCount += 1
            return base + 3_000
        }
        for sequence in 2...4 {
            collector.receive(
                sourceID: binding.sourceID,
                sourceEpoch: binding.sourceEpoch,
                frameSequence: UInt64(sequence),
                activeFormatWidth: 2_532,
                activeFormatHeight: 1_170,
                delegateMonotonicNanoseconds: base + UInt64(sequence) * 1_000
            ) { current in
                acceptedBinding = current
                enqueueCount += 1
                return base + UInt64(sequence) * 1_000 + 3_000
            }
        }
        collector.receive(
            sourceID: binding.sourceID,
            sourceEpoch: binding.sourceEpoch + 1,
            frameSequence: 5,
            activeFormatWidth: 1_170,
            activeFormatHeight: 2_532,
            delegateMonotonicNanoseconds: base + 5_000
        ) { _ in
            XCTFail("stale binding must remain fail closed")
            return base + 8_000
        }

        XCTAssertEqual(acceptedBinding?.geometryRevision, 14)
        XCTAssertEqual(collector.bindingIdentity.geometryRevision, 14)
        XCTAssertEqual(enqueueCount, 4)
        XCTAssertEqual(collector.snapshot().activeFormatWidth, 2_532)
        XCTAssertEqual(collector.snapshot().activeFormatHeight, 1_170)
        XCTAssertEqual(collector.snapshot().formatRevision, 2)
        XCTAssertEqual(collector.snapshot().receivedFrameCount, 5)
        XCTAssertEqual(collector.snapshot().enqueuedFrameCount, 4)
        XCTAssertEqual(collector.snapshot().droppedFrameCount, 1)
    }

    func testCaptureReconfigurationIsSingleAttemptAndCancelsOnConvergence()
        throws
    {
        let target = try CanonicalUDID(
            canonicalString: "M2031-CAPTURE-RECONFIGURATION"
        )
        let binding = VideoBindingIdentity(
            canonicalUDID: target,
            connectionEpoch: 7,
            sourceID: String(repeating: "a", count: 64),
            sourceEpoch: 11,
            geometryRevision: 14
        )
        let portrait = try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 14,
            logicalHeight: 2_532,
            logicalWidth: 1_170,
            orientation: .portrait
        )
        let landscapePresentation = try LiveSamplePresentationFormat(
            sourceEpoch: 11,
            width: 2_532,
            height: 1_170
        )
        let portraitPresentation = try LiveSamplePresentationFormat(
            sourceEpoch: 11,
            width: 1_170,
            height: 2_532,
            formatRevision: 2
        )

        var state = ProductionCaptureReconfigurationState()
        XCTAssertFalse(state.schedule(
            geometry: portrait,
            presentation: portraitPresentation
        ))
        XCTAssertTrue(state.schedule(
            geometry: portrait,
            presentation: landscapePresentation
        ))
        XCTAssertFalse(state.schedule(
            geometry: portrait,
            presentation: landscapePresentation
        ))
        XCTAssertFalse(state.beginAttempt(
            geometry: portrait,
            currentBinding: binding,
            presentation: portraitPresentation
        ))
        XCTAssertFalse(state.schedule(
            geometry: portrait,
            presentation: landscapePresentation
        ))

        let next = try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 15,
            logicalHeight: 2_532,
            logicalWidth: 1_170,
            orientation: .portrait
        )
        let nextBinding = VideoBindingIdentity(
            canonicalUDID: target,
            connectionEpoch: 7,
            sourceID: binding.sourceID,
            sourceEpoch: 11,
            geometryRevision: 15
        )
        XCTAssertTrue(state.schedule(
            geometry: next,
            presentation: landscapePresentation
        ))
        XCTAssertTrue(state.beginAttempt(
            geometry: next,
            currentBinding: nextBinding,
            presentation: landscapePresentation
        ))
        XCTAssertEqual(state.inProgressGeometry, next)
        XCTAssertTrue(state.isPendingOrInProgress)
        XCTAssertFalse(state.schedule(
            geometry: next,
            presentation: landscapePresentation
        ))
        let latest = try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 16,
            logicalHeight: 2_532,
            logicalWidth: 1_170,
            orientation: .portrait
        )
        let latestBinding = VideoBindingIdentity(
            canonicalUDID: target,
            connectionEpoch: 7,
            sourceID: binding.sourceID,
            sourceEpoch: 11,
            geometryRevision: 16
        )
        XCTAssertTrue(state.schedule(
            geometry: latest,
            presentation: landscapePresentation
        ))
        XCTAssertTrue(state.beginAttempt(
            geometry: latest,
            currentBinding: latestBinding,
            presentation: landscapePresentation
        ))
        XCTAssertNil(state.inProgressGeometry)
        XCTAssertTrue(state.finishAttempt(for: next))
        XCTAssertTrue(state.isPendingOrInProgress)
        XCTAssertFalse(state.finishAttempt(for: next))
        XCTAssertEqual(state.inProgressGeometry, latest)
        XCTAssertTrue(state.finishAttempt(for: latest))
        XCTAssertNil(state.inProgressGeometry)
        XCTAssertFalse(state.isPendingOrInProgress)
        XCTAssertEqual(state.handledGeometryRevisions, [14, 15, 16])
    }

    func testCaptureReconfigurationRequiresExactCurrentCollectorMismatch()
        throws
    {
        let target = try CanonicalUDID(
            canonicalString: "M2031-CAPTURE-RECONFIGURATION-FENCE"
        )
        let landscape = try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 14,
            logicalHeight: 1_170,
            logicalWidth: 2_532,
            orientation: .landscapeLeft
        )
        let collector = ProductionVideoObservationCollector(
            binding: VideoBindingIdentity(
                canonicalUDID: target,
                connectionEpoch: 7,
                sourceID: String(repeating: "a", count: 64),
                sourceEpoch: 11,
                geometryRevision: 14
            ),
            geometry: landscape,
            sourceWidth: 2_532,
            sourceHeight: 1_170
        )
        collector.receive(
            sourceID: String(repeating: "a", count: 64),
            sourceEpoch: 11,
            frameSequence: 0,
            activeFormatWidth: 2_532,
            activeFormatHeight: 1_170,
            delegateMonotonicNanoseconds: 1
        ) { _ in 2 }

        XCTAssertFalse(collector.beginCaptureReconfiguration(for: landscape))
        let portrait = try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 15,
            logicalHeight: 2_532,
            logicalWidth: 1_170,
            orientation: .portrait
        )
        XCTAssertTrue(collector.rebindGeometry(portrait))
        XCTAssertTrue(collector.beginCaptureReconfiguration(for: portrait))
        XCTAssertFalse(collector.beginCaptureReconfiguration(for:
            try DisplayGeometryDTO(
                connectionEpoch: 7,
                geometryRevision: 16,
                logicalHeight: 2_532,
                logicalWidth: 1_170,
                orientation: .portrait
            )
        ))
    }

    func testPresentationTrackerRequiresStableCandidateAndCommitsAtDeadline() throws {
        var tracker = ProductionVideoPresentationTracker(sourceEpoch: 9)
        XCTAssertEqual(
            tracker.observe(width: 1_170, height: 2_532, at: 1),
            .committed(try LiveSamplePresentationFormat(
                sourceEpoch: 9,
                width: 1_170,
                height: 2_532
            ))
        )
        guard case .candidate(let staleToken, _, _) = tracker.observe(
            width: 2_532,
            height: 1_170,
            at: 10
        ) else { return XCTFail("expected orientation candidate") }
        XCTAssertEqual(
            tracker.observe(width: 1_000, height: 1_000, at: 20),
            .anomalous
        )
        XCTAssertNil(tracker.commitCandidate(
            token: staleToken,
            at: ProductionVideoPresentationTracker.debounceNanoseconds + 10
        ))

        guard case .candidate(let token, let deadline, _) = tracker.observe(
            width: 2_532,
            height: 1_170,
            at: 100
        ) else { return XCTFail("expected replacement candidate") }
        guard case .candidate(_, _, let sampleCount) = tracker.observe(
            width: 2_532,
            height: 1_170,
            at: 200
        ) else { return XCTFail("expected second candidate sample") }
        XCTAssertEqual(sampleCount, 2)
        XCTAssertNil(tracker.commitCandidate(token: token, at: deadline - 1))
        let committed = try XCTUnwrap(
            tracker.commitCandidate(token: token, at: deadline)
        )
        XCTAssertEqual(committed.formatRevision, 2)
        XCTAssertEqual(committed.orientation, .landscape)
    }

    func testPresentationTrackerCommitsResolutionChangeOnThirdSample() throws {
        var tracker = ProductionVideoPresentationTracker(sourceEpoch: 4)
        _ = tracker.observe(width: 1_170, height: 2_532, at: 1)
        _ = tracker.observe(width: 1_080, height: 2_336, at: 2)
        _ = tracker.observe(width: 1_080, height: 2_336, at: 3)
        guard case .committed(let format) = tracker.observe(
            width: 1_080,
            height: 2_336,
            at: 4
        ) else { return XCTFail("expected third-sample commit") }
        XCTAssertEqual(format.formatRevision, 2)
        XCTAssertEqual(format.orientation, .portrait)
    }

    func testStoppedCollectorCancelsPresentationDeadline() async throws {
        let target = try CanonicalUDID(canonicalString: "M2031-VIDEO-STOP-TIMER")
        let binding = VideoBindingIdentity(
            canonicalUDID: target,
            connectionEpoch: 7,
            sourceID: String(repeating: "a", count: 64),
            sourceEpoch: 11,
            geometryRevision: 13
        )
        let unexpected = expectation(description: "stale presentation callback")
        unexpected.isInverted = true
        let collector = ProductionVideoObservationCollector(
            binding: binding,
            sourceWidth: 1_170,
            sourceHeight: 2_532,
            presentationHandler: { format in
                if format.formatRevision > 1 { unexpected.fulfill() }
            }
        )
        let base = DispatchTime.now().uptimeNanoseconds
        for (sequence, width, height) in [
            (UInt64(1), UInt64(1_170), UInt64(2_532)),
            (UInt64(2), UInt64(2_532), UInt64(1_170)),
            (UInt64(3), UInt64(2_532), UInt64(1_170)),
        ] {
            collector.receive(
                sourceID: binding.sourceID,
                sourceEpoch: binding.sourceEpoch,
                frameSequence: sequence,
                activeFormatWidth: width,
                activeFormatHeight: height,
                delegateMonotonicNanoseconds: base + sequence * 1_000
            ) { _ in base + sequence * 1_000 + 1_000 }
        }
        collector.stop()
        await fulfillment(of: [unexpected], timeout: 0.5)
        XCTAssertEqual(collector.snapshot().formatRevision, 1)
    }

    func testWritesCanonicalUnknownArtifactsAndHashBoundReceipt() throws {
        let output = try makeOutputDescriptors()
        defer { output.closeAndRemove() }
        let arguments = baselineArguments(
            measurementDescriptor: output.measurement,
            metricsDescriptor: output.metrics,
            receiptDescriptor: output.receipt
        )

        XCTAssertTrue(GUIHostProcessEntrypoint.handles(arguments))
        XCTAssertEqual(GUIHostProcessEntrypoint.run(arguments: arguments), 0)
        for descriptor in output.descriptors {
            XCTAssertNotEqual(fcntl(descriptor, F_GETFD) & FD_CLOEXEC, 0)
            XCTAssertEqual(fsync(descriptor), 0)
            XCTAssertEqual(Darwin.close(descriptor), 0)
        }
        output.closed = true

        let measurement = try Data(contentsOf: output.measurementURL)
        let metrics = try Data(contentsOf: output.metricsURL)
        let receipt = try Data(contentsOf: output.receiptURL)
        let measurementDocument = try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](measurement),
            maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
        )
        let metricsDocument = try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](metrics),
            maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
        )
        let receiptDocument = try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](receipt),
            maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
        )

        XCTAssertEqual(
            measurementDocument.root["profileID"]?.stringValue,
            "measurement.production.unknown.v1"
        )
        XCTAssertEqual(
            metricsDocument.root["evaluationMode"]?.stringValue,
            "baseline"
        )
        let currentContract = try PerformanceMetricRegistryV1.identity(
            repositoryRoot: repositoryRoot
        )
        let exportedContract = try XCTUnwrap(
            metricsDocument.root["performanceContract"]?.objectValue
        )
        XCTAssertEqual(
            exportedContract["revision"]?.stringValue,
            currentContract.revision
        )
        XCTAssertEqual(
            exportedContract["sha256"]?.stringValue,
            currentContract.sha256
        )
        XCTAssertEqual(
            metricsDocument.root["targetUDIDHash"]?.stringValue,
            try CanonicalUDID(canonicalString: "M2031-PERFORMANCE").domainSeparatedHash
        )
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(
                metricsDocument.root["monotonicDurationMs"]?.numberValue
            ).requireUInt64(),
            1_000
        )
        let gates = try XCTUnwrap(metricsDocument.root["gateValues"]?.arrayValue)
        XCTAssertEqual(gates.count, 8)
        XCTAssertEqual(
            gates.first?.objectValue?["dataQuality"]?.stringValue,
            "gap"
        )
        XCTAssertEqual(
            gates[6].objectValue?["applicability"]?.stringValue,
            "notApplicable"
        )
        XCTAssertEqual(
            metricsDocument.root["connectionEpochs"]?.arrayValue?.count,
            0
        )
        XCTAssertEqual(metricsDocument.root["sourceEpochs"]?.arrayValue?.count, 0)
        XCTAssertEqual(
            metricsDocument.root["excludedSegments"]?.arrayValue?.first?
                .objectValue?["reasonCode"]?.stringValue,
            "sourceUnbound"
        )
        XCTAssertNil(String(data: metrics, encoding: .utf8)?.range(
            of: "M2031-PERFORMANCE"
        ))
        XCTAssertEqual(
            receiptDocument.root["candidateInputHash"]?.stringValue,
            String(repeating: "c", count: 64)
        )
        XCTAssertEqual(
            receiptDocument.root["sessionNonce"]?.stringValue,
            String(repeating: "d", count: 32)
        )
        XCTAssertEqual(
            receiptDocument.root["measurementSHA256"]?.stringValue,
            StableBytes.sha256Hex(measurement)
        )
        XCTAssertEqual(
            receiptDocument.root["metricsSHA256"]?.stringValue,
            StableBytes.sha256Hex(metrics)
        )
    }

    func testRejectsMissingDuplicateAndUnexpectedArguments() {
        let complete = baselineArguments(
            measurementDescriptor: 20,
            metricsDescriptor: 21,
            receiptDescriptor: 22
        )
        XCTAssertEqual(
            GUIHostProcessEntrypoint.run(arguments: Array(complete.dropLast(2))),
            64
        )
        XCTAssertEqual(
            GUIHostProcessEntrypoint.run(
                arguments: complete + ["--target-udid", "M2031-OTHER"]
            ),
            64
        )
        var unexpected = complete
        unexpected.append(contentsOf: ["--unknown-private-flag", "value"])
        XCTAssertEqual(GUIHostProcessEntrypoint.run(arguments: unexpected), 64)

        let partialVideoMapping = complete + [
            "--video-source-id", String(repeating: "e", count: 64),
        ]
        XCTAssertEqual(
            GUIHostProcessEntrypoint.run(arguments: partialVideoMapping),
            64
        )
    }

    func testRejectsAliasedOrIncorrectModeOutputDescriptors() throws {
        let output = try makeOutputDescriptors()
        defer { output.closeAndRemove() }
        XCTAssertEqual(
            GUIHostProcessEntrypoint.run(arguments: baselineArguments(
                measurementDescriptor: output.measurement,
                metricsDescriptor: output.measurement,
                receiptDescriptor: output.receipt
            )),
            64
        )

        let unsafeURL = output.root.appendingPathComponent("unsafe.json")
        let unsafe = Darwin.open(
            unsafeURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            0o644
        )
        XCTAssertGreaterThanOrEqual(unsafe, 0)
        defer { if unsafe >= 0 { _ = Darwin.close(unsafe) } }
        XCTAssertEqual(
            GUIHostProcessEntrypoint.run(arguments: baselineArguments(
                measurementDescriptor: unsafe,
                metricsDescriptor: output.metrics,
                receiptDescriptor: output.receipt
            )),
            64
        )
    }

    func testUnknownExplicitVideoMappingFallsBackToUnboundGap() throws {
        let output = try makeOutputDescriptors()
        defer { output.closeAndRemove() }
        let arguments = baselineArguments(
            measurementDescriptor: output.measurement,
            metricsDescriptor: output.metrics,
            receiptDescriptor: output.receipt
        ) + [
            "--video-connection-epoch", "1",
            "--video-device-os-build", "23F84",
            "--video-device-product-type", "iPhone14,7",
            "--video-display-refresh-rate-millihz", "60000",
            "--video-geometry-revision", "1",
            "--video-logical-height", "2532",
            "--video-logical-width", "1170",
            "--video-mapping-proof-id", "proof.not-current",
            "--video-orientation", "portrait",
            "--video-source-epoch", "1",
            "--video-source-id", String(repeating: "e", count: 64),
            "--video-window-height-pixels", "780",
            "--video-window-width-pixels", "430",
        ]

        XCTAssertEqual(GUIHostProcessEntrypoint.run(arguments: arguments), 0)
        output.descriptors.forEach { XCTAssertEqual(Darwin.close($0), 0) }
        output.closed = true
        let measurement = try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](Data(contentsOf: output.measurementURL)),
            maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
        )
        let metrics = try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](Data(contentsOf: output.metricsURL)),
            maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
        )
        XCTAssertEqual(
            measurement.root["device"]?.objectValue?["osBuild"]?.stringValue,
            "unknown"
        )
        XCTAssertEqual(metrics.root["connectionEpochs"]?.arrayValue?.count, 0)
        XCTAssertEqual(metrics.root["sourceEpochs"]?.arrayValue?.count, 0)
        XCTAssertEqual(
            metrics.root["excludedSegments"]?.arrayValue?.first?
                .objectValue?["reasonCode"]?.stringValue,
            "sourceUnbound"
        )
    }

    func testBaselineRejectsThresholdArguments() throws {
        let output = try makeOutputDescriptors()
        defer { output.closeAndRemove() }
        let profile = repositoryRoot.appendingPathComponent(
            "Fixtures/performance/threshold-profile/profile.v1.json"
        )
        let arguments = baselineArguments(
            measurementDescriptor: output.measurement,
            metricsDescriptor: output.metrics,
            receiptDescriptor: output.receipt
        ) + [
            "--threshold-profile", profile.path,
            "--threshold-set", "threshold.synthetic.iphone.v1",
        ]
        XCTAssertEqual(GUIHostProcessEntrypoint.run(arguments: arguments), 64)
    }

    private func baselineArguments(
        measurementDescriptor: Int32,
        metricsDescriptor: Int32,
        receiptDescriptor: Int32
    ) -> [String] {
        [
            ProductionPerformanceCollectionEntrypoint.roleArgument,
            "--target-udid", "M2031-PERFORMANCE",
            "--minimum-duration-ms", "1000",
            "--required-reconnect-count", "0",
            "--evaluation-mode", "baseline",
            "--measurement-profile-id", "measurement.production.unknown.v1",
            "--evidence-environment-profile-id", "environment.production.v1",
            "--evidence-environment-profile-hash", String(repeating: "a", count: 64),
            "--reconnect-readiness-profile-id", "reconnect.production.v1",
            "--reconnect-readiness-profile-hash", String(repeating: "b", count: 64),
            "--performance-measurement-fd", String(measurementDescriptor),
            "--performance-metrics-fd", String(metricsDescriptor),
            "--performance-receipt-fd", String(receiptDescriptor),
            "--performance-session-nonce", String(repeating: "d", count: 32),
            "--performance-candidate-input-hash", String(repeating: "c", count: 64),
        ]
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeOutputDescriptors() throws -> OutputFiles {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-M2031-performance-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return try OutputFiles(root: root)
    }
}

private final class LockedVideoResizeGateObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var storedGateTransitions = [Bool]()
    private var storedPresentations = [LiveSamplePresentationFormat]()

    var gateTransitions: [Bool] {
        lock.withLock { storedGateTransitions }
    }

    var presentations: [LiveSamplePresentationFormat] {
        lock.withLock { storedPresentations }
    }

    func append(gateTransition: Bool) {
        lock.withLock { storedGateTransitions.append(gateTransition) }
    }

    func append(presentation: LiveSamplePresentationFormat) {
        lock.withLock { storedPresentations.append(presentation) }
    }
}

private final class OutputFiles {
    let root: URL
    let measurementURL: URL
    let metricsURL: URL
    let receiptURL: URL
    let measurement: Int32
    let metrics: Int32
    let receipt: Int32
    var closed = false

    var descriptors: [Int32] { [measurement, metrics, receipt] }

    init(root: URL) throws {
        self.root = root
        measurementURL = root.appendingPathComponent("measurement.json")
        metricsURL = root.appendingPathComponent("metrics.json")
        receiptURL = root.appendingPathComponent("receipt.json")
        measurement = try Self.open(measurementURL)
        do {
            metrics = try Self.open(metricsURL)
        } catch {
            _ = Darwin.close(measurement)
            throw error
        }
        do {
            receipt = try Self.open(receiptURL)
        } catch {
            _ = Darwin.close(measurement)
            _ = Darwin.close(metrics)
            throw error
        }
    }

    func closeAndRemove() {
        if !closed {
            descriptors.forEach { _ = Darwin.close($0) }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private static func open(_ url: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return descriptor
    }
}
