import PulsePhoneMedia

public enum ScreenshotPreviewFallbackReason: String, Equatable, Sendable {
    case bindingMismatch
    case frameFromFuture
    case frameStale
    case noBoundFrame
}

public struct ScreenshotPreviewFrame: Equatable, Sendable {
    public let artifact: GUIScreenshotPNGArtifact
    public let capturedAtNanoseconds: UInt64
    public let identity: VideoFrameIdentity

    public init(
        artifact: GUIScreenshotPNGArtifact,
        capturedAtNanoseconds: UInt64,
        identity: VideoFrameIdentity
    ) {
        self.artifact = artifact
        self.capturedAtNanoseconds = capturedAtNanoseconds
        self.identity = identity
    }
}

public enum ScreenshotPreviewSelection: Equatable, Sendable {
    case deviceFallback(ScreenshotPreviewFallbackReason)
    case preview(artifact: GUIScreenshotPNGArtifact, frameSequence: UInt64)
}

public enum ScreenshotPreviewSelector {
    public static let maximumFrameAgeNanoseconds: UInt64 = 1_000_000_000

    public static func select(
        frame: ScreenshotPreviewFrame?,
        currentBinding: VideoBindingIdentity?,
        selectedAtNanoseconds: UInt64
    ) -> ScreenshotPreviewSelection {
        guard let frame, let currentBinding else {
            return .deviceFallback(.noBoundFrame)
        }
        guard case .accepted(let sequence) = VideoBinding.validate(
            frame: frame.identity,
            against: currentBinding
        ) else {
            return .deviceFallback(.bindingMismatch)
        }
        guard frame.capturedAtNanoseconds <= selectedAtNanoseconds else {
            return .deviceFallback(.frameFromFuture)
        }
        guard selectedAtNanoseconds - frame.capturedAtNanoseconds
                <= maximumFrameAgeNanoseconds
        else {
            return .deviceFallback(.frameStale)
        }
        return .preview(artifact: frame.artifact, frameSequence: sequence)
    }
}
