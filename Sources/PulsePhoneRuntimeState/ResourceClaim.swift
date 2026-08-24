import PulsePhoneCommandCatalog
import PulsePhoneCommandPlanner

public enum ResourceClaimError: Error, Equatable, Sendable {
    case invalidResourceID
    case conflictingAccess(String)
    case hostAcquisitionForbidden
    case invalidClaimantPhase
}

public struct ResourceClaim: Equatable, Hashable, Sendable {
    public let accessMode: ResourceAccessMode
    public let resourceID: String

    public init(
        accessMode: ResourceAccessMode,
        resourceID: String
    ) throws {
        let bytes = Array(resourceID.utf8)
        guard (1...256).contains(bytes.count),
              bytes.allSatisfy({ (0x21...0x7e).contains($0) })
        else {
            throw ResourceClaimError.invalidResourceID
        }
        self.accessMode = accessMode
        self.resourceID = resourceID
    }

    public init(materialized: MaterializedResourceClaim) throws {
        try self.init(
            accessMode: materialized.accessMode,
            resourceID: materialized.resourceID
        )
    }

    fileprivate var stableSortKey: [UInt8] {
        "\(resourceID)\u{0}\(accessMode.rawValue)".utf8.map { $0 }
    }

    static func normalize(_ claims: [ResourceClaim]) throws -> [ResourceClaim] {
        var modeByResource = [String: ResourceAccessMode]()
        for claim in claims {
            if let current = modeByResource[claim.resourceID],
               current != claim.accessMode
            {
                throw ResourceClaimError.conflictingAccess(claim.resourceID)
            }
            modeByResource[claim.resourceID] = claim.accessMode
        }
        return Array(Set(claims)).sorted {
            $0.stableSortKey.lexicographicallyPrecedes($1.stableSortKey)
        }
    }

    static func conflict(_ lhs: ResourceClaim, _ rhs: ResourceClaim) -> Bool {
        guard lhs.resourceID == rhs.resourceID else { return false }
        return lhs.accessMode != .shared || rhs.accessMode != .shared
    }
}

public enum SchedulerClaimantKind: String, Equatable, Sendable {
    case oneShot
    case stream
    case preparation
}

public struct SchedulerRequest: Equatable, Sendable {
    public let requestID: String
    public let claimantKind: SchedulerClaimantKind
    public let phase: ResourceClaimPhase
    public let claims: [ResourceClaim]

    public init(
        requestID: String,
        claimantKind: SchedulerClaimantKind,
        phase: ResourceClaimPhase,
        claims: [ResourceClaim]
    ) throws {
        let bytes = Array(requestID.utf8)
        guard (1...256).contains(bytes.count),
              bytes.allSatisfy({ (0x21...0x7e).contains($0) })
        else {
            throw ResourceClaimError.invalidResourceID
        }
        guard phase != .hostAcquisition else {
            throw ResourceClaimError.hostAcquisitionForbidden
        }
        switch (claimantKind, phase) {
        case (.oneShot, .running), (.stream, .stream),
             (.preparation, .devicePreparation):
            break
        default:
            throw ResourceClaimError.invalidClaimantPhase
        }
        self.requestID = requestID
        self.claimantKind = claimantKind
        self.phase = phase
        self.claims = try ResourceClaim.normalize(claims)
    }

    public init(
        requestID: String,
        claimantKind: SchedulerClaimantKind,
        phase: ResourceClaimPhase,
        materializedClaims: [MaterializedResourceClaim]
    ) throws {
        let phaseClaims = materializedClaims.filter { $0.phase == phase }
        try self.init(
            requestID: requestID,
            claimantKind: claimantKind,
            phase: phase,
            claims: try phaseClaims.map(ResourceClaim.init(materialized:))
        )
    }

    public var productAcceptedWhenQueued: Bool {
        claimantKind == .oneShot
    }

    public var productAcceptedWhenGranted: Bool {
        claimantKind != .preparation
    }
}
