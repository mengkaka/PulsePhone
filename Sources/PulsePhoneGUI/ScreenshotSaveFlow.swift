import PulsePhoneMedia
import PulsePhoneSharedDefinitions

public enum ScreenshotSaveFlowState: Equatable, Sendable {
    case awaitingSavePanel
    case terminal(GUIScreenshotRootOutcome)
}

public enum ScreenshotSaveFlowError: Error, Equatable, Sendable {
    case invalidOutputPath
    case rootChildIdentityCollision
    case terminalAlreadyRecorded
}

public struct ScreenshotSaveResult: Equatable, Sendable {
    public let byteLength: UInt64
    public let childActionID: CanonicalUUID?
    public let rootActionID: CanonicalUUID
    public let source: GUIScreenshotSource

    public init(
        byteLength: UInt64,
        childActionID: CanonicalUUID?,
        rootActionID: CanonicalUUID,
        source: GUIScreenshotSource
    ) {
        self.byteLength = byteLength
        self.childActionID = childActionID
        self.rootActionID = rootActionID
        self.source = source
    }
}

public struct ScreenshotSaveFlow: Sendable {
    public let canonicalUDID: CanonicalUDID
    public let rootActionID: CanonicalUUID
    public private(set) var state: ScreenshotSaveFlowState

    private let backend: any GUIScreenshotDeviceBackend
    private let outputWriter: any GUIScreenshotOutputWriting
    private let rootLogger: (any GUIScreenshotRootLogging)?

    init(
        rootActionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID,
        backend: any GUIScreenshotDeviceBackend,
        outputWriter: any GUIScreenshotOutputWriting,
        rootLogger: (any GUIScreenshotRootLogging)?
    ) {
        self.rootActionID = rootActionID
        self.canonicalUDID = canonicalUDID
        self.backend = backend
        self.outputWriter = outputWriter
        self.rootLogger = rootLogger
        self.state = .awaitingSavePanel
    }

    public mutating func cancel() throws {
        try requireOpen()
        finish(.cancelled)
    }

    public mutating func save(
        absoluteOutputPath: String,
        replaceExisting: Bool,
        selectedAtNanoseconds: UInt64,
        previewFrame: ScreenshotPreviewFrame?,
        currentBinding: VideoBindingIdentity?,
        childActionID: CanonicalUUID,
        tempID: CanonicalUUID
    ) throws -> ScreenshotSaveResult {
        try requireOpen()
        guard Self.validAbsoluteOutputPath(absoluteOutputPath) else {
            finish(.failed)
            throw ScreenshotSaveFlowError.invalidOutputPath
        }
        let selection = ScreenshotPreviewSelector.select(
            frame: previewFrame,
            currentBinding: currentBinding,
            selectedAtNanoseconds: selectedAtNanoseconds
        )
        do {
            switch selection {
            case .preview(let artifact, _):
                try outputWriter.write(
                    artifact,
                    toAbsolutePath: absoluteOutputPath,
                    replaceExisting: replaceExisting,
                    tempID: tempID
                )
                finish(.succeeded)
                return ScreenshotSaveResult(
                    byteLength: UInt64(artifact.bytes.count),
                    childActionID: nil,
                    rootActionID: rootActionID,
                    source: .preview
                )
            case .deviceFallback:
                guard childActionID != rootActionID else {
                    throw ScreenshotSaveFlowError.rootChildIdentityCollision
                }
                let artifact = try backend.requestDeviceScreenshot(
                    rootActionID: rootActionID,
                    childActionID: childActionID,
                    canonicalUDID: canonicalUDID
                )
                try outputWriter.write(
                    artifact,
                    toAbsolutePath: absoluteOutputPath,
                    replaceExisting: replaceExisting,
                    tempID: tempID
                )
                finish(.succeeded)
                return ScreenshotSaveResult(
                    byteLength: UInt64(artifact.bytes.count),
                    childActionID: childActionID,
                    rootActionID: rootActionID,
                    source: .device
                )
            }
        } catch {
            finish(.failed)
            throw error
        }
    }

    private mutating func finish(_ outcome: GUIScreenshotRootOutcome) {
        state = .terminal(outcome)
        rootLogger?.recordBestEffort(.terminal(
            actionID: rootActionID,
            canonicalUDID: canonicalUDID,
            outcome: outcome
        ))
    }

    private func requireOpen() throws {
        guard state == .awaitingSavePanel else {
            throw ScreenshotSaveFlowError.terminalAlreadyRecorded
        }
    }

    private static func validAbsoluteOutputPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.utf8.contains(0)
    }
}
