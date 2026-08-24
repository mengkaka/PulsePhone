import Darwin
import PulsePhoneSharedDefinitions

public enum HostPathLayoutError: Error, Equatable, Sendable {
    case invalidHomeDirectory
    case privateTemporaryPathForbidden
    case unixDomainSocketPathTooLong(actualByteCountIncludingNUL: Int)
}

public struct HostPathLayoutV1: Hashable, Sendable {
    public static let unixDomainSocketPathCapacity = 104

    public let effectiveUserID: uid_t
    public let homeDirectory: String
    public let temporaryBasePath: String
    public let persistentHistoryDirectory: String
    public let developerImageStoreDirectory: String
    public let videoSourceMappingsDirectory: String

    public init(effectiveUserID: uid_t, trustedHomeDirectory: String) throws {
        guard CanonicalAppPath.isCanonicalAbsolutePath(trustedHomeDirectory) else {
            throw HostPathLayoutError.invalidHomeDirectory
        }
        self.effectiveUserID = effectiveUserID
        self.homeDirectory = trustedHomeDirectory
        self.temporaryBasePath = "/tmp/pulsephone-\(effectiveUserID)"
        self.persistentHistoryDirectory = trustedHomeDirectory
            + "/Library/Application Support/PulsePhone/ActionLogs"
        self.developerImageStoreDirectory = trustedHomeDirectory
            + "/Library/Application Support/PulsePhone/DeveloperImages"
        self.videoSourceMappingsDirectory = trustedHomeDirectory
            + "/Library/Application Support/PulsePhone/VideoSourceMappings"
    }

    public func runtimeSocketPath(for canonicalUDID: CanonicalUDID) throws -> String {
        try checkedSocketPath("\(temporaryBasePath)/\(canonicalUDID.domainSeparatedHash).sock")
    }

    public func runtimeBootstrapLockPath(
        for canonicalUDID: CanonicalUDID
    ) -> String {
        "\(temporaryBasePath)/\(canonicalUDID.domainSeparatedHash).bootstrap.lock"
    }

    public func runtimeLockPath(for canonicalUDID: CanonicalUDID) -> String {
        "\(temporaryBasePath)/\(canonicalUDID.domainSeparatedHash).runtime.lock"
    }

    public func helperStatePath(for canonicalUDID: CanonicalUDID) -> String {
        "\(temporaryBasePath)/\(canonicalUDID.domainSeparatedHash).helpers.v1.json"
    }

    public func guiHostSocketPath(for canonicalAppPath: CanonicalAppPath) throws -> String {
        try checkedSocketPath(
            "\(temporaryBasePath)/gui-\(canonicalAppPath.guiHostHash).sock"
        )
    }

    public func screenshotDirectory(
        for canonicalUDID: CanonicalUDID,
        runtimeEpoch: CanonicalUUID
    ) -> String {
        "\(temporaryBasePath)/scratch/\(canonicalUDID.domainSeparatedHash)"
            + "/\(runtimeEpoch)/screenshots"
    }

    public func traceDirectory(for canonicalUDID: CanonicalUDID) -> String {
        "\(temporaryBasePath)/artifacts/\(canonicalUDID.domainSeparatedHash)/traces"
    }

    public func diagnosticsDirectory(for canonicalUDID: CanonicalUDID) -> String {
        "\(temporaryBasePath)/artifacts/\(canonicalUDID.domainSeparatedHash)/diagnostics"
    }

    public func videoSourceMappingPath(
        for canonicalUDID: CanonicalUDID
    ) -> String {
        "\(videoSourceMappingsDirectory)/\(VideoSourceMappingPathV2.fileName(for: canonicalUDID))"
    }

    public func legacyVideoSourceMappingPath(
        for canonicalUDID: CanonicalUDID
    ) -> String {
        "\(videoSourceMappingsDirectory)/\(VideoSourceMappingPathV1.fileName(for: canonicalUDID))"
    }

    public static func validateUnixDomainSocketPath(_ path: String) throws {
        guard !path.hasPrefix("/private/tmp/") else {
            throw HostPathLayoutError.privateTemporaryPathForbidden
        }
        let count = path.utf8.count + 1
        guard count <= unixDomainSocketPathCapacity else {
            throw HostPathLayoutError.unixDomainSocketPathTooLong(
                actualByteCountIncludingNUL: count
            )
        }
    }

    private func checkedSocketPath(_ path: String) throws -> String {
        try Self.validateUnixDomainSocketPath(path)
        return path
    }
}
