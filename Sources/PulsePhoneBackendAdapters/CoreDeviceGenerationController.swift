import PulsePhoneDeveloperSupportDefinitions

public enum CoreDeviceGenerationState: String, Equatable, Sendable {
    case starting
    case tunnelReady
    case servicesReady
    case ready
    case draining
    case retired
}

public enum CoreDeviceGenerationControllerError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidDemand
    case noActiveConnection
    case wrongConnectionEpoch
    case generationRetirementInProgress
    case runtimeNotAcceptingDemand
    case conflictingPreparationAttempt
    case invalidTransition
    case generationOverflow
}

public struct CoreDeviceGenerationSnapshot: Equatable, Sendable {
    public let identity: CoreDeviceGenerationIdentity
    public let state: CoreDeviceGenerationState
    public let preparationAttemptID: String?
    public let pendingDemandIDs: [String]
    public let helperAccepted: Bool
    public let tunnelStartIssued: Bool
    public let serviceStartIssued: Bool
    public let serviceSet: CoreDeviceServiceSet?
}

public struct CoreDeviceGenerationCoordinatorSnapshot: Equatable, Sendable {
    public let runtimeEpoch: UInt64
    public let activeConnectionEpoch: UInt64?
    public let activeGeneration: CoreDeviceGenerationSnapshot?
    public let retiringGenerationIDs: [CoreDeviceGenerationIdentity]
    public let acceptingDemands: Bool
    public let nextExecutorGeneration: UInt64
}

public enum CoreDeviceAttachDisposition: Equatable, Sendable {
    case attached(CoreDeviceGenerationCoordinatorSnapshot)
    case unchanged(CoreDeviceGenerationCoordinatorSnapshot)
    case replacedConnection(
        CoreDeviceGenerationRetirementPlan,
        CoreDeviceGenerationCoordinatorSnapshot
    )
    case staleIgnored(CoreDeviceGenerationCoordinatorSnapshot)
}

public enum CoreDeviceDemandDisposition: Equatable, Sendable {
    case notApplicable(CoreDeviceGenerationCoordinatorSnapshot)
    case start(
        CoreDeviceGenerationCommand,
        CoreDeviceGenerationCoordinatorSnapshot
    )
    case joined(
        CoreDeviceGenerationIdentity,
        CoreDeviceGenerationCoordinatorSnapshot
    )
    case reusedReady(
        CoreDeviceGenerationIdentity,
        CoreDeviceServiceSet,
        CoreDeviceGenerationCoordinatorSnapshot
    )
}

public enum CoreDeviceGenerationCallbackDisposition: Equatable, Sendable {
    case advance(
        CoreDeviceGenerationCommand,
        CoreDeviceGenerationCoordinatorSnapshot
    )
    case ready(
        identity: CoreDeviceGenerationIdentity,
        satisfiedDemandIDs: [String],
        serviceSet: CoreDeviceServiceSet,
        snapshot: CoreDeviceGenerationCoordinatorSnapshot
    )
    case staleIgnored(CoreDeviceGenerationCoordinatorSnapshot)
}

public enum CoreDeviceGenerationRetirementDisposition: Equatable, Sendable {
    case noGeneration(CoreDeviceGenerationCoordinatorSnapshot)
    case started(
        CoreDeviceGenerationRetirementPlan,
        CoreDeviceGenerationCoordinatorSnapshot
    )
    case completed(
        CoreDeviceGenerationSnapshot,
        CoreDeviceGenerationCoordinatorSnapshot
    )
    case staleIgnored(CoreDeviceGenerationCoordinatorSnapshot)
}

public struct CoreDeviceGenerationCoordinator: Sendable {
    public static let preparationGroupID = "prep.coredevice.v2"

    private struct Record: Sendable {
        let identity: CoreDeviceGenerationIdentity
        var state: CoreDeviceGenerationState
        var preparationAttemptID: String?
        var pendingDemandIDs: Set<String>
        var helperAccepted: Bool
        var tunnelStartIssued: Bool
        var serviceStartIssued: Bool
        var serviceSet: CoreDeviceServiceSet?

        var snapshot: CoreDeviceGenerationSnapshot {
            CoreDeviceGenerationSnapshot(
                identity: identity,
                state: state,
                preparationAttemptID: preparationAttemptID,
                pendingDemandIDs: pendingDemandIDs.sorted {
                    $0.utf8.lexicographicallyPrecedes($1.utf8)
                },
                helperAccepted: helperAccepted,
                tunnelStartIssued: tunnelStartIssued,
                serviceStartIssued: serviceStartIssued,
                serviceSet: serviceSet
            )
        }
    }

    public let runtimeEpoch: UInt64
    private var activeConnectionEpoch: UInt64?
    private var activeGeneration: Record?
    private var retiringGenerations = [CoreDeviceGenerationIdentity: Record]()
    private var acceptingDemands = true
    private var nextExecutorGeneration: UInt64

    public init(runtimeEpoch: UInt64, firstExecutorGeneration: UInt64 = 1) throws {
        guard firstExecutorGeneration > 0 else {
            throw CoreDeviceGenerationControllerError.generationOverflow
        }
        self.runtimeEpoch = runtimeEpoch
        self.nextExecutorGeneration = firstExecutorGeneration
    }

    public var snapshot: CoreDeviceGenerationCoordinatorSnapshot {
        CoreDeviceGenerationCoordinatorSnapshot(
            runtimeEpoch: runtimeEpoch,
            activeConnectionEpoch: activeConnectionEpoch,
            activeGeneration: activeGeneration?.snapshot,
            retiringGenerationIDs: retiringGenerations.keys.sorted {
                if $0.connectionEpoch != $1.connectionEpoch {
                    return $0.connectionEpoch < $1.connectionEpoch
                }
                return $0.executorGeneration < $1.executorGeneration
            },
            acceptingDemands: acceptingDemands,
            nextExecutorGeneration: nextExecutorGeneration
        )
    }

    @discardableResult
    public mutating func observeAttach(
        connectionEpoch: UInt64
    ) -> CoreDeviceAttachDisposition {
        guard connectionEpoch > 0 else {
            return .staleIgnored(snapshot)
        }
        if let currentEpoch = activeConnectionEpoch {
            if connectionEpoch < currentEpoch {
                return .staleIgnored(snapshot)
            }
            if connectionEpoch == currentEpoch {
                return .unchanged(snapshot)
            }
        }

        let retirement = activeGeneration.map {
            startRetirement(record: $0, reason: .detach)
        }
        activeConnectionEpoch = connectionEpoch
        if let retirement {
            return .replacedConnection(retirement, snapshot)
        }
        return .attached(snapshot)
    }

    public mutating func admitDemand(
        demandID: String,
        descriptor: PreparationDemandDescriptor,
        connectionEpoch: UInt64,
        preparationAttemptID: String
    ) throws -> CoreDeviceDemandDisposition {
        guard descriptor.preparationGroupID == Self.preparationGroupID else {
            return .notApplicable(snapshot)
        }
        guard Self.validIdentifier(demandID),
              Self.validIdentifier(preparationAttemptID),
              Self.validDemand(descriptor)
        else {
            throw CoreDeviceGenerationControllerError.invalidDemand
        }
        guard acceptingDemands else {
            throw CoreDeviceGenerationControllerError.runtimeNotAcceptingDemand
        }
        guard let activeConnectionEpoch else {
            throw CoreDeviceGenerationControllerError.noActiveConnection
        }
        guard connectionEpoch == activeConnectionEpoch else {
            throw CoreDeviceGenerationControllerError.wrongConnectionEpoch
        }
        guard !retiringGenerations.keys.contains(where: {
            $0.connectionEpoch == connectionEpoch
        }) else {
            throw CoreDeviceGenerationControllerError
                .generationRetirementInProgress
        }

        if var generation = activeGeneration {
            guard generation.identity.connectionEpoch == connectionEpoch else {
                throw CoreDeviceGenerationControllerError.wrongConnectionEpoch
            }
            if generation.state == .ready {
                guard let serviceSet = generation.serviceSet else {
                    throw CoreDeviceGenerationControllerError.invalidTransition
                }
                return .reusedReady(generation.identity, serviceSet, snapshot)
            }
            guard generation.preparationAttemptID == preparationAttemptID else {
                throw CoreDeviceGenerationControllerError
                    .conflictingPreparationAttempt
            }
            generation.pendingDemandIDs.insert(demandID)
            activeGeneration = generation
            return .joined(generation.identity, snapshot)
        }

        let identity = CoreDeviceGenerationIdentity(
            runtimeEpoch: runtimeEpoch,
            connectionEpoch: connectionEpoch,
            executorGeneration: nextExecutorGeneration
        )
        let (next, overflow) = nextExecutorGeneration.addingReportingOverflow(1)
        guard !overflow, next > 0 else {
            throw CoreDeviceGenerationControllerError.generationOverflow
        }
        nextExecutorGeneration = next
        activeGeneration = Record(
            identity: identity,
            state: .starting,
            preparationAttemptID: preparationAttemptID,
            pendingDemandIDs: [demandID],
            helperAccepted: false,
            tunnelStartIssued: false,
            serviceStartIssued: false,
            serviceSet: nil
        )
        return .start(
            CoreDeviceGenerationCommand(identity: identity, action: .spawnHelper),
            snapshot
        )
    }

    public mutating func helperAccepted(
        identity: CoreDeviceGenerationIdentity
    ) throws -> CoreDeviceGenerationCallbackDisposition {
        guard var generation = matchingActiveGeneration(identity) else {
            return .staleIgnored(snapshot)
        }
        guard generation.state == .starting,
              !generation.helperAccepted,
              !generation.tunnelStartIssued
        else {
            throw CoreDeviceGenerationControllerError.invalidTransition
        }
        generation.helperAccepted = true
        generation.tunnelStartIssued = true
        activeGeneration = generation
        return .advance(
            CoreDeviceGenerationCommand(identity: identity, action: .startTunnel),
            snapshot
        )
    }

    public mutating func tunnelReady(
        identity: CoreDeviceGenerationIdentity
    ) throws -> CoreDeviceGenerationCallbackDisposition {
        guard var generation = matchingActiveGeneration(identity) else {
            return .staleIgnored(snapshot)
        }
        guard generation.state == .starting,
              generation.helperAccepted,
              generation.tunnelStartIssued,
              !generation.serviceStartIssued
        else {
            throw CoreDeviceGenerationControllerError.invalidTransition
        }
        generation.state = .tunnelReady
        generation.serviceStartIssued = true
        activeGeneration = generation
        return .advance(
            CoreDeviceGenerationCommand(identity: identity, action: .openServices),
            snapshot
        )
    }

    public mutating func servicesReady(
        identity: CoreDeviceGenerationIdentity,
        serviceSet: CoreDeviceServiceSet
    ) throws -> CoreDeviceGenerationCallbackDisposition {
        guard var generation = matchingActiveGeneration(identity) else {
            return .staleIgnored(snapshot)
        }
        guard generation.state == .tunnelReady,
              generation.serviceStartIssued
        else {
            throw CoreDeviceGenerationControllerError.invalidTransition
        }
        generation.state = .servicesReady
        generation.serviceSet = serviceSet
        activeGeneration = generation
        return .advance(
            CoreDeviceGenerationCommand(identity: identity, action: .publishReady),
            snapshot
        )
    }

    public mutating func commitReady(
        identity: CoreDeviceGenerationIdentity
    ) throws -> CoreDeviceGenerationCallbackDisposition {
        guard var generation = matchingActiveGeneration(identity) else {
            return .staleIgnored(snapshot)
        }
        guard generation.state == .servicesReady,
              let serviceSet = generation.serviceSet
        else {
            throw CoreDeviceGenerationControllerError.invalidTransition
        }
        let satisfied = generation.pendingDemandIDs.sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }
        generation.state = .ready
        generation.preparationAttemptID = nil
        generation.pendingDemandIDs.removeAll()
        activeGeneration = generation
        return .ready(
            identity: identity,
            satisfiedDemandIDs: satisfied,
            serviceSet: serviceSet,
            snapshot: snapshot
        )
    }

    public mutating func observeDetach(
        connectionEpoch: UInt64
    ) -> CoreDeviceGenerationRetirementDisposition {
        guard activeConnectionEpoch == connectionEpoch else {
            return .staleIgnored(snapshot)
        }
        activeConnectionEpoch = nil
        guard let generation = activeGeneration,
              generation.identity.connectionEpoch == connectionEpoch
        else {
            return .noGeneration(snapshot)
        }
        let plan = startRetirement(record: generation, reason: .detach)
        return .started(plan, snapshot)
    }

    public mutating func retireCurrent(
        reason: CoreDeviceGenerationRetirementReason
    ) -> CoreDeviceGenerationRetirementDisposition {
        if reason == .fatal || reason == .quiesce {
            acceptingDemands = false
        }
        guard let generation = activeGeneration else {
            return .noGeneration(snapshot)
        }
        let plan = startRetirement(record: generation, reason: reason)
        return .started(plan, snapshot)
    }

    public mutating func completeRetirement(
        identity: CoreDeviceGenerationIdentity
    ) -> CoreDeviceGenerationRetirementDisposition {
        guard var generation = retiringGenerations.removeValue(forKey: identity)
        else {
            return .staleIgnored(snapshot)
        }
        generation.state = .retired
        generation.preparationAttemptID = nil
        generation.pendingDemandIDs.removeAll()
        generation.serviceSet = nil
        return .completed(generation.snapshot, snapshot)
    }

    private func matchingActiveGeneration(
        _ identity: CoreDeviceGenerationIdentity
    ) -> Record? {
        guard let activeGeneration,
              activeGeneration.identity == identity,
              activeConnectionEpoch == identity.connectionEpoch
        else {
            return nil
        }
        return activeGeneration
    }

    private mutating func startRetirement(
        record: Record,
        reason: CoreDeviceGenerationRetirementReason
    ) -> CoreDeviceGenerationRetirementPlan {
        var draining = record
        draining.state = .draining
        draining.preparationAttemptID = nil
        draining.pendingDemandIDs.removeAll()
        activeGeneration = nil
        retiringGenerations[draining.identity] = draining

        var actions = [CoreDeviceGenerationAction]()
        if draining.serviceStartIssued {
            actions.append(.closeServices)
        }
        if draining.tunnelStartIssued {
            actions.append(.closeTunnel)
        }
        actions.append(.terminateHelper)
        return CoreDeviceGenerationRetirementPlan(
            identity: draining.identity,
            reason: reason,
            commands: actions.map {
                CoreDeviceGenerationCommand(identity: draining.identity, action: $0)
            },
            fatalFailStopRequired: reason == .fatal
        )
    }

    private static func validDemand(
        _ descriptor: PreparationDemandDescriptor
    ) -> Bool {
        switch descriptor.origin {
        case .explicitPrepare, .finiteCommand:
            if case .epochBound = descriptor.persistence { return true }
        case .livePrewarm:
            if case .persistentAcrossReconnect = descriptor.persistence {
                return true
            }
        }
        return false
    }

    private static func validIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...128).contains(bytes.count)
            && bytes.allSatisfy { (0x21...0x7e).contains($0) }
    }
}
