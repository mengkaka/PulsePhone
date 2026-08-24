import CoreMedia
import CoreVideo
import Foundation
@testable import PulsePhoneMedia
import PulsePhoneSharedDefinitions
import XCTest

final class LiveSnapshotFrameProviderTests: XCTestCase {
    func testProvisionalGeometryStartsUnavailableAndActivatesAfterRebind()
        async throws
    {
        let target = try CanonicalUDID(
            canonicalString: "M2031-LIVE-PROVISIONAL"
        )
        let geometry = try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 0,
            logicalHeight: 128,
            logicalWidth: 64,
            orientation: .portrait
        )
        let fixture = Fixture(
            binding: VideoBindingIdentity(
                canonicalUDID: target,
                connectionEpoch: geometry.connectionEpoch,
                sourceID: String(repeating: "a", count: 64),
                sourceEpoch: 11,
                geometryRevision: geometry.geometryRevision
            ),
            geometry: geometry
        )
        let clock = TestMonotonicClock(100)
        let provider = try fixture.provider(clock: clock)
        let sample = try makeSampleBuffer(width: 64, height: 128)

        XCTAssertEqual(provider.snapshot().state, .provisional)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: 100,
            frameSequence: 1,
            binding: fixture.binding
        ), .ignored(.provisional))
        await assertImmediateUnavailable(
            .provisional,
            provider: provider,
            fixture: fixture
        )
        XCTAssertThrowsError(try provider.recordAction(
            actionID: CanonicalUUID(value: UUID()),
            startedAtNanoseconds: 100
        )) { error in
            XCTAssertEqual(
                error as? LiveSnapshotFrameProviderError,
                .unavailable(.provisional)
            )
        }

        let authoritative = try fixture.rebound(
            geometryRevision: 1,
            orientation: .portrait
        )
        try provider.rebind(
            binding: authoritative.binding,
            geometry: authoritative.geometry,
            reconfiguring: false
        )
        XCTAssertEqual(provider.snapshot().state, .active)

        let request = Task {
            try await provider.frame(
                expectedBinding: authoritative.binding,
                expectedGeometry: authoritative.geometry,
                captureGeneration: 1,
                maximumFrameAgeNanoseconds: 1_000
            )
        }
        try await waitForPendingRequestCount(1, provider: provider)
        clock.set(101)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: 101,
            frameSequence: 2,
            binding: authoritative.binding
        ), .published(completedRequestCount: 1))
        let frame = try await request.value
        XCTAssertEqual(frame.metadata.geometry.geometryRevision, 1)
        XCTAssertEqual(frame.metadata.frameSequence, 2)
    }

    func testQueryFreezesBaselineAndTimestampAndReturnsAcceptedSampleLease()
        async throws
    {
        let fixture = try Fixture(
            target: "M2031-LIVE-FRESHNESS",
            orientation: .portrait
        )
        let clock = TestMonotonicClock(80)
        let provider = try fixture.provider(clock: clock)
        let sample = try makeSampleBuffer(width: 64, height: 128)

        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: 80,
            frameSequence: 30,
            binding: fixture.binding
        ), .published(completedRequestCount: 0))

        clock.set(100)
        let request = Task {
            try await provider.frame(
                expectedBinding: fixture.binding,
                expectedGeometry: fixture.geometry,
                captureGeneration: 7,
                maximumFrameAgeNanoseconds: 1_000
            )
        }
        try await waitForPendingRequestCount(1, provider: provider)

        clock.set(101)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: 99,
            frameSequence: 31,
            binding: fixture.binding
        ), .published(completedRequestCount: 0))
        XCTAssertEqual(provider.snapshot().pendingRequestCount, 1)

        clock.set(102)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: 101,
            frameSequence: 32,
            binding: fixture.binding
        ), .published(completedRequestCount: 1))

        let frame = try await request.value
        XCTAssertEqual(frame.metadata.provider, .liveVideo)
        XCTAssertEqual(frame.metadata.captureGeneration, 7)
        XCTAssertEqual(frame.metadata.frameSequence, 32)
        XCTAssertEqual(frame.metadata.capturedAtNanoseconds, 101)
        XCTAssertEqual(frame.metadata.freshnessFence.baselineFrameSequence, 30)
        XCTAssertEqual(frame.metadata.freshnessFence.queryStartedAtNanoseconds, 100)
        XCTAssertEqual(frame.metadata.pixelDimensions,
                       try SnapshotImageDimensions(width: 64, height: 128))
        XCTAssertEqual(frame.sourceImage.kind, .pixelBuffer)
        XCTAssertNil(frame.sourceImage.encodedImage)
        XCTAssertTrue(frame.sourceImage.sampleBuffer === sample)
        XCTAssertEqual(provider.snapshot(), LiveSnapshotFrameProviderSnapshot(
            latestAcceptedFrameSequence: 32,
            pendingRequestCount: 0,
            state: .active
        ))
    }

    func testCancellingOneQueryRemovesOnlyItsWaiter() async throws {
        let fixture = try Fixture(
            target: "M2031-LIVE-CANCELLATION",
            orientation: .portrait
        )
        let clock = TestMonotonicClock(100)
        let provider = try fixture.provider(clock: clock)
        let first = Task {
            try await provider.frame(
                expectedBinding: fixture.binding,
                expectedGeometry: fixture.geometry,
                captureGeneration: 1,
                maximumFrameAgeNanoseconds: 1_000
            )
        }
        let second = Task {
            try await provider.frame(
                expectedBinding: fixture.binding,
                expectedGeometry: fixture.geometry,
                captureGeneration: 2,
                maximumFrameAgeNanoseconds: 1_000
            )
        }
        try await waitForPendingRequestCount(2, provider: provider)

        first.cancel()
        do {
            _ = try await first.value
            XCTFail("cancelled query unexpectedly returned a frame")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        try await waitForPendingRequestCount(1, provider: provider)

        clock.set(101)
        XCTAssertEqual(provider.publish(
            sampleBuffer: try makeSampleBuffer(width: 64, height: 128),
            capturedAtNanoseconds: 101,
            frameSequence: 1,
            binding: fixture.binding
        ), .published(completedRequestCount: 1))
        let secondFrame = try await second.value
        XCTAssertEqual(secondFrame.metadata.captureGeneration, 2)
        XCTAssertEqual(provider.snapshot().pendingRequestCount, 0)
    }

    func testAuthorityChangeFailsPendingQueryAndRejectsStaleBinding()
        async throws
    {
        let fixture = try Fixture(
            target: "M2031-LIVE-AUTHORITY",
            orientation: .portrait
        )
        let clock = TestMonotonicClock(100)
        let provider = try fixture.provider(clock: clock)
        let pending = Task {
            try await provider.frame(
                expectedBinding: fixture.binding,
                expectedGeometry: fixture.geometry,
                captureGeneration: 1,
                maximumFrameAgeNanoseconds: 1_000
            )
        }
        try await waitForPendingRequestCount(1, provider: provider)

        let rebound = try fixture.rebound(
            geometryRevision: fixture.geometry.geometryRevision + 1,
            orientation: .landscapeRight
        )
        try provider.rebind(
            binding: rebound.binding,
            geometry: rebound.geometry,
            reconfiguring: false
        )
        await assertProviderError(.authorityChanged, from: pending)

        do {
            _ = try await provider.frame(
                expectedBinding: fixture.binding,
                expectedGeometry: fixture.geometry,
                captureGeneration: 2,
                maximumFrameAgeNanoseconds: 1_000
            )
            XCTFail("stale authority unexpectedly started a query")
        } catch {
            XCTAssertEqual(
                error as? LiveSnapshotFrameProviderError,
                .authorityMismatch
            )
        }

        let current = Task {
            try await provider.frame(
                expectedBinding: rebound.binding,
                expectedGeometry: rebound.geometry,
                captureGeneration: 3,
                maximumFrameAgeNanoseconds: 1_000
            )
        }
        try await waitForPendingRequestCount(1, provider: provider)
        let wrongOrientationSample = try makeSampleBuffer(width: 64, height: 128)
        XCTAssertEqual(provider.publish(
            sampleBuffer: wrongOrientationSample,
            capturedAtNanoseconds: 101,
            frameSequence: 1,
            binding: rebound.binding
        ), .rejected(.geometryOrientationMismatch))
        XCTAssertEqual(provider.snapshot().pendingRequestCount, 1)

        let sample = try makeSampleBuffer(width: 128, height: 64)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: 101,
            frameSequence: 1,
            binding: fixture.binding
        ), .rejected(.geometryRevisionMismatch))
        XCTAssertEqual(provider.snapshot().pendingRequestCount, 1)

        clock.set(102)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: 101,
            frameSequence: 1,
            binding: rebound.binding
        ), .published(completedRequestCount: 1))
        let frame = try await current.value
        XCTAssertEqual(frame.metadata.geometry, rebound.geometry)
        XCTAssertEqual(frame.authority.orientation, .landscapeRight)
    }

    func testUnavailableGatesFailClosedAndNeverReturnFrozenFrame()
        async throws
    {
        let fixture = try Fixture(
            target: "M2031-LIVE-GATES",
            orientation: .portrait
        )
        let clock = TestMonotonicClock(100)
        let provider = try fixture.provider(clock: clock)
        let sample = try makeSampleBuffer(width: 64, height: 128)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: 100,
            frameSequence: 1,
            binding: fixture.binding
        ), .published(completedRequestCount: 0))

        let pending = Task {
            try await provider.frame(
                expectedBinding: fixture.binding,
                expectedGeometry: fixture.geometry,
                captureGeneration: 1,
                maximumFrameAgeNanoseconds: 1_000
            )
        }
        try await waitForPendingRequestCount(1, provider: provider)
        provider.setWithheld(true)
        await assertProviderError(.unavailable(.withheld), from: pending)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: 101,
            frameSequence: 2,
            binding: fixture.binding
        ), .ignored(.withheld))
        XCTAssertEqual(provider.snapshot().latestAcceptedFrameSequence, 1)
        await assertImmediateUnavailable(.withheld, provider: provider, fixture: fixture)

        provider.setWithheld(false)
        provider.setReconfiguring(true)
        await assertImmediateUnavailable(
            .reconfiguring,
            provider: provider,
            fixture: fixture
        )
        provider.setReconfiguring(false)
        provider.markStalled()
        await assertImmediateUnavailable(.stalled, provider: provider, fixture: fixture)
        provider.retire()
        await assertImmediateUnavailable(.retired, provider: provider, fixture: fixture)
        XCTAssertEqual(provider.snapshot().state, .retired)
    }

    func testThirtyAndSixtyFPSStreamsRemainRawAndDeviceBound() async throws {
        for (index, rate) in [30, 60].enumerated() {
            let orientation: DisplayOrientationDTO = index == 0
                ? .portrait
                : .landscapeLeft
            let fixture = try Fixture(
                target: "M2031-LIVE-RATE-\(rate)",
                orientation: orientation
            )
            let other = try Fixture(
                target: "M2031-LIVE-RATE-OTHER-\(rate)",
                orientation: orientation
            )
            let clock = TestMonotonicClock(1_000_000_000)
            let provider = try fixture.provider(clock: clock)
            let request = Task {
                try await provider.frame(
                    expectedBinding: fixture.binding,
                    expectedGeometry: fixture.geometry,
                    captureGeneration: UInt64(rate),
                    maximumFrameAgeNanoseconds: 100_000_000
                )
            }
            try await waitForPendingRequestCount(1, provider: provider)
            let interval = UInt64(1_000_000_000 / rate)
            clock.set(1_000_000_000 + interval)
            let sample = try makeSampleBuffer(
                width: orientation == .portrait ? 64 : 128,
                height: orientation == .portrait ? 128 : 64
            )
            XCTAssertEqual(provider.publish(
                sampleBuffer: sample,
                capturedAtNanoseconds: 1_000_000_000 + interval,
                frameSequence: 1,
                binding: other.binding
            ), .rejected(.targetMismatch))
            XCTAssertEqual(provider.publish(
                sampleBuffer: sample,
                capturedAtNanoseconds: 1_000_000_000 + interval,
                frameSequence: 1,
                binding: fixture.binding
            ), .published(completedRequestCount: 1))

            let frame = try await request.value
            XCTAssertEqual(frame.metadata.canonicalUDID,
                           fixture.binding.canonicalUDID)
            XCTAssertEqual(frame.metadata.geometry.orientation, orientation)
            XCTAssertEqual(frame.sourceImage.kind, .pixelBuffer)
            XCTAssertNil(frame.sourceImage.cgImage)
            XCTAssertNil(frame.sourceImage.encodedImage)
            XCTAssertTrue(frame.sourceImage.sampleBuffer === sample)
        }
    }

    func testRetiredSourceEpochCannotPublishIntoReplacementProvider()
        async throws
    {
        let original = try Fixture(
            target: "M2031-LIVE-RECONNECT",
            orientation: .portrait
        )
        let replacement = try original.reconnected(
            sourceEpoch: original.binding.sourceEpoch + 1,
            sourceID: String(repeating: "b", count: 64)
        )
        let clock = TestMonotonicClock(100)
        let oldProvider = try original.provider(clock: clock)
        let oldRequest = Task {
            try await oldProvider.frame(
                expectedBinding: original.binding,
                expectedGeometry: original.geometry,
                captureGeneration: 1,
                maximumFrameAgeNanoseconds: 1_000
            )
        }
        try await waitForPendingRequestCount(1, provider: oldProvider)
        oldProvider.retire()
        await assertProviderError(.unavailable(.retired), from: oldRequest)

        let newProvider = try replacement.provider(clock: clock)
        let newRequest = Task {
            try await newProvider.frame(
                expectedBinding: replacement.binding,
                expectedGeometry: replacement.geometry,
                captureGeneration: 2,
                maximumFrameAgeNanoseconds: 1_000
            )
        }
        try await waitForPendingRequestCount(1, provider: newProvider)
        let sample = try makeSampleBuffer(width: 64, height: 128)
        clock.set(101)
        XCTAssertEqual(oldProvider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: 101,
            frameSequence: 1,
            binding: original.binding
        ), .ignored(.retired))
        XCTAssertEqual(newProvider.snapshot().pendingRequestCount, 1)
        XCTAssertEqual(newProvider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: 101,
            frameSequence: 1,
            binding: replacement.binding
        ), .published(completedRequestCount: 1))
        let frame = try await newRequest.value
        XCTAssertEqual(frame.metadata.sourceEpoch, replacement.binding.sourceEpoch)
        XCTAssertEqual(frame.metadata.sourceID, replacement.binding.sourceID)
    }

    @MainActor
    func testSixtyFramePublishPathAddsBoundedMainActorWork() throws {
        let fixture = try Fixture(
            target: "M2031-LIVE-MAIN-ACTOR",
            orientation: .portrait
        )
        let clock = TestMonotonicClock(1_000_000_000)
        let provider = try fixture.provider(clock: clock)
        let sample = try makeSampleBuffer(width: 64, height: 128)
        let started = ContinuousClock.now
        for sequence in 1...60 {
            let timestamp = 1_000_000_000 + UInt64(sequence) * 16_666_667
            clock.set(timestamp)
            XCTAssertEqual(provider.publish(
                sampleBuffer: sample,
                capturedAtNanoseconds: timestamp,
                frameSequence: UInt64(sequence),
                binding: fixture.binding
            ), .published(completedRequestCount: 0))
        }
        let elapsed = started.duration(to: .now)
        XCTAssertLessThan(elapsed, .milliseconds(100))
        XCTAssertEqual(provider.snapshot().latestAcceptedFrameSequence, 60)
    }

    func testSettlementRejectsUnknownAndDuplicateActions() async throws {
        let fixture = try Fixture(
            target: "M2031-LIVE-SETTLEMENT-REGISTRY",
            orientation: .portrait
        )
        let clock = TestMonotonicClock(1_000_000_000)
        let provider = try fixture.provider(
            clock: clock,
            settlementPolicy: settlementPolicy()
        )
        let actionID = CanonicalUUID(value: UUID())

        XCTAssertNoThrow(try provider.recordAction(
            actionID: actionID,
            startedAtNanoseconds: clock.now()
        ))
        XCTAssertThrowsError(try provider.recordAction(
            actionID: actionID,
            startedAtNanoseconds: clock.now()
        )) { error in
            XCTAssertEqual(
                error as? LiveSnapshotFrameProviderError,
                .duplicateAction
            )
        }

        let unknown = CanonicalUUID(value: UUID())
        let request = Task {
            try await provider.frame(
                expectedBinding: fixture.binding,
                expectedGeometry: fixture.geometry,
                captureGeneration: 1,
                maximumFrameAgeNanoseconds: 1_000_000_000,
                afterActionID: unknown
            )
        }
        await assertProviderError(.unknownAction, from: request)
    }

    func testSettlementWaitsForChangeAndStableWindow() async throws {
        let fixture = try Fixture(
            target: "M2031-LIVE-SETTLEMENT-STABLE",
            orientation: .portrait
        )
        let initial = UInt64(1_000_000_000)
        let clock = TestMonotonicClock(initial)
        let policy = try settlementPolicy()
        let provider = try fixture.provider(
            clock: clock,
            settlementPolicy: policy
        )
        let sample = try makeSampleBuffer(width: 64, height: 128)
        let dark = fingerprint(component: 0)
        let light = fingerprint(component: 255)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: initial,
            frameSequence: 1,
            binding: fixture.binding,
            visualFingerprint: dark
        ), .published(completedRequestCount: 0))
        let actionID = CanonicalUUID(value: UUID())
        try provider.recordAction(
            actionID: actionID,
            startedAtNanoseconds: initial
        )
        let request = settlementRequest(
            provider: provider,
            fixture: fixture,
            actionID: actionID
        )
        try await waitForPendingRequestCount(1, provider: provider)

        clock.set(initial + 1_000_000)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: clock.now(),
            frameSequence: 2,
            binding: fixture.binding,
            visualFingerprint: light
        ), .published(completedRequestCount: 0))
        clock.set(initial + policy.stableWindowNanoseconds - 1)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: clock.now(),
            frameSequence: 3,
            binding: fixture.binding,
            visualFingerprint: light
        ), .published(completedRequestCount: 0))
        XCTAssertEqual(provider.snapshot().pendingRequestCount, 1)

        clock.set(initial + 1_000_000 + policy.stableWindowNanoseconds)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: clock.now(),
            frameSequence: 4,
            binding: fixture.binding,
            visualFingerprint: light
        ), .published(completedRequestCount: 1))
        let frame = try await request.value
        XCTAssertEqual(frame.metadata.frameSequence, 4)
        XCTAssertEqual(frame.metadata.settleReason, .stableAfterVisualChange)
        XCTAssertEqual(frame.metadata.freshnessFence.afterActionID, actionID)
    }

    func testSettlementMotionResetsStableWindow() async throws {
        let fixture = try Fixture(
            target: "M2031-LIVE-SETTLEMENT-MOTION",
            orientation: .portrait
        )
        let initial = UInt64(2_000_000_000)
        let clock = TestMonotonicClock(initial)
        let policy = try settlementPolicy()
        let provider = try fixture.provider(
            clock: clock,
            settlementPolicy: policy
        )
        let sample = try makeSampleBuffer(width: 64, height: 128)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: initial,
            frameSequence: 1,
            binding: fixture.binding,
            visualFingerprint: fingerprint(component: 0)
        ), .published(completedRequestCount: 0))
        let actionID = CanonicalUUID(value: UUID())
        try provider.recordAction(
            actionID: actionID,
            startedAtNanoseconds: initial
        )
        let request = settlementRequest(
            provider: provider,
            fixture: fixture,
            actionID: actionID
        )
        try await waitForPendingRequestCount(1, provider: provider)

        for (sequence, offset, component) in [
            (UInt64(2), UInt64(1_000_000), UInt8(255)),
            (3, 8_000_000, 200),
            (4, 12_000_000, 200),
        ] {
            clock.set(initial + offset)
            XCTAssertEqual(provider.publish(
                sampleBuffer: sample,
                capturedAtNanoseconds: clock.now(),
                frameSequence: sequence,
                binding: fixture.binding,
                visualFingerprint: fingerprint(component: component)
            ), .published(completedRequestCount: 0))
        }
        XCTAssertEqual(provider.snapshot().pendingRequestCount, 1)

        clock.set(initial + 8_000_000 + policy.stableWindowNanoseconds)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: clock.now(),
            frameSequence: 5,
            binding: fixture.binding,
            visualFingerprint: fingerprint(component: 200)
        ), .published(completedRequestCount: 1))
        let frame = try await request.value
        XCTAssertEqual(frame.metadata.frameSequence, 5)
        XCTAssertEqual(frame.metadata.settleReason, .stableAfterVisualChange)
    }

    func testSettlementDeadlineReturnsLatestTrustedPostQueryFrame()
        async throws
    {
        let fixture = try Fixture(
            target: "M2031-LIVE-SETTLEMENT-DEADLINE",
            orientation: .portrait
        )
        let initial = UInt64(3_000_000_000)
        let clock = TestMonotonicClock(initial)
        let policy = try settlementPolicy()
        let provider = try fixture.provider(
            clock: clock,
            settlementPolicy: policy
        )
        let sample = try makeSampleBuffer(width: 64, height: 128)
        let unchanged = fingerprint(component: 20)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: initial,
            frameSequence: 1,
            binding: fixture.binding,
            visualFingerprint: unchanged
        ), .published(completedRequestCount: 0))
        let actionID = CanonicalUUID(value: UUID())
        try provider.recordAction(
            actionID: actionID,
            startedAtNanoseconds: initial
        )
        let request = settlementRequest(
            provider: provider,
            fixture: fixture,
            actionID: actionID
        )
        try await waitForPendingRequestCount(1, provider: provider)
        for (sequence, offset) in [
            (UInt64(2), UInt64(5_000_000)),
            (3, 20_000_000),
        ] {
            clock.set(initial + offset)
            XCTAssertEqual(provider.publish(
                sampleBuffer: sample,
                capturedAtNanoseconds: clock.now(),
                frameSequence: sequence,
                binding: fixture.binding,
                visualFingerprint: unchanged
            ), .published(completedRequestCount: 0))
        }
        clock.set(initial + policy.settlementDeadlineNanoseconds)

        let frame = try await request.value
        XCTAssertEqual(frame.metadata.frameSequence, 3)
        XCTAssertEqual(frame.metadata.settleReason, .unchangedAtDeadline)
    }

    func testSettlementDeadlineWithoutTrustedFrameFails() async throws {
        let fixture = try Fixture(
            target: "M2031-LIVE-SETTLEMENT-NO-FRAME",
            orientation: .portrait
        )
        let initial = UInt64(4_000_000_000)
        let clock = TestMonotonicClock(initial)
        let policy = try settlementPolicy()
        let provider = try fixture.provider(
            clock: clock,
            settlementPolicy: policy
        )
        let actionID = CanonicalUUID(value: UUID())
        try provider.recordAction(
            actionID: actionID,
            startedAtNanoseconds: initial
        )
        let request = settlementRequest(
            provider: provider,
            fixture: fixture,
            actionID: actionID
        )
        try await waitForPendingRequestCount(1, provider: provider)
        clock.set(initial + policy.settlementDeadlineNanoseconds)

        await assertProviderError(.noTrustedFrameAtDeadline, from: request)
        XCTAssertEqual(provider.snapshot().pendingRequestCount, 0)
    }

    func testSettlementCancellationAndAuthorityChangesDrainWaiters()
        async throws
    {
        let fixture = try Fixture(
            target: "M2031-LIVE-SETTLEMENT-LIFECYCLE",
            orientation: .portrait
        )
        let initial = UInt64(5_000_000_000)
        let clock = TestMonotonicClock(initial)
        let policy = try settlementPolicy()
        let provider = try fixture.provider(
            clock: clock,
            settlementPolicy: policy
        )
        let sample = try makeSampleBuffer(width: 64, height: 128)
        let firstAction = CanonicalUUID(value: UUID())
        try provider.recordAction(
            actionID: firstAction,
            startedAtNanoseconds: initial
        )
        let cancelled = settlementRequest(
            provider: provider,
            fixture: fixture,
            actionID: firstAction
        )
        try await waitForPendingRequestCount(1, provider: provider)
        clock.set(initial + 1_000_000)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: clock.now(),
            frameSequence: 1,
            binding: fixture.binding,
            visualFingerprint: fingerprint(component: 0)
        ), .published(completedRequestCount: 0))
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("cancelled settlement unexpectedly returned a frame")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(provider.snapshot().pendingRequestCount, 0)

        let secondAction = CanonicalUUID(value: UUID())
        try provider.recordAction(
            actionID: secondAction,
            startedAtNanoseconds: clock.now()
        )
        let pending = settlementRequest(
            provider: provider,
            fixture: fixture,
            actionID: secondAction
        )
        try await waitForPendingRequestCount(1, provider: provider)
        let rebound = try fixture.rebound(
            geometryRevision: 14,
            orientation: .landscapeRight
        )
        try provider.rebind(
            binding: rebound.binding,
            geometry: rebound.geometry,
            reconfiguring: false
        )
        await assertProviderError(.authorityChanged, from: pending)

        let invalidated = Task {
            try await provider.frame(
                expectedBinding: rebound.binding,
                expectedGeometry: rebound.geometry,
                captureGeneration: 1,
                maximumFrameAgeNanoseconds: 1_000_000_000,
                afterActionID: secondAction
            )
        }
        await assertProviderError(.unknownAction, from: invalidated)

        let retiringProvider = try fixture.provider(
            clock: clock,
            settlementPolicy: policy
        )
        let retiringAction = CanonicalUUID(value: UUID())
        try retiringProvider.recordAction(
            actionID: retiringAction,
            startedAtNanoseconds: clock.now()
        )
        let retiringRequest = settlementRequest(
            provider: retiringProvider,
            fixture: fixture,
            actionID: retiringAction
        )
        try await waitForPendingRequestCount(1, provider: retiringProvider)
        retiringProvider.retire()
        await assertProviderError(
            .unavailable(.retired),
            from: retiringRequest
        )
        XCTAssertThrowsError(try retiringProvider.recordAction(
            actionID: retiringAction,
            startedAtNanoseconds: clock.now()
        )) { error in
            XCTAssertEqual(
                error as? LiveSnapshotFrameProviderError,
                .unavailable(.retired)
            )
        }
    }

    func testTerminalSettlementActionsApplyToLaterQueries() async throws {
        let fixture = try Fixture(
            target: "M2031-LIVE-SETTLEMENT-TERMINAL",
            orientation: .portrait
        )
        let initial = UInt64(6_000_000_000)
        let clock = TestMonotonicClock(initial)
        let policy = try settlementPolicy()
        let provider = try fixture.provider(
            clock: clock,
            settlementPolicy: policy
        )
        let sample = try makeSampleBuffer(width: 64, height: 128)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: initial,
            frameSequence: 1,
            binding: fixture.binding,
            visualFingerprint: fingerprint(component: 0)
        ), .published(completedRequestCount: 0))

        let stableAction = CanonicalUUID(value: UUID())
        try provider.recordAction(
            actionID: stableAction,
            startedAtNanoseconds: initial
        )
        clock.set(initial + 1_000_000)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: clock.now(),
            frameSequence: 2,
            binding: fixture.binding,
            visualFingerprint: fingerprint(component: 255)
        ), .published(completedRequestCount: 0))
        clock.set(initial + 1_000_000 + policy.stableWindowNanoseconds)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: clock.now(),
            frameSequence: 3,
            binding: fixture.binding,
            visualFingerprint: fingerprint(component: 255)
        ), .published(completedRequestCount: 0))
        let stableRequest = settlementRequest(
            provider: provider,
            fixture: fixture,
            actionID: stableAction
        )
        try await waitForPendingRequestCount(1, provider: provider)
        clock.set(clock.now() + 1_000_000)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: clock.now(),
            frameSequence: 4,
            binding: fixture.binding,
            visualFingerprint: fingerprint(component: 255)
        ), .published(completedRequestCount: 1))
        let stableFrame = try await stableRequest.value
        XCTAssertEqual(stableFrame.metadata.settleReason, .stableAfterVisualChange)

        let deadlineAction = CanonicalUUID(value: UUID())
        try provider.recordAction(
            actionID: deadlineAction,
            startedAtNanoseconds: clock.now()
        )
        clock.set(clock.now() + policy.settlementDeadlineNanoseconds)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: clock.now(),
            frameSequence: 5,
            binding: fixture.binding,
            visualFingerprint: fingerprint(component: 255)
        ), .published(completedRequestCount: 0))
        let deadlineRequest = settlementRequest(
            provider: provider,
            fixture: fixture,
            actionID: deadlineAction
        )
        try await waitForPendingRequestCount(1, provider: provider)
        clock.set(clock.now() + 1_000_000)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: clock.now(),
            frameSequence: 6,
            binding: fixture.binding,
            visualFingerprint: fingerprint(component: 255)
        ), .published(completedRequestCount: 1))
        let deadlineFrame = try await deadlineRequest.value
        XCTAssertEqual(deadlineFrame.metadata.settleReason, .unchangedAtDeadline)
    }

    func testMissingAndMalformedFingerprintsRemainConservative()
        async throws
    {
        let fixture = try Fixture(
            target: "M2031-LIVE-SETTLEMENT-FINGERPRINT",
            orientation: .portrait
        )
        let initial = UInt64(7_000_000_000)
        let clock = TestMonotonicClock(initial)
        let policy = try settlementPolicy()
        let provider = try fixture.provider(
            clock: clock,
            settlementPolicy: policy
        )
        let sample = try makeSampleBuffer(width: 64, height: 128)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: initial,
            frameSequence: 1,
            binding: fixture.binding,
            visualFingerprint: fingerprint(component: 0)
        ), .published(completedRequestCount: 0))
        let actionID = CanonicalUUID(value: UUID())
        try provider.recordAction(
            actionID: actionID,
            startedAtNanoseconds: initial
        )
        let request = settlementRequest(
            provider: provider,
            fixture: fixture,
            actionID: actionID
        )
        try await waitForPendingRequestCount(1, provider: provider)
        clock.set(initial + 5_000_000)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: clock.now(),
            frameSequence: 2,
            binding: fixture.binding,
            visualFingerprint: nil
        ), .published(completedRequestCount: 0))
        clock.set(initial + 20_000_000)
        XCTAssertEqual(provider.publish(
            sampleBuffer: sample,
            capturedAtNanoseconds: clock.now(),
            frameSequence: 3,
            binding: fixture.binding,
            visualFingerprint: [255, 255, 255, 255]
        ), .published(completedRequestCount: 0))
        clock.set(initial + policy.settlementDeadlineNanoseconds)

        let frame = try await request.value
        XCTAssertEqual(frame.metadata.frameSequence, 3)
        XCTAssertEqual(frame.metadata.settleReason, .unchangedAtDeadline)
    }

    private func assertImmediateUnavailable(
        _ state: LiveSnapshotFrameProviderState,
        provider: LiveSnapshotFrameProvider,
        fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await provider.frame(
                expectedBinding: fixture.binding,
                expectedGeometry: fixture.geometry,
                captureGeneration: 9,
                maximumFrameAgeNanoseconds: 1_000
            )
            XCTFail("unavailable provider unexpectedly accepted a query",
                    file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? LiveSnapshotFrameProviderError,
                .unavailable(state),
                file: file,
                line: line
            )
        }
    }

    private func assertProviderError(
        _ expected: LiveSnapshotFrameProviderError,
        from task: Task<SnapshotFrame, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("query unexpectedly returned a frame", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? LiveSnapshotFrameProviderError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func waitForPendingRequestCount(
        _ expected: Int,
        provider: LiveSnapshotFrameProvider
    ) async throws {
        for _ in 0..<1_000 {
            if provider.snapshot().pendingRequestCount == expected { return }
            await Task.yield()
        }
        throw LiveSnapshotFrameProviderTestError.waiterDidNotRegister
    }

    private func settlementPolicy() throws -> LiveSnapshotSettlementPolicy {
        try LiveSnapshotSettlementPolicy(
            actionRetentionNanoseconds: 1_000_000_000,
            changeThresholdMilli: 30,
            maximumRegisteredActions: 8,
            settlementDeadlineNanoseconds: 100_000_000,
            stableThresholdMilli: 10,
            stableWindowNanoseconds: 10_000_000
        )
    }

    private func settlementRequest(
        provider: LiveSnapshotFrameProvider,
        fixture: Fixture,
        actionID: CanonicalUUID
    ) -> Task<SnapshotFrame, Error> {
        Task {
            try await provider.frame(
                expectedBinding: fixture.binding,
                expectedGeometry: fixture.geometry,
                captureGeneration: 1,
                maximumFrameAgeNanoseconds: 1_000_000_000,
                afterActionID: actionID
            )
        }
    }

    private func fingerprint(component: UInt8) -> [UInt8] {
        Array(repeating: [component, component, component, 255], count: 16 * 16)
            .flatMap { $0 }
    }

    private func makeSampleBuffer(
        width: Int,
        height: Int
    ) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        ) == kCVReturnSuccess,
        let pixelBuffer
        else { throw LiveSnapshotFrameProviderTestError.fixture }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        ) == noErr,
        let format
        else { throw LiveSnapshotFrameProviderTestError.fixture }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr,
        let sampleBuffer
        else { throw LiveSnapshotFrameProviderTestError.fixture }
        return sampleBuffer
    }
}

private enum LiveSnapshotFrameProviderTestError: Error {
    case fixture
    case waiterDidNotRegister
}

private final class TestMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(_ value: UInt64) {
        self.value = value
    }

    func now() -> UInt64 { lock.withLock { value } }

    func set(_ value: UInt64) {
        lock.withLock { self.value = value }
    }
}

private struct Fixture: Sendable {
    let binding: VideoBindingIdentity
    let geometry: DisplayGeometryDTO

    init(target: String, orientation: DisplayOrientationDTO) throws {
        let canonicalUDID = try CanonicalUDID(canonicalString: target)
        geometry = try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 13,
            logicalHeight: orientation == .portrait ? 128 : 64,
            logicalWidth: orientation == .portrait ? 64 : 128,
            orientation: orientation
        )
        binding = VideoBindingIdentity(
            canonicalUDID: canonicalUDID,
            connectionEpoch: geometry.connectionEpoch,
            sourceID: String(repeating: "a", count: 64),
            sourceEpoch: 11,
            geometryRevision: geometry.geometryRevision
        )
    }

    init(binding: VideoBindingIdentity, geometry: DisplayGeometryDTO) {
        self.binding = binding
        self.geometry = geometry
    }

    func provider(
        clock: TestMonotonicClock,
        settlementPolicy: LiveSnapshotSettlementPolicy = .production
    ) throws
        -> LiveSnapshotFrameProvider
    {
        try LiveSnapshotFrameProvider(
            binding: binding,
            geometry: geometry,
            monotonicNow: { clock.now() },
            settlementPolicy: settlementPolicy
        )
    }

    func rebound(
        geometryRevision: UInt64,
        orientation: DisplayOrientationDTO
    ) throws -> Fixture {
        let geometry = try DisplayGeometryDTO(
            connectionEpoch: geometry.connectionEpoch,
            geometryRevision: geometryRevision,
            logicalHeight: orientation == .portrait ? 128 : 64,
            logicalWidth: orientation == .portrait ? 64 : 128,
            orientation: orientation
        )
        return Fixture(
            binding: VideoBindingIdentity(
                canonicalUDID: binding.canonicalUDID,
                connectionEpoch: binding.connectionEpoch,
                sourceID: binding.sourceID,
                sourceEpoch: binding.sourceEpoch,
                geometryRevision: geometryRevision
            ),
            geometry: geometry
        )
    }

    func reconnected(sourceEpoch: UInt64, sourceID: String) throws -> Fixture {
        Fixture(
            binding: VideoBindingIdentity(
                canonicalUDID: binding.canonicalUDID,
                connectionEpoch: binding.connectionEpoch + 1,
                sourceID: sourceID,
                sourceEpoch: sourceEpoch,
                geometryRevision: geometry.geometryRevision + 1
            ),
            geometry: try DisplayGeometryDTO(
                connectionEpoch: geometry.connectionEpoch + 1,
                geometryRevision: geometry.geometryRevision + 1,
                logicalHeight: geometry.logicalHeight,
                logicalWidth: geometry.logicalWidth,
                orientation: geometry.orientation
            )
        )
    }
}
