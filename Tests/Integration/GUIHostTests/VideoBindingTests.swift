import AppKit
import AVFoundation
import Foundation
@testable import PulsePhoneMedia
import PulsePhoneSharedDefinitions
import XCTest

final class VideoBindingTests: XCTestCase {
    func testCapturePrefersEightBitDecodedPixelFormats() {
        let fallback: OSType = 0x78343230
        XCTAssertEqual(
            ProductionAVFoundationVideoCapture.preferredDecodedPixelFormat(
                available: [fallback, kCVPixelFormatType_32BGRA]
            ),
            kCVPixelFormatType_32BGRA
        )
        XCTAssertEqual(
            ProductionAVFoundationVideoCapture.preferredDecodedPixelFormat(
                available: [
                    kCVPixelFormatType_32BGRA,
                    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                ]
            ),
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        XCTAssertEqual(
            ProductionAVFoundationVideoCapture.preferredDecodedPixelFormat(
                available: [fallback]
            ),
            fallback
        )
        XCTAssertNil(
            ProductionAVFoundationVideoCapture.preferredDecodedPixelFormat(
                available: []
            )
        )
    }

    func testAVFoundationInventoryRetainsAndAdvancesSourceEpochs() throws {
        var tracker = AVFoundationVideoSourceInventoryTracker()
        let portrait = try AVFoundationVideoSourceObservation(
            sourceID: "source-a",
            activeFormatWidth: 1_179,
            activeFormatHeight: 2_556
        )
        let first = try tracker.refresh(observations: [portrait])
        let firstSource = try XCTUnwrap(first.sources.first)
        let stable = try tracker.refresh(observations: [portrait])
        XCTAssertEqual(stable.sources.first?.sourceEpoch, firstSource.sourceEpoch)
        XCTAssertGreaterThan(stable.inventoryRevision, first.inventoryRevision)

        _ = try tracker.refresh(observations: [])
        let reappeared = try tracker.refresh(observations: [portrait])
        XCTAssertGreaterThan(
            try XCTUnwrap(reappeared.sources.first).sourceEpoch,
            firstSource.sourceEpoch
        )

        let landscape = try AVFoundationVideoSourceObservation(
            sourceID: "source-a",
            activeFormatWidth: 2_556,
            activeFormatHeight: 1_179
        )
        let formatChanged = try tracker.refresh(observations: [landscape])
        XCTAssertGreaterThan(
            try XCTUnwrap(formatChanged.sources.first).sourceEpoch,
            try XCTUnwrap(reappeared.sources.first).sourceEpoch
        )
    }

    func testAVFoundationInventoryRetainsPendingMuxedFormatUntilFramesArrive() throws {
        var tracker = AVFoundationVideoSourceInventoryTracker()
        let pending = try AVFoundationVideoSourceObservation(
            sourceID: "pending-muxed-source",
            activeFormatWidth: 0,
            activeFormatHeight: 0
        )
        let first = try tracker.refresh(observations: [pending])
        let pendingDescriptor = try XCTUnwrap(first.sources.first)
        XCTAssertFalse(pendingDescriptor.hasActiveFormat)

        let stable = try tracker.refresh(observations: [pending])
        XCTAssertEqual(
            stable.sources.first?.sourceEpoch,
            pendingDescriptor.sourceEpoch
        )

        let active = try AVFoundationVideoSourceObservation(
            sourceID: pending.sourceID,
            activeFormatWidth: 1_179,
            activeFormatHeight: 2_556
        )
        let activated = try tracker.refresh(observations: [active])
        let activeDescriptor = try XCTUnwrap(activated.sources.first)
        XCTAssertTrue(activeDescriptor.hasActiveFormat)
        XCTAssertGreaterThan(
            activeDescriptor.sourceEpoch,
            pendingDescriptor.sourceEpoch
        )

        XCTAssertThrowsError(try AVFoundationVideoSourceObservation(
            sourceID: "invalid-half-format",
            activeFormatWidth: 1_179,
            activeFormatHeight: 0
        )) { error in
            XCTAssertEqual(
                error as? AVFoundationVideoSourceError,
                .invalidActiveFormat
            )
        }
        XCTAssertThrowsError(try VideoSourceDescriptor(
            sourceID: "invalid-half-format",
            sourceEpoch: 1,
            activeFormatWidth: 0,
            activeFormatHeight: 2_556
        )) { error in
            XCTAssertEqual(
                error as? VideoSourceInventoryError,
                .invalidActiveFormat
            )
        }
    }

    func testAVFoundationInventoryRejectsDuplicateAndStaleMapping() throws {
        var tracker = AVFoundationVideoSourceInventoryTracker()
        let observation = try AVFoundationVideoSourceObservation(
            sourceID: "source-a",
            activeFormatWidth: 1_179,
            activeFormatHeight: 2_556
        )
        XCTAssertThrowsError(try tracker.refresh(observations: [
            observation, observation,
        ])) { error in
            XCTAssertEqual(
                error as? AVFoundationVideoSourceError,
                .duplicateSourceID
            )
        }

        let target = try CanonicalUDID(
            canonicalString: "00008020-001C2D123456002E"
        )
        let first = try tracker.refresh(observations: [observation])
        let firstEpoch = try XCTUnwrap(first.sources.first).sourceEpoch
        _ = try tracker.refresh(observations: [])
        let current = try tracker.refresh(observations: [observation])
        XCTAssertThrowsError(try current.resolve(
            target: target,
            claims: [try VideoSourceMappingClaim(
                sourceID: observation.sourceID,
                sourceEpoch: firstEpoch,
                canonicalUDID: target,
                mappingProofID: "proof.old-source-epoch"
            )]
        )) { error in
            XCTAssertEqual(
                error as? VideoSourceInventoryError,
                .mappingSourceEpochMismatch
            )
        }
        let currentEpoch = try XCTUnwrap(current.sources.first).sourceEpoch
        XCTAssertEqual(
            try current.resolve(
                target: target,
                claims: [try VideoSourceMappingClaim(
                    sourceID: observation.sourceID,
                    sourceEpoch: currentEpoch,
                    canonicalUDID: target,
                    mappingProofID: "proof.current-source-epoch"
                )]
            ),
            .mapped(VideoResolvedSource(
                canonicalUDID: target,
                descriptor: try XCTUnwrap(current.sources.first),
                mappingProofID: "proof.current-source-epoch"
            ))
        )
    }

    func testSystemAVFoundationCatalogProducesOpaqueStableInventory() throws {
        let catalog = ProductionAVFoundationVideoSourceCatalog()
        let first = try catalog.refresh()
        let second = try catalog.refresh()
        XCTAssertGreaterThan(second.inventoryRevision, first.inventoryRevision)
        let firstByID = Dictionary(uniqueKeysWithValues: first.sources.map {
            ($0.sourceID, $0)
        })
        for source in second.sources {
            XCTAssertEqual(source.sourceID.utf8.count, 64)
            XCTAssertTrue(source.sourceID.utf8.allSatisfy { byte in
                (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
            })
            if let previous = firstByID[source.sourceID] {
                XCTAssertEqual(source.sourceEpoch, previous.sourceEpoch)
            }
        }
    }

    func testDiscoveryMergeKeepsTypedPrecedenceAndLegacyScreenSources() {
        struct Candidate: Equatable {
            let eligible: Bool
            let uniqueID: String
            let value: String
        }
        let merged = ProductionAVFoundationVideoSourceCatalog.mergeDiscoveredDevices(
            discovered: [
                Candidate(eligible: true, uniqueID: "camera", value: "typed-camera"),
                Candidate(eligible: false, uniqueID: "microphone", value: "typed-audio"),
            ],
            legacy: [
                Candidate(eligible: true, uniqueID: "camera", value: "legacy-duplicate"),
                Candidate(eligible: true, uniqueID: "iphone-screen", value: "legacy-screen"),
            ],
            direct: [
                Candidate(eligible: true, uniqueID: "iphone-screen", value: "direct-duplicate"),
                Candidate(eligible: true, uniqueID: "cmio-only", value: "direct-cmio"),
            ],
            uniqueID: \.uniqueID,
            isEligible: { $0.eligible }
        )
        XCTAssertEqual(
            merged.map(\.value),
            ["typed-camera", "legacy-screen", "direct-cmio"]
        )
    }

    func testAVFoundationInventoryEnforcesSourceCap() throws {
        var tracker = AVFoundationVideoSourceInventoryTracker()
        let observations = try (0..<65).map { index in
            try AVFoundationVideoSourceObservation(
                sourceID: "source-\(index)",
                activeFormatWidth: 1,
                activeFormatHeight: 1
            )
        }
        XCTAssertThrowsError(try tracker.refresh(observations: observations)) {
            XCTAssertEqual(
                $0 as? AVFoundationVideoSourceError,
                .inventoryCapacityExceeded
            )
        }
    }

    func testPhoneScreenClassifierRequiresCompletePublicPredicate() {
        let embedded = AVFoundationMediaFormatIdentity(
            mediaType: AVFoundationVideoSourceClassifier.muxedMediaType,
            mediaSubtype: AVFoundationVideoSourceClassifier
                .embeddedScreenRecordingMediaSubtype
        )
        let qualified = AVFoundationVideoSourceClassificationFacts(
            deviceType: AVCaptureDevice.DeviceType.external.rawValue,
            hasMuxedMedia: true,
            manufacturer: "Apple Inc.",
            activeFormat: embedded,
            availableFormats: [embedded]
        )
        XCTAssertEqual(
            AVFoundationVideoSourceClassifier.classify(qualified),
            .qualifiedPhoneScreen
        )
        XCTAssertEqual(
            AVFoundationVideoSourceClassifier.classify(
                AVFoundationVideoSourceClassificationFacts(
                    deviceType: qualified.deviceType,
                    hasMuxedMedia: qualified.hasMuxedMedia,
                    manufacturer: nil,
                    activeFormat: qualified.activeFormat,
                    availableFormats: qualified.availableFormats
                )
            ),
            .residual
        )
        XCTAssertEqual(
            AVFoundationVideoSourceClassifier.classify(
                AVFoundationVideoSourceClassificationFacts(
                    deviceType: AVCaptureDevice.DeviceType.continuityCamera.rawValue,
                    hasMuxedMedia: true,
                    manufacturer: "Apple Inc.",
                    activeFormat: embedded,
                    availableFormats: [embedded]
                )
            ),
            .knownNonPhone
        )
    }

    func testStableInventoryRequiresFullWindowAndFinalQuietProof() throws {
        let start: UInt64 = 10_000
        let source = try VideoSourceDescriptor(
            sourceID: "qualified-source",
            sourceEpoch: 1,
            activeFormatWidth: 0,
            activeFormatHeight: 0,
            displayName: "Test iPhone",
            classification: .qualifiedPhoneScreen
        )
        let inventory = try VideoSourceInventory(
            inventoryRevision: 1,
            sources: [source]
        )
        var accumulator = VideoSourceStableInventoryAccumulator(
            startedAtMonotonicNanoseconds: start
        )
        for index in 0...14 {
            accumulator.observe(
                inventory: inventory,
                atMonotonicNanoseconds: start
                    + UInt64(index) * 100_000_000
            )
        }
        XCTAssertEqual(
            accumulator.outcome(
                atMonotonicNanoseconds: start + 1_499_999_999
            ),
            .pending
        )
        accumulator.observe(
            inventory: inventory,
            atMonotonicNanoseconds: start + 1_500_000_000
        )
        XCTAssertEqual(
            accumulator.outcome(
                atMonotonicNanoseconds: start + 1_500_000_000
            ),
            .stable(qualifiedSourceIDs: [source.sourceID])
        )
    }

    func testStableInventoryFailsClosedForChangingOrEmptyFinalSet() throws {
        let start: UInt64 = 100
        let first = try VideoSourceDescriptor(
            sourceID: "first",
            sourceEpoch: 1,
            activeFormatWidth: 0,
            activeFormatHeight: 0,
            displayName: "First",
            classification: .qualifiedPhoneScreen
        )
        let second = try VideoSourceDescriptor(
            sourceID: "second",
            sourceEpoch: 2,
            activeFormatWidth: 0,
            activeFormatHeight: 0,
            displayName: "Second",
            classification: .qualifiedPhoneScreen
        )
        var changing = VideoSourceStableInventoryAccumulator(
            startedAtMonotonicNanoseconds: start
        )
        for index in 0...15 {
            let sources = index == 14 ? [first, second] : [first]
            changing.observe(
                inventory: try VideoSourceInventory(
                    inventoryRevision: UInt64(index + 1),
                    sources: sources
                ),
                atMonotonicNanoseconds: start
                    + UInt64(index) * 100_000_000
            )
        }
        XCTAssertEqual(
            changing.outcome(atMonotonicNanoseconds: start + 1_500_000_000),
            .unstable
        )

        var empty = VideoSourceStableInventoryAccumulator(
            startedAtMonotonicNanoseconds: start
        )
        for index in 0...15 {
            empty.observe(
                inventory: nil,
                atMonotonicNanoseconds: start
                    + UInt64(index) * 100_000_000
            )
        }
        XCTAssertEqual(
            empty.outcome(atMonotonicNanoseconds: start + 1_500_000_000),
            .unstable
        )
    }

    func testSourceNameGuardUsesCanonicalEquivalentExactMatch() {
        XCTAssertTrue(VideoSourceNameGuard.canonicalEquivalentExactMatch(
            sourceName: "Cafe\u{301}",
            targetName: "Caf\u{e9}"
        ))
        XCTAssertFalse(VideoSourceNameGuard.canonicalEquivalentExactMatch(
            sourceName: "My iPhone Camera",
            targetName: "My iPhone"
        ))
    }

    @MainActor
    func testPhysicalExternalSourceWhenExplicitlyRequired() throws {
        guard ProcessInfo.processInfo.environment[
            "PULSEPHONE_REQUIRE_EXTERNAL_VIDEO_SOURCE"
        ] == "1" else { return }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        let catalog = ProductionAVFoundationVideoSourceCatalog()
        let observed = expectation(description: "external or muxed source")
        catalog.startMonitoring { _ in
            if catalog.hasExternalOrMuxedDevice() {
                observed.fulfill()
            }
        }
        wait(for: [observed], timeout: 10)
        catalog.stopMonitoring()
    }

    func testInventoryRequiresExplicitUniqueMapping() throws {
        let target = try canonicalUDID("A")
        let source = try descriptor("av-source-a", epoch: 3)
        let inventory = try VideoSourceInventory(
            inventoryRevision: 1,
            sources: [source]
        )
        XCTAssertEqual(try inventory.resolve(target: target, claims: []), .unavailable)

        let claim = try VideoSourceMappingClaim(
            sourceID: source.sourceID,
            sourceEpoch: source.sourceEpoch,
            canonicalUDID: target,
            mappingProofID: "bridge-proof-a"
        )
        guard case .mapped(let resolved) = try inventory.resolve(
            target: target,
            claims: [claim]
        ) else { return XCTFail("expected mapped source") }
        XCTAssertEqual(resolved.canonicalUDID, target)
        XCTAssertEqual(resolved.descriptor, source)

        let second = try descriptor("av-source-b", epoch: 3)
        let ambiguous = try VideoSourceInventory(
            inventoryRevision: 2,
            sources: [source, second]
        )
        let secondClaim = try VideoSourceMappingClaim(
            sourceID: second.sourceID,
            sourceEpoch: second.sourceEpoch,
            canonicalUDID: target,
            mappingProofID: "bridge-proof-b"
        )
        XCTAssertEqual(
            try ambiguous.resolve(target: target, claims: [claim, secondClaim]),
            .ambiguous(sourceIDs: ["av-source-a", "av-source-b"])
        )
    }

    func testCachedMappingUsesExactCurrentDescriptorAndCurrentSourceEpoch() throws {
        let target = try canonicalUDID("CACHE-TARGET")
        let cachedSourceID = String(repeating: "a", count: 64)
        let otherSourceID = String(repeating: "b", count: 64)
        let current = try descriptor(
            cachedSourceID,
            epoch: 41,
            width: 1_170,
            height: 2_532
        )
        let other = try descriptor(
            otherSourceID,
            epoch: 99,
            width: 1_920,
            height: 1_440
        )

        XCTAssertEqual(
            try CachedVideoSourceMappingResolver.resolve(
                target: target,
                sourceID: cachedSourceID,
                mappingProofID: "operatorConfirmedPreview.v1",
                sources: [other, current]
            ),
            .mapped(VideoResolvedSource(
                canonicalUDID: target,
                descriptor: current,
                mappingProofID: "operatorConfirmedPreview.v1"
            ))
        )
        XCTAssertEqual(
            try CachedVideoSourceMappingResolver.resolve(
                target: target,
                sourceID: String(repeating: "c", count: 64),
                mappingProofID: "operatorConfirmedPreview.v1",
                sources: [current, other]
            ),
            .unavailable
        )
    }

    func testCachedMappingRejectsDuplicateSourceIdentityWithoutGuessingOrder() throws {
        let target = try canonicalUDID("CACHE-AMBIGUOUS")
        let cachedSourceID = String(repeating: "d", count: 64)
        let first = try descriptor(
            cachedSourceID,
            epoch: 1,
            width: 1_170,
            height: 2_532
        )
        let second = try descriptor(
            cachedSourceID,
            epoch: 2,
            width: 2_532,
            height: 1_170
        )

        XCTAssertEqual(
            try CachedVideoSourceMappingResolver.resolve(
                target: target,
                sourceID: cachedSourceID,
                mappingProofID: "operatorConfirmedPreview.v1",
                sources: [second, first]
            ),
            .ambiguous(sourceIDs: [cachedSourceID, cachedSourceID])
        )
    }

    func testVideoControlSourceBindingFixture() throws {
        let fixture = try loadBindingFixture()
        let expected = try loadBindingExpected()
        let target = try canonicalUDID(fixture.targetCanonicalUDID)
        let sources = try fixture.sources.map {
            try descriptor(
                $0.sourceID,
                epoch: $0.sourceEpoch,
                width: $0.activeFormatWidth,
                height: $0.activeFormatHeight
            )
        }
        let inventory = try VideoSourceInventory(
            inventoryRevision: fixture.inventoryRevision,
            sources: sources
        )
        let claims = try fixture.claims.map {
            try VideoSourceMappingClaim(
                sourceID: $0.sourceID,
                sourceEpoch: $0.sourceEpoch,
                canonicalUDID: canonicalUDID($0.canonicalUDID),
                mappingProofID: $0.mappingProofID
            )
        }
        let resolution = try inventory.resolve(target: target, claims: claims)
        let geometry = try DisplayGeometryDTO(
            connectionEpoch: fixture.connectionEpoch,
            geometryRevision: fixture.geometryRevision,
            logicalHeight: fixture.logicalHeight,
            logicalWidth: fixture.logicalWidth,
            orientation: .portrait
        )
        let binding = try VideoBinding.make(
            target: target,
            connectionEpoch: fixture.connectionEpoch,
            geometry: geometry,
            resolution: resolution
        )

        XCTAssertEqual(
            VideoBinding.validate(
                frame: VideoFrameIdentity(
                    binding: binding,
                    frameSequence: fixture.acceptedFrameSequence
                ),
                against: binding
            ),
            .accepted(frameSequence: expected.acceptedFrameSequence)
        )
        for mismatch in fixture.mismatchFrames {
            let frameBinding = VideoBindingIdentity(
                canonicalUDID: try canonicalUDID(mismatch.canonicalUDID),
                connectionEpoch: mismatch.connectionEpoch,
                sourceID: mismatch.sourceID,
                sourceEpoch: mismatch.sourceEpoch,
                geometryRevision: mismatch.geometryRevision
            )
            let disposition = VideoBinding.validate(
                frame: VideoFrameIdentity(
                    binding: frameBinding,
                    frameSequence: mismatch.frameSequence
                ),
                against: binding
            )
            guard case .discarded(let reason) = disposition else {
                return XCTFail("mismatched frame was accepted")
            }
            XCTAssertEqual(reason.rawValue, mismatch.expectedDiscardReason)
        }
        XCTAssertEqual(fixture.mappingMode, expected.mappingMode)
        XCTAssertEqual(expected.dimensionOnlyBinding, false)
    }

    func testReconnectInvalidatesBothOldEpochBindings() throws {
        let fixture = try loadReconnectFixture()
        let expected = try loadReconnectExpected()
        let target = try canonicalUDID(fixture.targetCanonicalUDID)
        var coordinator = VideoReconnectCoordinator(canonicalUDID: target)

        try apply(
            fixture.initial,
            target: target,
            coordinator: &coordinator
        )
        let initial = try XCTUnwrap(coordinator.bindIfReady())
        XCTAssertEqual(
            coordinator.receive(VideoFrameIdentity(
                binding: initial,
                frameSequence: 1
            )),
            .accepted(frameSequence: 1)
        )

        let newSource = try resolution(
            target: target,
            sourceID: fixture.sourceReconnect.sourceID,
            sourceEpoch: fixture.sourceReconnect.sourceEpoch
        )
        try coordinator.sourceChanged(newSource)
        XCTAssertNil(coordinator.binding)
        XCTAssertEqual(
            coordinator.receive(VideoFrameIdentity(
                binding: initial,
                frameSequence: 2
            )),
            .discarded(.unbound)
        )
        let reboundSource = try XCTUnwrap(coordinator.bindIfReady())
        XCTAssertEqual(
            reboundSource.sourceEpoch,
            expected.sourceReconnectBindingEpoch
        )

        try coordinator.runtimeReconnected(
            connectionEpoch: fixture.controlReconnect.connectionEpoch
        )
        XCTAssertTrue(coordinator.controlAvailable)
        XCTAssertFalse(coordinator.coordinateInputAvailable)
        XCTAssertNil(coordinator.binding)
        try coordinator.updateGeometry(DisplayGeometryDTO(
            connectionEpoch: fixture.controlReconnect.connectionEpoch,
            geometryRevision: fixture.controlReconnect.geometryRevision,
            logicalHeight: fixture.controlReconnect.logicalHeight,
            logicalWidth: fixture.controlReconnect.logicalWidth,
            orientation: .portrait
        ))
        let reboundControl = try XCTUnwrap(coordinator.bindIfReady())
        XCTAssertEqual(
            reboundControl.connectionEpoch,
            expected.controlReconnectBindingEpoch
        )
        XCTAssertEqual(
            coordinator.receive(VideoFrameIdentity(
                binding: reboundSource,
                frameSequence: 3
            )),
            .discarded(.connectionEpochMismatch)
        )
    }

    func testAmbiguousAndUnavailableBindingsFailClosed() throws {
        let target = try canonicalUDID("A")
        let geometry = try DisplayGeometryDTO(
            connectionEpoch: 1,
            geometryRevision: 1,
            logicalHeight: 2,
            logicalWidth: 1,
            orientation: .portrait
        )
        XCTAssertThrowsError(try VideoBinding.make(
            target: target,
            connectionEpoch: 1,
            geometry: geometry,
            resolution: .unavailable
        )) { error in
            XCTAssertEqual(error as? VideoBindingError, .sourceUnavailable)
        }
        XCTAssertThrowsError(try VideoBinding.make(
            target: target,
            connectionEpoch: 1,
            geometry: geometry,
            resolution: .ambiguous(sourceIDs: ["a", "b"])
        )) { error in
            XCTAssertEqual(error as? VideoBindingError, .ambiguousSource)
        }
    }

    func testReconnectFloorsRejectOldEpochsAfterDetachOrUnavailability() throws {
        let target = try canonicalUDID("A")
        var coordinator = VideoReconnectCoordinator(canonicalUDID: target)
        try coordinator.runtimeReconnected(connectionEpoch: 5)
        XCTAssertTrue(coordinator.runtimeDetached(connectionEpoch: 5))
        XCTAssertThrowsError(try coordinator.runtimeReconnected(
            connectionEpoch: 5
        )) { error in
            XCTAssertEqual(
                error as? VideoReconnectError,
                .staleConnectionEpoch
            )
        }

        try coordinator.sourceChanged(try resolution(
            target: target,
            sourceID: "source-a",
            sourceEpoch: 8
        ))
        try coordinator.sourceChanged(.unavailable)
        XCTAssertThrowsError(try coordinator.sourceChanged(try resolution(
            target: target,
            sourceID: "source-a",
            sourceEpoch: 7
        ))) { error in
            XCTAssertEqual(error as? VideoReconnectError, .staleSourceEpoch)
        }
    }

    private func apply(
        _ state: ReconnectFixture.State,
        target: CanonicalUDID,
        coordinator: inout VideoReconnectCoordinator
    ) throws {
        try coordinator.runtimeReconnected(
            connectionEpoch: state.connectionEpoch
        )
        try coordinator.updateGeometry(DisplayGeometryDTO(
            connectionEpoch: state.connectionEpoch,
            geometryRevision: state.geometryRevision,
            logicalHeight: state.logicalHeight,
            logicalWidth: state.logicalWidth,
            orientation: .portrait
        ))
        try coordinator.sourceChanged(try resolution(
            target: target,
            sourceID: state.sourceID,
            sourceEpoch: state.sourceEpoch
        ))
    }

    private func resolution(
        target: CanonicalUDID,
        sourceID: String,
        sourceEpoch: UInt64
    ) throws -> VideoSourceResolution {
        .mapped(VideoResolvedSource(
            canonicalUDID: target,
            descriptor: try descriptor(sourceID, epoch: sourceEpoch),
            mappingProofID: "fixture-bridge-proof"
        ))
    }

    private func descriptor(
        _ sourceID: String,
        epoch: UInt64,
        width: UInt64 = 1_920,
        height: UInt64 = 1_080
    ) throws -> VideoSourceDescriptor {
        try VideoSourceDescriptor(
            sourceID: sourceID,
            sourceEpoch: epoch,
            activeFormatWidth: width,
            activeFormatHeight: height
        )
    }

    private func canonicalUDID(_ value: String) throws -> CanonicalUDID {
        try CanonicalUDID(canonicalString: value)
    }

    private func fixtureURL(
        requirement: String,
        relativePath: String
    ) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Fixtures/requirements/\(requirement)/\(relativePath)"
            )
    }

    private func loadBindingFixture() throws -> BindingFixture {
        try JSONDecoder().decode(
            BindingFixture.self,
            from: Data(contentsOf: fixtureURL(
                requirement: "T-001/video-control-source-binding-l4",
                relativePath: "input/input.v1.json"
            ))
        )
    }

    private func loadBindingExpected() throws -> BindingExpected {
        try JSONDecoder().decode(
            BindingExpected.self,
            from: Data(contentsOf: fixtureURL(
                requirement: "T-001/video-control-source-binding-l4",
                relativePath: "expected.v1.json"
            ))
        )
    }

    private func loadReconnectFixture() throws -> ReconnectFixture {
        try JSONDecoder().decode(
            ReconnectFixture.self,
            from: Data(contentsOf: fixtureURL(
                requirement: "T-014/control-video-dual-reconnect-l4",
                relativePath: "input/input.v1.json"
            ))
        )
    }

    private func loadReconnectExpected() throws -> ReconnectExpected {
        try JSONDecoder().decode(
            ReconnectExpected.self,
            from: Data(contentsOf: fixtureURL(
                requirement: "T-014/control-video-dual-reconnect-l4",
                relativePath: "expected.v1.json"
            ))
        )
    }
}

private struct BindingFixture: Decodable {
    struct Claim: Decodable {
        let canonicalUDID: String
        let mappingProofID: String
        let sourceEpoch: UInt64
        let sourceID: String
    }

    struct MismatchFrame: Decodable {
        let canonicalUDID: String
        let connectionEpoch: UInt64
        let expectedDiscardReason: String
        let frameSequence: UInt64
        let geometryRevision: UInt64
        let sourceEpoch: UInt64
        let sourceID: String
    }

    struct Source: Decodable {
        let activeFormatHeight: UInt64
        let activeFormatWidth: UInt64
        let sourceEpoch: UInt64
        let sourceID: String
    }

    let acceptedFrameSequence: UInt64
    let claims: [Claim]
    let connectionEpoch: UInt64
    let geometryRevision: UInt64
    let inventoryRevision: UInt64
    let logicalHeight: UInt64
    let logicalWidth: UInt64
    let mappingMode: String
    let mismatchFrames: [MismatchFrame]
    let sources: [Source]
    let targetCanonicalUDID: String
}

private struct BindingExpected: Decodable {
    let acceptedFrameSequence: UInt64
    let dimensionOnlyBinding: Bool
    let mappingMode: String
}

private struct ReconnectFixture: Decodable {
    struct ControlReconnect: Decodable {
        let connectionEpoch: UInt64
        let geometryRevision: UInt64
        let logicalHeight: UInt64
        let logicalWidth: UInt64
    }

    struct SourceReconnect: Decodable {
        let sourceEpoch: UInt64
        let sourceID: String
    }

    struct State: Decodable {
        let connectionEpoch: UInt64
        let geometryRevision: UInt64
        let logicalHeight: UInt64
        let logicalWidth: UInt64
        let sourceEpoch: UInt64
        let sourceID: String
    }

    let controlReconnect: ControlReconnect
    let initial: State
    let sourceReconnect: SourceReconnect
    let targetCanonicalUDID: String
}

private struct ReconnectExpected: Decodable {
    let controlReconnectBindingEpoch: UInt64
    let sourceReconnectBindingEpoch: UInt64
}
