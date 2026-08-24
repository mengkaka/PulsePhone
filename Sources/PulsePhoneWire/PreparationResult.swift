import PulsePhoneSharedDefinitions

public enum PreparationResultValidationError: Error, Equatable, Sendable {
    case invalidAttemptDisposition
    case invalidCapabilityIDs
    case invalidGroupID
    case invalidProvenance
}

public enum PreparationResultDisposition: String, Equatable, Sendable {
    case alreadyReady
    case ready
}

public enum PreparationAssetDisposition: String, Equatable, Sendable {
    case cacheHit
    case downloaded
    case mountedOnly
    case notRequired
    case xcodeHit
}

public enum PreparationMountDisposition: String, Equatable, Sendable {
    case alreadyMounted
    case mounted
    case notRequired
}

public enum PreparationServiceDisposition: String, Equatable, Sendable {
    case notRequired
    case ready
}

public struct PreparationResultV1: Equatable, Sendable {
    public let assetDisposition: PreparationAssetDisposition
    public let capabilityIDs: [String]
    public let connectionEpoch: UInt64?
    public let disposition: PreparationResultDisposition
    public let executorGeneration: UInt64?
    public let mountDisposition: PreparationMountDisposition
    public let preparationAttemptID: CanonicalUUID?
    public let preparationGroupID: String
    public let provenance: String
    public let serviceDisposition: PreparationServiceDisposition

    public init(
        assetDisposition: PreparationAssetDisposition,
        capabilityIDs: [String],
        connectionEpoch: UInt64? = nil,
        disposition: PreparationResultDisposition,
        executorGeneration: UInt64? = nil,
        mountDisposition: PreparationMountDisposition,
        preparationAttemptID: CanonicalUUID? = nil,
        preparationGroupID: String,
        provenance: String,
        serviceDisposition: PreparationServiceDisposition
    ) throws {
        guard PreparationWireValidation.validGroupID(preparationGroupID) else {
            throw PreparationResultValidationError.invalidGroupID
        }
        guard PreparationWireValidation.validASCIISet(
            capabilityIDs,
            maximumCount: 64
        ) else {
            throw PreparationResultValidationError.invalidCapabilityIDs
        }
        guard provenance == "approved"
                || provenance == "mountedUnknownUnverified"
        else {
            throw PreparationResultValidationError.invalidProvenance
        }
        guard (disposition == .ready && preparationAttemptID != nil)
                || (disposition == .alreadyReady && preparationAttemptID == nil)
        else {
            throw PreparationResultValidationError.invalidAttemptDisposition
        }
        self.assetDisposition = assetDisposition
        self.capabilityIDs = capabilityIDs
        self.connectionEpoch = connectionEpoch
        self.disposition = disposition
        self.executorGeneration = executorGeneration
        self.mountDisposition = mountDisposition
        self.preparationAttemptID = preparationAttemptID
        self.preparationGroupID = preparationGroupID
        self.provenance = provenance
        self.serviceDisposition = serviceDisposition
    }
}
