import PulsePhoneSharedDefinitions

public struct VideoBindingIdentity: Equatable, Sendable {
    public let canonicalUDID: CanonicalUDID
    public let connectionEpoch: UInt64
    public let geometryRevision: UInt64
    public let sourceEpoch: UInt64
    public let sourceID: String

    public init(
        canonicalUDID: CanonicalUDID,
        connectionEpoch: UInt64,
        sourceID: String,
        sourceEpoch: UInt64,
        geometryRevision: UInt64
    ) {
        self.canonicalUDID = canonicalUDID
        self.connectionEpoch = connectionEpoch
        self.sourceID = sourceID
        self.sourceEpoch = sourceEpoch
        self.geometryRevision = geometryRevision
    }
}

public struct VideoFrameIdentity: Equatable, Sendable {
    public let binding: VideoBindingIdentity
    public let frameSequence: UInt64

    public init(binding: VideoBindingIdentity, frameSequence: UInt64) {
        self.binding = binding
        self.frameSequence = frameSequence
    }
}

public enum VideoFrameDiscardReason: String, Equatable, Sendable {
    case connectionEpochMismatch
    case geometryRevisionMismatch
    case sourceEpochMismatch
    case sourceIDMismatch
    case targetMismatch
    case unbound
}

public enum VideoFrameDisposition: Equatable, Sendable {
    case accepted(frameSequence: UInt64)
    case discarded(VideoFrameDiscardReason)
}

public enum VideoBindingError: Error, Equatable, Sendable {
    case ambiguousSource
    case geometryConnectionEpochMismatch
    case invalidConnectionEpoch
    case sourceUnavailable
    case targetMismatch
}

public enum VideoBinding {
    public static func make(
        target canonicalUDID: CanonicalUDID,
        connectionEpoch: UInt64,
        geometry: DisplayGeometryDTO,
        resolution: VideoSourceResolution
    ) throws -> VideoBindingIdentity {
        guard connectionEpoch > 0 else {
            throw VideoBindingError.invalidConnectionEpoch
        }
        guard geometry.connectionEpoch == connectionEpoch else {
            throw VideoBindingError.geometryConnectionEpochMismatch
        }
        let resolved: VideoResolvedSource
        switch resolution {
        case .ambiguous:
            throw VideoBindingError.ambiguousSource
        case .mapped(let value):
            resolved = value
        case .unavailable:
            throw VideoBindingError.sourceUnavailable
        }
        guard resolved.canonicalUDID == canonicalUDID else {
            throw VideoBindingError.targetMismatch
        }
        return VideoBindingIdentity(
            canonicalUDID: canonicalUDID,
            connectionEpoch: connectionEpoch,
            sourceID: resolved.descriptor.sourceID,
            sourceEpoch: resolved.descriptor.sourceEpoch,
            geometryRevision: geometry.geometryRevision
        )
    }

    public static func validate(
        frame: VideoFrameIdentity,
        against binding: VideoBindingIdentity?
    ) -> VideoFrameDisposition {
        guard let binding else { return .discarded(.unbound) }
        guard frame.binding.canonicalUDID == binding.canonicalUDID else {
            return .discarded(.targetMismatch)
        }
        guard frame.binding.connectionEpoch == binding.connectionEpoch else {
            return .discarded(.connectionEpochMismatch)
        }
        guard frame.binding.sourceID == binding.sourceID else {
            return .discarded(.sourceIDMismatch)
        }
        guard frame.binding.sourceEpoch == binding.sourceEpoch else {
            return .discarded(.sourceEpochMismatch)
        }
        guard frame.binding.geometryRevision == binding.geometryRevision else {
            return .discarded(.geometryRevisionMismatch)
        }
        return .accepted(frameSequence: frame.frameSequence)
    }
}
