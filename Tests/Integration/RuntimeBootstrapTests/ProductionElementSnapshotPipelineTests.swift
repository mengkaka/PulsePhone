import Darwin
import Foundation
@testable import PulsePhoneElement
@testable import PulsePhoneMedia
@testable import PulsePhoneRuntimeExecutable
import PulsePhoneSharedDefinitions
import XCTest

final class ProductionElementSnapshotPipelineTests: XCTestCase {
    func testOuterSafetyDeadlinesReserveColdPrewarmAllowanceWithinClientBudget() {
        XCTAssertEqual(
            ProductionElementSnapshotPipeline.jsonOuterSafetyDeadlineSeconds,
            27
        )
        XCTAssertEqual(
            ProductionElementSnapshotPipeline.annotationOuterSafetyDeadlineSeconds,
            32
        )
        XCTAssertLessThan(
            ProductionElementSnapshotPipeline.annotationOuterSafetyDeadlineSeconds,
            60
        )
    }

    func testPipelineUsesOneCaptureGenerationForJSONAndAnnotation() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let pipeline = ProductionElementSnapshotPipeline(
            canonicalUDID: target,
            analyzer: ElementAnalyzerCoordinator(operations: .init(
                omniparser: Self.emptyOmni,
                vision: Self.emptyVision,
                appleRegion: Self.emptyApple
            ))
        )
        let geometry = try DisplayGeometryDTO(
            connectionEpoch: 1,
            geometryRevision: 1,
            logicalHeight: 1,
            logicalWidth: 1,
            orientation: .portrait
        )
        let captureCount = LockedPipelineCounter()
        let json = try pipeline.run(
            requestID: CanonicalUUID(value: UUID()),
            cancellation: ProductionElementSnapshotCancellation(),
            includeAnnotation: false,
            artifactID: nil,
            capture: { _ in
                captureCount.increment()
                return ProductionElementSnapshotCapture(
                    bytes: try Self.png(),
                    geometry: geometry,
                    provider: .coreDevice
                )
            }
        )
        XCTAssertEqual(captureCount.value, 1)
        XCTAssertEqual(json.result.snapshotGeneration, 1)
        XCTAssertNil(json.annotation)
        XCTAssertNil(json.result.root["annotation"])
        let capture = try XCTUnwrap(
            json.result.root["capture"]?.objectValue
        )
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(capture["fenceWaitMilliseconds"]?.numberValue)
                .requireUInt64(),
            30_000
        )
        XCTAssertEqual(
            try XCTUnwrap(capture["frameAgeMilliseconds"]?.numberValue)
                .requireUInt64(),
            0
        )

        let artifactID = try CanonicalUUID(
            "00000000-0000-0000-0000-000000000021"
        )
        let annotated = try pipeline.run(
            requestID: CanonicalUUID(value: UUID()),
            cancellation: ProductionElementSnapshotCancellation(),
            includeAnnotation: true,
            artifactID: artifactID,
            capture: { _ in
                captureCount.increment()
                return ProductionElementSnapshotCapture(
                    bytes: try Self.png(),
                    geometry: geometry,
                    provider: .coreDevice
                )
            }
        )
        XCTAssertEqual(captureCount.value, 2)
        XCTAssertEqual(annotated.result.snapshotGeneration, 2)
        XCTAssertEqual(annotated.annotation?.snapshotGeneration, 2)
        XCTAssertEqual(
            annotated.annotation?.captureSHA256,
            annotated.result.captureSHA256
        )
        XCTAssertEqual(
            annotated.result.root["annotation"]?.objectValue?["artifactID"]?
                .stringValue,
            artifactID.canonicalString
        )
        XCTAssertTrue(annotated.annotation?.bytes.starts(with: [
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        ]) == true)
    }

    func testPipelineCoalescesCompatibleConcurrentCapture() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let captureCoordinator = ProductionElementDeviceCaptureCoordinator(
            coalescingWindowNanoseconds: 100_000_000
        )
        let pipeline = ProductionElementSnapshotPipeline(
            canonicalUDID: target,
            analyzer: ElementAnalyzerCoordinator(operations: .init(
                omniparser: Self.emptyOmni,
                vision: Self.emptyVision,
                appleRegion: Self.emptyApple
            )),
            captureCoordinator: captureCoordinator
        )
        let geometry = try DisplayGeometryDTO(
            connectionEpoch: 1,
            geometryRevision: 1,
            logicalHeight: 1,
            logicalWidth: 1,
            orientation: .portrait
        )
        let key = ProductionElementDeviceCaptureKey(
            geometry: geometry,
            providerPlanID: "dvt,coreDevice,axAudit",
            targetIdentity: "target-1"
        )
        let captureCount = LockedPipelineCounter()
        let captureStarted = expectation(description: "capture started")
        let releaseCapture = DispatchSemaphore(value: 0)
        let firstFinished = expectation(description: "first finished")
        let secondFinished = expectation(description: "second finished")
        let firstFailures = LockedPipelineFailures()
        let secondFailures = LockedPipelineFailures()
        let firstOutput = LockedPipelineOutput()
        let secondOutput = LockedPipelineOutput()
        let capture: ProductionElementSnapshotPipeline.Capture = { _ in
            captureCount.increment()
            captureStarted.fulfill()
            releaseCapture.wait()
            return ProductionElementSnapshotCapture(
                bytes: try Self.png(),
                geometry: geometry,
                provider: .coreDevice
            )
        }
        DispatchQueue.global().async {
            defer { firstFinished.fulfill() }
            do {
                firstOutput.store(try pipeline.run(
                    requestID: CanonicalUUID(value: UUID()),
                    cancellation: ProductionElementSnapshotCancellation(),
                    includeAnnotation: false,
                    artifactID: nil,
                    captureKey: key,
                    capture: capture
                ))
            } catch {
                firstFailures.store(error)
            }
        }
        usleep(10_000)
        DispatchQueue.global().async {
            defer { secondFinished.fulfill() }
            do {
                secondOutput.store(try pipeline.run(
                    requestID: CanonicalUUID(value: UUID()),
                    cancellation: ProductionElementSnapshotCancellation(),
                    includeAnnotation: false,
                    artifactID: nil,
                    captureKey: key,
                    capture: capture
                ))
            } catch {
                secondFailures.store(error)
            }
        }
        wait(for: [captureStarted], timeout: 2)
        releaseCapture.signal()
        wait(for: [firstFinished, secondFinished], timeout: 2)
        XCTAssertEqual(captureCount.value, 1)
        XCTAssertNil(firstFailures.error)
        XCTAssertNil(secondFailures.error)
        XCTAssertEqual(
            firstOutput.value?.result.captureSHA256,
            secondOutput.value?.result.captureSHA256
        )
        XCTAssertNotEqual(
            firstOutput.value?.result.snapshotGeneration,
            secondOutput.value?.result.snapshotGeneration
        )
    }

    func testCaptureCoordinatorSerializesIncompatibleKeys() throws {
        let baseGeometry = try Self.geometry()
        let incompatibleKeys = [
            ProductionElementDeviceCaptureKey(
                geometry: try Self.geometry(connectionEpoch: 2),
            providerPlanID: "dvt,coreDevice,axAudit",
                targetIdentity: "target-1"
            ),
            ProductionElementDeviceCaptureKey(
                geometry: try Self.geometry(geometryRevision: 2),
            providerPlanID: "dvt,coreDevice,axAudit",
                targetIdentity: "target-1"
            ),
            ProductionElementDeviceCaptureKey(
                geometry: baseGeometry,
                providerPlanID: "legacyScreenshotR",
                targetIdentity: "target-1"
            ),
            ProductionElementDeviceCaptureKey(
                geometry: baseGeometry,
            providerPlanID: "dvt,coreDevice,axAudit",
                targetIdentity: "target-2"
            ),
        ]
        let baseKey = ProductionElementDeviceCaptureKey(
            geometry: baseGeometry,
            providerPlanID: "dvt,coreDevice,axAudit",
            targetIdentity: "target-1"
        )

        for incompatibleKey in incompatibleKeys {
            let coordinator = ProductionElementDeviceCaptureCoordinator(
                coalescingWindowNanoseconds: 100_000_000
            )
            let firstStarted = DispatchSemaphore(value: 0)
            let secondStarted = DispatchSemaphore(value: 0)
            let releaseFirst = DispatchSemaphore(value: 0)
            let group = DispatchGroup()
            let failures = LockedPipelineFailures()
            let deadline = DispatchTime.now().uptimeNanoseconds
                + 3_000_000_000

            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    _ = try coordinator.capture(
                        key: baseKey,
                        queryStartedAtNanoseconds:
                            DispatchTime.now().uptimeNanoseconds,
                        deadlineNanoseconds: deadline,
                        cancellation: ProductionElementSnapshotCancellation(),
                        operation: { _ in
                            firstStarted.signal()
                            releaseFirst.wait()
                            return try Self.capture(geometry: baseGeometry)
                        }
                    )
                } catch {
                    failures.store(error)
                }
            }
            usleep(10_000)
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    _ = try coordinator.capture(
                        key: incompatibleKey,
                        queryStartedAtNanoseconds:
                            DispatchTime.now().uptimeNanoseconds,
                        deadlineNanoseconds: deadline,
                        cancellation: ProductionElementSnapshotCancellation(),
                        operation: { _ in
                            secondStarted.signal()
                            return try Self.capture(
                                geometry: incompatibleKey.geometry
                            )
                        }
                    )
                } catch {
                    failures.store(error)
                }
            }

            XCTAssertEqual(firstStarted.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(secondStarted.wait(timeout: .now() + 0.05), .timedOut)
            releaseFirst.signal()
            XCTAssertEqual(secondStarted.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(group.wait(timeout: .now() + 1), .success)
            XCTAssertNil(failures.error)
        }
    }

    func testCaptureCoordinatorDoesNotReuseCaptureStartedBeforeQuery() throws {
        let geometry = try Self.geometry()
        let key = ProductionElementDeviceCaptureKey(
            geometry: geometry,
            providerPlanID: "dvt,coreDevice,axAudit",
            targetIdentity: "target-1"
        )
        let coordinator = ProductionElementDeviceCaptureCoordinator(
            coalescingWindowNanoseconds: 0
        )
        let firstStarted = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let failures = LockedPipelineFailures()
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000

        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                _ = try coordinator.capture(
                    key: key,
                    queryStartedAtNanoseconds:
                        DispatchTime.now().uptimeNanoseconds,
                    deadlineNanoseconds: deadline,
                    cancellation: ProductionElementSnapshotCancellation(),
                    operation: { _ in
                        firstStarted.signal()
                        releaseFirst.wait()
                        return try Self.capture(geometry: geometry)
                    }
                )
            } catch {
                failures.store(error)
            }
        }
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 1), .success)

        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                _ = try coordinator.capture(
                    key: key,
                    queryStartedAtNanoseconds:
                        DispatchTime.now().uptimeNanoseconds,
                    deadlineNanoseconds: deadline,
                    cancellation: ProductionElementSnapshotCancellation(),
                    operation: { _ in
                        secondStarted.signal()
                        return try Self.capture(geometry: geometry)
                    }
                )
            } catch {
                failures.store(error)
            }
        }
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 0.05), .timedOut)
        releaseFirst.signal()
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(group.wait(timeout: .now() + 1), .success)
        XCTAssertNil(failures.error)
    }

    func testCancellingOneJoinedWaiterDoesNotCancelSharedProducer() throws {
        let geometry = try Self.geometry()
        let key = ProductionElementDeviceCaptureKey(
            geometry: geometry,
            providerPlanID: "dvt,coreDevice,axAudit",
            targetIdentity: "target-1"
        )
        let coordinator = ProductionElementDeviceCaptureCoordinator(
            coalescingWindowNanoseconds: 100_000_000
        )
        let firstCancellation = ProductionElementSnapshotCancellation()
        let producerStarted = DispatchSemaphore(value: 0)
        let producerCancelled = DispatchSemaphore(value: 0)
        let releaseProducer = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        let firstFailure = LockedPipelineFailures()
        let secondFailure = LockedPipelineFailures()
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        let captureCount = LockedPipelineCounter()

        DispatchQueue.global().async {
            defer { firstFinished.signal() }
            do {
                _ = try coordinator.capture(
                    key: key,
                    queryStartedAtNanoseconds:
                        DispatchTime.now().uptimeNanoseconds,
                    deadlineNanoseconds: deadline,
                    cancellation: firstCancellation,
                    operation: { producerCancellation in
                        captureCount.increment()
                        let registration = producerCancellation.register {
                            producerCancelled.signal()
                        }
                        defer {
                            producerCancellation.unregister(registration)
                        }
                        producerStarted.signal()
                        releaseProducer.wait()
                        try producerCancellation.check()
                        return try Self.capture(geometry: geometry)
                    }
                )
            } catch {
                firstFailure.store(error)
            }
        }
        usleep(10_000)
        DispatchQueue.global().async {
            defer { secondFinished.signal() }
            do {
                _ = try coordinator.capture(
                    key: key,
                    queryStartedAtNanoseconds:
                        DispatchTime.now().uptimeNanoseconds,
                    deadlineNanoseconds: deadline,
                    cancellation: ProductionElementSnapshotCancellation(),
                    operation: { _ in
                        XCTFail("joined waiter must not start a second producer")
                        return try Self.capture(geometry: geometry)
                    }
                )
            } catch {
                secondFailure.store(error)
            }
        }

        XCTAssertEqual(producerStarted.wait(timeout: .now() + 1), .success)
        firstCancellation.cancel()
        XCTAssertEqual(firstFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(producerCancelled.wait(timeout: .now() + 0.05), .timedOut)
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 0.05), .timedOut)
        XCTAssertEqual(
            firstFailure.error as? ProductionElementSnapshotPipelineError,
            .cancelled
        )
        releaseProducer.signal()
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 1), .success)
        XCTAssertNil(secondFailure.error)
        XCTAssertEqual(captureCount.value, 1)
    }

    func testJoinedWaiterDeadlineDoesNotStartOrCancelProducer() throws {
        let geometry = try Self.geometry()
        let key = ProductionElementDeviceCaptureKey(
            geometry: geometry,
            providerPlanID: "dvt,coreDevice,axAudit",
            targetIdentity: "target-1"
        )
        let coordinator = ProductionElementDeviceCaptureCoordinator(
            coalescingWindowNanoseconds: 100_000_000
        )
        let producerStarted = DispatchSemaphore(value: 0)
        let producerCancelled = DispatchSemaphore(value: 0)
        let releaseProducer = DispatchSemaphore(value: 0)
        let leaderFinished = DispatchSemaphore(value: 0)
        let waiterFinished = DispatchSemaphore(value: 0)
        let leaderFailure = LockedPipelineFailures()
        let waiterFailure = LockedPipelineFailures()
        let leaderDeadline = DispatchTime.now().uptimeNanoseconds
            + 3_000_000_000

        DispatchQueue.global().async {
            defer { leaderFinished.signal() }
            do {
                _ = try coordinator.capture(
                    key: key,
                    queryStartedAtNanoseconds:
                        DispatchTime.now().uptimeNanoseconds,
                    deadlineNanoseconds: leaderDeadline,
                    cancellation: ProductionElementSnapshotCancellation(),
                    operation: { producerCancellation in
                        let registration = producerCancellation.register {
                            producerCancelled.signal()
                        }
                        defer {
                            producerCancellation.unregister(registration)
                        }
                        producerStarted.signal()
                        releaseProducer.wait()
                        try producerCancellation.check()
                        return try Self.capture(geometry: geometry)
                    }
                )
            } catch {
                leaderFailure.store(error)
            }
        }
        usleep(10_000)
        DispatchQueue.global().async {
            defer { waiterFinished.signal() }
            do {
                _ = try coordinator.capture(
                    key: key,
                    queryStartedAtNanoseconds:
                        DispatchTime.now().uptimeNanoseconds,
                    deadlineNanoseconds:
                        DispatchTime.now().uptimeNanoseconds + 250_000_000,
                    cancellation: ProductionElementSnapshotCancellation(),
                    operation: { _ in
                        XCTFail("expired joined waiter must not capture")
                        return try Self.capture(geometry: geometry)
                    }
                )
            } catch {
                waiterFailure.store(error)
            }
        }

        XCTAssertEqual(producerStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(waiterFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            waiterFailure.error as? ProductionElementSnapshotPipelineError,
            .analysisTimedOut
        )
        XCTAssertEqual(producerCancelled.wait(timeout: .now() + 0.05), .timedOut)
        releaseProducer.signal()
        XCTAssertEqual(leaderFinished.wait(timeout: .now() + 1), .success)
        XCTAssertNil(leaderFailure.error)
    }

    func testExpiredOnlyWaiterDoesNotStartDelayedProducer() throws {
        let geometry = try Self.geometry()
        let key = ProductionElementDeviceCaptureKey(
            geometry: geometry,
            providerPlanID: "dvt,coreDevice,axAudit",
            targetIdentity: "target-1"
        )
        let captureQueue = DispatchQueue(
            label: "com.pulsephone.tests.delayed-element-capture"
        )
        let releaseQueue = DispatchSemaphore(value: 0)
        captureQueue.async { releaseQueue.wait() }
        let coordinator = ProductionElementDeviceCaptureCoordinator(
            coalescingWindowNanoseconds: 0,
            captureQueue: captureQueue
        )
        let finished = DispatchSemaphore(value: 0)
        let failure = LockedPipelineFailures()
        let captureCount = LockedPipelineCounter()

        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                _ = try coordinator.capture(
                    key: key,
                    queryStartedAtNanoseconds:
                        DispatchTime.now().uptimeNanoseconds,
                    deadlineNanoseconds:
                        DispatchTime.now().uptimeNanoseconds + 50_000_000,
                    cancellation: ProductionElementSnapshotCancellation(),
                    operation: { _ in
                        captureCount.increment()
                        return try Self.capture(geometry: geometry)
                    }
                )
            } catch {
                failure.store(error)
            }
        }

        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            failure.error as? ProductionElementSnapshotPipelineError,
            .analysisTimedOut
        )
        releaseQueue.signal()
        captureQueue.sync {}
        XCTAssertEqual(captureCount.value, 0)
    }

    func testProducerFailurePropagatesToAllJoinedWaiters() throws {
        let geometry = try Self.geometry()
        let key = ProductionElementDeviceCaptureKey(
            geometry: geometry,
            providerPlanID: "dvt,coreDevice,axAudit",
            targetIdentity: "target-1"
        )
        let coordinator = ProductionElementDeviceCaptureCoordinator(
            coalescingWindowNanoseconds: 100_000_000
        )
        let firstFinished = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        let firstFailure = LockedPipelineFailures()
        let secondFailure = LockedPipelineFailures()
        let captureCount = LockedPipelineCounter()
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000

        DispatchQueue.global().async {
            defer { firstFinished.signal() }
            do {
                _ = try coordinator.capture(
                    key: key,
                    queryStartedAtNanoseconds:
                        DispatchTime.now().uptimeNanoseconds,
                    deadlineNanoseconds: deadline,
                    cancellation: ProductionElementSnapshotCancellation(),
                    operation: { _ in
                        captureCount.increment()
                        throw PipelineCaptureTestError.failed
                    }
                )
            } catch {
                firstFailure.store(error)
            }
        }
        usleep(10_000)
        DispatchQueue.global().async {
            defer { secondFinished.signal() }
            do {
                _ = try coordinator.capture(
                    key: key,
                    queryStartedAtNanoseconds:
                        DispatchTime.now().uptimeNanoseconds,
                    deadlineNanoseconds: deadline,
                    cancellation: ProductionElementSnapshotCancellation(),
                    operation: { _ in
                        XCTFail("joined waiter must consume producer failure")
                        return try Self.capture(geometry: geometry)
                    }
                )
            } catch {
                secondFailure.store(error)
            }
        }

        XCTAssertEqual(firstFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(firstFailure.error is PipelineCaptureTestError)
        XCTAssertTrue(secondFailure.error is PipelineCaptureTestError)
        XCTAssertEqual(captureCount.value, 1)
    }

    func testJoinedFallbackCaptureKeepsDistinctGenerationsAndAnnotations() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let geometry = try Self.geometry()
        let key = ProductionElementDeviceCaptureKey(
            geometry: geometry,
            providerPlanID: "dvt,coreDevice,axAudit",
            targetIdentity: "target-1"
        )
        let pipeline = ProductionElementSnapshotPipeline(
            canonicalUDID: target,
            analyzer: ElementAnalyzerCoordinator(operations: .init(
                omniparser: Self.emptyOmni,
                vision: Self.emptyVision,
                appleRegion: Self.emptyApple
            )),
            captureCoordinator: ProductionElementDeviceCaptureCoordinator(
                coalescingWindowNanoseconds: 100_000_000
            )
        )
        let firstArtifactID = try CanonicalUUID(
            "00000000-0000-0000-0000-000000000031"
        )
        let secondArtifactID = try CanonicalUUID(
            "00000000-0000-0000-0000-000000000032"
        )
        let attempts = [
            Self.captureAttempt(
                provider: .dvt,
                status: .failed,
                errorCode: .developerServicesUnavailable,
                failureStage: .captureOrValidate
            ),
            Self.captureAttempt(provider: .coreDevice, status: .succeeded),
        ]
        let captureCount = LockedPipelineCounter()
        let firstOutput = LockedPipelineOutput()
        let secondOutput = LockedPipelineOutput()
        let firstFailure = LockedPipelineFailures()
        let secondFailure = LockedPipelineFailures()
        let group = DispatchGroup()
        let capture: ProductionElementSnapshotPipeline.Capture = { _ in
            captureCount.increment()
            return try Self.capture(
                geometry: geometry,
                provider: .coreDevice,
                captureAttempts: attempts
            )
        }

        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                firstOutput.store(try pipeline.run(
                    requestID: CanonicalUUID(value: UUID()),
                    cancellation: ProductionElementSnapshotCancellation(),
                    includeAnnotation: true,
                    artifactID: firstArtifactID,
                    captureKey: key,
                    capture: capture
                ))
            } catch {
                firstFailure.store(error)
            }
        }
        usleep(10_000)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                secondOutput.store(try pipeline.run(
                    requestID: CanonicalUUID(value: UUID()),
                    cancellation: ProductionElementSnapshotCancellation(),
                    includeAnnotation: true,
                    artifactID: secondArtifactID,
                    captureKey: key,
                    capture: capture
                ))
            } catch {
                secondFailure.store(error)
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
        XCTAssertNil(firstFailure.error)
        XCTAssertNil(secondFailure.error)
        XCTAssertEqual(captureCount.value, 1)
        let first = try XCTUnwrap(firstOutput.value)
        let second = try XCTUnwrap(secondOutput.value)
        XCTAssertEqual(first.result.captureSHA256, second.result.captureSHA256)
        XCTAssertNotEqual(
            first.result.snapshotGeneration,
            second.result.snapshotGeneration
        )
        XCTAssertEqual(first.annotation?.captureSHA256, first.result.captureSHA256)
        XCTAssertEqual(second.annotation?.captureSHA256, second.result.captureSHA256)
        XCTAssertEqual(
            first.result.root["annotation"]?.objectValue?["artifactID"]?
                .stringValue,
            firstArtifactID.canonicalString
        )
        XCTAssertEqual(
            second.result.root["annotation"]?.objectValue?["artifactID"]?
                .stringValue,
            secondArtifactID.canonicalString
        )
        XCTAssertEqual(
            first.result.root["capture"]?.objectValue?["provider"]?.stringValue,
            SnapshotCaptureProvider.coreDevice.rawValue
        )
        XCTAssertEqual(
            second.result.root["capture"]?.objectValue?["provider"]?.stringValue,
            SnapshotCaptureProvider.coreDevice.rawValue
        )
    }

    func testCancellationWaitsForBranchCleanupBeforePipelineBecomesIdle() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let operation = SequencedPipelineOperation()
        let pipeline = ProductionElementSnapshotPipeline(
            canonicalUDID: target,
            analyzer: ElementAnalyzerCoordinator(operations: .init(
                omniparser: operation.analyze,
                vision: Self.emptyVision,
                appleRegion: Self.emptyApple
            ))
        )
        let cancellation = ProductionElementSnapshotCancellation()
        let failures = LockedPipelineFailures()
        let finished = expectation(description: "cancelled run finished")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                _ = try pipeline.run(
                    requestID: CanonicalUUID(value: UUID()),
                    cancellation: cancellation,
                    includeAnnotation: false,
                    artifactID: nil,
                    capture: { _ in try Self.capture() }
                )
            } catch {
                failures.store(error)
            }
        }
        XCTAssertEqual(operation.started.wait(timeout: .now() + 2), .success)
        cancellation.cancel()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(
            failures.error as? ProductionElementSnapshotPipelineError,
            .cancelled
        )
        XCTAssertTrue(operation.firstCleanupFinished)

        let next = try pipeline.run(
            requestID: CanonicalUUID(value: UUID()),
            cancellation: ProductionElementSnapshotCancellation(),
            includeAnnotation: false,
            artifactID: nil,
            capture: { _ in try Self.capture() }
        )
        XCTAssertEqual(next.result.snapshotGeneration, 2)
    }

    func testShutdownCancelsAndJoinsActivePipelineThenRejectsNewWork() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let operation = SequencedPipelineOperation()
        let pipeline = ProductionElementSnapshotPipeline(
            canonicalUDID: target,
            analyzer: ElementAnalyzerCoordinator(operations: .init(
                omniparser: operation.analyze,
                vision: Self.emptyVision,
                appleRegion: Self.emptyApple
            ))
        )
        let failures = LockedPipelineFailures()
        let finished = expectation(description: "shutdown run finished")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                _ = try pipeline.run(
                    requestID: CanonicalUUID(value: UUID()),
                    cancellation: ProductionElementSnapshotCancellation(),
                    includeAnnotation: false,
                    artifactID: nil,
                    capture: { _ in try Self.capture() }
                )
            } catch {
                failures.store(error)
            }
        }
        XCTAssertEqual(operation.started.wait(timeout: .now() + 2), .success)
        pipeline.shutdown()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(
            failures.error as? ProductionElementSnapshotPipelineError,
            .cancelled
        )
        XCTAssertTrue(operation.firstCleanupFinished)
        XCTAssertThrowsError(try pipeline.run(
            requestID: CanonicalUUID(value: UUID()),
            cancellation: ProductionElementSnapshotCancellation(),
            includeAnnotation: false,
            artifactID: nil,
            capture: { _ in try Self.capture() }
        )) {
            XCTAssertEqual(
                $0 as? ProductionElementSnapshotPipelineError,
                .stopping
            )
        }
    }

    func testShutdownCancelsAndJoinsMultipleSharedCaptureWaiters() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let geometry = try Self.geometry()
        let key = ProductionElementDeviceCaptureKey(
            geometry: geometry,
            providerPlanID: "dvt,coreDevice,axAudit",
            targetIdentity: "target-1"
        )
        let pipeline = ProductionElementSnapshotPipeline(
            canonicalUDID: target,
            analyzer: ElementAnalyzerCoordinator(operations: .init(
                omniparser: Self.emptyOmni,
                vision: Self.emptyVision,
                appleRegion: Self.emptyApple
            )),
            captureCoordinator: ProductionElementDeviceCaptureCoordinator(
                coalescingWindowNanoseconds: 100_000_000
            )
        )
        let producerStarted = DispatchSemaphore(value: 0)
        let producerCancelled = DispatchSemaphore(value: 0)
        let captureCount = LockedPipelineCounter()
        let firstFailure = LockedPipelineFailures()
        let secondFailure = LockedPipelineFailures()
        let group = DispatchGroup()
        let capture: ProductionElementSnapshotPipeline.Capture = {
            producerCancellation in
            captureCount.increment()
            let registration = producerCancellation.register {
                producerCancelled.signal()
            }
            defer { producerCancellation.unregister(registration) }
            producerStarted.signal()
            producerCancelled.wait()
            try producerCancellation.check()
            return try Self.capture(geometry: geometry)
        }

        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                _ = try pipeline.run(
                    requestID: CanonicalUUID(value: UUID()),
                    cancellation: ProductionElementSnapshotCancellation(),
                    includeAnnotation: false,
                    artifactID: nil,
                    captureKey: key,
                    capture: capture
                )
            } catch {
                firstFailure.store(error)
            }
        }
        usleep(10_000)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                _ = try pipeline.run(
                    requestID: CanonicalUUID(value: UUID()),
                    cancellation: ProductionElementSnapshotCancellation(),
                    includeAnnotation: false,
                    artifactID: nil,
                    captureKey: key,
                    capture: capture
                )
            } catch {
                secondFailure.store(error)
            }
        }

        XCTAssertEqual(producerStarted.wait(timeout: .now() + 1), .success)
        pipeline.shutdown()
        XCTAssertEqual(group.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(captureCount.value, 1)
        XCTAssertEqual(
            firstFailure.error as? ProductionElementSnapshotPipelineError,
            .cancelled
        )
        XCTAssertEqual(
            secondFailure.error as? ProductionElementSnapshotPipelineError,
            .cancelled
        )
    }

    func testAuthorityChangeCancelsAllSharedCaptureWaitersAndProducer() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let geometry = try Self.geometry()
        let key = ProductionElementDeviceCaptureKey(
            geometry: geometry,
            providerPlanID: "dvt,coreDevice,axAudit",
            targetIdentity: "target-1"
        )
        let pipeline = ProductionElementSnapshotPipeline(
            canonicalUDID: target,
            analyzer: ElementAnalyzerCoordinator(operations: .init(
                omniparser: Self.emptyOmni,
                vision: Self.emptyVision,
                appleRegion: Self.emptyApple
            )),
            captureCoordinator: ProductionElementDeviceCaptureCoordinator(
                coalescingWindowNanoseconds: 100_000_000
            )
        )
        let firstCancellation = ProductionElementSnapshotCancellation()
        let secondCancellation = ProductionElementSnapshotCancellation()
        let producerStarted = DispatchSemaphore(value: 0)
        let producerCancelled = DispatchSemaphore(value: 0)
        let firstFailure = LockedPipelineFailures()
        let secondFailure = LockedPipelineFailures()
        let group = DispatchGroup()
        let capture: ProductionElementSnapshotPipeline.Capture = {
            producerCancellation in
            let registration = producerCancellation.register {
                producerCancelled.signal()
            }
            defer { producerCancellation.unregister(registration) }
            producerStarted.signal()
            producerCancelled.wait()
            try producerCancellation.check()
            return try Self.capture(geometry: geometry)
        }

        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                _ = try pipeline.run(
                    requestID: CanonicalUUID(value: UUID()),
                    cancellation: firstCancellation,
                    includeAnnotation: false,
                    artifactID: nil,
                    captureKey: key,
                    capture: capture
                )
            } catch {
                firstFailure.store(error)
            }
        }
        usleep(10_000)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                _ = try pipeline.run(
                    requestID: CanonicalUUID(value: UUID()),
                    cancellation: secondCancellation,
                    includeAnnotation: false,
                    artifactID: nil,
                    captureKey: key,
                    capture: capture
                )
            } catch {
                secondFailure.store(error)
            }
        }

        XCTAssertEqual(producerStarted.wait(timeout: .now() + 1), .success)
        firstCancellation.cancel(cause: .authorityChanged)
        secondCancellation.cancel(cause: .authorityChanged)
        XCTAssertEqual(group.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(firstCancellation.cancellationCause, .authorityChanged)
        XCTAssertEqual(secondCancellation.cancellationCause, .authorityChanged)
        XCTAssertEqual(
            firstFailure.error as? ProductionElementSnapshotPipelineError,
            .cancelled
        )
        XCTAssertEqual(
            secondFailure.error as? ProductionElementSnapshotPipelineError,
            .cancelled
        )
    }

    func testOwnerDisconnectMonitorCancelsOnSocketEOF() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer {
            if descriptors[0] >= 0 { _ = Darwin.close(descriptors[0]) }
            if descriptors[1] >= 0 { _ = Darwin.close(descriptors[1]) }
        }
        let cancellation = ProductionElementSnapshotCancellation()
        let cancelled = DispatchSemaphore(value: 0)
        _ = cancellation.register { cancelled.signal() }
        let monitor = ProductionElementOwnerDisconnectMonitor(
            descriptor: descriptors[0],
            cancellation: cancellation
        )
        _ = Darwin.close(descriptors[1])
        descriptors[1] = -1
        XCTAssertEqual(cancelled.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(cancellation.isCancelled)
        monitor.stop()
    }

    func testOwnedCancellationFencesForeignUnknownAndTerminalRequests() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let operation = SequencedPipelineOperation()
        let pipeline = ProductionElementSnapshotPipeline(
            canonicalUDID: target,
            analyzer: ElementAnalyzerCoordinator(operations: .init(
                omniparser: operation.analyze,
                vision: Self.emptyVision,
                appleRegion: Self.emptyApple
            ))
        )
        let requestID = CanonicalUUID(value: UUID())
        let owner = CanonicalUUID(value: UUID())
        let cancellation = ProductionElementSnapshotCancellation()
        let failures = LockedPipelineFailures()
        let finished = expectation(description: "owned cancellation finished")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                _ = try pipeline.run(
                    requestID: requestID,
                    cancellation: cancellation,
                    ownerClientInstanceID: owner,
                    includeAnnotation: false,
                    artifactID: nil,
                    capture: { _ in try Self.capture() }
                )
            } catch {
                failures.store(error)
            }
        }
        XCTAssertEqual(operation.started.wait(timeout: .now() + 2), .success)

        XCTAssertEqual(
            pipeline.cancelOwnedPendingWork(
                targetRequestID: requestID,
                ownerClientInstanceID: CanonicalUUID(value: UUID())
            ),
            ProductionElementPendingCancellationResult(
                disposition: .notOwned,
                targetPhase: "analysis"
            )
        )
        XCTAssertFalse(cancellation.isCancelled)
        XCTAssertEqual(
            pipeline.cancelOwnedPendingWork(
                targetRequestID: CanonicalUUID(value: UUID()),
                ownerClientInstanceID: owner
            ),
            ProductionElementPendingCancellationResult(
                disposition: .notFound,
                targetPhase: nil
            )
        )
        XCTAssertEqual(
            pipeline.cancelOwnedPendingWork(
                targetRequestID: requestID,
                ownerClientInstanceID: owner
            ),
            ProductionElementPendingCancellationResult(
                disposition: .cancellationRequested,
                targetPhase: "analysis"
            )
        )
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(
            failures.error as? ProductionElementSnapshotPipelineError,
            .cancelled
        )
        XCTAssertEqual(
            pipeline.cancelOwnedPendingWork(
                targetRequestID: requestID,
                ownerClientInstanceID: owner
            ),
            ProductionElementPendingCancellationResult(
                disposition: .alreadyTerminal,
                targetPhase: "terminal"
            )
        )
    }

    func testOwnedCancellationOnlyRemovesMatchingSharedCaptureWaiter() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let geometry = try Self.geometry()
        let key = ProductionElementDeviceCaptureKey(
            geometry: geometry,
            providerPlanID: "dvt,coreDevice,axAudit",
            targetIdentity: "target-1"
        )
        let pipeline = ProductionElementSnapshotPipeline(
            canonicalUDID: target,
            analyzer: ElementAnalyzerCoordinator(operations: .init(
                omniparser: Self.emptyOmni,
                vision: Self.emptyVision,
                appleRegion: Self.emptyApple
            )),
            captureCoordinator: ProductionElementDeviceCaptureCoordinator(
                coalescingWindowNanoseconds: 100_000_000
            )
        )
        let firstRequestID = CanonicalUUID(value: UUID())
        let secondRequestID = CanonicalUUID(value: UUID())
        let firstOwner = CanonicalUUID(value: UUID())
        let secondOwner = CanonicalUUID(value: UUID())
        let producerStarted = DispatchSemaphore(value: 0)
        let producerCancelled = DispatchSemaphore(value: 0)
        let releaseProducer = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        let firstFailure = LockedPipelineFailures()
        let secondFailure = LockedPipelineFailures()
        let capture: ProductionElementSnapshotPipeline.Capture = {
            producerCancellation in
            let registration = producerCancellation.register {
                producerCancelled.signal()
            }
            defer { producerCancellation.unregister(registration) }
            producerStarted.signal()
            releaseProducer.wait()
            try producerCancellation.check()
            return try Self.capture(geometry: geometry)
        }

        DispatchQueue.global().async {
            defer { firstFinished.signal() }
            do {
                _ = try pipeline.run(
                    requestID: firstRequestID,
                    cancellation: ProductionElementSnapshotCancellation(),
                    ownerClientInstanceID: firstOwner,
                    includeAnnotation: false,
                    artifactID: nil,
                    captureKey: key,
                    capture: capture
                )
            } catch {
                firstFailure.store(error)
            }
        }
        usleep(10_000)
        DispatchQueue.global().async {
            defer { secondFinished.signal() }
            do {
                _ = try pipeline.run(
                    requestID: secondRequestID,
                    cancellation: ProductionElementSnapshotCancellation(),
                    ownerClientInstanceID: secondOwner,
                    includeAnnotation: false,
                    artifactID: nil,
                    captureKey: key,
                    capture: capture
                )
            } catch {
                secondFailure.store(error)
            }
        }

        XCTAssertEqual(producerStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            pipeline.cancelOwnedPendingWork(
                targetRequestID: secondRequestID,
                ownerClientInstanceID: firstOwner
            ),
            ProductionElementPendingCancellationResult(
                disposition: .notOwned,
                targetPhase: "capture"
            )
        )
        XCTAssertEqual(
            pipeline.cancelOwnedPendingWork(
                targetRequestID: firstRequestID,
                ownerClientInstanceID: firstOwner
            ),
            ProductionElementPendingCancellationResult(
                disposition: .cancellationRequested,
                targetPhase: "capture"
            )
        )
        XCTAssertEqual(firstFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(producerCancelled.wait(timeout: .now() + 0.05), .timedOut)
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 0.05), .timedOut)
        XCTAssertEqual(
            firstFailure.error as? ProductionElementSnapshotPipelineError,
            .cancelled
        )
        releaseProducer.signal()
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 1), .success)
        XCTAssertNil(secondFailure.error)
    }

    func testOwnedCancellationMarksCaptureBeforeAnalyzerStarts() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let pipeline = ProductionElementSnapshotPipeline(
            canonicalUDID: target,
            analyzer: ElementAnalyzerCoordinator(operations: .init(
                omniparser: Self.emptyOmni,
                vision: Self.emptyVision,
                appleRegion: Self.emptyApple
            ))
        )
        let requestID = CanonicalUUID(value: UUID())
        let owner = CanonicalUUID(value: UUID())
        let cancellation = ProductionElementSnapshotCancellation()
        let captureStarted = DispatchSemaphore(value: 0)
        let releaseCapture = DispatchSemaphore(value: 0)
        let failures = LockedPipelineFailures()
        let finished = expectation(description: "capture cancellation finished")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                _ = try pipeline.run(
                    requestID: requestID,
                    cancellation: cancellation,
                    ownerClientInstanceID: owner,
                    includeAnnotation: false,
                    artifactID: nil,
                    capture: { _ in
                        captureStarted.signal()
                        _ = releaseCapture.wait(timeout: .now() + 2)
                        return try Self.capture()
                    }
                )
            } catch {
                failures.store(error)
            }
        }
        XCTAssertEqual(captureStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(
            pipeline.cancelOwnedPendingWork(
                targetRequestID: requestID,
                ownerClientInstanceID: owner
            ),
            ProductionElementPendingCancellationResult(
                disposition: .cancellationRequested,
                targetPhase: "capture"
            )
        )
        XCTAssertTrue(cancellation.isCancelled)
        releaseCapture.signal()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(
            failures.error as? ProductionElementSnapshotPipelineError,
            .cancelled
        )
    }

    func testAuthorityCancellationInterruptsAnalysisAndFencesLateResult() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let operation = SequencedPipelineOperation()
        let pipeline = ProductionElementSnapshotPipeline(
            canonicalUDID: target,
            analyzer: ElementAnalyzerCoordinator(operations: .init(
                omniparser: operation.analyze,
                vision: Self.emptyVision,
                appleRegion: Self.emptyApple
            ))
        )
        let cancellation = ProductionElementSnapshotCancellation()
        let failures = LockedPipelineFailures()
        let finished = expectation(description: "authority cancellation finished")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                _ = try pipeline.run(
                    requestID: CanonicalUUID(value: UUID()),
                    cancellation: cancellation,
                    includeAnnotation: false,
                    artifactID: nil,
                    capture: { _ in try Self.capture() }
                )
            } catch {
                failures.store(error)
            }
        }
        XCTAssertEqual(operation.started.wait(timeout: .now() + 2), .success)
        cancellation.cancel(cause: .authorityChanged)
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(cancellation.cancellationCause, .authorityChanged)
        XCTAssertEqual(
            failures.error as? ProductionElementSnapshotPipelineError,
            .cancelled
        )
        XCTAssertTrue(operation.firstCleanupFinished)

        let next = try pipeline.run(
            requestID: CanonicalUUID(value: UUID()),
            cancellation: ProductionElementSnapshotCancellation(),
            includeAnnotation: false,
            artifactID: nil,
            capture: { _ in try Self.capture() }
        )
        XCTAssertEqual(next.result.snapshotGeneration, 2)
    }

    func testAuthorityCancellationInterruptsCaptureBeforeAnalysis() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let pipeline = ProductionElementSnapshotPipeline(
            canonicalUDID: target,
            analyzer: ElementAnalyzerCoordinator(operations: .init(
                omniparser: Self.emptyOmni,
                vision: Self.emptyVision,
                appleRegion: Self.emptyApple
            ))
        )
        let cancellation = ProductionElementSnapshotCancellation()
        let captureStarted = DispatchSemaphore(value: 0)
        let releaseCapture = DispatchSemaphore(value: 0)
        let failures = LockedPipelineFailures()
        let finished = expectation(description: "authority capture cancellation finished")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                _ = try pipeline.run(
                    requestID: CanonicalUUID(value: UUID()),
                    cancellation: cancellation,
                    includeAnnotation: false,
                    artifactID: nil,
                    capture: { _ in
                        captureStarted.signal()
                        _ = releaseCapture.wait(timeout: .now() + 2)
                        return try Self.capture()
                    }
                )
            } catch {
                failures.store(error)
            }
        }
        XCTAssertEqual(captureStarted.wait(timeout: .now() + 2), .success)
        cancellation.cancel(cause: .authorityChanged)
        releaseCapture.signal()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(cancellation.cancellationCause, .authorityChanged)
        XCTAssertEqual(
            failures.error as? ProductionElementSnapshotPipelineError,
            .cancelled
        )
    }

    func testAuthorityCancellationInterruptsAnnotationAndFencesArtifact() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let annotationStarted = DispatchSemaphore(value: 0)
        let renderer = ElementAnnotationRenderer()
        let pipeline = ProductionElementSnapshotPipeline(
            canonicalUDID: target,
            analyzer: ElementAnalyzerCoordinator(operations: .init(
                omniparser: Self.emptyOmni,
                vision: Self.emptyVision,
                appleRegion: Self.emptyApple
            )),
            renderAnnotation: { frame, result in
                annotationStarted.signal()
                do { try await Task.sleep(for: .seconds(30)) } catch {}
                return try await renderer.render(frame: frame, result: result)
            }
        )
        let cancellation = ProductionElementSnapshotCancellation()
        let failures = LockedPipelineFailures()
        let finished = expectation(description: "annotation cancellation finished")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                _ = try pipeline.run(
                    requestID: CanonicalUUID(value: UUID()),
                    cancellation: cancellation,
                    includeAnnotation: true,
                    artifactID: CanonicalUUID(value: UUID()),
                    capture: { _ in try Self.capture() }
                )
            } catch {
                failures.store(error)
            }
        }
        XCTAssertEqual(annotationStarted.wait(timeout: .now() + 2), .success)
        cancellation.cancel(cause: .authorityChanged)
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(
            failures.error as? ProductionElementSnapshotPipelineError,
            .cancelled
        )
    }

    func testOwnerCancellationRemainsActiveBetweenAuthorityRetryAttempts() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let pipeline = ProductionElementSnapshotPipeline(
            canonicalUDID: target,
            analyzer: ElementAnalyzerCoordinator(operations: .init(
                omniparser: Self.emptyOmni,
                vision: Self.emptyVision,
                appleRegion: Self.emptyApple
            ))
        )
        let requestID = CanonicalUUID(value: UUID())
        let owner = CanonicalUUID(value: UUID())
        let requestCancellation = ProductionElementSnapshotCancellation()
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        try pipeline.withRequest(
            requestID: requestID,
            cancellation: requestCancellation,
            ownerClientInstanceID: owner,
            deadlineNanoseconds: deadline
        ) {
            let driftedAttempt = ProductionElementSnapshotCancellation()
            driftedAttempt.cancel(cause: .authorityChanged)
            XCTAssertThrowsError(try pipeline.runAttempt(
                requestID: requestID,
                cancellation: driftedAttempt,
                includeAnnotation: false,
                artifactID: nil,
                deadlineNanoseconds: deadline,
                capture: { _ in try Self.capture() }
            )) {
                XCTAssertEqual(
                    $0 as? ProductionElementSnapshotPipelineError,
                    .cancelled
                )
            }
            XCTAssertEqual(
                pipeline.cancelOwnedPendingWork(
                    targetRequestID: requestID,
                    ownerClientInstanceID: owner
                ),
                ProductionElementPendingCancellationResult(
                    disposition: .cancellationRequested,
                    targetPhase: "preparing"
                )
            )
            XCTAssertThrowsError(try pipeline.runAttempt(
                requestID: requestID,
                cancellation: ProductionElementSnapshotCancellation(),
                includeAnnotation: false,
                artifactID: nil,
                deadlineNanoseconds: deadline,
                capture: { _ in
                    XCTFail("owner-cancelled retry must not capture")
                    return try Self.capture()
                }
            )) {
                XCTAssertEqual(
                    $0 as? ProductionElementSnapshotPipelineError,
                    .cancelled
                )
            }
        }
        XCTAssertEqual(requestCancellation.cancellationCause, .requestCancelled)
    }

    func testWholeRequestDeadlineCancelsCaptureWithoutResetForRetry() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let pipeline = ProductionElementSnapshotPipeline(
            canonicalUDID: target,
            analyzer: ElementAnalyzerCoordinator(operations: .init(
                omniparser: Self.emptyOmni,
                vision: Self.emptyVision,
                appleRegion: Self.emptyApple
            ))
        )
        let requestID = CanonicalUUID(value: UUID())
        let requestCancellation = ProductionElementSnapshotCancellation()
        let deadline = DispatchTime.now().uptimeNanoseconds + 20_000_000
        XCTAssertThrowsError(try pipeline.withRequest(
            requestID: requestID,
            cancellation: requestCancellation,
            ownerClientInstanceID: nil,
            deadlineNanoseconds: deadline
        ) {
            try pipeline.runAttempt(
                requestID: requestID,
                cancellation: ProductionElementSnapshotCancellation(),
                includeAnnotation: false,
                artifactID: nil,
                deadlineNanoseconds: deadline,
                capture: { _ in
                    Thread.sleep(forTimeInterval: 0.05)
                    return try Self.capture()
                }
            )
        }) {
            XCTAssertEqual(
                $0 as? ProductionElementSnapshotPipelineError,
                .analysisTimedOut
            )
        }
        XCTAssertEqual(requestCancellation.cancellationCause, .deadlineExceeded)
    }

    private static func emptyOmni(
        _ frame: SnapshotFrame
    ) async -> ElementAnalyzerResult {
        empty(.omniparser, profileID: ElementAnalyzerProfiles.omniparser.profileID)
    }

    private static func emptyVision(
        _ frame: SnapshotFrame
    ) async -> ElementAnalyzerResult {
        empty(.vision, profileID: ElementAnalyzerProfiles.visionProfileID)
    }

    private static func emptyApple(
        _ frame: SnapshotFrame
    ) async -> ElementAnalyzerResult {
        empty(.appleRegion, profileID: ElementAnalyzerProfiles.appleRegion.profileID)
    }

    private static func empty(
        _ source: ElementAnalyzerSource,
        profileID: String
    ) -> ElementAnalyzerResult {
        let stageTimings: ElementAnalyzerStageTimings
        switch source {
        case .omniparser:
            stageTimings = .init(
                resizeAndColorSpaceMicroseconds: 0,
                inputEncodeMicroseconds: 0,
                requestEncodeMicroseconds: 0,
                transportRoundTripMicroseconds: 0,
                transportOverheadMicroseconds: 0,
                responseDecodeMicroseconds: 0
            )
        case .vision:
            stageTimings = .noDerivedInputOrTransport
        case .appleRegion:
            stageTimings = .init(
                resizeAndColorSpaceMicroseconds: 0,
                inputEncodeMicroseconds: 0,
                transportRoundTripMicroseconds: 0,
                transportOverheadMicroseconds: 0,
                responseDecodeMicroseconds: 0
            )
        case .localGeometry:
            stageTimings = .init()
        }
        return ElementAnalyzerResult(
            source: source,
            status: .succeeded,
            profileID: profileID,
            elapsedMilliseconds: 0,
            inputDimensions: try! SnapshotImageDimensions(width: 1, height: 1),
            backend: "test",
            version: "1",
            stageTimings: stageTimings
        )
    }

    private static func png() throws -> [UInt8] {
        let encoded =
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        return try XCTUnwrap(Data(base64Encoded: encoded)).map { $0 }
    }

    private static func capture() throws -> ProductionElementSnapshotCapture {
        try capture(geometry: geometry())
    }

    private static func capture(
        geometry: DisplayGeometryDTO,
        provider: SnapshotCaptureProvider = .coreDevice,
        captureAttempts: [ElementSnapshotCaptureAttempt]? = nil
    ) throws -> ProductionElementSnapshotCapture {
        ProductionElementSnapshotCapture(
            bytes: try png(),
            geometry: geometry,
            provider: provider,
            captureAttempts: captureAttempts
        )
    }

    private static func geometry(
        connectionEpoch: UInt64 = 1,
        geometryRevision: UInt64 = 1
    ) throws -> DisplayGeometryDTO {
        try DisplayGeometryDTO(
            connectionEpoch: connectionEpoch,
            geometryRevision: geometryRevision,
            logicalHeight: 1,
            logicalWidth: 1,
            orientation: .portrait
        )
    }

    private static func captureAttempt(
        provider: SnapshotCaptureProvider,
        status: ElementSnapshotCaptureAttemptStatus,
        errorCode: ElementSnapshotCaptureFailureCode? = nil,
        failureStage: ElementSnapshotCaptureFailureStage? = nil
    ) -> ElementSnapshotCaptureAttempt {
        ElementSnapshotCaptureAttempt(
            provider: provider,
            status: status,
            errorCode: errorCode,
            failureStage: failureStage,
            timings: ElementSnapshotCaptureAttemptTimings(
                captureMicroseconds: 10,
                queueWaitMicroseconds: 0,
                serviceCloseMicroseconds: 0,
                serviceOpenMicroseconds: 0,
                totalMicroseconds: 10
            )
        )
    }
}

private enum PipelineCaptureTestError: Error {
    case failed
}

private final class LockedPipelineFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    var error: Error? { lock.withLock { stored } }

    func store(_ error: Error) {
        lock.withLock { stored = error }
    }
}

private final class LockedPipelineOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ProductionElementSnapshotPipelineOutput?

    var value: ProductionElementSnapshotPipelineOutput? {
        lock.withLock { stored }
    }

    func store(_ output: ProductionElementSnapshotPipelineOutput) {
        lock.withLock { stored = output }
    }
}

private final class LockedPipelineCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int { lock.withLock { stored } }

    func increment() {
        lock.withLock { stored += 1 }
    }
}

private final class SequencedPipelineOperation: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var cleanupFinished = false
    private var invocationCount = 0

    var firstCleanupFinished: Bool {
        lock.withLock { cleanupFinished }
    }

    func analyze(_ frame: SnapshotFrame) async -> ElementAnalyzerResult {
        let invocation = lock.withLock {
            invocationCount += 1
            return invocationCount
        }
        if invocation == 1 {
            started.signal()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {}
            lock.withLock { cleanupFinished = true }
        }
        return ElementAnalyzerResult(
            source: .omniparser,
            status: .succeeded,
            profileID: ElementAnalyzerProfiles.omniparser.profileID,
            elapsedMilliseconds: 0,
            inputDimensions: frame.metadata.pixelDimensions,
            backend: "test",
            version: "1",
            stageTimings: ElementAnalyzerStageTimings(
                resizeAndColorSpaceMicroseconds: 0,
                inputEncodeMicroseconds: 0,
                requestEncodeMicroseconds: 0,
                transportRoundTripMicroseconds: 0,
                transportOverheadMicroseconds: 0,
                responseDecodeMicroseconds: 0
            )
        )
    }
}
