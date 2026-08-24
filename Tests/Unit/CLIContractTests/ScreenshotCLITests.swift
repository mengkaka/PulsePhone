import Foundation
import PulsePhoneCLI
import PulsePhoneClientCore
import PulsePhoneSharedDefinitions
import XCTest

final class ScreenshotCLITests: XCTestCase {
    func testScreenshotAtomicOutputFormatFixture() throws {
        let input = try loadRequirementObject(
            "T-011/screenshot-atomic-output-format-l3",
            relativePath: "input/input.v1.json"
        )
        let expected = try loadRequirementObject(
            "T-011/screenshot-atomic-output-format-l3",
            relativePath: "expected.v1.json"
        )
        let fileSystem = MockAtomicOutputFileSystem()
        fileSystem.nodes["/work/out.png"] = .present
        let backend = MockScreenshotBackend()
        let command = ScreenshotCommand(backend: backend, fileSystem: fileSystem)
        XCTAssertThrowsError(try command.run(
            outputPath: "out.png",
            currentDirectory: "/work",
            force: false,
            requestID: uuid(1),
            actionID: uuid(2),
            tempID: uuid(3),
            canonicalUDID: CanonicalUDID(canonicalString: "A"),
            outputMode: .human
        )) { error in
            XCTAssertEqual(error as? AtomicOutputFileError, .outputExists)
        }
        XCTAssertEqual(backend.requestCount, 0)
        fileSystem.operations.removeAll()

        let output = try command.run(
            outputPath: "out.png",
            currentDirectory: "/work",
            force: true,
            requestID: uuid(4),
            actionID: uuid(5),
            tempID: uuid(6),
            canonicalUDID: CanonicalUDID(canonicalString: "A"),
            outputMode: .json
        )
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(backend.requestCount, 1)
        XCTAssertEqual(
            fileSystem.operations,
            ["stat", "create:0600", "write", "fsync-file", "rename:replace", "fsync-dir"]
        )
        XCTAssertTrue(output.chunk.stdout[0].contains("\"format\":\"png\""))
        XCTAssertEqual(string(expected["format"]), "png")
        XCTAssertEqual(bool(expected["sameDirectoryTemp"]), true)

        fileSystem.failOperation = "write"
        XCTAssertThrowsError(try command.run(
            outputPath: "/work/second.png",
            currentDirectory: "/work",
            force: false,
            requestID: uuid(7),
            actionID: uuid(8),
            tempID: uuid(9),
            canonicalUDID: CanonicalUDID(canonicalString: "A"),
            outputMode: .human
        )) { error in
            XCTAssertEqual(error as? AtomicOutputFileError, .localWriteFailed)
        }
        XCTAssertEqual(backend.requestCount, 2)
        XCTAssertEqual(uint(input["localWriteDeadlineSeconds"]), 5)
    }

    func testArtifactTextPathPrivacyFixture() throws {
        let input = try loadRequirementObject(
            "T-011/artifact-text-path-privacy-l5",
            relativePath: "input/input.v1.json"
        )
        let expected = try loadRequirementObject(
            "T-011/artifact-text-path-privacy-l5",
            relativePath: "expected.v1.json"
        )
        let projection = ScreenshotCommand.semanticLogProjection(byteLength: 12)
        let encoded = projection.keys.sorted().map {
            "\($0)=\(projection[$0]!)"
        }.joined(separator: " ")
        XCTAssertEqual(projection["outputPath"], "<redacted-path>")
        for key in ["absoluteRuntimePath", "artifactBytes", "text"] {
            if let secret = string(input[key]) {
                XCTAssertFalse(encoded.contains(secret), key)
            }
        }
        XCTAssertEqual(string(expected["pathProjection"]), "<redacted-path>")
        XCTAssertFalse(encoded.contains("sha256"))
    }

    private func uuid(_ value: Int) throws -> CanonicalUUID {
        try CanonicalUUID(
            String(format: "00000000-0000-0000-0000-%012x", value)
        )
    }

    private func loadRequirementObject(
        _ requirementID: String,
        relativePath: String
    ) throws -> RepositoryJSONObject {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent(
            "Fixtures/requirements/\(requirementID)/\(relativePath)"
        ))
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

private final class MockScreenshotBackend: ScreenshotCommandBackend,
    @unchecked Sendable
{
    private(set) var requestCount = 0

    func requestDeviceScreenshot(
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID
    ) throws -> ScreenshotReceivedArtifact {
        requestCount += 1
        return try ScreenshotReceivedArtifact(
            bytes: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1],
            contentType: "image/png",
            readOnly: true
        )
    }
}

private final class MockAtomicOutputFileSystem: AtomicOutputFileSystem,
    @unchecked Sendable
{
    var failOperation: String?
    var nodes = [String: AtomicOutputNodeState]()
    var operations = [String]()

    func nodeState(at absolutePath: String) throws -> AtomicOutputNodeState {
        operations.append("stat")
        return nodes[absolutePath] ?? .absent
    }

    func createExclusiveSiblingTemp(
        for absoluteOutputPath: String,
        tempBasename: String,
        mode: UInt16
    ) throws -> String {
        try fail("create")
        operations.append(String(format: "create:%04o", mode))
        let parent = (absoluteOutputPath as NSString).deletingLastPathComponent
        return parent + "/" + tempBasename
    }

    func write(_ bytes: [UInt8], toTempPath: String) throws {
        try fail("write")
        operations.append("write")
    }

    func syncFile(atTempPath: String) throws {
        try fail("fsync-file")
        operations.append("fsync-file")
    }

    func renameTemp(
        _ tempPath: String,
        to absoluteOutputPath: String,
        replaceExisting: Bool
    ) throws {
        try fail("rename")
        operations.append(replaceExisting ? "rename:replace" : "rename:no-replace")
        nodes[absoluteOutputPath] = .present
    }

    func syncParentDirectory(of absoluteOutputPath: String) throws {
        try fail("fsync-dir")
        operations.append("fsync-dir")
    }

    func removeTempIfPresent(_ tempPath: String) {
        operations.append("remove-temp")
    }

    private func fail(_ operation: String) throws {
        if failOperation == operation {
            failOperation = nil
            throw AtomicOutputFileError.localWriteFailed
        }
    }
}
