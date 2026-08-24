import PulsePhoneCommandCatalog
import PulsePhoneCommandPlanner
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneSharedDefinitions

public enum DemandSpecError: Error, Equatable, Sendable {
    case invalidOrigin
}

public struct DemandSpec: Equatable, Sendable {
    public let waitID: CanonicalUUID
    public let ownerClientInstanceID: CanonicalUUID
    public let descriptor: PreparationDemandDescriptor
    public let kind: PreparationWaitKind
    public let capabilityWaiter: CapabilityGateWaiter?

    private init(
        waitID: CanonicalUUID,
        ownerClientInstanceID: CanonicalUUID,
        descriptor: PreparationDemandDescriptor,
        kind: PreparationWaitKind,
        capabilityWaiter: CapabilityGateWaiter?
    ) {
        self.waitID = waitID
        self.ownerClientInstanceID = ownerClientInstanceID
        self.descriptor = descriptor
        self.kind = kind
        self.capabilityWaiter = capabilityWaiter
    }

    public static func explicitPrepare(
        observerID: CanonicalUUID,
        ownerClientInstanceID: CanonicalUUID,
        osMajor: UInt64,
        executionCatalog: ExecutionProfileCatalogV1
    ) throws -> Self {
        Self(
            waitID: observerID,
            ownerClientInstanceID: ownerClientInstanceID,
            descriptor: try PreparationDemandAuthority.derive(
                origin: .explicitPrepare,
                osMajor: osMajor,
                executionCatalog: executionCatalog
            ),
            kind: .explicitObserver,
            capabilityWaiter: nil
        )
    }

    public static func finiteCommand(
        waiterID: CanonicalUUID,
        ownerClientInstanceID: CanonicalUUID,
        candidatePreparationGroupID: String,
        capabilityWaiter: CapabilityGateWaiter,
        executionCatalog: ExecutionProfileCatalogV1
    ) throws -> Self {
        Self(
            waitID: waiterID,
            ownerClientInstanceID: ownerClientInstanceID,
            descriptor: try PreparationDemandAuthority.derive(
                origin: .finiteCommand,
                osMajor: 0,
                executionCatalog: executionCatalog,
                candidatePreparationGroupID: candidatePreparationGroupID
            ),
            kind: .commandWaiter,
            capabilityWaiter: capabilityWaiter
        )
    }

    public static func livePrewarm(
        demandID: CanonicalUUID,
        ownerClientInstanceID: CanonicalUUID,
        osMajor: UInt64,
        executionCatalog: ExecutionProfileCatalogV1
    ) throws -> Self {
        Self(
            waitID: demandID,
            ownerClientInstanceID: ownerClientInstanceID,
            descriptor: try PreparationDemandAuthority.derive(
                origin: .livePrewarm,
                osMajor: osMajor,
                executionCatalog: executionCatalog
            ),
            kind: .livePrewarm,
            capabilityWaiter: nil
        )
    }

    public func makeWaitEntry(
        runtimeEpoch: UInt64,
        connectionEpoch: UInt64
    ) throws -> PreparationWaitEntry {
        let expectedKind: PreparationWaitKind
        switch descriptor.origin {
        case .explicitPrepare:
            expectedKind = .explicitObserver
        case .finiteCommand:
            expectedKind = .commandWaiter
        case .livePrewarm:
            expectedKind = .livePrewarm
        }
        guard expectedKind == kind else {
            throw DemandSpecError.invalidOrigin
        }
        let key = try PreparationAttemptKey(
            runtimeEpoch: runtimeEpoch,
            connectionEpoch: connectionEpoch,
            preparationGroupID: descriptor.preparationGroupID
        )
        return try PreparationWaitEntry(
            waitID: waitID.description,
            ownerClientInstanceID: ownerClientInstanceID,
            key: key,
            demand: descriptor,
            kind: kind,
            capabilityWaiter: capabilityWaiter
        )
    }
}
