import CoreMedia
import CoreVideo
import Foundation
@testable import PulsePhoneGUI
@testable import PulsePhoneMedia
import PulsePhoneSharedDefinitions
import XCTest

final class ProductionSourceCaptureCoordinatorTests: XCTestCase {
    func testBoundSessionPromotesProvisionalGeometryWithoutRestartingCapture()
        async throws
    {
        let harness = try CaptureCoordinatorHarness()
        let coordinator = ProductionSourceCaptureCoordinator(
            captureFactory: harness.factory
        )
        let target = try CanonicalUDID(
            canonicalString: "M2031-LIVE-PROVISIONAL-SESSION"
        )
        let provisional = try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 0,
            logicalHeight: 32,
            logicalWidth: 16,
            orientation: .portrait
        )
        let mapping = ProductionVideoSourceMapping(
            connectionEpoch: provisional.connectionEpoch,
            geometry: provisional,
            mappingProofID: "operator-proof",
            sourceEpoch: 7,
            sourceID: harness.sourceID
        )
        let inventory = try VideoSourceInventory(
            inventoryRevision: 1,
            sources: [try VideoSourceDescriptor(
                sourceID: harness.sourceID,
                sourceEpoch: 7,
                activeFormatWidth: 16,
                activeFormatHeight: 32
            )]
        )
        let lease = try coordinator.acquire(
            sourceID: harness.sourceID,
            sourceEpoch: 7,
            role: .liveProbe,
            frameHandler: { _ in }
        )
        try lease.start()
        let captureReady = LockedInteger()
        let session = try ProductionBoundVideoSession.start(
            target: target,
            mapping: mapping,
            captureLease: lease,
            inventory: inventory,
            captureReadyHandler: { _ in captureReady.increment() }
        )
        let provider = session.liveSnapshotFrameProvider

        XCTAssertEqual(provider.snapshot().state, .provisional)
        harness.emit()
        XCTAssertEqual(captureReady.value, 1)
        XCTAssertEqual(provider.snapshot().latestAcceptedFrameSequence, nil)
        XCTAssertEqual(harness.backendCount, 1)
        XCTAssertEqual(harness.startCount, 1)

        let authoritative = try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 1,
            logicalHeight: 32,
            logicalWidth: 16,
            orientation: .portrait
        )
        XCTAssertTrue(session.rebindGeometry(authoritative))
        XCTAssertEqual(provider.snapshot().state, .active)
        XCTAssertEqual(harness.backendCount, 1)
        XCTAssertEqual(harness.startCount, 1)

        let request = Task {
            try await provider.frame(
                expectedBinding: session.bindingIdentity,
                expectedGeometry: authoritative,
                captureGeneration: 1,
                maximumFrameAgeNanoseconds: 1_000_000_000
            )
        }
        for _ in 0..<1_000 {
            if provider.snapshot().pendingRequestCount == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(provider.snapshot().pendingRequestCount, 1)
        harness.emit()
        let frame = try await request.value
        XCTAssertEqual(frame.metadata.geometry.geometryRevision, 1)
        XCTAssertEqual(frame.metadata.frameSequence, 2)

        session.stop()
        XCTAssertEqual(provider.snapshot().state, .retired)
        XCTAssertEqual(harness.stopCount, 1)
    }

    func testBoundSessionPublishesAcceptedSampleToLiveSnapshotProvider()
        async throws
    {
        let harness = try CaptureCoordinatorHarness()
        let coordinator = ProductionSourceCaptureCoordinator(
            captureFactory: harness.factory
        )
        let target = try CanonicalUDID(
            canonicalString: "M2031-LIVE-SNAPSHOT-SESSION"
        )
        let geometry = try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 13,
            logicalHeight: 32,
            logicalWidth: 16,
            orientation: .portrait
        )
        let mapping = ProductionVideoSourceMapping(
            connectionEpoch: geometry.connectionEpoch,
            geometry: geometry,
            mappingProofID: "operator-proof",
            sourceEpoch: 7,
            sourceID: harness.sourceID
        )
        let inventory = try VideoSourceInventory(
            inventoryRevision: 1,
            sources: [try VideoSourceDescriptor(
                sourceID: harness.sourceID,
                sourceEpoch: 7,
                activeFormatWidth: 16,
                activeFormatHeight: 32
            )]
        )
        let lease = try coordinator.acquire(
            sourceID: harness.sourceID,
            sourceEpoch: 7,
            role: .liveProbe,
            frameHandler: { _ in }
        )
        try lease.start()
        let session = try ProductionBoundVideoSession.start(
            target: target,
            mapping: mapping,
            captureLease: lease,
            inventory: inventory
        )
        let provider = session.liveSnapshotFrameProvider
        let request = Task {
            try await provider.frame(
                expectedBinding: session.bindingIdentity,
                expectedGeometry: geometry,
                captureGeneration: 1,
                maximumFrameAgeNanoseconds: 1_000_000_000
            )
        }
        for _ in 0..<1_000 {
            if provider.snapshot().pendingRequestCount == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(provider.snapshot().pendingRequestCount, 1)

        harness.emit()

        let frame = try await request.value
        XCTAssertEqual(frame.metadata.provider, .liveVideo)
        XCTAssertEqual(frame.metadata.canonicalUDID, target)
        XCTAssertEqual(frame.metadata.frameSequence, 1)
        XCTAssertEqual(frame.sourceImage.kind, .pixelBuffer)
        XCTAssertNotNil(frame.sourceImage.sampleBuffer)
        XCTAssertEqual(harness.backendCount, 1)
        XCTAssertEqual(harness.startCount, 1)
        session.stop()
        XCTAssertEqual(provider.snapshot().state, .retired)
        XCTAssertEqual(harness.stopCount, 1)
    }

    func testBoundSessionReusesAcceptedSampleAndFingerprintForSettlement()
        async throws
    {
        let harness = try CaptureCoordinatorHarness()
        let coordinator = ProductionSourceCaptureCoordinator(
            captureFactory: harness.factory
        )
        let target = try CanonicalUDID(
            canonicalString: "M2031-LIVE-SETTLEMENT-SESSION"
        )
        let geometry = try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 13,
            logicalHeight: 32,
            logicalWidth: 16,
            orientation: .portrait
        )
        let mapping = ProductionVideoSourceMapping(
            connectionEpoch: geometry.connectionEpoch,
            geometry: geometry,
            mappingProofID: "operator-proof",
            sourceEpoch: 7,
            sourceID: harness.sourceID
        )
        let inventory = try VideoSourceInventory(
            inventoryRevision: 1,
            sources: [try VideoSourceDescriptor(
                sourceID: harness.sourceID,
                sourceEpoch: 7,
                activeFormatWidth: 16,
                activeFormatHeight: 32
            )]
        )
        let lease = try coordinator.acquire(
            sourceID: harness.sourceID,
            sourceEpoch: 7,
            role: .liveProbe,
            frameHandler: { _ in }
        )
        try lease.start()
        let session = try ProductionBoundVideoSession.start(
            target: target,
            mapping: mapping,
            captureLease: lease,
            inventory: inventory
        )
        harness.emit()
        let actionID = CanonicalUUID(value: UUID())
        XCTAssertEqual(session.beginVisualChangeProbe(
            actionID: actionID,
            commandID: "button.home",
            clickedAtNanoseconds: SystemMonotonicClock().now().nanoseconds
        ).rawValue, "armed")
        let provider = session.liveSnapshotFrameProvider
        let request = Task {
            try await provider.frame(
                expectedBinding: session.bindingIdentity,
                expectedGeometry: geometry,
                captureGeneration: 1,
                maximumFrameAgeNanoseconds: 1_000_000_000,
                afterActionID: actionID
            )
        }
        for _ in 0..<1_000 {
            if provider.snapshot().pendingRequestCount == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(provider.snapshot().pendingRequestCount, 1)

        harness.emit(changed: true)
        try await Task.sleep(for: .milliseconds(130))
        let stableSample = harness.emit(changed: true)

        let frame = try await request.value
        XCTAssertEqual(frame.metadata.settleReason, .stableAfterVisualChange)
        XCTAssertTrue(frame.sourceImage.sampleBuffer === stableSample)
        XCTAssertEqual(harness.backendCount, 1)
        XCTAssertEqual(harness.startCount, 1)
        session.stop()
        XCTAssertEqual(harness.stopCount, 1)
    }

    func testSameSourceUsesOneBackendAndStopsAfterLastConsumer() throws {
        let harness = try CaptureCoordinatorHarness()
        let coordinator = ProductionSourceCaptureCoordinator(
            captureFactory: harness.factory
        )
        let first = try coordinator.acquire(
            sourceID: harness.sourceID,
            sourceEpoch: 7,
            role: .thumbnail,
            frameHandler: { _ in }
        )
        let second = try coordinator.acquire(
            sourceID: harness.sourceID,
            sourceEpoch: 7,
            role: .chooserPreview,
            frameHandler: { _ in }
        )

        try first.start()
        try second.start()
        XCTAssertEqual(harness.backendCount, 1)
        XCTAssertEqual(harness.startCount, 1)

        first.stop()
        XCTAssertEqual(harness.stopCount, 0)
        second.stop()
        XCTAssertEqual(harness.stopCount, 1)
    }

    func testProbePromotionReplacesSinkWithoutRestartingBackend() throws {
        let harness = try CaptureCoordinatorHarness()
        let coordinator = ProductionSourceCaptureCoordinator(
            captureFactory: harness.factory
        )
        let probeFrames = LockedInteger()
        let boundFrames = LockedInteger()
        let lease = try coordinator.acquire(
            sourceID: harness.sourceID,
            sourceEpoch: 7,
            role: .liveProbe,
            frameHandler: { _ in probeFrames.increment() }
        )
        try lease.start()
        harness.emit()
        XCTAssertEqual(probeFrames.value, 1)

        try lease.update(
            role: .bound,
            frameHandler: { _ in boundFrames.increment() }
        )
        harness.emit()
        XCTAssertEqual(probeFrames.value, 1)
        XCTAssertEqual(boundFrames.value, 1)
        XCTAssertEqual(harness.backendCount, 1)
        XCTAssertEqual(harness.startCount, 1)
        lease.stop()
        XCTAssertEqual(harness.stopCount, 1)
    }

    func testChooserHandoffIsClaimedByLiveWithoutStoppingBackend() throws {
        let harness = try CaptureCoordinatorHarness()
        let coordinator = ProductionSourceCaptureCoordinator(
            captureFactory: harness.factory
        )
        let target = try CanonicalUDID(canonicalString: "TARGET-HANDOFF")
        let chooser = try coordinator.acquire(
            sourceID: harness.sourceID,
            sourceEpoch: 7,
            role: .chooserPreview,
            frameHandler: { _ in }
        )
        try chooser.start()
        XCTAssertTrue(chooser.transferForHandoff(target: target, ownerID: "owner"))
        XCTAssertEqual(harness.stopCount, 0)

        let live = try coordinator.acquire(
            sourceID: harness.sourceID,
            sourceEpoch: 7,
            role: .liveProbe,
            handoffTarget: target,
            handoffOwnerID: "owner",
            frameHandler: { _ in }
        )
        try live.start()
        XCTAssertEqual(harness.backendCount, 1)
        XCTAssertEqual(harness.startCount, 1)
        XCTAssertEqual(harness.stopCount, 0)
        live.stop()
        XCTAssertEqual(harness.stopCount, 1)
    }

    func testChooserHandoffRestartsBackendStoppedOutsideCoordinator() throws {
        let harness = try CaptureCoordinatorHarness()
        let coordinator = ProductionSourceCaptureCoordinator(
            captureFactory: harness.factory
        )
        let target = try CanonicalUDID(canonicalString: "TARGET-HANDOFF")
        let chooser = try coordinator.acquire(
            sourceID: harness.sourceID,
            sourceEpoch: 7,
            role: .chooserPreview,
            frameHandler: { _ in }
        )
        try chooser.start()
        XCTAssertTrue(chooser.transferForHandoff(target: target, ownerID: "owner"))
        harness.stopBackendOutsideCoordinator()

        let live = try coordinator.acquire(
            sourceID: harness.sourceID,
            sourceEpoch: 7,
            role: .liveProbe,
            handoffTarget: target,
            handoffOwnerID: "owner",
            frameHandler: { _ in }
        )
        try live.start()

        XCTAssertEqual(harness.backendCount, 1)
        XCTAssertEqual(harness.startCount, 2)
        XCTAssertTrue(live.isRunning)
        live.stop()
        XCTAssertEqual(harness.stopCount, 1)
    }

    func testDifferentSourceEpochCreatesIndependentBackend() throws {
        let harness = try CaptureCoordinatorHarness()
        let coordinator = ProductionSourceCaptureCoordinator(
            captureFactory: harness.factory
        )
        let first = try coordinator.acquire(
            sourceID: harness.sourceID,
            sourceEpoch: 7,
            role: .liveProbe,
            frameHandler: { _ in }
        )
        let second = try coordinator.acquire(
            sourceID: harness.sourceID,
            sourceEpoch: 8,
            role: .liveProbe,
            frameHandler: { _ in }
        )
        try first.start()
        try second.start()
        XCTAssertEqual(harness.backendCount, 2)
        first.stop()
        second.stop()
        XCTAssertEqual(harness.stopCount, 2)
    }

    func testStopDrainsSynchronousTailFrameWithoutCoordinatorLockCycle() throws {
        let harness = try CaptureCoordinatorHarness()
        harness.emitsFrameOnStop = true
        let coordinator = ProductionSourceCaptureCoordinator(
            captureFactory: harness.factory
        )
        let frames = LockedInteger()
        let lease = try coordinator.acquire(
            sourceID: harness.sourceID,
            sourceEpoch: 7,
            role: .bound,
            frameHandler: { _ in frames.increment() }
        )
        try lease.start()

        lease.stop()

        XCTAssertEqual(harness.stopCount, 1)
        XCTAssertEqual(frames.value, 0)
    }

    func testBoundAndChooserDisplayConsumersReceiveIndependentSampleWrappers() throws {
        let harness = try CaptureCoordinatorHarness()
        let coordinator = ProductionSourceCaptureCoordinator(
            captureFactory: harness.factory
        )
        let boundSamples = LockedSamples()
        let chooserSamples = LockedSamples()
        let bound = try coordinator.acquire(
            sourceID: harness.sourceID,
            sourceEpoch: 7,
            role: .bound,
            frameHandler: { sample in
                if let copy = ProductionSampleBufferDisplay.makeImmediateDisplayCopy(
                    sample.sampleBuffer
                ) {
                    boundSamples.append(copy)
                }
            }
        )
        let chooser = try coordinator.acquire(
            sourceID: harness.sourceID,
            sourceEpoch: 7,
            role: .chooserPreview,
            frameHandler: { sample in
                if let copy = ProductionSampleBufferDisplay.makeImmediateDisplayCopy(
                    sample.sampleBuffer
                ) {
                    chooserSamples.append(copy)
                }
            }
        )
        try bound.start()
        try chooser.start()

        for _ in 0..<100 { harness.emit() }
        chooser.stop()
        for _ in 0..<20 { harness.emit() }
        bound.stop()

        XCTAssertEqual(boundSamples.count, 120)
        XCTAssertEqual(chooserSamples.count, 100)
        let boundFirst = try XCTUnwrap(boundSamples.first)
        let chooserFirst = try XCTUnwrap(chooserSamples.first)
        let boundAttachments = try sampleAttachments(boundFirst)
        let chooserAttachments = try sampleAttachments(chooserFirst)
        XCTAssertFalse(boundAttachments[0] === chooserAttachments[0])
        boundAttachments[0]["bound-only"] = true
        XCTAssertNil(chooserAttachments[0]["bound-only"])
        XCTAssertTrue(harness.originalAttachments.allSatisfy {
            $0[kCMSampleAttachmentKey_DisplayImmediately] == nil
        })
        XCTAssertEqual(harness.backendCount, 1)
        XCTAssertEqual(harness.stopCount, 1)
    }

    func testVideoLivenessUsesExactTwoSecondDeadlineAndStallsOnce() {
        let timeout = ProductionVideoCaptureLivenessState.timeoutNanoseconds
        var state = ProductionVideoCaptureLivenessState()

        XCTAssertEqual(
            state.evaluate(atNanoseconds: 100, captureIsRunning: true),
            .inactive
        )
        state.observeSample(atNanoseconds: 1_000)
        XCTAssertEqual(
            state.evaluate(atNanoseconds: 1_500, captureIsRunning: false),
            .inactive
        )
        XCTAssertEqual(
            state.evaluate(
                atNanoseconds: 1_000 + timeout - 1,
                captureIsRunning: true
            ),
            .pending(afterNanoseconds: 1)
        )
        XCTAssertEqual(
            state.evaluate(
                atNanoseconds: 1_000 + timeout,
                captureIsRunning: true
            ),
            .stalled
        )
        XCTAssertEqual(
            state.evaluate(
                atNanoseconds: 1_000 + timeout + 1,
                captureIsRunning: true
            ),
            .inactive
        )
    }

    func testVideoLivenessFutureTimestampWaitsAFullWindow() {
        var state = ProductionVideoCaptureLivenessState()
        state.observeSample(atNanoseconds: 2_000)

        XCTAssertEqual(
            state.evaluate(atNanoseconds: 1_000, captureIsRunning: true),
            .pending(
                afterNanoseconds: ProductionVideoCaptureLivenessState
                    .timeoutNanoseconds
            )
        )
    }

    func testStallRecoveryGateAllowsOneAttemptPerVideoIdentity() {
        let first = ProductionVideoSourceMappingAttempt(
            connectionEpoch: 3,
            sourceEpoch: 5,
            sourceID: "source-a"
        )
        let newer = ProductionVideoSourceMappingAttempt(
            connectionEpoch: 3,
            sourceEpoch: 6,
            sourceID: "source-a"
        )
        var gate = ProductionVideoStallRecoveryGate()

        XCTAssertTrue(gate.beginCleanReacquire(for: first))
        XCTAssertFalse(gate.beginCleanReacquire(for: first))
        XCTAssertTrue(gate.beginCleanReacquire(for: newer))
        gate.reset()
        XCTAssertTrue(gate.beginCleanReacquire(for: first))
    }
}

private final class CaptureCoordinatorHarness: @unchecked Sendable {
    let sourceID = String(repeating: "a", count: 64)

    private let lock = NSLock()
    private var backends = [CaptureCoordinatorBackend]()
    private var frameHandlers = [
        ProductionAVFoundationVideoSourceCatalog.FrameHandler
    ]()
    private let changedSampleBuffer: CMSampleBuffer
    private var nextFrameSequence: UInt64 = 1
    private let sampleBuffer: CMSampleBuffer
    var emitsFrameOnStop = false

    init() throws {
        sampleBuffer = try Self.makeSampleBuffer(component: 0)
        changedSampleBuffer = try Self.makeSampleBuffer(component: 255)
    }

    var factory: ProductionSourceCaptureCoordinator.CaptureFactory {
        { [self] _, _, frameHandler, _ in
            let emitsFrameOnStop = lock.withLock { self.emitsFrameOnStop }
            let onStop: (@Sendable () -> Void)?
            if emitsFrameOnStop {
                onStop = { [self] in
                    frameHandler(makeSample())
                }
            } else {
                onStop = nil
            }
            let backend = CaptureCoordinatorBackend(onStop: onStop)
            lock.withLock {
                backends.append(backend)
                frameHandlers.append(frameHandler)
            }
            return backend
        }
    }

    var backendCount: Int { lock.withLock { backends.count } }
    var startCount: Int { lock.withLock { backends.reduce(0) { $0 + $1.startCount } } }
    var stopCount: Int { lock.withLock { backends.reduce(0) { $0 + $1.stopCount } } }

    var originalAttachments: [NSMutableDictionary] {
        (try? sampleAttachments(sampleBuffer)) ?? []
    }

    @discardableResult
    func emit(changed: Bool = false) -> CMSampleBuffer {
        let handlers = lock.withLock { frameHandlers }
        let sample = makeSample(
            sampleBuffer: changed ? changedSampleBuffer : sampleBuffer
        )
        for handler in handlers { handler(sample) }
        return sample.sampleBuffer
    }

    func stopBackendOutsideCoordinator() {
        lock.withLock { backends.first }?.stopOutsideCoordinator()
    }

    private func makeSample(
        sampleBuffer: CMSampleBuffer? = nil
    ) -> AVFoundationVideoFrameSample {
        let frameSequence = lock.withLock { () -> UInt64 in
            let sequence = nextFrameSequence
            nextFrameSequence &+= 1
            return sequence
        }
        return AVFoundationVideoFrameSample(
            sourceID: sourceID,
            sourceEpoch: 7,
            frameSequence: frameSequence,
            delegateMonotonicNanoseconds: SystemMonotonicClock().now().nanoseconds,
            presentationWidth: 16,
            presentationHeight: 32,
            sampleBuffer: sampleBuffer ?? self.sampleBuffer
        )
    }

    private static func makeSampleBuffer(component: UInt8) throws
        -> CMSampleBuffer
    {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            32,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        ) == kCVReturnSuccess,
        let pixelBuffer,
        CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess,
        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
        else { throw CaptureCoordinatorTestError.fixture }
        memset(
            baseAddress,
            Int32(component),
            CVPixelBufferGetBytesPerRow(pixelBuffer)
                * CVPixelBufferGetHeight(pixelBuffer)
        )
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &description
        ) == noErr,
        let description
        else { throw CaptureCoordinatorTestError.fixture }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr,
        let sample
        else { throw CaptureCoordinatorTestError.fixture }
        return sample
    }
}

private final class LockedSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = [CMSampleBuffer]()

    var count: Int { lock.withLock { samples.count } }
    var first: CMSampleBuffer? { lock.withLock { samples.first } }

    func append(_ sample: CMSampleBuffer) {
        lock.withLock { samples.append(sample) }
    }
}

private func sampleAttachments(
    _ sampleBuffer: CMSampleBuffer
) throws -> [NSMutableDictionary] {
    guard let raw = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer,
        createIfNecessary: true
    ) else { throw CaptureCoordinatorTestError.fixture }
    let array = raw as NSArray
    let dictionaries = array.compactMap { $0 as? NSMutableDictionary }
    guard dictionaries.count == array.count else {
        throw CaptureCoordinatorTestError.fixture
    }
    return dictionaries
}

private final class CaptureCoordinatorBackend:
    ProductionSourceCaptureBackend,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var running = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private let onStop: (@Sendable () -> Void)?

    init(onStop: (@Sendable () -> Void)? = nil) {
        self.onStop = onStop
    }

    var audioDeviceUniqueID: String? { nil }
    var hasAudioOutput: Bool { false }
    var isRunning: Bool { lock.withLock { running } }

    func start() throws {
        lock.withLock {
            guard !running else { return }
            running = true
            startCount += 1
        }
    }

    func stop() {
        let shouldNotify = lock.withLock { () -> Bool in
            guard running else { return false }
            running = false
            stopCount += 1
            return true
        }
        if shouldNotify { onStop?() }
    }

    func stopOutsideCoordinator() {
        lock.withLock { running = false }
    }

    func reconfigure(
        shouldRestart: @escaping @Sendable () -> Bool
    ) throws -> Bool {
        shouldRestart()
    }
}

private final class LockedInteger: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

private enum CaptureCoordinatorTestError: Error {
    case fixture
}
