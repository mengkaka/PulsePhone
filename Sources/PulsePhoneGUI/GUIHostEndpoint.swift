import PulsePhoneHostPaths

public struct GUIHostEndpoint: Equatable, Sendable {
    public let canonicalAppPathHash: String
    public let socketPath: String

    public init(
        canonicalAppPath: CanonicalAppPath,
        hostPaths: HostPathLayoutV1
    ) throws {
        self.canonicalAppPathHash = canonicalAppPath.guiHostHash
        self.socketPath = try hostPaths.guiHostSocketPath(
            for: canonicalAppPath
        )
    }
}
