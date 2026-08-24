import Darwin
import Foundation
@testable import PulsePhoneGUI
import PulsePhoneClientCore
import PulsePhoneMedia
import PulsePhoneSharedDefinitions
import XCTest

final class GUIScreenshotTests: XCTestCase {
    func testPreviewFallbackBindingFixture() throws {
        let input = try loadInput()
        let expected = try loadExpected()
        let binding = try makeBinding(input.binding)
        let frame = try makeFrame(
            binding: binding,
            capturedAtNanoseconds: input.selectedAtNanoseconds
                - input.freshFrameAgeNanoseconds
        )
        let logger = MockRootLogger()
        let backend = MockDeviceBackend()
        let writer = MockOutputWriter()
        let action = ScreenshotAction(
            backend: backend,
            outputWriter: writer,
            existingRuntimeRootLogger: logger
        )
        var flow = action.begin(
            rootActionID: uuid(1),
            canonicalUDID: binding.canonicalUDID
        )
        let result = try flow.save(
            absoluteOutputPath: input.absoluteOutputPath,
            replaceExisting: true,
            selectedAtNanoseconds: input.selectedAtNanoseconds,
            previewFrame: frame,
            currentBinding: binding,
            childActionID: uuid(2),
            tempID: uuid(3)
        )

        XCTAssertEqual(result.source.rawValue, expected.freshFrameSource)
        XCTAssertNil(result.childActionID)
        XCTAssertEqual(backend.requests.count, expected.freshFrameChildCount)
        XCTAssertEqual(writer.writes.count, 1)
        XCTAssertEqual(logger.events.count, 2)
        XCTAssertEqual(flow.state, .terminal(.succeeded))
    }

    func testStaleOrMismatchedPreviewUsesOneDistinctDeviceChild() throws {
        let input = try loadInput()
        let expected = try loadExpected()
        let binding = try makeBinding(input.binding)
        let staleFrame = try makeFrame(
            binding: binding,
            capturedAtNanoseconds: input.selectedAtNanoseconds
                - input.staleFrameAgeNanoseconds
        )
        let backend = MockDeviceBackend()
        let writer = MockOutputWriter()
        var flow = ScreenshotAction(
            backend: backend,
            outputWriter: writer
        ).begin(rootActionID: uuid(10), canonicalUDID: binding.canonicalUDID)
        let result = try flow.save(
            absoluteOutputPath: input.absoluteOutputPath,
            replaceExisting: false,
            selectedAtNanoseconds: input.selectedAtNanoseconds,
            previewFrame: staleFrame,
            currentBinding: binding,
            childActionID: uuid(11),
            tempID: uuid(12)
        )

        XCTAssertEqual(result.source.rawValue, expected.staleFrameSource)
        XCTAssertEqual(backend.requests.count, expected.staleFrameChildCount)
        XCTAssertEqual(backend.requests[0].rootActionID, uuid(10))
        XCTAssertEqual(backend.requests[0].childActionID, uuid(11))
        XCTAssertEqual(
            backend.requests[0].rootActionID != backend.requests[0].childActionID,
            expected.rootChildActionIDsDistinct
        )
        XCTAssertEqual(writer.writes.count, 1)

        let mismatched = VideoBindingIdentity(
            canonicalUDID: binding.canonicalUDID,
            connectionEpoch: binding.connectionEpoch + 1,
            sourceID: binding.sourceID,
            sourceEpoch: binding.sourceEpoch,
            geometryRevision: binding.geometryRevision
        )
        XCTAssertEqual(
            ScreenshotPreviewSelector.select(
                frame: staleFrame,
                currentBinding: mismatched,
                selectedAtNanoseconds: staleFrame.capturedAtNanoseconds
            ),
            .deviceFallback(.bindingMismatch)
        )
    }

    func testCancelHasRootTerminalAndNoDeviceChild() throws {
        let logger = MockRootLogger()
        let backend = MockDeviceBackend()
        var flow = ScreenshotAction(
            backend: backend,
            outputWriter: MockOutputWriter(),
            existingRuntimeRootLogger: logger
        ).begin(rootActionID: uuid(20), canonicalUDID: try udid())
        try flow.cancel()
        XCTAssertEqual(flow.state, .terminal(.cancelled))
        XCTAssertTrue(backend.requests.isEmpty)
        XCTAssertEqual(logger.events.count, 2)
        XCTAssertThrowsError(try flow.cancel()) { error in
            XCTAssertEqual(
                error as? ScreenshotSaveFlowError,
                .terminalAlreadyRecorded
            )
        }
        XCTAssertEqual(logger.events.count, 2)
    }

    func testPreviewWriteFailureNeverFallsBackToDevice() throws {
        let input = try loadInput()
        let expected = try loadExpected()
        let binding = try makeBinding(input.binding)
        let writer = MockOutputWriter()
        writer.failNextWrite = true
        let backend = MockDeviceBackend()
        var flow = ScreenshotAction(
            backend: backend,
            outputWriter: writer
        ).begin(rootActionID: uuid(30), canonicalUDID: binding.canonicalUDID)
        XCTAssertThrowsError(try flow.save(
            absoluteOutputPath: input.absoluteOutputPath,
            replaceExisting: true,
            selectedAtNanoseconds: input.selectedAtNanoseconds,
            previewFrame: makeFrame(
                binding: binding,
                capturedAtNanoseconds: input.selectedAtNanoseconds
            ),
            currentBinding: binding,
            childActionID: uuid(31),
            tempID: uuid(32)
        ))
        XCTAssertEqual(
            !backend.requests.isEmpty,
            expected.previewWriteFailureFallsBack
        )
        XCTAssertEqual(flow.state, .terminal(.failed))
    }

    func testRootChildCollisionFailsBeforeDeviceRequest() throws {
        let backend = MockDeviceBackend()
        var flow = ScreenshotAction(
            backend: backend,
            outputWriter: MockOutputWriter()
        ).begin(rootActionID: uuid(40), canonicalUDID: try udid())
        XCTAssertThrowsError(try flow.save(
            absoluteOutputPath: "/tmp/out.png",
            replaceExisting: true,
            selectedAtNanoseconds: 2_000_000_000,
            previewFrame: nil,
            currentBinding: nil,
            childActionID: uuid(40),
            tempID: uuid(41)
        )) { error in
            XCTAssertEqual(
                error as? ScreenshotSaveFlowError,
                .rootChildIdentityCollision
            )
        }
        XCTAssertTrue(backend.requests.isEmpty)
        XCTAssertEqual(flow.state, .terminal(.failed))
    }

    func testProductionErrorProjectionUsesCatalogCodes() {
        XCTAssertEqual(
            ProductionGUIHostWindowController.screenshotErrorCode(
                ScreenshotSaveFlowError.invalidOutputPath
            ),
            "invalidOutputPath"
        )
        XCTAssertEqual(
            ProductionGUIHostWindowController.screenshotErrorCode(
                AtomicOutputFileError.invalidArtifact
            ),
            "unsupportedScreenshotFormat"
        )
        XCTAssertEqual(
            ProductionGUIHostWindowController.screenshotErrorCode(
                AtomicOutputFileError.localWriteFailed
            ),
            "localWriteFailed"
        )
        XCTAssertEqual(
            ProductionGUIHostWindowController.screenshotErrorCode(
                RuntimeClientError.socketUnavailable(errno: ENOENT)
            ),
            "runtimeNotRunning"
        )
        XCTAssertEqual(
            ProductionGUIHostWindowController.screenshotErrorCode(
                RuntimeClientError.closedBeforeResponse
            ),
            "transportFailure"
        )
        XCTAssertEqual(
            ProductionGUIHostWindowController.screenshotErrorCode(
                ProductionGUIScreenshotDeviceError.terminal(
                    errorCode: "capabilityUnavailable"
                )
            ),
            "capabilityUnavailable"
        )
    }

    private func makeFrame(
        binding: VideoBindingIdentity,
        capturedAtNanoseconds: UInt64
    ) throws -> ScreenshotPreviewFrame {
        ScreenshotPreviewFrame(
            artifact: try GUIScreenshotPNGArtifact(bytes: pngBytes()),
            capturedAtNanoseconds: capturedAtNanoseconds,
            identity: VideoFrameIdentity(binding: binding, frameSequence: 7)
        )
    }

    private func makeBinding(
        _ value: FixtureBinding
    ) throws -> VideoBindingIdentity {
        VideoBindingIdentity(
            canonicalUDID: try CanonicalUDID(
                canonicalString: value.canonicalUDID
            ),
            connectionEpoch: value.connectionEpoch,
            sourceID: value.sourceID,
            sourceEpoch: value.sourceEpoch,
            geometryRevision: value.geometryRevision
        )
    }

    private func udid() throws -> CanonicalUDID {
        try CanonicalUDID(canonicalString: "00008020-001C2D123456002E")
    }

    private func uuid(_ suffix: Int) -> CanonicalUUID {
        try! CanonicalUUID(String(format: "00000000-0000-4000-8000-%012d", suffix))
    }

    private func pngBytes() -> [UInt8] {
        [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1]
    }

    private func loadInput() throws -> FixtureInput {
        try JSONDecoder().decode(
            FixtureInput.self,
            from: Data(contentsOf: fixtureURL("input/input.v1.json"))
        )
    }

    private func loadExpected() throws -> FixtureExpected {
        try JSONDecoder().decode(
            FixtureExpected.self,
            from: Data(contentsOf: fixtureURL("expected.v1.json"))
        )
    }

    private func fixtureURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/requirements/T-011")
            .appendingPathComponent("screenshot-preview-fallback-binding-l4")
            .appendingPathComponent(relativePath)
    }
}

private struct FixtureInput: Decodable {
    let absoluteOutputPath: String
    let binding: FixtureBinding
    let freshFrameAgeNanoseconds: UInt64
    let selectedAtNanoseconds: UInt64
    let staleFrameAgeNanoseconds: UInt64
}

private struct FixtureBinding: Decodable {
    let canonicalUDID: String
    let connectionEpoch: UInt64
    let geometryRevision: UInt64
    let sourceEpoch: UInt64
    let sourceID: String
}

private struct FixtureExpected: Decodable {
    let freshFrameChildCount: Int
    let freshFrameSource: String
    let previewWriteFailureFallsBack: Bool
    let rootChildActionIDsDistinct: Bool
    let staleFrameChildCount: Int
    let staleFrameSource: String
}

private struct DeviceRequest: Equatable {
    let canonicalUDID: CanonicalUDID
    let childActionID: CanonicalUUID
    let rootActionID: CanonicalUUID
}

private final class MockDeviceBackend: GUIScreenshotDeviceBackend,
    @unchecked Sendable
{
    private(set) var requests = [DeviceRequest]()

    func requestDeviceScreenshot(
        rootActionID: CanonicalUUID,
        childActionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID
    ) throws -> GUIScreenshotPNGArtifact {
        requests.append(DeviceRequest(
            canonicalUDID: canonicalUDID,
            childActionID: childActionID,
            rootActionID: rootActionID
        ))
        return try GUIScreenshotPNGArtifact(
            bytes: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 2]
        )
    }
}

private struct OutputWrite: Equatable {
    let absolutePath: String
    let replaceExisting: Bool
}

private final class MockOutputWriter: GUIScreenshotOutputWriting,
    @unchecked Sendable
{
    var failNextWrite = false
    private(set) var writes = [OutputWrite]()

    func write(
        _ artifact: GUIScreenshotPNGArtifact,
        toAbsolutePath absolutePath: String,
        replaceExisting: Bool,
        tempID: CanonicalUUID
    ) throws {
        if failNextWrite {
            failNextWrite = false
            throw MockError.writeFailed
        }
        writes.append(OutputWrite(
            absolutePath: absolutePath,
            replaceExisting: replaceExisting
        ))
    }
}

private final class MockRootLogger: GUIScreenshotRootLogging,
    @unchecked Sendable
{
    private(set) var events = [GUIScreenshotRootEvent]()

    func recordBestEffort(_ event: GUIScreenshotRootEvent) {
        events.append(event)
    }
}

private enum MockError: Error {
    case writeFailed
}
