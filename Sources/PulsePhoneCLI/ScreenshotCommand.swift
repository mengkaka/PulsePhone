import Foundation
import PulsePhoneClientCore
import PulsePhoneCommandPlanner
import PulsePhoneSharedDefinitions

public enum ScreenshotCommandError: Error, Equatable, Sendable {
    case invalidOutputPath
}

public protocol ScreenshotCommandBackend: Sendable {
    func requestDeviceScreenshot(
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID
    ) throws -> ScreenshotReceivedArtifact
}

public struct ScreenshotCommandResult: Codable, Equatable, Sendable {
    public let byteLength: UInt64
    public let format: String
    public let sha256: String
    public let source: String
}

public struct ScreenshotCommand: Sendable {
    public static let commandID = "screenshot.cli"

    private let backend: any ScreenshotCommandBackend
    private let fileSystem: any AtomicOutputFileSystem

    public init(
        backend: any ScreenshotCommandBackend,
        fileSystem: any AtomicOutputFileSystem
    ) {
        self.backend = backend
        self.fileSystem = fileSystem
    }

    public func run(
        outputPath: String,
        currentDirectory: String,
        force: Bool,
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        tempID: CanonicalUUID,
        canonicalUDID: CanonicalUDID,
        outputMode: CLIOutputMode,
        costs: AtomicOutputStageCosts = AtomicOutputStageCosts()
    ) throws -> CLITerminalOutput {
        let absolutePath = try Self.absoluteOutputPath(
            outputPath,
            currentDirectory: currentDirectory
        )
        let normalized = try ArgumentNormalizer.normalize(
            schemaID: "outputPath.v1",
            raw: ["outputPath": absolutePath]
        )
        guard case .string(let canonicalPath)? = normalized.values["outputPath"] else {
            throw ScreenshotCommandError.invalidOutputPath
        }
        let plan = try AtomicOutputFile.preflight(
            absoluteOutputPath: canonicalPath,
            force: force,
            fileSystem: fileSystem
        )
        let artifact = try backend.requestDeviceScreenshot(
            requestID: requestID,
            actionID: actionID,
            canonicalUDID: canonicalUDID
        )
        try AtomicOutputFile.write(
            plan: plan,
            artifact: artifact,
            tempID: tempID,
            costs: costs,
            fileSystem: fileSystem
        )
        let result = ScreenshotCommandResult(
            byteLength: UInt64(artifact.bytes.count),
            format: "png",
            sha256: StableBytes.sha256Hex(artifact.bytes),
            source: "device"
        )
        return try CLIOutputAdapter(mode: outputMode).success(
            commandID: Self.commandID,
            target: .device(canonicalUDID),
            result: result,
            human: "Saved screenshot to \(canonicalPath)"
        )
    }

    public static func semanticLogProjection(
        byteLength: UInt64
    ) -> [String: String] {
        [
            "byteLength": String(byteLength),
            "format": "png",
            "outputPath": "<redacted-path>",
        ]
    }

    private static func absoluteOutputPath(
        _ outputPath: String,
        currentDirectory: String
    ) throws -> String {
        guard !outputPath.isEmpty,
              !outputPath.utf8.contains(0),
              currentDirectory.hasPrefix("/")
        else {
            throw ScreenshotCommandError.invalidOutputPath
        }
        let raw = outputPath.hasPrefix("/")
            ? outputPath
            : currentDirectory + "/" + outputPath
        let standardized = (raw as NSString).standardizingPath
        guard standardized.hasPrefix("/") else {
            throw ScreenshotCommandError.invalidOutputPath
        }
        return standardized
    }
}
