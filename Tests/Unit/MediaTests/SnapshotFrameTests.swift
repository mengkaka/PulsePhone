import CoreMedia
import CoreVideo
import Darwin
import Foundation
@testable import PulsePhoneMedia
import PulsePhoneSharedDefinitions
import XCTest

final class SnapshotFrameTests: XCTestCase {
    func testMetadataRejectsOldSequenceStaleFutureAndMismatchedEpoch() throws {
        let dimensions = try SnapshotImageDimensions(width: 1_179, height: 2_556)
        let geometry = try makeGeometry(
            connectionEpoch: 7,
            revision: 11,
            width: 393,
            height: 852,
            orientation: .portrait
        )
        let fence = try SnapshotFreshnessFence(
            queryStartedAtNanoseconds: 1_000,
            baselineFrameSequence: 40,
            maximumFrameAgeNanoseconds: 200,
            validatedAtNanoseconds: 1_150
        )

        XCTAssertThrowsError(try makeMetadata(
            geometry: geometry,
            dimensions: dimensions,
            fence: fence,
            frameSequence: 40,
            capturedAt: 1_100
        )) { error in
            XCTAssertEqual(error as? SnapshotFrameError, .frameSequenceNotAdvanced)
        }
        XCTAssertThrowsError(try makeMetadata(
            geometry: geometry,
            dimensions: dimensions,
            fence: fence,
            frameSequence: 41,
            capturedAt: 999
        )) { error in
            XCTAssertEqual(error as? SnapshotFrameError, .captureBeforeQueryFence)
        }
        XCTAssertThrowsError(try makeMetadata(
            geometry: geometry,
            dimensions: dimensions,
            fence: fence,
            frameSequence: 41,
            capturedAt: 1_151
        )) { error in
            XCTAssertEqual(error as? SnapshotFrameError, .frameFromFuture)
        }
        let staleFence = try SnapshotFreshnessFence(
            queryStartedAtNanoseconds: 1_000,
            baselineFrameSequence: 40,
            maximumFrameAgeNanoseconds: 100,
            validatedAtNanoseconds: 1_150
        )
        XCTAssertThrowsError(try makeMetadata(
            geometry: geometry,
            dimensions: dimensions,
            fence: staleFence,
            frameSequence: 41,
            capturedAt: 1_049
        )) { error in
            XCTAssertEqual(error as? SnapshotFrameError, .frameStale)
        }
        XCTAssertThrowsError(try SnapshotFrameMetadata(
            canonicalUDID: udid(),
            connectionEpoch: 8,
            sourceEpoch: 3,
            sourceID: "live-source",
            geometry: geometry,
            captureGeneration: 1,
            frameSequence: 41,
            capturedAtNanoseconds: 1_100,
            freshnessFence: fence,
            pixelDimensions: dimensions,
            provider: .liveVideo,
            settleReason: .queryFenceSatisfied
        )) { error in
            XCTAssertEqual(error as? SnapshotFrameError, .connectionEpochMismatch)
        }
    }

    func testFrameValidatesSourceDimensionsAndRetainsPixelBufferLease() throws {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            128,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        ), kCVReturnSuccess)
        weak let weakBuffer = pixelBuffer
        let lease = try SnapshotSourceImageLease(pixelBuffer: try XCTUnwrap(pixelBuffer))
        pixelBuffer = nil
        XCTAssertNotNil(weakBuffer)

        let metadata = try makeMetadata(
                geometry: makeGeometry(
                    connectionEpoch: 7,
                    revision: 11,
                    width: 32,
                    height: 64,
                    orientation: .portrait
                ),
                dimensions: SnapshotImageDimensions(width: 64, height: 128),
                fence: SnapshotFreshnessFence(
                    queryStartedAtNanoseconds: 1_000,
                    baselineFrameSequence: 40,
                    maximumFrameAgeNanoseconds: 200,
                    validatedAtNanoseconds: 1_150
                ),
                frameSequence: 41,
                capturedAt: 1_100
            )
        let frame = try SnapshotFrame(
            authority: authority(for: metadata),
            metadata: metadata,
            sourceImage: lease
        )
        XCTAssertTrue(frame.sourceImage.pixelBuffer === weakBuffer)

        let mismatched = try SnapshotSourceImageLease(
            encodedBytes: [1],
            contentType: "image/png",
            dimensions: SnapshotImageDimensions(width: 32, height: 32)
        )
        XCTAssertThrowsError(try SnapshotFrame(
            authority: frame.authority,
            metadata: frame.metadata,
            sourceImage: mismatched
        )) { error in
            XCTAssertEqual(error as? SnapshotFrameError, .sourceDimensionsMismatch)
        }
    }

    func testFrameRejectsAuthorityTargetEpochGeometryOrientationAndGenerationDrift() throws {
        let frame = try makeEncodedFrame(orientation: .portrait)
        let metadata = frame.metadata
        let cases: [(SnapshotFrameAuthority, SnapshotFrameError)] = [
            (
                try SnapshotFrameAuthority(
                    canonicalUDID: CanonicalUDID(
                        canonicalString: "00008030-001C2D123456002F"
                    ),
                    connectionEpoch: metadata.connectionEpoch,
                    sourceEpoch: metadata.sourceEpoch,
                    sourceID: metadata.sourceID,
                    geometryRevision: metadata.geometry.geometryRevision,
                    orientation: metadata.geometry.orientation,
                    captureGeneration: metadata.captureGeneration
                ),
                .targetMismatch
            ),
            (
                try authority(for: metadata, connectionEpoch: metadata.connectionEpoch + 1),
                .connectionEpochMismatch
            ),
            (
                try authority(for: metadata, sourceEpoch: try XCTUnwrap(metadata.sourceEpoch) + 1),
                .sourceEpochMismatch
            ),
            (
                try SnapshotFrameAuthority(
                    canonicalUDID: metadata.canonicalUDID,
                    connectionEpoch: metadata.connectionEpoch,
                    sourceEpoch: metadata.sourceEpoch,
                    sourceID: "different-source",
                    geometryRevision: metadata.geometry.geometryRevision,
                    orientation: metadata.geometry.orientation,
                    captureGeneration: metadata.captureGeneration
                ),
                .sourceIDMismatch
            ),
            (
                try authority(for: metadata, geometryRevision: metadata.geometry.geometryRevision + 1),
                .geometryRevisionMismatch
            ),
            (
                try authority(for: metadata, orientation: .landscapeLeft),
                .geometryOrientationMismatch
            ),
            (
                try authority(for: metadata, captureGeneration: metadata.captureGeneration + 1),
                .captureGenerationMismatch
            ),
        ]

        for (authority, expected) in cases {
            XCTAssertThrowsError(try SnapshotFrame(
                authority: authority,
                metadata: metadata,
                sourceImage: frame.sourceImage
            )) { error in
                XCTAssertEqual(error as? SnapshotFrameError, expected)
            }
        }
    }

    func testLongestEdgeUsesNonIntegerScaleAndRoundTripsPortraitBox() throws {
        let source = try SnapshotImageDimensions(width: 1_179, height: 2_556)
        let profile = try SnapshotDerivedImageProfile(
            profileID: "omniparser-v1",
            resize: .longestEdge(1_280),
            colorSpace: .sRGB,
            encoding: .png
        )
        let geometry = try profile.geometry(sourceDimensions: source)
        XCTAssertEqual(geometry.inputDimensions.width, 590)
        XCTAssertEqual(geometry.inputDimensions.height, 1_280)
        XCTAssertEqual(geometry.padding, zeroInsets())
        XCTAssertEqual(geometry.crop, zeroInsets())

        let sourceRect = try SnapshotPixelRect(x: 137.25, y: 401.5, width: 204.75, height: 88.25)
        let inputRect = try XCTUnwrap(geometry.mapSourceRectToInput(sourceRect))
        let restored = try XCTUnwrap(geometry.mapInputRectToSource(inputRect))
        assertRect(restored, equals: sourceRect, accuracy: 0.000_001)
    }

    func testLandscapeAspectFitRecordsLetterboxAndClipsPadding() throws {
        let source = try SnapshotImageDimensions(width: 2_556, height: 1_179)
        let profile = try SnapshotDerivedImageProfile(
            profileID: "apple-region-v1",
            resize: .aspectFit(width: 1_536, height: 1_024),
            colorSpace: .sRGB,
            encoding: .png
        )
        let geometry = try profile.geometry(sourceDimensions: source)
        XCTAssertEqual(geometry.padding.left, 0, accuracy: 0.000_001)
        XCTAssertEqual(geometry.padding.right, 0, accuracy: 0.000_001)
        XCTAssertGreaterThan(geometry.padding.top, 0)
        XCTAssertEqual(geometry.padding.top, geometry.padding.bottom, accuracy: 0.000_001)

        let partlyPadded = try SnapshotPixelRect(
            x: 100,
            y: geometry.padding.top - 20,
            width: 200,
            height: 80
        )
        let restored = try XCTUnwrap(geometry.mapInputRectToSource(partlyPadded))
        XCTAssertEqual(restored.y, 0, accuracy: 0.000_001)
        XCTAssertGreaterThan(restored.height, 0)

        let paddingOnly = try SnapshotPixelRect(x: 10, y: 1, width: 10, height: 10)
        XCTAssertNil(try geometry.mapInputRectToSource(paddingOnly))
    }

    func testAspectFillRecordsSymmetricCropAndInverseTransform() throws {
        let source = try SnapshotImageDimensions(width: 1_179, height: 2_556)
        let profile = try SnapshotDerivedImageProfile(
            profileID: "synthetic-crop-v1",
            resize: .aspectFill(width: 1_000, height: 1_000),
            colorSpace: .displayP3,
            encoding: .jpeg
        )
        let geometry = try profile.geometry(sourceDimensions: source)
        XCTAssertEqual(geometry.crop.left, 0, accuracy: 0.000_001)
        XCTAssertEqual(geometry.crop.right, 0, accuracy: 0.000_001)
        XCTAssertGreaterThan(geometry.crop.top, 0)
        XCTAssertEqual(geometry.crop.top, geometry.crop.bottom, accuracy: 0.000_001)
        XCTAssertEqual(geometry.padding, zeroInsets())

        let input = try SnapshotPixelRect(x: 100, y: 200, width: 300, height: 400)
        let sourceRect = try XCTUnwrap(geometry.mapInputRectToSource(input))
        let restored = try XCTUnwrap(geometry.mapSourceRectToInput(sourceRect))
        assertRect(restored, equals: input, accuracy: 0.000_001)
    }

    func testDerivedImageMaterializationIsSingleFlightAndCached() async throws {
        let frame = try makeEncodedFrame(orientation: .portrait)
        let profile = try SnapshotDerivedImageProfile(
            profileID: "single-flight-v1",
            resize: .longestEdge(1_280),
            colorSpace: .sRGB,
            encoding: .png
        )
        let calls = Counter()
        let materializer: SnapshotFrame.DerivedImageMaterializer = { _, geometry in
            await calls.increment()
            try await Task.sleep(nanoseconds: 30_000_000)
            return try SnapshotDerivedImagePayload(
                bytes: [1, 2, 3],
                contentType: "image/png",
                dimensions: geometry.inputDimensions
            )
        }

        async let first = frame.derivedImage(for: profile, materialize: materializer)
        async let second = frame.derivedImage(for: profile, materialize: materializer)
        let (firstImage, secondImage) = try await (first, second)
        XCTAssertEqual(firstImage, secondImage)
        let concurrentCallCount = await calls.value
        XCTAssertEqual(concurrentCallCount, 1)

        let cached = try await frame.derivedImage(for: profile, materialize: materializer)
        XCTAssertEqual(cached, firstImage)
        let cachedCallCount = await calls.value
        XCTAssertEqual(cachedCallCount, 1)
        XCTAssertEqual(cached.orientation, .portrait)
    }

    func testFailedOrCancelledMaterializationDoesNotPoisonRetry() async throws {
        let frame = try makeEncodedFrame(orientation: .landscapeLeft)
        let profile = try SnapshotDerivedImageProfile(
            profileID: "retry-v1",
            resize: .source,
            colorSpace: .source,
            encoding: .png
        )
        do {
            _ = try await frame.derivedImage(for: profile) { _, _ in
                throw CancellationError()
            }
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }

        let recovered = try await frame.derivedImage(for: profile) { _, geometry in
            try SnapshotDerivedImagePayload(
                bytes: [9],
                contentType: "image/png",
                dimensions: geometry.inputDimensions
            )
        }
        XCTAssertEqual(recovered.payload.bytes, [9])
        XCTAssertEqual(recovered.orientation, .landscapeLeft)
    }

    func testSampleBufferLeaseRetainsImageAndReleasesOffCaller() throws {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            128,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        ), kCVReturnSuccess)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: try XCTUnwrap(pixelBuffer),
            formatDescriptionOut: &format
        ), noErr)
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: try XCTUnwrap(pixelBuffer),
            formatDescription: try XCTUnwrap(format),
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ), noErr)
        weak let weakPixelBuffer = pixelBuffer
        weak let weakSampleBuffer = sampleBuffer
        let releaseStarted = DispatchSemaphore(value: 0)
        let allowRelease = DispatchSemaphore(value: 0)
        let releaseFinished = DispatchSemaphore(value: 0)
        var lease: SnapshotSourceImageLease? = try SnapshotSourceImageLease(
            sampleBuffer: try XCTUnwrap(sampleBuffer),
            releaseObserver: {
                releaseStarted.signal()
                _ = allowRelease.wait(timeout: .now() + 2)
                releaseFinished.signal()
            }
        )
        XCTAssertTrue(lease?.sampleBuffer === sampleBuffer)
        XCTAssertTrue(lease?.pixelBuffer === pixelBuffer)
        sampleBuffer = nil
        format = nil
        pixelBuffer = nil
        XCTAssertNotNil(weakSampleBuffer)
        XCTAssertNotNil(weakPixelBuffer)

        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            allowRelease.signal()
        }
        let started = ContinuousClock.now
        lease = nil
        let releaseCallDuration = started.duration(to: .now)
        XCTAssertLessThan(releaseCallDuration, .milliseconds(100))
        XCTAssertEqual(releaseStarted.wait(timeout: .now() + 1), .success)
        XCTAssertNotNil(weakSampleBuffer)
        XCTAssertNotNil(weakPixelBuffer)
        allowRelease.signal()
        XCTAssertEqual(releaseFinished.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(waitUntil { weakSampleBuffer == nil && weakPixelBuffer == nil })
    }

    func testCancellingOneDerivedImageWaiterDoesNotCancelSharedFlight() async throws {
        let frame = try makeEncodedFrame(orientation: .portrait)
        let profile = try SnapshotDerivedImageProfile(
            profileID: "shared-cancellation-v1",
            resize: .source,
            colorSpace: .source,
            encoding: .png
        )
        let started = DispatchSemaphore(value: 0)
        let release = AsyncGate()
        let calls = Counter()
        let materializer: SnapshotFrame.DerivedImageMaterializer = { _, geometry in
            await calls.increment()
            started.signal()
            await release.wait()
            try Task.checkCancellation()
            return try SnapshotDerivedImagePayload(
                bytes: [7],
                contentType: "image/png",
                dimensions: geometry.inputDimensions
            )
        }
        let first = Task {
            try await frame.derivedImage(for: profile, materialize: materializer)
        }
        let second = Task {
            try await frame.derivedImage(for: profile, materialize: materializer)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()
        let firstCancelled = expectation(description: "first waiter cancelled")
        let firstResult = Task {
            let result = await first.result
            firstCancelled.fulfill()
            return result
        }
        await fulfillment(of: [firstCancelled], timeout: 0.25)
        switch await firstResult.value {
        case .failure(let error):
            XCTAssertTrue(error is CancellationError)
        case .success:
            XCTFail("the cancelled waiter must not receive the shared result")
        }

        await release.open()
        let secondImage = try await second.value
        XCTAssertEqual(secondImage.payload.bytes, [7])
        let callCount = await calls.value
        XCTAssertEqual(callCount, 1)
    }

    func testCancellingAllDerivedImageWaitersStopsAndDoesNotCacheFlight()
        async throws
    {
        let frame = try makeEncodedFrame(orientation: .portrait)
        let profile = try SnapshotDerivedImageProfile(
            profileID: "all-cancelled-v1",
            resize: .source,
            colorSpace: .source,
            encoding: .png
        )
        let started = DispatchSemaphore(value: 0)
        let materializerCancelled = DispatchSemaphore(value: 0)
        let calls = Counter()
        let materializer: SnapshotFrame.DerivedImageMaterializer = { _, geometry in
            await calls.increment()
            started.signal()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                materializerCancelled.signal()
                throw error
            }
            return try SnapshotDerivedImagePayload(
                bytes: [1],
                contentType: "image/png",
                dimensions: geometry.inputDimensions
            )
        }
        let first = Task {
            try await frame.derivedImage(for: profile, materialize: materializer)
        }
        let second = Task {
            try await frame.derivedImage(for: profile, materialize: materializer)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()
        second.cancel()
        for result in [await first.result, await second.result] {
            guard case .failure(let error) = result else {
                XCTFail("all cancelled waiters must fail")
                continue
            }
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(materializerCancelled.wait(timeout: .now() + 1), .success)

        let recovered = try await frame.derivedImage(for: profile) { _, geometry in
            await calls.increment()
            return try SnapshotDerivedImagePayload(
                bytes: [9],
                contentType: "image/png",
                dimensions: geometry.inputDimensions
            )
        }
        XCTAssertEqual(recovered.payload.bytes, [9])
        let callCount = await calls.value
        XCTAssertEqual(callCount, 2)
    }

    @MainActor
    func testDerivedImageMaterializationLeavesMainActor() async throws {
        XCTAssertTrue(Thread.isMainThread)
        let frame = try makeEncodedFrame(orientation: .portrait)
        let profile = try SnapshotDerivedImageProfile(
            profileID: "detached-materialization-v1",
            resize: .source,
            colorSpace: .source,
            encoding: .png
        )
        let observed = ThreadObservation()
        _ = try await frame.derivedImage(for: profile) { _, geometry in
            await observed.record(isMainThread: pthread_main_np() != 0)
            return try SnapshotDerivedImagePayload(
                bytes: [3],
                contentType: "image/png",
                dimensions: geometry.inputDimensions
            )
        }
        let materializedOnMainThread = await observed.isMainThread
        XCTAssertEqual(materializedOnMainThread, false)
    }

    private func makeEncodedFrame(
        orientation: DisplayOrientationDTO
    ) throws -> SnapshotFrame {
        let dimensions = try SnapshotImageDimensions(width: 1_179, height: 2_556)
        let geometry = try makeGeometry(
            connectionEpoch: 7,
            revision: 11,
            width: 393,
            height: 852,
            orientation: orientation
        )
        let fence = try SnapshotFreshnessFence(
            queryStartedAtNanoseconds: 1_000,
            baselineFrameSequence: 40,
            maximumFrameAgeNanoseconds: 200,
            validatedAtNanoseconds: 1_150
        )
        return try SnapshotFrame(
            authority: SnapshotFrameAuthority(
                canonicalUDID: udid(),
                geometry: geometry,
                sourceEpoch: 3,
                sourceID: "live-source",
                captureGeneration: 5
            ),
            metadata: makeMetadata(
                geometry: geometry,
                dimensions: dimensions,
                fence: fence,
                frameSequence: 41,
                capturedAt: 1_100
            ),
            sourceImage: SnapshotSourceImageLease(
                encodedBytes: [0x89, 0x50, 0x4e, 0x47],
                contentType: "image/png",
                dimensions: dimensions
            )
        )
    }

    private func makeMetadata(
        geometry: DisplayGeometryDTO,
        dimensions: SnapshotImageDimensions,
        fence: SnapshotFreshnessFence,
        frameSequence: UInt64,
        capturedAt: UInt64
    ) throws -> SnapshotFrameMetadata {
        try SnapshotFrameMetadata(
            canonicalUDID: udid(),
            connectionEpoch: geometry.connectionEpoch,
            sourceEpoch: 3,
            sourceID: "live-source",
            geometry: geometry,
            captureGeneration: 5,
            frameSequence: frameSequence,
            capturedAtNanoseconds: capturedAt,
            freshnessFence: fence,
            pixelDimensions: dimensions,
            provider: .liveVideo,
            settleReason: .queryFenceSatisfied
        )
    }

    private func makeGeometry(
        connectionEpoch: UInt64,
        revision: UInt64,
        width: UInt64,
        height: UInt64,
        orientation: DisplayOrientationDTO
    ) throws -> DisplayGeometryDTO {
        try DisplayGeometryDTO(
            connectionEpoch: connectionEpoch,
            geometryRevision: revision,
            logicalHeight: height,
            logicalWidth: width,
            orientation: orientation
        )
    }

    private func authority(
        for metadata: SnapshotFrameMetadata,
        connectionEpoch: UInt64? = nil,
        sourceEpoch: UInt64? = nil,
        geometryRevision: UInt64? = nil,
        orientation: DisplayOrientationDTO? = nil,
        captureGeneration: UInt64? = nil
    ) throws -> SnapshotFrameAuthority {
        try SnapshotFrameAuthority(
            canonicalUDID: metadata.canonicalUDID,
            connectionEpoch: connectionEpoch ?? metadata.connectionEpoch,
            sourceEpoch: sourceEpoch ?? metadata.sourceEpoch,
            sourceID: metadata.sourceID,
            geometryRevision: geometryRevision ?? metadata.geometry.geometryRevision,
            orientation: orientation ?? metadata.geometry.orientation,
            captureGeneration: captureGeneration ?? metadata.captureGeneration
        )
    }

    private func udid() throws -> CanonicalUDID {
        try CanonicalUDID(canonicalString: "00008020-001C2D123456002E")
    }

    private func zeroInsets() -> SnapshotImageInsets {
        try! SnapshotImageInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    private func assertRect(
        _ actual: SnapshotPixelRect,
        equals expected: SnapshotPixelRect,
        accuracy: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, file: file, line: line)
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return condition()
    }
}

private actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor AsyncGate {
    private var openState = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func wait() async {
        if openState { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !openState else { return }
        openState = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor ThreadObservation {
    private(set) var isMainThread: Bool?

    func record(isMainThread: Bool) {
        self.isMainThread = isMainThread
    }
}
