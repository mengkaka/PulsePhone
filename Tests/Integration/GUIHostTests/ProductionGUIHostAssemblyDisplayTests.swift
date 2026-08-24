import CoreMedia
import CoreImage
import Foundation
@testable import PulsePhoneGUI
import PulsePhoneMedia
import PulsePhoneSharedDefinitions
import XCTest

final class ProductionGUIHostAssemblyDisplayTests: XCTestCase {
    func testImmediateDisplayCopyOwnsAttachmentsAndLeavesInputUntouched() throws {
        let sampleBuffer = try makeSampleBuffer(sampleCount: 2)
        let before = try sampleAttachments(sampleBuffer)
        XCTAssertEqual(before.count, 2)
        XCTAssertTrue(before.allSatisfy {
            $0[kCMSampleAttachmentKey_DisplayImmediately] == nil
        })

        let firstCopy = try XCTUnwrap(
            ProductionSampleBufferDisplay.makeImmediateDisplayCopy(sampleBuffer)
        )
        let secondCopy = try XCTUnwrap(
            ProductionSampleBufferDisplay.makeImmediateDisplayCopy(sampleBuffer)
        )

        let originalAfter = try sampleAttachments(sampleBuffer)
        XCTAssertTrue(originalAfter.allSatisfy {
            $0[kCMSampleAttachmentKey_DisplayImmediately] == nil
        })
        let firstAttachments = try sampleAttachments(firstCopy)
        let secondAttachments = try sampleAttachments(secondCopy)
        XCTAssertTrue(firstAttachments.allSatisfy {
            ($0[kCMSampleAttachmentKey_DisplayImmediately] as? Bool) == true
        })
        XCTAssertTrue(secondAttachments.allSatisfy {
            ($0[kCMSampleAttachmentKey_DisplayImmediately] as? Bool) == true
        })
        XCTAssertFalse(firstAttachments[0] === secondAttachments[0])

        firstAttachments[0]["consumer-local"] = true
        XCTAssertNil(secondAttachments[0]["consumer-local"])
        XCTAssertNil(originalAfter[0]["consumer-local"])
    }

    func testPresentationAgeUsesHostClockTimelineAndRejectsFutureSamples() throws {
        let sampleBuffer = try makeSampleBuffer(sampleCount: 1)
        XCTAssertEqual(
            ProductionSampleBufferDisplay.presentationAgeMicroseconds(
                sampleBuffer,
                hostTime: CMTime(value: 1, timescale: 1)
            ),
            1_000_000
        )
        XCTAssertNil(ProductionSampleBufferDisplay.presentationAgeMicroseconds(
            sampleBuffer,
            hostTime: CMTime(value: -1, timescale: 1)
        ))
    }

    func testVisualFingerprintDifferenceIsNormalizedAndIgnoresAlpha() {
        XCTAssertEqual(
            ProductionBoundVideoSession.fingerprintDifferenceMilli(
                [0, 0, 0, 0],
                [0, 0, 0, 255]
            ),
            0
        )
        XCTAssertEqual(
            ProductionBoundVideoSession.fingerprintDifferenceMilli(
                [0, 0, 0, 255],
                [255, 255, 255, 255]
            ),
            1_000
        )
        XCTAssertNil(ProductionBoundVideoSession.fingerprintDifferenceMilli(
            [0, 0, 0],
            [0, 0, 0]
        ))
    }

    func testVisualFingerprintRendersDistinctImageContent() throws {
        let context = CIContext(options: nil)
        let extent = CGRect(x: 0, y: 0, width: 64, height: 128)
        let black = try XCTUnwrap(ProductionBoundVideoSession.frameFingerprint(
            CIImage(color: .black).cropped(to: extent),
            imageContext: context
        ))
        let white = try XCTUnwrap(ProductionBoundVideoSession.frameFingerprint(
            CIImage(color: .white).cropped(to: extent),
            imageContext: context
        ))
        XCTAssertEqual(black.count, 16 * 16 * 4)
        XCTAssertEqual(white.count, 16 * 16 * 4)
        XCTAssertEqual(
            ProductionBoundVideoSession.fingerprintDifferenceMilli(black, white),
            1_000
        )
    }

    func testVisualFingerprintSamplesDistinctBGRAPixelBuffers() throws {
        let black = try makeBGRAPixelBuffer(component: 0)
        let white = try makeBGRAPixelBuffer(component: 255)
        let blackFingerprint = try XCTUnwrap(
            ProductionBoundVideoSession.pixelBufferFingerprint(black)
        )
        let whiteFingerprint = try XCTUnwrap(
            ProductionBoundVideoSession.pixelBufferFingerprint(white)
        )
        XCTAssertEqual(blackFingerprint.count, 16 * 16 * 4)
        XCTAssertEqual(whiteFingerprint.count, 16 * 16 * 4)
        XCTAssertEqual(
            ProductionBoundVideoSession.fingerprintDifferenceMilli(
                blackFingerprint,
                whiteFingerprint
            ),
            1_000
        )
    }

    func testVisualFingerprintSamplesDistinctNV12LumaPlanes() throws {
        let black = try makeNV12PixelBuffer(luma: 16)
        let white = try makeNV12PixelBuffer(luma: 235)
        let blackFingerprint = try XCTUnwrap(
            ProductionBoundVideoSession.pixelBufferFingerprint(black)
        )
        let whiteFingerprint = try XCTUnwrap(
            ProductionBoundVideoSession.pixelBufferFingerprint(white)
        )

        XCTAssertGreaterThan(
            try XCTUnwrap(ProductionBoundVideoSession.fingerprintDifferenceMilli(
                blackFingerprint,
                whiteFingerprint
            )),
            800
        )
    }

    func testPixelBufferFormatDescriptionContainsOnlyStructuralMetadata() throws {
        let pixelBuffer = try makeBGRAPixelBuffer(component: 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        XCTAssertEqual(
            ProductionBoundVideoSession.pixelBufferFormatDescription(pixelBuffer),
            "pixelFormat=BGRA "
                + "pixelFormatNumeric=1111970369 "
                + "planeCount=0 planes=0:64x128@\(bytesPerRow)"
        )
    }

    func testSampleBufferFormatDescriptionIdentifiesCompressedVideo() throws {
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: 1_170,
            height: 2_532,
            extensions: nil,
            formatDescriptionOut: &format
        ), noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleSize = 1
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            formatDescription: try XCTUnwrap(format),
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ), noErr)

        XCTAssertEqual(
            ProductionBoundVideoSession.sampleBufferFormatDescription(
                try XCTUnwrap(sampleBuffer)
            ),
            "outcome=missingImageBuffer mediaType=vide mediaSubtype=avc1"
        )
    }

    func testVisualProbeUsesFirstIncomingFrameAsBaseline() throws {
        let actionID = CanonicalUUID(value: UUID())
        var probe = ProductionVisualChangeProbeAccumulator()
        probe.arm(
            actionID: actionID,
            commandID: "button.home",
            clickedAtNanoseconds: 1_000
        )
        XCTAssertNil(probe.observe(
            fingerprint: [0, 0, 0, 255],
            capturedAtNanoseconds: 2_000,
            difference: ProductionBoundVideoSession.fingerprintDifferenceMilli
        ))
        XCTAssertNil(probe.observe(
            fingerprint: [0, 0, 0, 255],
            capturedAtNanoseconds: 3_000,
            difference: ProductionBoundVideoSession.fingerprintDifferenceMilli
        ))
        let changed = try XCTUnwrap(probe.observe(
            fingerprint: [255, 255, 255, 255],
            capturedAtNanoseconds: 4_000,
            difference: ProductionBoundVideoSession.fingerprintDifferenceMilli
        ))
        XCTAssertEqual(changed.actionID, actionID)
        XCTAssertTrue(changed.changed)
        XCTAssertEqual(changed.differenceMilli, 1_000)
    }

    func testVisualProbeUsesLastPreClickIncomingFrameAsBaseline() throws {
        let actionID = CanonicalUUID(value: UUID())
        var probe = ProductionVisualChangeProbeAccumulator()
        probe.arm(
            actionID: actionID,
            commandID: "button.appSwitcher",
            clickedAtNanoseconds: 1_000,
            baseline: [0, 0, 0, 255]
        )
        let changed = try XCTUnwrap(probe.observe(
            fingerprint: [255, 255, 255, 255],
            capturedAtNanoseconds: 2_000,
            difference: ProductionBoundVideoSession.fingerprintDifferenceMilli
        ))
        XCTAssertEqual(changed.actionID, actionID)
        XCTAssertTrue(changed.changed)
        XCTAssertEqual(changed.differenceMilli, 1_000)
        XCTAssertEqual(changed.elapsedNanoseconds, 1_000)
    }

    func testVisualProbeTimesOutWithoutReadableIncomingFingerprint() throws {
        let actionID = CanonicalUUID(value: UUID())
        var probe = ProductionVisualChangeProbeAccumulator()
        probe.arm(
            actionID: actionID,
            commandID: "button.appSwitcher",
            clickedAtNanoseconds: 10
        )
        let terminal = try XCTUnwrap(probe.observe(
            fingerprint: nil,
            capturedAtNanoseconds: 5_000_000_010,
            difference: ProductionBoundVideoSession.fingerprintDifferenceMilli
        ))
        XCTAssertFalse(terminal.changed)
        XCTAssertEqual(terminal.differenceMilli, 0)
        XCTAssertEqual(terminal.elapsedNanoseconds, 5_000_000_000)
    }

    func testVisualProbeClickTimestampUsesCaptureClockDomain() {
        let before = SystemMonotonicClock().now().nanoseconds
        let timestamp = ProductionGUIHostWindowController
            .visualProbeClickedAtNanoseconds()
        let after = SystemMonotonicClock().now().nanoseconds

        XCTAssertGreaterThanOrEqual(timestamp, before)
        XCTAssertLessThanOrEqual(timestamp, after)
    }

    func testCaptureReadyRequiresExactCurrentBindingLineage() throws {
        let target = try CanonicalUDID(
            canonicalString: "00008110-001A7D523E90401E"
        )
        let geometry = try DisplayGeometryDTO(
            connectionEpoch: 8,
            geometryRevision: 4,
            logicalHeight: 2_532,
            logicalWidth: 1_170,
            orientation: .portrait
        )
        let mapping = ProductionVideoSourceMapping(
            connectionEpoch: 8,
            geometry: geometry,
            mappingProofID: "operator-proof",
            sourceEpoch: 6,
            sourceID: "opaque-source"
        )
        let current = VideoBindingIdentity(
            canonicalUDID: target,
            connectionEpoch: 8,
            sourceID: "opaque-source",
            sourceEpoch: 6,
            geometryRevision: 4
        )
        XCTAssertTrue(ProductionGUIHostWindowController
            .captureReadyBindingIsCurrent(
                current,
                mapping: mapping,
                target: target
            ))
        XCTAssertFalse(ProductionGUIHostWindowController
            .captureReadyBindingIsCurrent(
                VideoBindingIdentity(
                    canonicalUDID: target,
                    connectionEpoch: 8,
                    sourceID: "opaque-source",
                    sourceEpoch: 7,
                    geometryRevision: 4
                ),
                mapping: mapping,
                target: target
            ))
        XCTAssertFalse(ProductionGUIHostWindowController
            .captureReadyBindingIsCurrent(
                VideoBindingIdentity(
                    canonicalUDID: target,
                    connectionEpoch: 8,
                    sourceID: "opaque-source",
                    sourceEpoch: 6,
                    geometryRevision: 5
                ),
                mapping: mapping,
                target: target
            ))
    }

    func testToolbarTerminalDiagnosticPreservesTypedOutcome() throws {
        let failed = try RepositoryJSONObject(members: [
            RepositoryJSONMember(
                key: "error",
                value: .object(try RepositoryJSONObject(members: [
                    RepositoryJSONMember(
                        key: "code",
                        value: .string("capabilityPreparing")
                    ),
                ]))
            ),
            RepositoryJSONMember(key: "outcome", value: .string("failed")),
        ])
        let failedDiagnostic = ProductionGUIHostWindowController
            .toolbarTerminalDiagnostic(failed)
        XCTAssertEqual(failedDiagnostic.outcome, "failed")
        XCTAssertEqual(failedDiagnostic.errorCode, "capabilityPreparing")

        let clientDiagnostic = ProductionGUIHostWindowController
            .toolbarTerminalDiagnostic(nil, clientErrorCode: "transportFailure")
        XCTAssertEqual(clientDiagnostic.outcome, "clientError")
        XCTAssertEqual(clientDiagnostic.errorCode, "transportFailure")
    }

    private func makeSampleBuffer(sampleCount: Int) throws -> CMSampleBuffer {
        var timing = (0..<sampleCount).map { index in
            CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 30),
                presentationTimeStamp: CMTime(value: Int64(index), timescale: 30),
                decodeTimeStamp: .invalid
            )
        }
        var sizes = Array(repeating: 1, count: sampleCount)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            formatDescription: nil,
            sampleCount: sampleCount,
            sampleTimingEntryCount: sampleCount,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: sampleCount,
            sampleSizeArray: &sizes,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(sampleBuffer)
    }

    private func makeBGRAPixelBuffer(component: UInt8) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            128,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        ), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        XCTAssertEqual(
            CVPixelBufferLockBaseAddress(buffer, []),
            kCVReturnSuccess
        )
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let baseAddress = try XCTUnwrap(
            CVPixelBufferGetBaseAddress(buffer)
        ).assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<CVPixelBufferGetHeight(buffer) {
            for column in 0..<CVPixelBufferGetWidth(buffer) {
                let offset = row * bytesPerRow + column * 4
                baseAddress[offset] = component
                baseAddress[offset + 1] = component
                baseAddress[offset + 2] = component
                baseAddress[offset + 3] = 255
            }
        }
        return buffer
    }

    private func makeNV12PixelBuffer(luma: UInt8) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            128,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        ), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        XCTAssertEqual(CVPixelBufferGetPlaneCount(buffer), 2)
        XCTAssertEqual(
            CVPixelBufferLockBaseAddress(buffer, []),
            kCVReturnSuccess
        )
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let baseAddress = try XCTUnwrap(
            CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
        ).assumingMemoryBound(to: UInt8.self)
        let byteCount = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            * CVPixelBufferGetHeightOfPlane(buffer, 0)
        baseAddress.update(repeating: luma, count: byteCount)
        return buffer
    }

    private func sampleAttachments(
        _ sampleBuffer: CMSampleBuffer
    ) throws -> [NSMutableDictionary] {
        let raw = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ))
        return try (raw as NSArray).map {
            try XCTUnwrap($0 as? NSMutableDictionary)
        }
    }
}
