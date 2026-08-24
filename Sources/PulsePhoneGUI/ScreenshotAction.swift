import PulsePhoneClientCore
import PulsePhoneSharedDefinitions

public enum GUIScreenshotSource: String, Equatable, Sendable {
    case device
    case preview
}

public struct GUIScreenshotPNGArtifact: Equatable, Sendable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        let validated = try ScreenshotReceivedArtifact(
            bytes: bytes,
            contentType: "image/png",
            readOnly: true
        )
        self.bytes = validated.bytes
    }

    fileprivate var receivedArtifact: ScreenshotReceivedArtifact {
        try! ScreenshotReceivedArtifact(
            bytes: bytes,
            contentType: "image/png",
            readOnly: true
        )
    }
}

public enum GUIScreenshotRootOutcome: String, Equatable, Sendable {
    case cancelled
    case failed
    case succeeded
}

public enum GUIScreenshotRootEvent: Equatable, Sendable {
    case begin(actionID: CanonicalUUID, canonicalUDID: CanonicalUDID)
    case terminal(
        actionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID,
        outcome: GUIScreenshotRootOutcome
    )
}

public protocol GUIScreenshotRootLogging: AnyObject, Sendable {
    func recordBestEffort(_ event: GUIScreenshotRootEvent)
}

public protocol GUIScreenshotDeviceBackend: Sendable {
    func requestDeviceScreenshot(
        rootActionID: CanonicalUUID,
        childActionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID
    ) throws -> GUIScreenshotPNGArtifact
}

public protocol GUIScreenshotOutputWriting: Sendable {
    func write(
        _ artifact: GUIScreenshotPNGArtifact,
        toAbsolutePath absolutePath: String,
        replaceExisting: Bool,
        tempID: CanonicalUUID
    ) throws
}

public struct AtomicGUIScreenshotOutputWriter: Sendable {
    private let fileSystem: any AtomicOutputFileSystem

    public init(fileSystem: any AtomicOutputFileSystem) {
        self.fileSystem = fileSystem
    }
}

extension AtomicGUIScreenshotOutputWriter: GUIScreenshotOutputWriting {
    public func write(
        _ artifact: GUIScreenshotPNGArtifact,
        toAbsolutePath absolutePath: String,
        replaceExisting: Bool,
        tempID: CanonicalUUID
    ) throws {
        let plan = try AtomicOutputFile.preflight(
            absoluteOutputPath: absolutePath,
            force: replaceExisting,
            fileSystem: fileSystem
        )
        try AtomicOutputFile.write(
            plan: plan,
            artifact: artifact.receivedArtifact,
            tempID: tempID,
            fileSystem: fileSystem
        )
    }
}

public struct ScreenshotAction: Sendable {
    public static let commandID = "screenshot.gui"

    private let backend: any GUIScreenshotDeviceBackend
    private let outputWriter: any GUIScreenshotOutputWriting
    private let rootLogger: (any GUIScreenshotRootLogging)?

    public init(
        backend: any GUIScreenshotDeviceBackend,
        outputWriter: any GUIScreenshotOutputWriting,
        existingRuntimeRootLogger: (any GUIScreenshotRootLogging)? = nil
    ) {
        self.backend = backend
        self.outputWriter = outputWriter
        self.rootLogger = existingRuntimeRootLogger
    }

    public func begin(
        rootActionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID
    ) -> ScreenshotSaveFlow {
        rootLogger?.recordBestEffort(.begin(
            actionID: rootActionID,
            canonicalUDID: canonicalUDID
        ))
        return ScreenshotSaveFlow(
            rootActionID: rootActionID,
            canonicalUDID: canonicalUDID,
            backend: backend,
            outputWriter: outputWriter,
            rootLogger: rootLogger
        )
    }
}
