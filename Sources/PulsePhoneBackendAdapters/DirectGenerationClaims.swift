public enum DirectGenerationOperationKind: String, Equatable, Sendable {
    case lockdownCommand
    case legacyMountedQuery
    case legacyMountGeneration

    public var exclusiveClaimIDs: [String] {
        var claims = ["executor.direct.process-slot"]
        switch self {
        case .lockdownCommand:
            break
        case .legacyMountedQuery:
            claims.append("service.mobile-image-mounter")
        case .legacyMountGeneration:
            claims.append("device.developer-environment")
            claims.append("service.mobile-image-mounter")
        }
        return claims.sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }
    }
}

public struct DirectGenerationIdentity: Equatable, Hashable, Sendable {
    public let runtimeEpoch: UInt64
    public let connectionEpoch: UInt64
    public let executorGeneration: UInt64

    public init(
        runtimeEpoch: UInt64,
        connectionEpoch: UInt64,
        executorGeneration: UInt64
    ) {
        self.runtimeEpoch = runtimeEpoch
        self.connectionEpoch = connectionEpoch
        self.executorGeneration = executorGeneration
    }
}

public enum DirectGenerationAction: String, Equatable, Sendable {
    case spawnHelper
    case sendHelloAccepted
    case sendRequest
    case beginCleanup
    case reapHelper
}

public struct DirectGenerationCommand: Equatable, Sendable {
    public let identity: DirectGenerationIdentity
    public let action: DirectGenerationAction
    public let requestID: String

    public init(
        identity: DirectGenerationIdentity,
        action: DirectGenerationAction,
        requestID: String
    ) {
        self.identity = identity
        self.action = action
        self.requestID = requestID
    }
}
