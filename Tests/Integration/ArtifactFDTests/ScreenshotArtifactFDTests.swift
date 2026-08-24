import Foundation
import PulsePhoneHostPaths
import PulsePhoneRuntimeKernel
import PulsePhoneSharedDefinitions
import XCTest

final class ScreenshotArtifactFDTests: XCTestCase {
    func testScreenshotReservationFDPathSafetyFixture() throws {
        let expected = try loadExpected(
            "T-011/screenshot-reservation-fd-path-safety-l3"
        )
        let artifactID = try uuid(1)
        let requestID = try uuid(2)
        let identity = HostNodeIdentity(device: 7, inode: 11)
        let node = ScreenshotReservationNode(
            identity: identity,
            owner: 501,
            kind: .regularFile,
            mode: 0o600
        )
        let reservation = try ScreenshotReservation(
            artifactID: artifactID,
            directoryPath: "/tmp/pulsephone-501/scratch/device/epoch/screenshots",
            node: node
        )
        let png = ScreenshotReservationValidator.pngSignature + [0, 1, 2, 3]
        let completion = ScreenshotHelperCompletion(
            artifactID: artifactID,
            byteCount: UInt64(png.count),
            format: .png
        )
        let validated = try ScreenshotReservationValidator.validate(
            reservation: reservation,
            completion: completion,
            reopenedNode: node,
            bytes: png
        )
        XCTAssertTrue(validated.readOnly)
        XCTAssertTrue(validated.reservationUnlinked)
        XCTAssertEqual(validated.contentType, "image/png")
        XCTAssertEqual(validated.nodeIdentity, identity)

        let foreignNode = ScreenshotReservationNode(
            identity: HostNodeIdentity(device: 7, inode: 12),
            owner: 501,
            kind: .regularFile,
            mode: 0o600
        )
        XCTAssertThrowsError(try ScreenshotReservationValidator.validate(
            reservation: reservation,
            completion: completion,
            reopenedNode: foreignNode,
            bytes: png
        )) { error in
            XCTAssertEqual(error as? ScreenshotArtifactError, .unsafeHostPath)
            XCTAssertEqual(
                ScreenshotReservationValidator.failureCleanup(for: .unsafeHostPath),
                .preserveNode
            )
        }
        XCTAssertThrowsError(try ScreenshotReservationValidator.validate(
            reservation: reservation,
            completion: ScreenshotHelperCompletion(
                artifactID: artifactID,
                byteCount: ScreenshotReservationValidator.maximumArtifactBytes + 1,
                format: .png
            ),
            reopenedNode: node,
            bytes: []
        )) { error in
            XCTAssertEqual(error as? ScreenshotArtifactError, .artifactTooLarge)
        }
        XCTAssertThrowsError(try ScreenshotReservationValidator.validate(
            reservation: reservation,
            completion: ScreenshotHelperCompletion(
                artifactID: artifactID,
                byteCount: UInt64(png.count),
                format: .png,
                returnedPath: "/tmp/replacement.png"
            ),
            reopenedNode: node,
            bytes: png
        )) { error in
            XCTAssertEqual(error as? ScreenshotArtifactError, .protocolViolation)
        }

        let metadata = ArtifactFDMetadata(
            requestID: requestID,
            artifactID: artifactID,
            sizeBytes: validated.byteCount
        )
        let frames = try ArtifactFDOutboundPlanner.plan(
            metadata: metadata,
            availableFinalControlFrames: 2
        )
        XCTAssertEqual(frames.count, 2)
        guard case .artifactFD = frames[0],
              case .successResponse = frames[1]
        else {
            return XCTFail("ArtifactFD must precede success Response")
        }
        XCTAssertThrowsError(try ArtifactFDOutboundPlanner.plan(
            metadata: metadata,
            availableFinalControlFrames: 1
        ))

        try ArtifactFDSCMRightsTranscript(
            headerByteCount: 16,
            firstSendByteCount: 1,
            firstSendFDCount: 1,
            remainingHeaderFDCount: 0,
            payloadAncillaryFDCount: 0,
            receiverControlTruncated: false
        ).validate()
        XCTAssertThrowsError(try ArtifactFDSCMRightsTranscript(
            headerByteCount: 16,
            firstSendByteCount: 1,
            firstSendFDCount: 1,
            remainingHeaderFDCount: 1,
            payloadAncillaryFDCount: 0,
            receiverControlTruncated: false
        ).validate())

        let handle = ArtifactFDHandle(
            metadata: metadata,
            node: node,
            readOnly: true,
            pngValid: true
        )
        var binder = ArtifactFDClientBinder()
        XCTAssertEqual(try binder.receiveArtifact(handle), .waitingForResponse)
        XCTAssertEqual(
            try binder.receiveSuccessResponse(
                requestID: requestID,
                artifactID: artifactID
            ),
            .complete(handle)
        )
        XCTAssertEqual(bool(expected["unlinkBeforeDelivery"]), true)
        XCTAssertEqual(uint(expected["headerBytes"]), 16)
        XCTAssertEqual(uint(expected["maximumArtifactBytes"]), 64 * 1_024 * 1_024)
    }

    func testLegacyScreenshotFormatConversionFixture() throws {
        let input = try loadInput(
            "T-005/legacy-screenshot-format-conversion-l4"
        )
        let expected = try loadExpected(
            "T-005/legacy-screenshot-format-conversion-l4"
        )
        let png = ScreenshotReservationValidator.pngSignature + [9, 8, 7]
        let converted = try ScreenshotHelperFormatNormalizer.normalizeToPNG(
            sourceFormat: .tiff,
            sourceBytes: [1, 2, 3],
            convertedPNG: png
        )
        XCTAssertEqual(converted, png)
        XCTAssertEqual(string(input["sourceFormat"]), "tiff")
        XCTAssertEqual(string(expected["outputFormat"]), "png")
        XCTAssertThrowsError(try ScreenshotHelperFormatNormalizer.normalizeToPNG(
            sourceFormat: .unknown,
            sourceBytes: []
        ))
    }

    func testElementAnnotationArtifactRequiresExactPurposeAndFrameBinding() throws {
        let artifactID = try uuid(3)
        let requestID = try uuid(4)
        let binding = try ElementAnnotationArtifactBinding(
            snapshotGeneration: 7,
            captureSHA256: String(repeating: "a", count: 64),
            pixelWidth: 1_179,
            pixelHeight: 2_556
        )
        let metadata = ArtifactFDMetadata(
            requestID: requestID,
            artifactID: artifactID,
            sizeBytes: 8,
            elementAnnotation: binding
        )
        XCTAssertEqual(metadata.purpose, .elementAnnotation)
        XCTAssertEqual(metadata.elementAnnotation, binding)

        let node = ScreenshotReservationNode(
            identity: HostNodeIdentity(device: 7, inode: 12),
            owner: 501,
            kind: .regularFile,
            mode: 0o600
        )
        let handle = ArtifactFDHandle(
            metadata: metadata,
            node: node,
            readOnly: true,
            pngValid: true
        )
        var binder = ArtifactFDClientBinder()
        XCTAssertThrowsError(try binder.receiveArtifact(handle)) { error in
            XCTAssertEqual(error as? ArtifactFDProtocolError, .invalidDescriptor)
        }
        XCTAssertEqual(
            try binder.receiveArtifact(
                handle,
                expectedBinding: .elementAnnotation(binding)
            ),
            .waitingForResponse
        )
        XCTAssertEqual(
            try binder.receiveSuccessResponse(
                requestID: requestID,
                artifactID: artifactID
            ),
            .complete(handle)
        )

        for invalid in [
            { try ElementAnnotationArtifactBinding(
                snapshotGeneration: 0,
                captureSHA256: String(repeating: "a", count: 64),
                pixelWidth: 1,
                pixelHeight: 1
            ) },
            { try ElementAnnotationArtifactBinding(
                snapshotGeneration: 1,
                captureSHA256: "invalid",
                pixelWidth: 1,
                pixelHeight: 1
            ) },
            { try ElementAnnotationArtifactBinding(
                snapshotGeneration: 1,
                captureSHA256: String(repeating: "a", count: 64),
                pixelWidth: 65_536,
                pixelHeight: 1
            ) },
        ] {
            XCTAssertThrowsError(try invalid()) { error in
                XCTAssertEqual(error as? ArtifactFDProtocolError, .invalidMetadata)
            }
        }
    }

    func testScreenshotRouteRequiresMatchingReadyPreparation() throws {
        XCTAssertEqual(
            try ScreenshotReservationValidator.validatePreparation(
                osMajor: 14,
                preparation: ScreenshotPreparation(
                    preparationGroupID: "prep.legacy.developer.v2",
                    state: .ready
                )
            ),
            .legacyScreenshotR
        )
        XCTAssertEqual(
            try ScreenshotReservationValidator.validatePreparation(
                osMajor: 26,
                preparation: ScreenshotPreparation(
                    preparationGroupID: "prep.coredevice.v2",
                    state: .ready
                )
            ),
            .modernCoreDevice
        )
        XCTAssertThrowsError(try ScreenshotReservationValidator
            .validatePreparation(
                osMajor: 16,
                preparation: ScreenshotPreparation(
                    preparationGroupID: "prep.coredevice.v2",
                    state: .ready
                )
            ))
    }

    private func uuid(_ value: Int) throws -> CanonicalUUID {
        try CanonicalUUID(
            String(format: "00000000-0000-0000-0000-%012x", value)
        )
    }

    private func loadInput(_ requirementID: String) throws -> RepositoryJSONObject {
        try loadObject(
            "Fixtures/requirements/\(requirementID)/input/input.v1.json"
        )
    }

    private func loadExpected(_ requirementID: String) throws -> RepositoryJSONObject {
        try loadObject(
            "Fixtures/requirements/\(requirementID)/expected.v1.json"
        )
    }

    private func loadObject(_ relativePath: String) throws -> RepositoryJSONObject {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
        return try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](data),
            maximumByteCount: 16 * 1_024
        ).root
    }

    private func bool(_ value: RepositoryJSONValue?) -> Bool? {
        guard case .bool(let value)? = value else { return nil }
        return value
    }

    private func string(_ value: RepositoryJSONValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        return value
    }

    private func uint(_ value: RepositoryJSONValue?) -> UInt64? {
        guard let number = value?.numberValue else { return nil }
        return try? number.requireUInt64()
    }
}
