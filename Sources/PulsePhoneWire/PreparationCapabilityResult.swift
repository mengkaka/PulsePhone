import PulsePhoneSharedDefinitions

public enum PreparationCapabilityRequirement: String, Codable, Equatable, Sendable {
    case optional
    case required
}

public enum PreparationCapabilityState: String, Codable, Equatable, Sendable {
    case available
    case unavailable
    case unknown
}

public struct PreparationCapabilityResultV1: Codable, Equatable, Sendable {
    public let capabilityID: String
    public let reason: String?
    public let requirement: PreparationCapabilityRequirement
    public let state: PreparationCapabilityState

    public init(
        capabilityID: String,
        reason: String? = nil,
        requirement: PreparationCapabilityRequirement,
        state: PreparationCapabilityState
    ) throws {
        guard PreparationWireValidation.validCapabilityID(capabilityID),
              reason == nil || PreparationWireValidation.validReason(reason!)
        else {
            throw PreparationCapabilityResultValidationError.invalidValue
        }
        if state == .available {
            guard reason == nil else {
                throw PreparationCapabilityResultValidationError.invalidValue
            }
        } else {
            guard reason != nil else {
                throw PreparationCapabilityResultValidationError.invalidValue
            }
        }
        self.capabilityID = capabilityID
        self.reason = reason
        self.requirement = requirement
        self.state = state
    }
}

public enum PreparationCapabilityResultValidationError: Error, Equatable, Sendable {
    case invalidValue
}
