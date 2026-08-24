import Darwin
import Foundation
import XCTest
@testable import PulsePhoneSharedDefinitions
@testable import PulsePhoneWire

final class SwiftGenerationTests: XCTestCase {
    private static let generatedFiles = [
        "GeneratedWireIdentifiers.generated.swift",
        "GeneratedWireMetadata.generated.swift",
        "GeneratedWireValidator.generated.swift",
        "StandardErrorRegistry.generated.swift",
    ]

    func testGeneratedBindingsCompileAndProjectRegistryData() throws {
        XCTAssertEqual(StandardErrorCode.allCases.count, 87)
        XCTAssertEqual(GeneratedStandardErrorRegistry.descriptors.count, 87)
        XCTAssertEqual(GeneratedWireRegistryMetadata.entries.count, 59)
        XCTAssertEqual(GeneratedWireRegistryMetadata.schemaDescriptors.count, 90)

        XCTAssertEqual(
            GeneratedWireRegistryDecoder.runtimeMessageType(rawValue: 0x0108),
            .aggregateResponse
        )
        XCTAssertEqual(
            GeneratedWireRegistryDecoder.guiHostMessageType(rawValue: 0x0100),
            .openLive
        )
        XCTAssertEqual(
            GeneratedWireRegistryDecoder.runtimeOperation(
                rawValue: "runtime.prepareCapabilities"
            ),
            .runtimePrepareCapabilities
        )
        XCTAssertNil(GeneratedWireRegistryDecoder.runtimeOperation(rawValue: "runtime.unknown"))

        let prepare = try XCTUnwrap(
            GeneratedWireRegistryValidator.entry(
                registryID: .runtimeOperations,
                id: "runtime.prepareCapabilities"
            )
        )
        XCTAssertEqual(prepare.requestSchemaID, .prepareCapabilitiesRequestV1)
        XCTAssertEqual(prepare.responseSchemaID, .preparationResultV1)
        XCTAssertEqual(prepare.allowedEventKinds, [.preparationStarted])

        let localAction = try XCTUnwrap(
            GeneratedWireRegistryValidator.entry(
                registryID: .runtimeOperations,
                id: "runtime.recordLocalAction"
            )
        )
        XCTAssertEqual(localAction.terminalPolicy, .oneWay)
        XCTAssertNil(localAction.responseSchemaID)
        XCTAssertTrue(localAction.allowedErrorCodes.isEmpty)

        let streamFrame = try XCTUnwrap(
            GeneratedWireRegistryValidator.entry(
                registryID: .runtimeWireMessages,
                numericMessageType: 0x0106
            )
        )
        XCTAssertEqual(streamFrame.payloadLimitClass, .streamFrame8KiB)
        XCTAssertEqual(streamFrame.fdPolicy, .none)

        let internalFailure = try XCTUnwrap(
            GeneratedStandardErrorRegistry.descriptors.first {
                $0.code == .internalFailure
            }
        )
        XCTAssertEqual(internalFailure.family, .internal)
        XCTAssertEqual(internalFailure.defaultCLIExit, 1)
        XCTAssertFalse(internalFailure.retryable)

        let frameSchema = try XCTUnwrap(
            GeneratedWireRegistryValidator.schemaDescriptor(.streamFrameV1)
        )
        XCTAssertEqual(frameSchema.maxEncodedBytes, 8_192)
        XCTAssertTrue(frameSchema.requiredPropertyNames.contains("sessionID"))
    }

    func testFreshStagingAndTrackedOutputAreExact() throws {
        let temporaryRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let stagingRoot = temporaryRoot.appendingPathComponent("staging")
        try FileManager.default.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(to: stagingRoot.appendingPathComponent("stale"))

        let staged = try runGenerator(
            action: "--stage-only",
            stagingRoot: stagingRoot,
            trackedRoot: nil
        )
        XCTAssertEqual(staged.status, 0, staged.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.appendingPathComponent("stale").path))
        let generatedRoot = stagingRoot
            .appendingPathComponent("Sources/PulsePhoneWire/Generated")
        XCTAssertEqual(try regularFileNames(at: generatedRoot), Self.generatedFiles)

        let verified = try runGenerator(
            action: "--verify",
            stagingRoot: temporaryRoot.appendingPathComponent("verify-staging"),
            trackedRoot: generatedSourceURL()
        )
        XCTAssertEqual(verified.status, 0, verified.output)
    }

    func testVerifierRejectsMissingExtraSymlinkHardlinkAndOtherNodes() throws {
        let temporaryRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let trackedRoot = temporaryRoot.appendingPathComponent("tracked")
        let stagingRoot = temporaryRoot.appendingPathComponent("staging")

        try resetTrackedCopy(at: trackedRoot)
        try FileManager.default.removeItem(
            at: trackedRoot.appendingPathComponent(Self.generatedFiles[0])
        )
        try assertVerificationFails(stagingRoot: stagingRoot, trackedRoot: trackedRoot)

        try resetTrackedCopy(at: trackedRoot)
        try Data("extra".utf8).write(to: trackedRoot.appendingPathComponent("Extra.swift"))
        try assertVerificationFails(stagingRoot: stagingRoot, trackedRoot: trackedRoot)

        try resetTrackedCopy(at: trackedRoot)
        let symlinkPath = trackedRoot.appendingPathComponent(Self.generatedFiles[0])
        try FileManager.default.removeItem(at: symlinkPath)
        try FileManager.default.createSymbolicLink(
            at: symlinkPath,
            withDestinationURL: generatedSourceURL().appendingPathComponent(Self.generatedFiles[0])
        )
        try assertVerificationFails(stagingRoot: stagingRoot, trackedRoot: trackedRoot)

        try resetTrackedCopy(at: trackedRoot)
        let hardlinkSource = trackedRoot.appendingPathComponent(Self.generatedFiles[0])
        let hardlinkTarget = trackedRoot.appendingPathComponent(Self.generatedFiles[1])
        try FileManager.default.removeItem(at: hardlinkTarget)
        try FileManager.default.linkItem(at: hardlinkSource, to: hardlinkTarget)
        try assertVerificationFails(stagingRoot: stagingRoot, trackedRoot: trackedRoot)

        try resetTrackedCopy(at: trackedRoot)
        try FileManager.default.createDirectory(
            at: trackedRoot.appendingPathComponent("unexpected-directory"),
            withIntermediateDirectories: false
        )
        try assertVerificationFails(stagingRoot: stagingRoot, trackedRoot: trackedRoot)

        try resetTrackedCopy(at: trackedRoot)
        let fifoPath = trackedRoot.appendingPathComponent("unexpected-fifo")
        XCTAssertEqual(mkfifo(fifoPath.path, mode_t(0o600)), 0)
        try assertVerificationFails(stagingRoot: stagingRoot, trackedRoot: trackedRoot)
    }

    func testNoParallelRegistryDeclarationsOutsideGeneratedOutput() throws {
        let sourceRoot = packageRootURL().appendingPathComponent("Sources/PulsePhoneWire")
        let forbiddenDeclarations = [
            "enum StandardErrorCode",
            "enum RuntimeOperationID",
            "enum RuntimeWireMessageType",
            "enum WireSchemaID",
            "[GeneratedWireEntry]",
        ]
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
        )
        while let url = enumerator.nextObject() as? URL {
            if url == generatedSourceURL() {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            for declaration in forbiddenDeclarations {
                XCTAssertFalse(source.contains(declaration), "\(url.path):\(declaration)")
            }
        }
    }

    private func assertVerificationFails(
        stagingRoot: URL,
        trackedRoot: URL
    ) throws {
        let result = try runGenerator(
            action: "--verify",
            stagingRoot: stagingRoot,
            trackedRoot: trackedRoot
        )
        XCTAssertNotEqual(result.status, 0, result.output)
    }

    private func resetTrackedCopy(at destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        for fileName in Self.generatedFiles {
            try FileManager.default.copyItem(
                at: generatedSourceURL().appendingPathComponent(fileName),
                to: destination.appendingPathComponent(fileName)
            )
        }
    }

    private func runGenerator(
        action: String,
        stagingRoot: URL,
        trackedRoot: URL?
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = packageRootURL().appendingPathComponent("Scripts/generate-registries")
        var arguments = ["swift", action, "--staging-root", stagingRoot.path]
        if let trackedRoot {
            arguments += ["--tracked-root", trackedRoot.path]
        }
        process.arguments = arguments
        process.currentDirectoryURL = packageRootURL()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func regularFileNames(at root: URL) throws -> [String] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        var names = [String]()
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            XCTAssertEqual(values.isRegularFile, true)
            XCTAssertEqual(values.isSymbolicLink, false)
            names.append(url.lastPathComponent)
        }
        return names.sorted()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pulsephone-swift-generation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        return url
    }

    private func generatedSourceURL() -> URL {
        packageRootURL().appendingPathComponent("Sources/PulsePhoneWire/Generated")
    }

    private func packageRootURL() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 {
            root.deleteLastPathComponent()
        }
        return root
    }
}
