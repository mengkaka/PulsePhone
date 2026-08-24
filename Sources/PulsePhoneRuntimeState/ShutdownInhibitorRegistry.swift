import PulsePhoneSharedDefinitions

public enum ShutdownInhibitorKind: String, CaseIterable, Hashable, Sendable {
    case live
    case runningJob
    case pendingJob
    case stream
    case activeTrace
    case assetAcquisition
    case preparingCapability
    case controlMutation
    case cleanup
    case fencing
}

public enum ShutdownRetryWhen: String, CaseIterable, Hashable, Sendable {
    case liveDetached
    case jobTerminal
    case streamClosed
    case traceStopped
    case acquisitionFinished
    case capabilityResolved
    case controlFinished
    case cleanupFinished
    case stateChanged
}

public enum ShutdownInhibitorRegistryError: Error, Equatable, Sendable {
    case invalidMetadata
    case duplicateToken
    case unknownToken
    case staleToken
    case admissionClosed
    case capacityExceeded
    case blockersRemain
    case revisionOverflow
}

public struct ShutdownInhibitorMetadata: Hashable, Sendable {
    public let kind: ShutdownInhibitorKind
    public let retryWhen: ShutdownRetryWhen
    public let ownerClientInstanceID: CanonicalUUID?
    public let jobID: String?
    public let sessionID: CanonicalUUID?
    public let commandID: String?
    public let state: String?

    public init(
        kind: ShutdownInhibitorKind,
        retryWhen: ShutdownRetryWhen,
        ownerClientInstanceID: CanonicalUUID? = nil,
        jobID: String? = nil,
        sessionID: CanonicalUUID? = nil,
        commandID: String? = nil,
        state: String? = nil
    ) throws {
        guard retryWhen == Self.requiredRetryWhen(for: kind),
              Self.validProjectionValue(jobID),
              Self.validProjectionValue(commandID),
              Self.validProjectionValue(state)
        else {
            throw ShutdownInhibitorRegistryError.invalidMetadata
        }
        self.kind = kind
        self.retryWhen = retryWhen
        self.ownerClientInstanceID = ownerClientInstanceID
        self.jobID = jobID
        self.sessionID = sessionID
        self.commandID = commandID
        self.state = state
    }

    fileprivate var stableSortKey: [UInt8] {
        [
            kind.rawValue,
            ownerClientInstanceID?.description ?? "",
            jobID ?? "",
            sessionID?.description ?? "",
            commandID ?? "",
            state ?? "",
            retryWhen.rawValue,
        ].joined(separator: "\u{0}").utf8.map { $0 }
    }

    private static func validProjectionValue(_ value: String?) -> Bool {
        guard let value else { return true }
        let bytes = Array(value.utf8)
        guard (1...128).contains(bytes.count) else { return false }
        return bytes.allSatisfy {
            (0x21...0x7e).contains($0) && $0 != 0x2f && $0 != 0x5c
        }
    }

    private static func requiredRetryWhen(
        for kind: ShutdownInhibitorKind
    ) -> ShutdownRetryWhen {
        switch kind {
        case .live:
            .liveDetached
        case .runningJob, .pendingJob:
            .jobTerminal
        case .stream:
            .streamClosed
        case .activeTrace:
            .traceStopped
        case .assetAcquisition:
            .acquisitionFinished
        case .preparingCapability:
            .capabilityResolved
        case .controlMutation:
            .controlFinished
        case .cleanup:
            .cleanupFinished
        case .fencing:
            .stateChanged
        }
    }
}

public struct ShutdownInhibitorToken: Hashable, Sendable {
    public let tokenID: CanonicalUUID
    public let metadata: ShutdownInhibitorMetadata

    public init(
        tokenID: CanonicalUUID,
        metadata: ShutdownInhibitorMetadata
    ) {
        self.tokenID = tokenID
        self.metadata = metadata
    }
}

public struct StopBlocker: Equatable, Sendable {
    public let kind: ShutdownInhibitorKind
    public let count: UInt64
    public let ownerClientInstanceID: CanonicalUUID?
    public let jobID: String?
    public let sessionID: CanonicalUUID?
    public let commandID: String?
    public let state: String?
    public let retryWhen: ShutdownRetryWhen

    fileprivate init(
        metadata: ShutdownInhibitorMetadata,
        count: UInt64
    ) {
        self.kind = metadata.kind
        self.count = count
        self.ownerClientInstanceID = metadata.ownerClientInstanceID
        self.jobID = metadata.jobID
        self.sessionID = metadata.sessionID
        self.commandID = metadata.commandID
        self.state = metadata.state
        self.retryWhen = metadata.retryWhen
    }
}

public struct ShutdownInhibitorRegistrySnapshot: Equatable, Sendable {
    public let inhibitorRevision: UInt64
    public let tokenCount: Int
    public let acceptingNewTokens: Bool
    public let blockers: [StopBlocker]
}

public struct ShutdownInhibitorRelease: Equatable, Sendable {
    public let snapshot: ShutdownInhibitorRegistrySnapshot
    public let becameEmpty: Bool
}

public struct ShutdownInhibitorRegistry: Sendable {
    public static let maximumTokenCount = 64

    private var tokens = [CanonicalUUID: ShutdownInhibitorMetadata]()
    private var inhibitorRevision: UInt64 = 0
    private var acceptingNewTokens = true

    public init() {}

    public var snapshot: ShutdownInhibitorRegistrySnapshot {
        var counts = [ShutdownInhibitorMetadata: UInt64]()
        for metadata in tokens.values {
            counts[metadata, default: 0] += 1
        }
        let blockers = counts
            .sorted { lhs, rhs in
                lhs.key.stableSortKey.lexicographicallyPrecedes(
                    rhs.key.stableSortKey
                )
            }
            .map { StopBlocker(metadata: $0.key, count: $0.value) }
        return ShutdownInhibitorRegistrySnapshot(
            inhibitorRevision: inhibitorRevision,
            tokenCount: tokens.count,
            acceptingNewTokens: acceptingNewTokens,
            blockers: blockers
        )
    }

    public mutating func acquire(
        tokenID: CanonicalUUID,
        metadata: ShutdownInhibitorMetadata
    ) throws -> ShutdownInhibitorToken {
        guard acceptingNewTokens else {
            throw ShutdownInhibitorRegistryError.admissionClosed
        }
        guard tokens[tokenID] == nil else {
            throw ShutdownInhibitorRegistryError.duplicateToken
        }
        guard tokens.count < Self.maximumTokenCount else {
            throw ShutdownInhibitorRegistryError.capacityExceeded
        }
        let nextRevision = try nextRevision()
        tokens[tokenID] = metadata
        inhibitorRevision = nextRevision
        return ShutdownInhibitorToken(tokenID: tokenID, metadata: metadata)
    }

    public mutating func handoff(
        _ token: ShutdownInhibitorToken,
        to metadata: ShutdownInhibitorMetadata
    ) throws -> ShutdownInhibitorToken {
        try validate(token)
        let nextRevision = try nextRevision()
        tokens[token.tokenID] = metadata
        inhibitorRevision = nextRevision
        return ShutdownInhibitorToken(tokenID: token.tokenID, metadata: metadata)
    }

    public mutating func release(
        _ token: ShutdownInhibitorToken
    ) throws -> ShutdownInhibitorRelease {
        try validate(token)
        let nextRevision = try nextRevision()
        tokens.removeValue(forKey: token.tokenID)
        inhibitorRevision = nextRevision
        return ShutdownInhibitorRelease(
            snapshot: snapshot,
            becameEmpty: tokens.isEmpty
        )
    }

    mutating func closeAdmissionIfEmpty() throws {
        guard tokens.isEmpty else {
            throw ShutdownInhibitorRegistryError.blockersRemain
        }
        acceptingNewTokens = false
    }

    mutating func closeAdmission() {
        acceptingNewTokens = false
    }

    private func validate(_ token: ShutdownInhibitorToken) throws {
        guard let current = tokens[token.tokenID] else {
            throw ShutdownInhibitorRegistryError.unknownToken
        }
        guard current == token.metadata else {
            throw ShutdownInhibitorRegistryError.staleToken
        }
    }

    private func nextRevision() throws -> UInt64 {
        let (next, overflow) = inhibitorRevision.addingReportingOverflow(1)
        guard !overflow else {
            throw ShutdownInhibitorRegistryError.revisionOverflow
        }
        return next
    }
}
