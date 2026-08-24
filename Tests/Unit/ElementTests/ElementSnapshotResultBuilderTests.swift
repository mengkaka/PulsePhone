import CoreGraphics
import Foundation
import ImageIO
@testable import PulsePhoneElement
import PulsePhoneMedia
import PulsePhoneSharedDefinitions
import XCTest

final class ElementSnapshotResultBuilderTests: XCTestCase {
    private let captureSHA256 = String(repeating: "a", count: 64)

    func testBuildsCanonicalPortraitCoordinatesAndUnknownSemantics() throws {
        let frame = try makeFrame(
            pixelWidth: 120,
            pixelHeight: 240,
            logicalWidth: 60,
            logicalHeight: 120,
            orientation: .portrait
        )
        let candidate = try fusedCandidate(
            x: 12.25,
            y: 20.5,
            width: 30.5,
            height: 40.25,
            sources: [.vision, .omniparser],
            type: .controlCandidate,
            confidence: 0.8123456786,
            label: "Settings",
            labelSource: .vision
        )
        let result = try build(frame: frame, candidates: [candidate])
        let document = try RepositoryCanonicalJSON.validateCanonicalDocument(
            result.canonicalBytes,
            maximumByteCount: ElementSnapshotResultBuilder.maximumEncodedBytes
        )
        XCTAssertEqual(document.exactBytes, result.canonicalBytes)
        XCTAssertEqual(result.snapshotGeneration, 5)
        XCTAssertEqual(result.captureSHA256, captureSHA256)

        let capture = try object(document.root, "capture")
        XCTAssertEqual(capture["orientation"]?.stringValue, "portrait")
        XCTAssertEqual(capture["provider"]?.stringValue, "coreDevice")
        XCTAssertEqual(capture["sha256"]?.stringValue, captureSHA256)
        XCTAssertEqual(
            capture["fenceWaitMilliseconds"]?.numberValue,
            .uint64(100)
        )
        XCTAssertEqual(
            capture["frameAgeMilliseconds"]?.numberValue,
            .uint64(50)
        )
        XCTAssertTrue(isNull(capture["fallbackReason"]))
        let attempts = try array(capture, "attempts")
        XCTAssertEqual(attempts.count, 1)
        let attempt = try XCTUnwrap(attempts.first?.objectValue)
        XCTAssertEqual(attempt["provider"]?.stringValue, "coreDevice")
        XCTAssertEqual(attempt["status"]?.stringValue, "succeeded")
        XCTAssertTrue(isNull(attempt["errorCode"]))
        XCTAssertTrue(isNull(attempt["failureStage"]))
        XCTAssertEqual(
            try object(attempt, "timings")["totalMicroseconds"]?
                .numberValue?.requireUInt64(),
            12_000
        )
        XCTAssertEqual(document.root["settleReason"]?.stringValue, "freshFrame")

        let element = try firstElement(document.root)
        XCTAssertEqual(element["snapshotID"]?.stringValue?.count, 72)
        XCTAssertEqual(element["label"]?.stringValue, "Settings")
        XCTAssertEqual(element["labelSource"]?.stringValue, "vision")
        XCTAssertEqual(element["elementType"]?.stringValue, "controlCandidate")
        XCTAssertEqual(
            try strings(try array(element, "sources")),
            ["omniparser", "vision"]
        )
        for key in ["trackingID", "identifier", "enabled", "selected", "hittable"] {
            XCTAssertTrue(isNull(element[key]), key)
        }
        XCTAssertEqual(
            element["confidence"]?.numberValue,
            .decimal(try RepositoryJSONDecimal("0.812345679"))
        )

        let frames = try object(element, "frame")
        try assertRect(
            try object(frames, "pixel"),
            x: 12.25,
            y: 20.5,
            width: 30.5,
            height: 40.25
        )
        try assertRect(
            try object(frames, "logicalPoints"),
            x: 6.125,
            y: 10.25,
            width: 15.25,
            height: 20.125
        )
        try assertRect(
            try object(frames, "normalized"),
            x: 0.10208333,
            y: 0.08541667,
            width: 0.25416667,
            height: 0.16770833
        )
        let center = try object(element, "center")
        try assertPoint(try object(center, "pixel"), x: 27.5, y: 40.625)
        try assertPoint(
            try object(center, "logicalPoints"),
            x: 13.75,
            y: 20.3125
        )
        try assertPoint(
            try object(center, "normalized"),
            x: 0.229166665,
            y: 0.169270835
        )
        try assertCenterInsideFrame(element)
    }

    func testLandscapeUsesCaptureAxesWithoutSecondRotation() throws {
        let frame = try makeFrame(
            pixelWidth: 240,
            pixelHeight: 120,
            logicalWidth: 120,
            logicalHeight: 60,
            orientation: .landscapeLeft
        )
        let candidate = try fusedCandidate(
            x: 20,
            y: 10,
            width: 40,
            height: 20,
            sources: [.omniparser],
            type: .controlCandidate
        )
        let element = try firstElement(build(frame: frame, candidates: [candidate]).root)
        let frames = try object(element, "frame")
        try assertRect(
            try object(frames, "pixel"),
            x: 20,
            y: 10,
            width: 40,
            height: 20
        )
        try assertRect(
            try object(frames, "logicalPoints"),
            x: 10,
            y: 5,
            width: 20,
            height: 10
        )
        try assertRect(
            try object(frames, "normalized"),
            x: 0.08333333,
            y: 0.08333333,
            width: 0.16666667,
            height: 0.16666667
        )
        XCTAssertEqual(
            try object(try object(element, "center"), "pixel")["x"]?.numberValue,
            .uint64(40)
        )
    }

    func testIntegerAndDecimalTokensAreCanonicalWithoutExponentOrNegativeZero() throws {
        let frame = try makeFrame(
            pixelWidth: 120,
            pixelHeight: 240,
            logicalWidth: 60,
            logicalHeight: 120
        )
        let fullFrame = try fusedCandidate(
            x: 0,
            y: 0,
            width: 120,
            height: 240,
            sources: [.omniparser],
            type: .controlCandidate,
            confidence: 1
        )
        let fractional = try fusedCandidate(
            x: 0.000000004,
            y: 1,
            width: 20,
            height: 20,
            sources: [.vision],
            type: .text,
            confidence: 0
        )
        let result = try build(frame: frame, candidates: [fractional, fullFrame])
        let json = String(decoding: result.canonicalBytes, as: UTF8.self)
        _ = try RepositoryCanonicalJSON.validateCanonicalDocument(
            result.canonicalBytes,
            maximumByteCount: ElementSnapshotResultBuilder.maximumEncodedBytes
        )
        XCTAssertFalse(json.lowercased().contains("e+"))
        XCTAssertFalse(json.lowercased().contains("e-"))
        XCTAssertFalse(json.contains("-0"))

        let elements = try array(result.root, "elements").compactMap(\.objectValue)
        XCTAssertEqual(elements.count, 2)
        let full = try XCTUnwrap(elements.first { element in
            element["confidence"]?.numberValue == .uint64(1)
        })
        let normalized = try object(try object(full, "frame"), "normalized")
        XCTAssertEqual(normalized["x"]?.numberValue, .uint64(0))
        XCTAssertEqual(normalized["width"]?.numberValue, .uint64(1))
        let zeroConfidence = try XCTUnwrap(elements.first { element in
            element["confidence"]?.numberValue == .uint64(0)
        })
        XCTAssertEqual(
            try object(try object(zeroConfidence, "frame"), "pixel")["x"]?.numberValue,
            .uint64(0)
        )
    }

    func testSnapshotIDIgnoresLabelButChangesWithGeometryOrSources() throws {
        let frame = try makeFrame()
        let base = try fusedCandidate(
            x: 10,
            y: 20,
            width: 30,
            height: 40,
            sources: [.vision],
            type: .text,
            label: "Alpha",
            labelSource: .vision
        )
        let changedLabel = try fusedCandidate(
            x: 10,
            y: 20,
            width: 30,
            height: 40,
            sources: [.vision],
            type: .text,
            label: "Beta",
            labelSource: .vision
        )
        let changedGeometry = try fusedCandidate(
            x: 11,
            y: 20,
            width: 30,
            height: 40,
            sources: [.vision],
            type: .text,
            label: "Alpha",
            labelSource: .vision
        )
        let changedSources = try fusedCandidate(
            x: 10,
            y: 20,
            width: 30,
            height: 40,
            sources: [.vision, .omniparser],
            type: .text,
            label: "Alpha",
            labelSource: .vision
        )
        let baseID = try snapshotID(build(frame: frame, candidates: [base]).root)
        XCTAssertEqual(
            baseID,
            try snapshotID(build(frame: frame, candidates: [changedLabel]).root)
        )
        XCTAssertNotEqual(
            baseID,
            try snapshotID(build(frame: frame, candidates: [changedGeometry]).root)
        )
        XCTAssertNotEqual(
            baseID,
            try snapshotID(build(frame: frame, candidates: [changedSources]).root)
        )
    }

    func testCaptureFallbackAttemptsAreCanonicalAndFailClosed() throws {
        let fallbackAttempts = [
            captureAttempt(
                provider: .dvt,
                status: .failed,
                errorCode: .developerServicesUnavailable,
                failureStage: .captureOrValidate,
                totalMicroseconds: 19
            ),
            captureAttempt(
                provider: .coreDevice,
                status: .succeeded,
                totalMicroseconds: 23
            ),
        ]
        let result = try build(
            frame: makeFrame(provider: .coreDevice),
            candidates: [],
            captureAttempts: fallbackAttempts
        )
        let capture = try object(result.root, "capture")
        XCTAssertEqual(capture["provider"]?.stringValue, "coreDevice")
        let fallback = try object(capture, "fallbackReason")
        XCTAssertEqual(fallback["failedProvider"]?.stringValue, "dvt")
        XCTAssertEqual(
            fallback["errorCode"]?.stringValue,
            "developerServicesUnavailable"
        )
        XCTAssertEqual(fallback["failureStage"]?.stringValue, "captureOrValidate")
        let attempts = try array(capture, "attempts")
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(
            attempts.compactMap { $0.objectValue?["status"]?.stringValue },
            ["failed", "succeeded"]
        )

        let axAuditResult = try build(
            frame: makeFrame(provider: .axAudit),
            candidates: [],
            captureAttempts: [
                captureAttempt(
                    provider: .dvt,
                    status: .failed,
                    errorCode: .developerServicesUnavailable,
                    failureStage: .serviceOpen
                ),
                captureAttempt(
                    provider: .coreDevice,
                    status: .failed,
                    errorCode: .developerServicesUnavailable,
                    failureStage: .captureOrValidate
                ),
                captureAttempt(provider: .axAudit, status: .succeeded),
            ]
        )
        let axAuditCapture = try object(axAuditResult.root, "capture")
        XCTAssertEqual(axAuditCapture["provider"]?.stringValue, "axAudit")
        XCTAssertEqual(
            try object(axAuditCapture, "fallbackReason")["failedProvider"]?
                .stringValue,
            "coreDevice"
        )
        XCTAssertEqual(try array(axAuditCapture, "attempts").count, 3)

        let invalidAttempts: [[ElementSnapshotCaptureAttempt]] = [
            [
                captureAttempt(provider: .coreDevice, status: .failed),
                captureAttempt(provider: .dvt, status: .succeeded),
            ],
            [
                captureAttempt(provider: .coreDevice, status: .succeeded),
                captureAttempt(provider: .dvt, status: .succeeded),
            ],
            [
                captureAttempt(provider: .dvt, status: .failed),
                captureAttempt(provider: .axAudit, status: .succeeded),
            ],
            [
                captureAttempt(
                    provider: .coreDevice,
                    status: .succeeded,
                    totalMicroseconds: 30_000_001
                ),
            ],
        ]
        for invalid in invalidAttempts {
            XCTAssertThrowsError(try build(
                frame: makeFrame(provider: invalid.last!.provider),
                candidates: [],
                captureAttempts: invalid
            )) { error in
                XCTAssertEqual(
                    error as? ElementSnapshotResultBuildError,
                    .invalidCaptureAttempts
                )
            }
        }
    }

    func testCandidateOrderAndDuplicateCollisionSuffixAreDeterministic() throws {
        let frame = try makeFrame()
        let alpha = try fusedCandidate(
            x: 10,
            y: 20,
            width: 30,
            height: 40,
            sources: [.vision],
            type: .text,
            label: "Alpha",
            labelSource: .vision
        )
        let beta = try fusedCandidate(
            x: 10,
            y: 20,
            width: 30,
            height: 40,
            sources: [.vision],
            type: .text,
            label: "Beta",
            labelSource: .vision
        )
        let third = try fusedCandidate(
            x: 50,
            y: 60,
            width: 20,
            height: 20,
            sources: [.appleRegion],
            type: .unknown
        )
        let first = try build(frame: frame, candidates: [third, beta, alpha])
        let second = try build(frame: frame, candidates: [alpha, third, beta])
        XCTAssertEqual(first.canonicalBytes, second.canonicalBytes)

        let duplicateElements = try array(first.root, "elements")
            .compactMap(\.objectValue)
            .filter { $0["label"]?.stringValue != nil }
        XCTAssertEqual(duplicateElements.count, 2)
        let ids = try duplicateElements.map {
            try XCTUnwrap($0["snapshotID"]?.stringValue)
        }
        XCTAssertNotEqual(ids[0], ids[1])
        XCTAssertTrue(ids[1].hasSuffix(".2"))
        XCTAssertEqual(ids[0].utf8.count, 72)
        XCTAssertLessThanOrEqual(ids[1].utf8.count, 128)
    }

    func testDegradationAndEngineHealthUseOnlyThreeAnalyzerSources() throws {
        let frame = try makeFrame()
        let batch = ElementAnalyzerBatch(
            degraded: true,
            elapsedMilliseconds: 88,
            results: [
                analyzerResult(
                    source: .appleRegion,
                    status: .unavailable,
                    elapsed: nil
                ),
                analyzerResult(
                    source: .omniparser,
                    status: .succeeded,
                    elapsed: 80,
                    inference: 40,
                    queueWait: 12,
                    backend: "remote-http",
                    version: "v1"
                ),
                analyzerResult(
                    source: .vision,
                    status: .timedOut,
                    elapsed: 50,
                    queueWait: 20
                ),
            ]
        )
        let local = try fusedCandidate(
            x: 10,
            y: 10,
            width: 20,
            height: 20,
            sources: [.localGeometry],
            type: .unknown
        )
        let result = try build(frame: frame, batch: batch, candidates: [local])
        XCTAssertEqual(
            try strings(try array(result.root, "degradationReasons")),
            ["vision", "appleRegion"]
        )
        XCTAssertEqual(result.root["degraded"].map(bool), true)
        let engines = try object(result.root, "engines")
        XCTAssertEqual(Set(engines.members.map(\.key)), [
            "appleRegion", "omniparser", "vision",
        ])
        XCTAssertEqual(
            try object(engines, "omniparser")["backend"]?.stringValue,
            "remote-http"
        )
        XCTAssertEqual(
            try object(engines, "omniparser")["inferenceMilliseconds"]?
                .numberValue,
            .uint64(40)
        )
        XCTAssertEqual(
            try object(engines, "omniparser")["queueWaitMilliseconds"]?
                .numberValue,
            .uint64(12)
        )
        XCTAssertEqual(
            try object(engines, "vision")["status"]?.stringValue,
            "timedOut"
        )
        XCTAssertEqual(
            try object(engines, "appleRegion")["status"]?.stringValue,
            "unavailable"
        )
        let omniStages = try object(
            try object(engines, "omniparser"),
            "stageTimings"
        )
        XCTAssertEqual(
            omniStages["transportRoundTripMicroseconds"]?.numberValue,
            .uint64(2)
        )
        XCTAssertEqual(
            omniStages["transportOverheadMicroseconds"]?.numberValue,
            .uint64(1)
        )
        XCTAssertEqual(
            try object(result.root, "timings")["sourceDecodeMicroseconds"]?
                .numberValue,
            .uint64(17)
        )
    }

    func testEmptyElementsAreAValidSuccessfulSnapshot() throws {
        let result = try build(frame: makeFrame(), candidates: [])
        XCTAssertTrue(try array(result.root, "elements").isEmpty)
        XCTAssertEqual(result.root["degraded"].map(bool), false)
        XCTAssertLessThanOrEqual(
            result.canonicalBytes.count,
            ElementSnapshotResultBuilder.maximumEncodedBytes
        )
    }

    func testAnnotationProjectsControlsWhileJSONRetainsText() throws {
        let frame = try makeFrame()
        let control = try fusedCandidate(
            x: 10,
            y: 10,
            width: 20,
            height: 20,
            sources: [.omniparser],
            type: .controlCandidate,
            confidence: nil
        )
        let text = try fusedCandidate(
            x: 40,
            y: 10,
            width: 20,
            height: 20,
            sources: [.vision],
            type: .text,
            confidence: 0.9
        )

        let result = try build(frame: frame, candidates: [control, text])

        XCTAssertEqual(try array(result.root, "elements").count, 2)
        XCTAssertEqual(result.annotationElements.count, 1)
        XCTAssertEqual(result.annotationElements[0].type, .controlCandidate)
        XCTAssertEqual(result.annotationElements[0].frame, control.frame)
    }

    func testAnnotationRendererDrawsTopLeftFrameAndAttachesMetadata() async throws {
        let image = try makeTopLeftImage(width: 80, height: 120)
        let frame = try makeFrame(
            pixelWidth: 80,
            pixelHeight: 120,
            logicalWidth: 40,
            logicalHeight: 60,
            image: image
        )
        let candidate = try fusedCandidate(
            x: 10,
            y: 15,
            width: 25,
            height: 30,
            sources: [.omniparser],
            type: .controlCandidate,
            confidence: 0.9
        )
        let result = try build(frame: frame, candidates: [candidate])
        XCTAssertNil(result.root["annotation"])
        XCTAssertTrue(isNull(
            try object(result.root, "timings")["annotationMilliseconds"]
        ))

        let rendered = try await ElementAnnotationRenderer().render(
            frame: frame,
            result: result
        )
        XCTAssertEqual(rendered.contentType, "image/png")
        XCTAssertEqual(rendered.dimensions, frame.metadata.pixelDimensions)
        XCTAssertEqual(rendered.snapshotGeneration, result.snapshotGeneration)
        XCTAssertEqual(rendered.captureSHA256, captureSHA256)
        XCTAssertEqual(rendered.sha256, StableBytes.sha256Hex(rendered.bytes))
        XCTAssertLessThanOrEqual(
            UInt64(rendered.bytes.count),
            ElementAnnotationRenderer.maximumArtifactBytes
        )
        XCTAssertEqual(Array(rendered.bytes.prefix(8)), [
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        ])
        let decoded = try decodeCGImage(rendered.bytes)
        XCTAssertEqual(decoded.width, 80)
        XCTAssertEqual(decoded.height, 120)
        let pixels = try topLeftRGBAPixels(decoded)
        XCTAssertEqual(pixel(pixels, width: 80, x: 5, y: 5), [255, 255, 255, 255])
        let topEdge = pixel(pixels, width: 80, x: 20, y: 16)
        XCTAssertGreaterThan(topEdge[1], topEdge[0])
        XCTAssertGreaterThan(topEdge[1], topEdge[2])
        XCTAssertEqual(pixel(pixels, width: 80, x: 20, y: 60), [255, 255, 255, 255])

        let artifactID = try CanonicalUUID(
            "00000000-0000-0000-0000-000000000001"
        )
        let attached = try ElementSnapshotResultBuilder().attachingAnnotation(
            ElementSnapshotAnnotationMetadata(
                artifactID: artifactID,
                byteLength: UInt64(rendered.bytes.count),
                captureSHA256: rendered.captureSHA256,
                sha256: rendered.sha256,
                snapshotGeneration: rendered.snapshotGeneration
            ),
            elapsedMilliseconds: rendered.elapsedMilliseconds,
            to: result
        )
        let annotation = try object(attached.root, "annotation")
        XCTAssertEqual(annotation["artifactID"]?.stringValue, artifactID.canonicalString)
        XCTAssertEqual(annotation["captureSHA256"]?.stringValue, captureSHA256)
        XCTAssertEqual(annotation["sha256"]?.stringValue, rendered.sha256)
        XCTAssertNil(annotation["outputPath"])
        XCTAssertEqual(
            try object(attached.root, "timings")["annotationMilliseconds"]?.numberValue,
            .uint64(rendered.elapsedMilliseconds)
        )
        XCTAssertEqual(attached.annotationElements, result.annotationElements)
        _ = try RepositoryCanonicalJSON.validateCanonicalDocument(
            attached.canonicalBytes,
            maximumByteCount: ElementSnapshotResultBuilder.maximumEncodedBytes
        )
    }

    func testAnnotationRendererRejectsMismatchedFrameAndOversizedCanvas() async throws {
        let sourceFrame = try makeFrame()
        let result = try build(frame: sourceFrame, candidates: [])
        let mismatched = try makeFrame(
            pixelWidth: 100,
            pixelHeight: 240,
            logicalWidth: 50,
            logicalHeight: 120
        )
        do {
            _ = try await ElementAnnotationRenderer().render(
                frame: mismatched,
                result: result
            )
            XCTFail("mismatched frame rendered")
        } catch {
            XCTAssertEqual(
                error as? ElementAnnotationRendererError,
                .resultFrameMismatch
            )
        }

        let oversized = try makeFrame(
            pixelWidth: 5_000,
            pixelHeight: 5_000,
            logicalWidth: 1_000,
            logicalHeight: 1_000
        )
        let oversizedResult = try build(frame: oversized, candidates: [])
        do {
            _ = try await ElementAnnotationRenderer().render(
                frame: oversized,
                result: oversizedResult
            )
            XCTFail("oversized canvas rendered")
        } catch {
            XCTAssertEqual(error as? ElementAnnotationRendererError, .canvasTooLarge)
        }
    }

    func testAnnotationRendererPreservesSourceTopLeftOrientation() async throws {
        let image = try makeVerticalSplitImage(width: 40, height: 60)
        let frame = try makeFrame(
            pixelWidth: 40,
            pixelHeight: 60,
            logicalWidth: 20,
            logicalHeight: 30,
            image: image
        )
        let result = try build(frame: frame, candidates: [])
        let rendered = try await ElementAnnotationRenderer().render(
            frame: frame,
            result: result
        )
        let pixels = try topLeftRGBAPixels(try decodeCGImage(rendered.bytes))
        XCTAssertEqual(pixel(pixels, width: 40, x: 5, y: 5), [255, 0, 0, 255])
        XCTAssertEqual(pixel(pixels, width: 40, x: 5, y: 55), [0, 0, 255, 255])
    }

    func testAnnotationRendererAcceptsFractionalFrameAtDeviceCanvasEdge() async throws {
        let image = try makeTopLeftImage(width: 1_170, height: 2_532)
        let frame = try makeFrame(
            pixelWidth: 1_170,
            pixelHeight: 2_532,
            logicalWidth: 390,
            logicalHeight: 844,
            image: image
        )
        let candidate = try fusedCandidate(
            x: 1_130.01,
            y: 2_490.01,
            width: 39.99,
            height: 41.99,
            sources: [.vision],
            type: .text,
            confidence: 0.9
        )
        let result = try build(frame: frame, candidates: [candidate])

        let rendered = try await ElementAnnotationRenderer().render(
            frame: frame,
            result: result
        )

        XCTAssertEqual(rendered.dimensions, frame.metadata.pixelDimensions)
        XCTAssertEqual(rendered.snapshotGeneration, result.snapshotGeneration)
        XCTAssertEqual(Array(rendered.bytes.prefix(8)), [
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        ])
    }

    func testAnnotationMetadataRejectsCrossGenerationDigestAndRepeatedAttachment() throws {
        let result = try build(frame: makeFrame(), candidates: [])
        let artifactID = try CanonicalUUID(
            "00000000-0000-0000-0000-000000000001"
        )
        let valid = ElementSnapshotAnnotationMetadata(
            artifactID: artifactID,
            byteLength: 8,
            captureSHA256: captureSHA256,
            sha256: String(repeating: "b", count: 64),
            snapshotGeneration: result.snapshotGeneration
        )
        let attached = try ElementSnapshotResultBuilder().attachingAnnotation(
            valid,
            elapsedMilliseconds: 2,
            to: result
        )
        for invalid in [
            ElementSnapshotAnnotationMetadata(
                artifactID: artifactID,
                byteLength: 8,
                captureSHA256: String(repeating: "c", count: 64),
                sha256: String(repeating: "b", count: 64),
                snapshotGeneration: result.snapshotGeneration
            ),
            ElementSnapshotAnnotationMetadata(
                artifactID: artifactID,
                byteLength: 8,
                captureSHA256: captureSHA256,
                sha256: String(repeating: "b", count: 64),
                snapshotGeneration: result.snapshotGeneration + 1
            ),
        ] {
            XCTAssertThrowsError(
                try ElementSnapshotResultBuilder().attachingAnnotation(
                    invalid,
                    elapsedMilliseconds: 2,
                    to: result
                )
            ) { error in
                XCTAssertEqual(
                    error as? ElementSnapshotResultBuildError,
                    .invalidAnnotation
                )
            }
        }
        XCTAssertThrowsError(
            try ElementSnapshotResultBuilder().attachingAnnotation(
                valid,
                elapsedMilliseconds: 2,
                to: attached
            )
        ) { error in
            XCTAssertEqual(
                error as? ElementSnapshotResultBuildError,
                .invalidAnnotation
            )
        }
    }

    func testFailsClosedForElementLabelResultAndTimingCaps() throws {
        let frame = try makeFrame()
        let ordinary = try fusedCandidate(
            x: 1,
            y: 1,
            width: 20,
            height: 20,
            sources: [.vision],
            type: .text,
            label: "A",
            labelSource: .vision
        )
        XCTAssertThrowsError(
            try build(
                frame: frame,
                candidates: Array(repeating: ordinary, count: 257)
            )
        ) { error in
            XCTAssertEqual(error as? ElementSnapshotResultBuildError, .tooManyElements)
        }

        let oversizedLabel = try fusedCandidate(
            x: 1,
            y: 1,
            width: 20,
            height: 20,
            sources: [.vision],
            type: .text,
            label: String(repeating: "a", count: 1_025),
            labelSource: .vision
        )
        XCTAssertThrowsError(try build(frame: frame, candidates: [oversizedLabel])) { error in
            XCTAssertEqual(error as? ElementSnapshotResultBuildError, .labelTooLarge)
        }

        let maximumLabel = try fusedCandidate(
            x: 1,
            y: 1,
            width: 20,
            height: 20,
            sources: [.vision],
            type: .text,
            label: String(repeating: "a", count: 1_024),
            labelSource: .vision
        )
        XCTAssertThrowsError(
            try build(
                frame: frame,
                candidates: Array(repeating: maximumLabel, count: 256)
            )
        ) { error in
            XCTAssertEqual(
                error as? ElementSnapshotResultBuildError,
                .encodedResultTooLarge
            )
        }

        XCTAssertThrowsError(
            try build(
                frame: frame,
                candidates: [],
                timings: ElementSnapshotPipelineTimings(
                    captureMilliseconds: 30_001,
                    fusionMilliseconds: 1
                )
            )
        ) { error in
            XCTAssertEqual(error as? ElementSnapshotResultBuildError, .invalidTiming)
        }

        XCTAssertNoThrow(try build(
            frame: frame,
            candidates: [],
            correctionMilliseconds: 1_001
        ))
        XCTAssertThrowsError(try build(
            frame: frame,
            candidates: [],
            correctionMilliseconds:
                ElementSnapshotResultBuilder.maximumCorrectionTimingMilliseconds + 1
        )) { error in
            XCTAssertEqual(error as? ElementSnapshotResultBuildError, .invalidTiming)
        }
    }

    func testFailsClosedForInvalidConfidenceDigestAndEngineMetadata() throws {
        let frame = try makeFrame()
        let invalidConfidence = try fusedCandidate(
            x: 1,
            y: 1,
            width: 20,
            height: 20,
            sources: [.omniparser],
            type: .controlCandidate,
            confidence: 1.1
        )
        XCTAssertThrowsError(try build(frame: frame, candidates: [invalidConfidence])) { error in
            XCTAssertEqual(error as? ElementSnapshotResultBuildError, .invalidCandidate)
        }
        XCTAssertThrowsError(
            try build(frame: frame, candidates: [], captureSHA256: "ABC")
        ) { error in
            XCTAssertEqual(error as? ElementSnapshotResultBuildError, .invalidCaptureDigest)
        }

        let invalidBatch = ElementAnalyzerBatch(
            degraded: false,
            elapsedMilliseconds: 1,
            results: [
                ElementAnalyzerResult(
                    source: .omniparser,
                    status: .succeeded,
                    profileID: ""
                ),
                analyzerResult(source: .vision, status: .succeeded),
                analyzerResult(source: .appleRegion, status: .succeeded),
            ]
        )
        XCTAssertThrowsError(
            try build(frame: frame, batch: invalidBatch, candidates: [])
        ) { error in
            XCTAssertEqual(error as? ElementSnapshotResultBuildError, .invalidEngineMetadata)
        }

        for invalidTiming in [
            analyzerResult(
                source: .omniparser,
                status: .succeeded,
                inference: 10_001
            ),
            analyzerResult(
                source: .omniparser,
                status: .succeeded,
                queueWait: 10_001
            ),
        ] {
            let batch = ElementAnalyzerBatch(
                degraded: false,
                elapsedMilliseconds: 1,
                results: [
                    invalidTiming,
                    analyzerResult(source: .vision, status: .succeeded),
                    analyzerResult(source: .appleRegion, status: .succeeded),
                ]
            )
            XCTAssertThrowsError(
                try build(frame: frame, batch: batch, candidates: [])
            ) { error in
                XCTAssertEqual(
                    error as? ElementSnapshotResultBuildError,
                    .invalidEngineMetadata
                )
            }
        }
    }

    func testFailsClosedForInvalidAnalyzerStageTimings() throws {
        let frame = try makeFrame()
        let invalidStages = [
            ElementAnalyzerStageTimings(),
            ElementAnalyzerStageTimings(
                resizeAndColorSpaceMicroseconds: 1,
                inputEncodeMicroseconds: 1,
                requestEncodeMicroseconds: 1,
                transportRoundTripMicroseconds: 2,
                transportOverheadMicroseconds: 3,
                responseDecodeMicroseconds: 1
            ),
            ElementAnalyzerStageTimings(
                resizeAndColorSpaceMicroseconds: 1,
                inputEncodeMicroseconds: 1,
                requestEncodeMicroseconds: 1,
                transportRoundTripMicroseconds: 2,
                transportOverheadMicroseconds: 1,
                responseDecodeMicroseconds:
                    ElementSnapshotResultBuilder.maximumStageTimingMicroseconds + 1
            ),
        ]
        for stageTimings in invalidStages {
            let batch = ElementAnalyzerBatch(
                degraded: false,
                elapsedMilliseconds: 2,
                results: [
                    analyzerResult(
                        source: .omniparser,
                        status: .succeeded,
                        stageTimings: stageTimings
                    ),
                    analyzerResult(source: .vision, status: .succeeded),
                    analyzerResult(source: .appleRegion, status: .succeeded),
                ]
            )
            XCTAssertThrowsError(
                try build(frame: frame, batch: batch, candidates: [])
            ) { error in
                XCTAssertEqual(
                    error as? ElementSnapshotResultBuildError,
                    .invalidEngineMetadata
                )
            }
        }
    }

    func testFailsClosedForCaptureFreshnessTimingsAboveHardCap() throws {
        let staleFrame = try makeFrame(
            queryStartedAtNanoseconds: 0,
            capturedAtNanoseconds: 0,
            validatedAtNanoseconds: 30_001_000_000,
            maximumFrameAgeNanoseconds: 30_001_000_000
        )
        XCTAssertThrowsError(try build(frame: staleFrame, candidates: [])) { error in
            XCTAssertEqual(error as? ElementSnapshotResultBuildError, .invalidTiming)
        }

        let delayedFrame = try makeFrame(
            queryStartedAtNanoseconds: 0,
            capturedAtNanoseconds: 30_001_000_000,
            validatedAtNanoseconds: 30_001_000_000,
            maximumFrameAgeNanoseconds: 1
        )
        XCTAssertThrowsError(try build(frame: delayedFrame, candidates: [])) { error in
            XCTAssertEqual(error as? ElementSnapshotResultBuildError, .invalidTiming)
        }
    }

    private func build(
        frame: SnapshotFrame,
        batch: ElementAnalyzerBatch? = nil,
        candidates: [FusedElementCandidate],
        captureSHA256: String? = nil,
        timings: ElementSnapshotPipelineTimings = .init(
            captureMilliseconds: 12,
            fusionMilliseconds: 3,
            sourceDecodeMicroseconds: 17
        ),
        correctionMilliseconds: UInt64 = 2,
        captureAttempts: [ElementSnapshotCaptureAttempt]? = nil
    ) throws -> ElementSnapshotResult {
        try ElementSnapshotResultBuilder().build(
            frame: frame,
            analyzerBatch: batch ?? successfulBatch(),
            localGeometry: ElementLocalGeometryResult(
                appliedParentCount: 0,
                candidates: candidates,
                componentCount: 0,
                elapsedMilliseconds: correctionMilliseconds
            ),
            captureSHA256: captureSHA256 ?? self.captureSHA256,
            timings: timings,
            captureAttempts: captureAttempts
        )
    }

    private func captureAttempt(
        provider: SnapshotCaptureProvider,
        status: ElementSnapshotCaptureAttemptStatus,
        errorCode: ElementSnapshotCaptureFailureCode? = nil,
        failureStage: ElementSnapshotCaptureFailureStage? = nil,
        totalMicroseconds: UInt64 = 10
    ) -> ElementSnapshotCaptureAttempt {
        ElementSnapshotCaptureAttempt(
            provider: provider,
            status: status,
            errorCode: errorCode,
            failureStage: failureStage,
            timings: ElementSnapshotCaptureAttemptTimings(
                captureMicroseconds: totalMicroseconds,
                queueWaitMicroseconds: 0,
                serviceCloseMicroseconds: 0,
                serviceOpenMicroseconds: 0,
                totalMicroseconds: totalMicroseconds
            )
        )
    }

    private func successfulBatch() -> ElementAnalyzerBatch {
        ElementAnalyzerBatch(
            degraded: false,
            elapsedMilliseconds: 25,
            results: [
                analyzerResult(
                    source: .omniparser,
                    status: .succeeded,
                    elapsed: 20,
                    inference: 15,
                    queueWait: 2
                ),
                analyzerResult(
                    source: .vision,
                    status: .succeeded,
                    elapsed: 10,
                    inference: 8,
                    queueWait: 1
                ),
                analyzerResult(
                    source: .appleRegion,
                    status: .succeeded,
                    elapsed: 8,
                    inference: 6,
                    queueWait: 1
                ),
            ]
        )
    }

    private func analyzerResult(
        source: ElementAnalyzerSource,
        status: ElementAnalyzerStatus,
        elapsed: UInt64? = 1,
        inference: UInt64? = nil,
        queueWait: UInt64? = nil,
        backend: String? = nil,
        version: String? = nil,
        stageTimings explicitStageTimings: ElementAnalyzerStageTimings? = nil
    ) -> ElementAnalyzerResult {
        let stageTimings: ElementAnalyzerStageTimings
        switch source {
        case .omniparser:
            stageTimings = ElementAnalyzerStageTimings(
                resizeAndColorSpaceMicroseconds: 1,
                inputEncodeMicroseconds: 1,
                requestEncodeMicroseconds: 1,
                transportRoundTripMicroseconds: 2,
                transportOverheadMicroseconds: 1,
                responseDecodeMicroseconds: 1
            )
        case .vision:
            stageTimings = .noDerivedInputOrTransport
        case .appleRegion:
            stageTimings = ElementAnalyzerStageTimings(
                resizeAndColorSpaceMicroseconds: 1,
                inputEncodeMicroseconds: 1,
                transportRoundTripMicroseconds: 2,
                transportOverheadMicroseconds: 1,
                responseDecodeMicroseconds: 1
            )
        case .localGeometry:
            stageTimings = .init()
        }
        return ElementAnalyzerResult(
            source: source,
            status: status,
            profileID: "\(source.rawValue).test.v1",
            elapsedMilliseconds: elapsed,
            inferenceMilliseconds: inference,
            inputDimensions: try! SnapshotImageDimensions(width: 60, height: 120),
            queueWaitMilliseconds: queueWait,
            backend: backend,
            version: version,
            stageTimings: explicitStageTimings ?? stageTimings
        )
    }

    private func fusedCandidate(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        sources: [ElementAnalyzerSource],
        type: ElementCandidateType,
        confidence: Double? = nil,
        label: String? = nil,
        labelSource: ElementAnalyzerSource? = nil
    ) throws -> FusedElementCandidate {
        FusedElementCandidate(
            frame: try SnapshotPixelRect(
                x: x,
                y: y,
                width: width,
                height: height
            ),
            sources: sources,
            type: type,
            confidence: confidence,
            label: label,
            labelSource: labelSource
        )
    }

    private func makeFrame(
        pixelWidth: UInt64 = 120,
        pixelHeight: UInt64 = 240,
        logicalWidth: UInt64 = 60,
        logicalHeight: UInt64 = 120,
        orientation: DisplayOrientationDTO = .portrait,
        provider: SnapshotCaptureProvider = .coreDevice,
        image: CGImage? = nil,
        queryStartedAtNanoseconds: UInt64 = 1_000_000,
        capturedAtNanoseconds: UInt64 = 101_000_000,
        validatedAtNanoseconds: UInt64 = 151_000_000,
        maximumFrameAgeNanoseconds: UInt64 = 200_000_000
    ) throws -> SnapshotFrame {
        let dimensions = try SnapshotImageDimensions(
            width: pixelWidth,
            height: pixelHeight
        )
        let geometry = try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 11,
            logicalHeight: logicalHeight,
            logicalWidth: logicalWidth,
            orientation: orientation
        )
        let fence = try SnapshotFreshnessFence(
            queryStartedAtNanoseconds: queryStartedAtNanoseconds,
            baselineFrameSequence: 40,
            maximumFrameAgeNanoseconds: maximumFrameAgeNanoseconds,
            validatedAtNanoseconds: validatedAtNanoseconds
        )
        let metadata = try SnapshotFrameMetadata(
            canonicalUDID: try CanonicalUDID(canonicalString: "DEVICE-A"),
            connectionEpoch: geometry.connectionEpoch,
            sourceEpoch: nil,
            sourceID: nil,
            geometry: geometry,
            captureGeneration: 5,
            frameSequence: 41,
            capturedAtNanoseconds: capturedAtNanoseconds,
            freshnessFence: fence,
            pixelDimensions: dimensions,
            provider: provider,
            settleReason: .queryFenceSatisfied
        )
        return try SnapshotFrame(
            authority: SnapshotFrameAuthority(
                canonicalUDID: metadata.canonicalUDID,
                geometry: geometry,
                sourceEpoch: nil,
                sourceID: nil,
                captureGeneration: metadata.captureGeneration
            ),
            metadata: metadata,
            sourceImage: try image.map { image in
                guard image.width == Int(pixelWidth), image.height == Int(pixelHeight) else {
                    throw SnapshotFrameError.sourceDimensionsMismatch
                }
                return try SnapshotSourceImageLease(cgImage: image)
            } ?? SnapshotSourceImageLease(
                encodedBytes: [0x89, 0x50, 0x4e, 0x47],
                contentType: "image/png",
                dimensions: dimensions
            )
        )
    }

    private func makeTopLeftImage(width: Int, height: Int) throws -> CGImage {
        let pixels = [UInt8](repeating: 255, count: width * height * 4)
        return try image(width: width, height: height, pixels: pixels)
    }

    private func makeVerticalSplitImage(width: Int, height: Int) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if y < height / 2 {
                    pixels[offset] = 255
                    pixels[offset + 1] = 0
                    pixels[offset + 2] = 0
                } else {
                    pixels[offset] = 0
                    pixels[offset + 1] = 0
                    pixels[offset + 2] = 255
                }
                pixels[offset + 3] = 255
            }
        }
        return try image(width: width, height: height, pixels: pixels)
    }

    private func image(
        width: Int,
        height: Int,
        pixels: [UInt8]
    ) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func decodeCGImage(_ bytes: [UInt8]) throws -> CGImage {
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(Data(bytes) as CFData, nil)
        )
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func topLeftRGBAPixels(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try pixels.withUnsafeMutableBytes { buffer in
            try XCTUnwrap(CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ))
        }
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        return pixels
    }

    private func pixel(
        _ pixels: [UInt8],
        width: Int,
        x: Int,
        y: Int
    ) -> [UInt8] {
        let offset = (y * width + x) * 4
        return Array(pixels[offset..<(offset + 4)])
    }

    private func firstElement(_ root: RepositoryJSONObject) throws -> RepositoryJSONObject {
        try XCTUnwrap(try array(root, "elements").first?.objectValue)
    }

    private func snapshotID(_ root: RepositoryJSONObject) throws -> String {
        try XCTUnwrap(try firstElement(root)["snapshotID"]?.stringValue)
    }

    private func object(
        _ object: RepositoryJSONObject,
        _ key: String
    ) throws -> RepositoryJSONObject {
        try XCTUnwrap(object[key]?.objectValue)
    }

    private func array(
        _ object: RepositoryJSONObject,
        _ key: String
    ) throws -> [RepositoryJSONValue] {
        try XCTUnwrap(object[key]?.arrayValue)
    }

    private func strings(_ values: [RepositoryJSONValue]) throws -> [String] {
        try values.map { try XCTUnwrap($0.stringValue) }
    }

    private func bool(_ value: RepositoryJSONValue) -> Bool {
        guard case .bool(let result) = value else {
            XCTFail("Expected bool")
            return false
        }
        return result
    }

    private func isNull(_ value: RepositoryJSONValue?) -> Bool {
        guard case .null? = value else { return false }
        return true
    }

    private func double(_ value: RepositoryJSONValue?) throws -> Double {
        switch try XCTUnwrap(value?.numberValue) {
        case .decimal(let value):
            return try XCTUnwrap(Double(value.canonicalString))
        case .int64(let value):
            return Double(value)
        case .uint64(let value):
            return Double(value)
        }
    }

    private func assertRect(
        _ value: RepositoryJSONObject,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(try double(value["x"]), x, accuracy: 0.000000001, file: file, line: line)
        XCTAssertEqual(try double(value["y"]), y, accuracy: 0.000000001, file: file, line: line)
        XCTAssertEqual(
            try double(value["width"]),
            width,
            accuracy: 0.000000001,
            file: file,
            line: line
        )
        XCTAssertEqual(
            try double(value["height"]),
            height,
            accuracy: 0.000000001,
            file: file,
            line: line
        )
    }

    private func assertPoint(
        _ value: RepositoryJSONObject,
        x: Double,
        y: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(try double(value["x"]), x, accuracy: 0.000000001, file: file, line: line)
        XCTAssertEqual(try double(value["y"]), y, accuracy: 0.000000001, file: file, line: line)
    }

    private func assertCenterInsideFrame(
        _ element: RepositoryJSONObject,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let frames = try object(element, "frame")
        let centers = try object(element, "center")
        for key in ["pixel", "logicalPoints", "normalized"] {
            let frame = try object(frames, key)
            let center = try object(centers, key)
            let x = try double(frame["x"])
            let y = try double(frame["y"])
            let maxX = x + (try double(frame["width"]))
            let maxY = y + (try double(frame["height"]))
            let centerX = try double(center["x"])
            let centerY = try double(center["y"])
            XCTAssertGreaterThanOrEqual(centerX, x, file: file, line: line)
            XCTAssertLessThanOrEqual(centerX, maxX, file: file, line: line)
            XCTAssertGreaterThanOrEqual(centerY, y, file: file, line: line)
            XCTAssertLessThanOrEqual(centerY, maxY, file: file, line: line)
        }
    }
}
