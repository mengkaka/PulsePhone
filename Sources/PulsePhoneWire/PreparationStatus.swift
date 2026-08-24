import PulsePhoneSharedDefinitions

public enum PreparationStatusValidationError: Error, Equatable, Sendable {
    case invalidCapabilityIDs
    case invalidGroupID
    case inconsistentProjection
}

public enum PreparationStatusState: String, Equatable, Sendable {
    case acquiring
    case preparingDevice
    case ready
    case unavailable
    case unknown
}

public struct PreparationErrorDetailsV1: Equatable, Sendable {
    public let capacityClass: String?
    public let limit: UInt64?
    public let phase: String?
    public let reason: String?
    public let runtimeMayContinue: Bool?
    public let truncated: Bool

    public init(
        capacityClass: String? = nil,
        limit: UInt64? = nil,
        phase: String? = nil,
        reason: String? = nil,
        runtimeMayContinue: Bool? = nil,
        truncated: Bool = false
    ) {
        self.capacityClass = capacityClass
        self.limit = limit
        self.phase = phase
        self.reason = reason
        self.runtimeMayContinue = runtimeMayContinue
        self.truncated = truncated
    }
}

public struct PreparationStatusV1: Equatable, Sendable {
    public let capabilityIDs: [String]
    public let connectionEpoch: UInt64?
    public let lastError: StandardErrorV1<PreparationErrorDetailsV1>?
    public let phase: PreparationWirePhase?
    public let preparationAttemptID: CanonicalUUID?
    public let preparationGroupID: String
    public let progress: PreparationProgressV1?
    public let state: PreparationStatusState
    public let truncated: Bool

    public init(
        capabilityIDs: [String] = [],
        connectionEpoch: UInt64? = nil,
        lastError: StandardErrorV1<PreparationErrorDetailsV1>? = nil,
        phase: PreparationWirePhase? = nil,
        preparationAttemptID: CanonicalUUID? = nil,
        preparationGroupID: String,
        progress: PreparationProgressV1? = nil,
        state: PreparationStatusState
    ) throws {
        guard PreparationWireValidation.validGroupID(preparationGroupID) else {
            throw PreparationStatusValidationError.invalidGroupID
        }
        guard PreparationWireValidation.validASCIISet(
            capabilityIDs,
            maximumCount: 64
        ) else {
            throw PreparationStatusValidationError.invalidCapabilityIDs
        }
        let active = state == .acquiring || state == .preparingDevice
        guard (!active || preparationAttemptID != nil),
              (state != .ready || lastError == nil),
              progress == nil || progress?.preparationGroupID == preparationGroupID
        else {
            throw PreparationStatusValidationError.inconsistentProjection
        }
        self.capabilityIDs = capabilityIDs
        self.connectionEpoch = connectionEpoch
        self.lastError = lastError
        self.phase = phase
        self.preparationAttemptID = preparationAttemptID
        self.preparationGroupID = preparationGroupID
        self.progress = progress
        self.state = state
        self.truncated = false
    }
}
