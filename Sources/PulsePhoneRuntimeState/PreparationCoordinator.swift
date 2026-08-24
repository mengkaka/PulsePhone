import PulsePhoneCommandCatalog
import PulsePhoneCommandPlanner
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneSharedDefinitions

public enum PreparationCoordinatorError: Error, Equatable, Sendable {
    case disconnected
    case invalidConnectionEpoch
    case unsupportedPreparationGroup
    case missingAttemptSeed
    case missingObserverContext
    case unknownAttempt
    case inconsistentState
    case claimAlreadyActive
    case missingPhaseClaim
    case staleCallback
    case observerDeadlineNotReached
}

public struct PreparationAttemptSeed: Equatable, Sendable {
    public let preparationAttemptID: CanonicalUUID
    public let inhibitorTokenID: CanonicalUUID

    public init(
        preparationAttemptID: CanonicalUUID,
        inhibitorTokenID: CanonicalUUID
    ) {
        self.preparationAttemptID = preparationAttemptID
        self.inhibitorTokenID = inhibitorTokenID
    }
}

public struct PrepareObserverContext: Equatable, Sendable {
    public let requestID: CanonicalUUID
    public let actionID: CanonicalUUID

    public init(requestID: CanonicalUUID, actionID: CanonicalUUID) {
        self.requestID = requestID
        self.actionID = actionID
    }
}

public enum PreparationImmediateCompletion: Equatable, Sendable {
    case commandResumePlanning(CapabilityGateWaiter)
    case explicitReady
    case liveReady
}

public enum PreparationDemandRegistration: Equatable, Sendable {
    case alreadyReady(PreparationImmediateCompletion)
    case started(PreparationAttemptIdentity, referenceCount: Int)
    case joined(PreparationAttemptIdentity, referenceCount: Int)
}

public enum PreparationInvalidationDisposition: Equatable, Sendable {
    case noDemand
    case attemptAlreadyActive(PreparationAttemptIdentity)
    case started(PreparationAttemptIdentity)
}

public enum PreparationAssetReadyDisposition: Equatable, Sendable {
    case requeryMountedState(PreparationAttemptIdentity)
    case staleIgnored
}

public struct PrepareObserverCompletion: Equatable, Sendable {
    public let observerID: CanonicalUUID
    public let terminal: PrepareObserverTerminal
}

public struct PreparationCoordinatorCompletion: Equatable, Sendable {
    public let waitCompletions: [PreparationWaitCompletion]
    public let observerCompletions: [PrepareObserverCompletion]
    public let persistentReferenceCount: Int
}

public struct PreparationCoordinatorDetach: Equatable, Sendable {
    public let waitCompletions: [PreparationWaitCompletion]
    public let observerCompletions: [PrepareObserverCompletion]
    public let continuingAcquisitionAttemptIDs: [String]
}

public struct PreparationCoordinatorSnapshot: Equatable, Sendable {
    public let runtimeEpoch: UInt64
    public let connectionEpoch: UInt64
    public let connected: Bool
    public let readyPreparationGroupIDs: [String]
    public let attempts: [PreparationAttemptSnapshot]
    public let observers: [PrepareObserverSnapshot]
    public let waitRegistry: PreparationWaitRegistrySnapshot
    public let scheduler: DeviceSchedulerSnapshot
    public let inhibitors: ShutdownInhibitorRegistrySnapshot
    public let activeAcquisitionAttemptIDs: [String]
}

public struct PreparationCoordinator: Sendable {
    private struct AttemptRecord: Sendable {
        var attempt: PreparationAttempt
        let inhibitor: ShutdownInhibitorToken
        var claimRequestID: String?
        var activeLease: ResourceLease?
    }

    private let runtimeEpoch: UInt64
    private let groups: [String: PreparationGroupDescriptor]
    private let claimTemplates: [String: ResourceClaimTemplateDescriptor]
    private var connectionEpoch: UInt64
    private var connected: Bool
    private var readyPreparationGroupIDs = Set<String>()
    private var attempts = [PreparationAttemptKey: AttemptRecord]()
    private var observers = [String: PrepareObserver]()
    private var waitRegistry = PreparationWaitRegistry()
    private var scheduler = DeviceScheduler()
    private var inhibitors = ShutdownInhibitorRegistry()
    private var activeAcquisitionAttemptIDs = Set<String>()

    public init(
        runtimeEpoch: UInt64,
        connectionEpoch: UInt64,
        executionCatalog: ExecutionProfileCatalogV1
    ) {
        self.runtimeEpoch = runtimeEpoch
        self.connectionEpoch = connectionEpoch
        self.connected = true
        self.groups = Dictionary(
            uniqueKeysWithValues: executionCatalog.preparationGroups.map {
                ($0.preparationGroupID, $0)
            }
        )
        self.claimTemplates = Dictionary(
            uniqueKeysWithValues: executionCatalog.resourceClaimTemplates.map {
                ($0.resourceClaimTemplateID, $0)
            }
        )
    }

    public var snapshot: PreparationCoordinatorSnapshot {
        PreparationCoordinatorSnapshot(
            runtimeEpoch: runtimeEpoch,
            connectionEpoch: connectionEpoch,
            connected: connected,
            readyPreparationGroupIDs: readyPreparationGroupIDs.sorted {
                $0.utf8.lexicographicallyPrecedes($1.utf8)
            },
            attempts: attempts.values.map { $0.attempt.snapshot }.sorted {
                $0.identity.preparationGroupID.utf8.lexicographicallyPrecedes(
                    $1.identity.preparationGroupID.utf8
                )
            },
            observers: observers.values.map(\.snapshot).sorted {
                $0.identity.observerID.description.utf8.lexicographicallyPrecedes(
                    $1.identity.observerID.description.utf8
                )
            },
            waitRegistry: waitRegistry.snapshot,
            scheduler: scheduler.snapshot,
            inhibitors: inhibitors.snapshot,
            activeAcquisitionAttemptIDs: activeAcquisitionAttemptIDs.sorted {
                $0.utf8.lexicographicallyPrecedes($1.utf8)
            }
        )
    }

    public mutating func observeCapabilityReady(
        preparationGroupID: String
    ) throws {
        guard groups[preparationGroupID] != nil else {
            throw PreparationCoordinatorError.unsupportedPreparationGroup
        }
        readyPreparationGroupIDs.insert(preparationGroupID)
    }

    public mutating func register(
        _ spec: DemandSpec,
        at instant: MonotonicInstant,
        newAttempt seed: PreparationAttemptSeed? = nil,
        observerContext: PrepareObserverContext? = nil
    ) throws -> PreparationDemandRegistration {
        guard connected else { throw PreparationCoordinatorError.disconnected }
        let groupID = spec.descriptor.preparationGroupID
        guard groups[groupID] != nil else {
            throw PreparationCoordinatorError.unsupportedPreparationGroup
        }
        if spec.kind == .explicitObserver, observerContext == nil {
            throw PreparationCoordinatorError.missingObserverContext
        }
        let entry = try spec.makeWaitEntry(
            runtimeEpoch: runtimeEpoch,
            connectionEpoch: connectionEpoch
        )

        if readyPreparationGroupIDs.contains(groupID) {
            switch spec.kind {
            case .commandWaiter:
                guard let waiter = spec.capabilityWaiter else {
                    throw PreparationCoordinatorError.inconsistentState
                }
                return .alreadyReady(.commandResumePlanning(waiter))
            case .explicitObserver:
                return .alreadyReady(.explicitReady)
            case .livePrewarm:
                try waitRegistry.registerDormantLivePrewarm(entry)
                return .alreadyReady(.liveReady)
            }
        }

        var preparedObserver: PrepareObserver?
        if spec.kind == .explicitObserver {
            let current = waitRegistry.snapshot
            if current.entries.allSatisfy({ $0.waitID != entry.waitID }),
               current.externalEntryCount >= PreparationWaitRegistry.maximumExternalEntryCount
            {
                throw PreparationWaitRegistryError.capacityExceeded(
                    PreparationWaitCapacityDetails()
                )
            }
            let observerContext = observerContext!
            preparedObserver = try PrepareObserver(
                identity: PrepareObserverIdentity(
                    requestID: observerContext.requestID,
                    actionID: observerContext.actionID,
                    observerID: spec.waitID,
                    ownerClientInstanceID: spec.ownerClientInstanceID
                ),
                startedAt: instant
            )
        }

        let key = entry.key
        let startsAttempt = !waitRegistry.snapshot.activeAttemptKeys.contains(key)
        var preparedRecord: AttemptRecord?
        if startsAttempt {
            guard let seed else {
                throw PreparationCoordinatorError.missingAttemptSeed
            }
            let identity = try PreparationAttemptIdentity(
                runtimeEpoch: runtimeEpoch,
                connectionEpoch: connectionEpoch,
                preparationGroupID: groupID,
                preparationAttemptID: seed.preparationAttemptID
            )
            let attempt = try PreparationAttempt(
                identity: identity,
                startedAt: instant
            )
            let metadata = try ShutdownInhibitorMetadata(
                kind: .preparingCapability,
                retryWhen: .capabilityResolved,
                state: groupID
            )
            let inhibitor = try inhibitors.acquire(
                tokenID: seed.inhibitorTokenID,
                metadata: metadata
            )
            preparedRecord = AttemptRecord(
                attempt: attempt,
                inhibitor: inhibitor
            )
        }

        let disposition: PreparationRegistrationDisposition
        do {
            disposition = try waitRegistry.register(entry)
        } catch {
            if let token = preparedRecord?.inhibitor {
                _ = try? inhibitors.release(token)
            }
            throw error
        }

        if let preparedObserver {
            observers[entry.waitID] = preparedObserver
        }

        switch disposition {
        case .startSharedAttempt(let key, let count):
            guard attempts[key] == nil, let preparedRecord else {
                throw PreparationCoordinatorError.inconsistentState
            }
            attempts[key] = preparedRecord
            return .started(preparedRecord.attempt.identity, referenceCount: count)
        case .joinedSharedAttempt(let key, let count):
            guard let record = attempts[key], preparedRecord == nil else {
                throw PreparationCoordinatorError.inconsistentState
            }
            return .joined(record.attempt.identity, referenceCount: count)
        }
    }

    public mutating func transitionAttempt(
        _ key: PreparationAttemptKey,
        to phase: PreparationAttemptPhase,
        at instant: MonotonicInstant
    ) throws {
        guard var record = attempts[key] else {
            throw PreparationCoordinatorError.unknownAttempt
        }
        try record.attempt.transition(to: phase, at: instant)
        attempts[key] = record
    }

    @discardableResult
    public mutating func beginDeadline(
        _ phase: PreparationDeadlinePhase,
        for key: PreparationAttemptKey,
        at instant: MonotonicInstant
    ) throws -> MonotonicInstant {
        guard var record = attempts[key] else {
            throw PreparationCoordinatorError.unknownAttempt
        }
        let deadline = try record.attempt.beginDeadline(phase, at: instant)
        attempts[key] = record
        return deadline
    }

    public mutating func beginAssetAcquisition(
        for key: PreparationAttemptKey,
        acquisitionAttemptID: String,
        at instant: MonotonicInstant
    ) throws {
        guard !acquisitionAttemptID.isEmpty, var record = attempts[key] else {
            throw PreparationCoordinatorError.unknownAttempt
        }
        try record.attempt.transition(to: .waitingForAcquisitionSlot, at: instant)
        _ = try record.attempt.beginDeadline(.acquisitionSlotWait, at: instant)
        _ = try record.attempt.beginDeadline(.assetAcquisition, at: instant)
        attempts[key] = record
        activeAcquisitionAttemptIDs.insert(acquisitionAttemptID)
    }

    public mutating func assetBecameReady(
        acquisitionAttemptID: String,
        callbackIdentity: PreparationAttemptIdentity,
        at instant: MonotonicInstant
    ) throws -> PreparationAssetReadyDisposition {
        activeAcquisitionAttemptIDs.remove(acquisitionAttemptID)
        let key = callbackIdentity.key
        guard var record = attempts[key],
              record.attempt.accepts(
                callbackIdentity,
                requiresExecutorGeneration: false
              )
        else {
            return .staleIgnored
        }
        for phase in [
            PreparationDeadlinePhase.acquisitionSlotWait,
            .assetAcquisition,
            .httpRequestPerSource,
            .downloadNoProgress,
            .validationAndExtraction,
        ] where record.attempt.snapshot.activeDeadlines[phase] != nil {
            try record.attempt.endDeadline(phase)
        }
        try record.attempt.transition(to: .queryingMountedImage, at: instant)
        _ = try record.attempt.beginDeadline(.mountedStateQuery, at: instant)
        attempts[key] = record
        return .requeryMountedState(record.attempt.identity)
    }

    public mutating func requestClaims(
        for key: PreparationAttemptKey,
        phaseID: PreparationPhaseID,
        at instant: MonotonicInstant
    ) throws -> SchedulerAdmission {
        guard var record = attempts[key] else {
            throw PreparationCoordinatorError.unknownAttempt
        }
        guard record.claimRequestID == nil, record.activeLease == nil else {
            throw PreparationCoordinatorError.claimAlreadyActive
        }
        guard let group = groups[key.preparationGroupID],
              let binding = group.phaseClaimBindings.first(where: {
                  $0.phaseID == phaseID
              }),
              let template = claimTemplates[binding.resourceClaimTemplateID]
        else {
            throw PreparationCoordinatorError.missingPhaseClaim
        }
        let claims = try template.claims.map {
            try ResourceClaim(
                accessMode: $0.accessMode,
                resourceID: $0.resourceIDTemplate
            )
        }
        let requestID = "\(record.attempt.identity.preparationAttemptID).\(phaseID.rawValue)"
        let request = try SchedulerRequest(
            requestID: requestID,
            claimantKind: .preparation,
            phase: .devicePreparation,
            claims: claims
        )
        _ = try record.attempt.beginDeadline(.deviceClaimWait, at: instant)
        let admission = try scheduler.submit(request)
        switch admission {
        case .running(let lease):
            try record.attempt.endDeadline(.deviceClaimWait)
            record.activeLease = lease
        case .waiting:
            record.claimRequestID = requestID
        case .pending, .resourceBusy, .queueFull:
            throw PreparationCoordinatorError.inconsistentState
        }
        attempts[key] = record
        return admission
    }

    public mutating func releaseClaims(
        for key: PreparationAttemptKey
    ) throws {
        guard var record = attempts[key], let lease = record.activeLease else {
            throw PreparationCoordinatorError.unknownAttempt
        }
        let release = try scheduler.release(requestID: lease.requestID)
        record.activeLease = nil
        attempts[key] = record
        applyGranted(release.newlyGranted)
    }

    public mutating func setExecutorGeneration(
        _ generation: UInt64,
        for key: PreparationAttemptKey
    ) throws {
        guard var record = attempts[key] else {
            throw PreparationCoordinatorError.unknownAttempt
        }
        try record.attempt.setExecutorGeneration(generation)
        attempts[key] = record
    }

    public mutating func completeAttempt(
        _ key: PreparationAttemptKey,
        resolution: PreparationAttemptResolution,
        at instant: MonotonicInstant
    ) throws -> PreparationCoordinatorCompletion {
        guard var record = attempts[key] else {
            throw PreparationCoordinatorError.unknownAttempt
        }
        switch resolution {
        case .ready:
            try record.attempt.finishReady(at: instant)
            readyPreparationGroupIDs.insert(key.preparationGroupID)
        case .unavailable(let reason):
            try record.attempt.finishUnavailable(reason: reason, at: instant)
            readyPreparationGroupIDs.remove(key.preparationGroupID)
        case .deviceDisconnected:
            try record.attempt.finishDisconnected(at: instant)
            readyPreparationGroupIDs.remove(key.preparationGroupID)
        }
        attempts.removeValue(forKey: key)
        try releaseResources(record)
        let completion = try waitRegistry.completeAttempt(
            key: key,
            resolution: resolution
        )
        let observerCompletions = try finishObservers(
            from: completion.completions,
            at: instant
        )
        return PreparationCoordinatorCompletion(
            waitCompletions: completion.completions,
            observerCompletions: observerCompletions,
            persistentReferenceCount: completion.persistentReferenceCount
        )
    }

    public mutating func releaseObserverReference(
        observerID: CanonicalUUID,
        reason: PrepareObserverReleaseReason,
        at instant: MonotonicInstant
    ) throws -> PrepareObserverCompletion {
        let waitID = observerID.description
        guard var observer = observers[waitID] else {
            throw PreparationCoordinatorError.inconsistentState
        }
        let terminal: PrepareObserverTerminal
        if reason == .observationTimeout {
            guard instant >= observer.deadline else {
                throw PreparationCoordinatorError.observerDeadlineNotReached
            }
            terminal = try observer.checkDeadline(at: instant)!
        } else {
            terminal = try observer.finish(.released(reason), at: instant)
        }
        _ = try waitRegistry.remove(waitID: waitID)
        observers.removeValue(forKey: waitID)
        return PrepareObserverCompletion(
            observerID: observerID,
            terminal: terminal
        )
    }

    public mutating func checkObserverDeadline(
        observerID: CanonicalUUID,
        at instant: MonotonicInstant
    ) throws -> PrepareObserverCompletion? {
        guard let observer = observers[observerID.description] else {
            throw PreparationCoordinatorError.inconsistentState
        }
        guard instant >= observer.deadline else { return nil }
        return try releaseObserverReference(
            observerID: observerID,
            reason: .observationTimeout,
            at: instant
        )
    }

    public mutating func checkAttemptDeadline(
        _ key: PreparationAttemptKey,
        at instant: MonotonicInstant
    ) throws -> PreparationCoordinatorCompletion? {
        guard let record = attempts[key] else {
            throw PreparationCoordinatorError.unknownAttempt
        }
        guard let phase = try record.attempt.expiredDeadline(at: instant) else {
            return nil
        }
        return try completeAttempt(
            key,
            resolution: .unavailable(
                reason: "preparationTimeout:\(phase.rawValue)"
            ),
            at: instant
        )
    }

    public mutating func invalidateCapability(
        preparationGroupID: String,
        at instant: MonotonicInstant,
        newAttempt seed: PreparationAttemptSeed?
    ) throws -> PreparationInvalidationDisposition {
        guard groups[preparationGroupID] != nil else {
            throw PreparationCoordinatorError.unsupportedPreparationGroup
        }
        readyPreparationGroupIDs.remove(preparationGroupID)
        guard connected else { return .noDemand }
        let key = try PreparationAttemptKey(
            runtimeEpoch: runtimeEpoch,
            connectionEpoch: connectionEpoch,
            preparationGroupID: preparationGroupID
        )
        guard let disposition = waitRegistry.restartAttemptIfReferenced(key: key) else {
            return .noDemand
        }
        switch disposition {
        case .joinedSharedAttempt:
            guard let record = attempts[key] else {
                throw PreparationCoordinatorError.inconsistentState
            }
            return .attemptAlreadyActive(record.attempt.identity)
        case .startSharedAttempt:
            guard seed != nil else {
                try waitRegistry.cancelAttemptStart(key: key)
                throw PreparationCoordinatorError.missingAttemptSeed
            }
            do {
                return .started(
                    try startAttempt(key: key, at: instant, seed: seed)
                )
            } catch {
                try? waitRegistry.cancelAttemptStart(key: key)
                throw error
            }
        }
    }

    public mutating func detach(
        at instant: MonotonicInstant
    ) throws -> PreparationCoordinatorDetach {
        guard connected else { throw PreparationCoordinatorError.disconnected }
        let oldEpoch = connectionEpoch
        for record in attempts.values where instant < record.attempt.startedAt {
            _ = record
            throw PreparationAttemptError.clockMovedBackwards
        }
        let waitCompletions = waitRegistry.detach(
            runtimeEpoch: runtimeEpoch,
            connectionEpoch: oldEpoch
        )
        let keys = attempts.keys.filter { $0.connectionEpoch == oldEpoch }
        for key in keys {
            guard var record = attempts[key] else { continue }
            try record.attempt.finishDisconnected(at: instant)
            attempts.removeValue(forKey: key)
            try releaseResources(record)
        }
        let observerCompletions = try finishObservers(
            from: waitCompletions,
            at: instant
        )
        readyPreparationGroupIDs.removeAll()
        connected = false
        return PreparationCoordinatorDetach(
            waitCompletions: waitCompletions,
            observerCompletions: observerCompletions,
            continuingAcquisitionAttemptIDs: snapshot.activeAcquisitionAttemptIDs
        )
    }

    public mutating func reconnect(
        connectionEpoch newConnectionEpoch: UInt64,
        at instant: MonotonicInstant,
        newAttempt seed: PreparationAttemptSeed?
    ) throws -> PreparationInvalidationDisposition {
        guard !connected, newConnectionEpoch > connectionEpoch else {
            throw PreparationCoordinatorError.invalidConnectionEpoch
        }
        let hasLivePrewarm = waitRegistry.snapshot.livePrewarmRegistered
        if hasLivePrewarm, seed == nil {
            throw PreparationCoordinatorError.missingAttemptSeed
        }
        connectionEpoch = newConnectionEpoch
        connected = true
        guard hasLivePrewarm else {
            return .noDemand
        }
        let disposition = try waitRegistry.rebindLivePrewarm(
            connectionEpoch: newConnectionEpoch
        )
        switch disposition {
        case .joinedSharedAttempt(let key, _):
            guard let record = attempts[key] else {
                throw PreparationCoordinatorError.inconsistentState
            }
            return .attemptAlreadyActive(record.attempt.identity)
        case .startSharedAttempt(let key, _):
            do {
                return .started(
                    try startAttempt(key: key, at: instant, seed: seed)
                )
            } catch {
                try? waitRegistry.cancelAttemptStart(key: key)
                throw error
            }
        }
    }

    private mutating func startAttempt(
        key: PreparationAttemptKey,
        at instant: MonotonicInstant,
        seed: PreparationAttemptSeed?
    ) throws -> PreparationAttemptIdentity {
        guard attempts[key] == nil, let seed else {
            throw PreparationCoordinatorError.missingAttemptSeed
        }
        let identity = try PreparationAttemptIdentity(
            runtimeEpoch: key.runtimeEpoch,
            connectionEpoch: key.connectionEpoch,
            preparationGroupID: key.preparationGroupID,
            preparationAttemptID: seed.preparationAttemptID
        )
        let token = try inhibitors.acquire(
            tokenID: seed.inhibitorTokenID,
            metadata: try ShutdownInhibitorMetadata(
                kind: .preparingCapability,
                retryWhen: .capabilityResolved,
                state: key.preparationGroupID
            )
        )
        attempts[key] = AttemptRecord(
            attempt: try PreparationAttempt(
                identity: identity,
                startedAt: instant
            ),
            inhibitor: token
        )
        return identity
    }

    private mutating func releaseResources(
        _ record: AttemptRecord
    ) throws {
        if let lease = record.activeLease {
            let release = try scheduler.release(requestID: lease.requestID)
            applyGranted(release.newlyGranted)
        } else if let requestID = record.claimRequestID {
            let granted = try scheduler.cancelPending(requestID: requestID)
            applyGranted(granted)
        }
        _ = try inhibitors.release(record.inhibitor)
    }

    private mutating func applyGranted(_ leases: [ResourceLease]) {
        for lease in leases {
            guard let key = attempts.first(where: {
                $0.value.claimRequestID == lease.requestID
            })?.key, var record = attempts[key]
            else {
                continue
            }
            record.claimRequestID = nil
            record.activeLease = lease
            if record.attempt.snapshot.activeDeadlines[.deviceClaimWait] != nil {
                try? record.attempt.endDeadline(.deviceClaimWait)
            }
            attempts[key] = record
        }
    }

    private mutating func finishObservers(
        from completions: [PreparationWaitCompletion],
        at instant: MonotonicInstant
    ) throws -> [PrepareObserverCompletion] {
        var result = [PrepareObserverCompletion]()
        for completion in completions {
            guard case .observerTerminal(let waitID, let resolution) = completion,
                  var observer = observers.removeValue(forKey: waitID)
            else {
                continue
            }
            let terminal = try observer.finish(.attempt(resolution), at: instant)
            result.append(
                PrepareObserverCompletion(
                    observerID: observer.identity.observerID,
                    terminal: terminal
                )
            )
        }
        return result
    }
}
