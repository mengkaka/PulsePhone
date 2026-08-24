import PulsePhoneCommandCatalog
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions
import PulsePhoneWire

public enum PrepareCapabilitiesControlError: Error, Equatable, Sendable {
    case invalidRequestBody
    case targetMismatch
    case unknownObserver
    case staleAttempt
    case missingSuccessProjection
    case duplicateTerminal
    case outputCapacityExceeded
}

public struct PrepareCapabilitiesActionContext: Equatable, Sendable {
    public let actionID: CanonicalUUID?
    public let parentActionID: CanonicalUUID?

    public init(
        actionID: CanonicalUUID?,
        parentActionID: CanonicalUUID?
    ) throws {
        guard parentActionID == nil || actionID != nil else {
            throw PrepareCapabilitiesControlError.invalidRequestBody
        }
        self.actionID = actionID
        self.parentActionID = parentActionID
    }
}

public struct PrepareCapabilitiesRequestV1: Equatable, Sendable {
    public let actionContext: PrepareCapabilitiesActionContext?
    public let canonicalUDID: CanonicalUDID

    public init(
        canonicalUDID: CanonicalUDID,
        actionContext: PrepareCapabilitiesActionContext? = nil
    ) {
        self.actionContext = actionContext
        self.canonicalUDID = canonicalUDID
    }

    public static func decode(
        _ body: RepositoryJSONObject
    ) throws -> PrepareCapabilitiesRequestV1 {
        let keys = Set(body.members.map(\.key))
        guard keys == ["canonicalUDID"]
                || keys == ["actionContext", "canonicalUDID"],
              let target = body["canonicalUDID"]?.stringValue,
              let canonicalUDID = try? CanonicalUDID(canonicalString: target)
        else {
            throw PrepareCapabilitiesControlError.invalidRequestBody
        }
        let context: PrepareCapabilitiesActionContext?
        if let value = body["actionContext"] {
            guard let object = value.objectValue else {
                throw PrepareCapabilitiesControlError.invalidRequestBody
            }
            let contextKeys = Set(object.members.map(\.key))
            guard contextKeys.isSubset(of: ["actionID", "parentActionID"]),
                  !contextKeys.isEmpty
            else {
                throw PrepareCapabilitiesControlError.invalidRequestBody
            }
            context = try PrepareCapabilitiesActionContext(
                actionID: try optionalUUID(object, key: "actionID"),
                parentActionID: try optionalUUID(object, key: "parentActionID")
            )
        } else {
            context = nil
        }
        return PrepareCapabilitiesRequestV1(
            canonicalUDID: canonicalUDID,
            actionContext: context
        )
    }

    private static func optionalUUID(
        _ object: RepositoryJSONObject,
        key: String
    ) throws -> CanonicalUUID? {
        guard let value = object[key] else { return nil }
        guard let string = value.stringValue,
              let uuid = try? CanonicalUUID(string)
        else {
            throw PrepareCapabilitiesControlError.invalidRequestBody
        }
        return uuid
    }
}

public struct PreparationSuccessProjection: Equatable, Sendable {
    public let assetDisposition: PreparationAssetDisposition
    public let mountDisposition: PreparationMountDisposition
    public let provenance: String
    public let serviceDisposition: PreparationServiceDisposition

    public init(
        assetDisposition: PreparationAssetDisposition,
        mountDisposition: PreparationMountDisposition,
        provenance: String,
        serviceDisposition: PreparationServiceDisposition
    ) {
        self.assetDisposition = assetDisposition
        self.mountDisposition = mountDisposition
        self.provenance = provenance
        self.serviceDisposition = serviceDisposition
    }
}

public struct PrepareCapabilitiesTerminal: Equatable, Sendable {
    public let actionID: CanonicalUUID
    public let parentActionID: CanonicalUUID?
    public let requestID: CanonicalUUID
    public let result: StandardResultV1<
        PreparationResultV1,
        PreparationErrorDetailsV1
    >
}

public enum PrepareCapabilitiesAdmission: Equatable, Sendable {
    case observing(
        actionID: CanonicalUUID,
        identity: PreparationAttemptIdentity,
        joined: Bool
    )
    case terminal(PrepareCapabilitiesTerminal)
    case rejected(PrepareCapabilitiesTerminal)
}

public enum PreparationOutputDisposition: Equatable, Sendable {
    case queued
    case coalesced
    case dropped
    case terminalQueued(progressDiscarded: Bool)
}

public struct PreparationOutputBufferSnapshot: Equatable, Sendable {
    public let progress: [CanonicalUUID: PreparationProgressV1]
    public let terminals: [CanonicalUUID: PrepareCapabilitiesTerminal]
}

public struct PreparationOutputBuffer: Sendable {
    public static let maximumRequestCount = 64

    private var progress = [CanonicalUUID: PreparationProgressV1]()
    private var terminals = [CanonicalUUID: PrepareCapabilitiesTerminal]()
    private var terminalOrder = [CanonicalUUID]()

    public init() {}

    public var snapshot: PreparationOutputBufferSnapshot {
        PreparationOutputBufferSnapshot(
            progress: progress,
            terminals: terminals
        )
    }

    public mutating func enqueueProgress(
        _ value: PreparationProgressV1,
        for requestID: CanonicalUUID
    ) throws -> PreparationOutputDisposition {
        guard terminals[requestID] == nil else {
            return .dropped
        }
        guard progress[requestID] != nil
                || progress.count < Self.maximumRequestCount
        else {
            return .dropped
        }
        let disposition: PreparationOutputDisposition = progress[requestID] == nil
            ? .queued
            : .coalesced
        progress[requestID] = value
        return disposition
    }

    public mutating func enqueueTerminal(
        _ value: PrepareCapabilitiesTerminal
    ) throws -> PreparationOutputDisposition {
        guard terminals[value.requestID] == nil else {
            throw PrepareCapabilitiesControlError.duplicateTerminal
        }
        guard terminals.count < Self.maximumRequestCount else {
            throw PrepareCapabilitiesControlError.outputCapacityExceeded
        }
        let discarded = progress.removeValue(forKey: value.requestID) != nil
        terminals[value.requestID] = value
        terminalOrder.append(value.requestID)
        return .terminalQueued(progressDiscarded: discarded)
    }

    public mutating func drainProgress() -> [(
        requestID: CanonicalUUID,
        progress: PreparationProgressV1
    )] {
        let values = progress.sorted { lhs, rhs in
            lhs.key.description.utf8.lexicographicallyPrecedes(
                rhs.key.description.utf8
            )
        }
        progress.removeAll()
        return values.map { ($0.key, $0.value) }
    }

    public mutating func drainTerminals() -> [PrepareCapabilitiesTerminal] {
        let values = terminalOrder.compactMap { terminals[$0] }
        terminals.removeAll()
        terminalOrder.removeAll()
        return values
    }
}

public struct PrepareCapabilitiesControlSnapshot: Equatable, Sendable {
    public let coordinator: PreparationCoordinatorSnapshot
    public let idle: RuntimeIdleSnapshot
    public let activeRequestIDs: [CanonicalUUID]
    public let output: PreparationOutputBufferSnapshot
}

public struct PrepareCapabilitiesControl: Sendable {
    private struct ActiveRequest: Equatable, Sendable {
        let actionID: CanonicalUUID
        let parentActionID: CanonicalUUID?
        let identity: PreparationAttemptIdentity
    }

    private let canonicalUDID: CanonicalUDID
    private let executionCatalog: ExecutionProfileCatalogV1
    private let groups: [String: PreparationGroupDescriptor]
    private var coordinator: PreparationCoordinator
    private var idle: RuntimeIdleCoordinator
    private var active = [CanonicalUUID: ActiveRequest]()
    private var output = PreparationOutputBuffer()

    public init(
        canonicalUDID: CanonicalUDID,
        runtimeEpoch: UInt64,
        connectionEpoch: UInt64,
        runtimeReadyAt: MonotonicInstant,
        executionCatalog: ExecutionProfileCatalogV1
    ) throws {
        self.canonicalUDID = canonicalUDID
        self.executionCatalog = executionCatalog
        self.groups = Dictionary(
            uniqueKeysWithValues: executionCatalog.preparationGroups.map {
                ($0.preparationGroupID, $0)
            }
        )
        self.coordinator = PreparationCoordinator(
            runtimeEpoch: runtimeEpoch,
            connectionEpoch: connectionEpoch,
            executionCatalog: executionCatalog
        )
        self.idle = try RuntimeIdleCoordinator(runtimeReadyAt: runtimeReadyAt)
    }

    public var snapshot: PrepareCapabilitiesControlSnapshot {
        PrepareCapabilitiesControlSnapshot(
            coordinator: coordinator.snapshot,
            idle: idle.snapshot,
            activeRequestIDs: active.keys.sorted {
                $0.description.utf8.lexicographicallyPrecedes($1.description.utf8)
            },
            output: output.snapshot
        )
    }

    public mutating func observeCapabilityReady(
        preparationGroupID: String
    ) throws {
        try coordinator.observeCapabilityReady(
            preparationGroupID: preparationGroupID
        )
    }

    public mutating func transitionAttempt(
        _ key: PreparationAttemptKey,
        to phase: PreparationAttemptPhase,
        at instant: MonotonicInstant
    ) throws {
        try coordinator.transitionAttempt(key, to: phase, at: instant)
    }

    public mutating func setExecutorGeneration(
        _ generation: UInt64,
        for key: PreparationAttemptKey
    ) throws {
        try coordinator.setExecutorGeneration(generation, for: key)
    }

    public mutating func prepareCapabilities(
        requestID: CanonicalUUID,
        request: PrepareCapabilitiesRequestV1,
        allocatedActionID: CanonicalUUID,
        ownerClientInstanceID: CanonicalUUID,
        osMajor: UInt64,
        at instant: MonotonicInstant,
        newAttempt seed: PreparationAttemptSeed,
        alreadyReadyProjection: PreparationSuccessProjection
    ) throws -> PrepareCapabilitiesAdmission {
        guard request.canonicalUDID == canonicalUDID else {
            throw PrepareCapabilitiesControlError.targetMismatch
        }
        let actionID = request.actionContext?.actionID ?? allocatedActionID
        let parentActionID = request.actionContext?.parentActionID
        let spec = try DemandSpec.explicitPrepare(
            observerID: requestID,
            ownerClientInstanceID: ownerClientInstanceID,
            osMajor: osMajor,
            executionCatalog: executionCatalog
        )
        let registration: PreparationDemandRegistration
        do {
            registration = try coordinator.register(
                spec,
                at: instant,
                newAttempt: seed,
                observerContext: PrepareObserverContext(
                    requestID: requestID,
                    actionID: actionID
                )
            )
        } catch let error as PreparationWaitRegistryError {
            guard case .capacityExceeded(let details) = error else { throw error }
            let terminal = try failureTerminal(
                requestID: requestID,
                actionID: actionID,
                parentActionID: parentActionID,
                outcome: .failed,
                code: "admissionCapacityExceeded",
                details: PreparationErrorDetailsV1(
                    capacityClass: details.capacityClass,
                    limit: UInt64(details.limit),
                    truncated: details.truncated
                )
            )
            _ = try output.enqueueTerminal(terminal)
            return .rejected(terminal)
        }
        _ = try idle.recordActivity(.acceptedPrepareCapabilities, at: instant)
        switch registration {
        case .alreadyReady(.explicitReady):
            let groupID = spec.descriptor.preparationGroupID
            let result = try successResult(
                groupID: groupID,
                disposition: .alreadyReady,
                identity: nil,
                projection: alreadyReadyProjection
            )
            let terminal = try successTerminal(
                requestID: requestID,
                actionID: actionID,
                parentActionID: parentActionID,
                value: result
            )
            _ = try output.enqueueTerminal(terminal)
            return .terminal(terminal)
        case .started(let identity, _):
            active[requestID] = ActiveRequest(
                actionID: actionID,
                parentActionID: parentActionID,
                identity: identity
            )
            return .observing(
                actionID: actionID,
                identity: identity,
                joined: false
            )
        case .joined(let identity, _):
            active[requestID] = ActiveRequest(
                actionID: actionID,
                parentActionID: parentActionID,
                identity: identity
            )
            return .observing(
                actionID: actionID,
                identity: identity,
                joined: true
            )
        case .alreadyReady:
            throw PreparationCoordinatorError.inconsistentState
        }
    }

    public mutating func publishProgress(
        requestID: CanonicalUUID,
        callbackIdentity: PreparationAttemptIdentity,
        phaseSequence: UInt64,
        stateRevision: UInt64,
        completedBytes: UInt64? = nil,
        totalBytes: UInt64? = nil,
        fraction: Double? = nil,
        sourceKind: PreparationProgressSourceKind? = nil,
        sharedAcquisition: Bool? = nil,
        retryAfterMs: UInt64? = nil
    ) throws -> PreparationOutputDisposition {
        guard let request = active[requestID] else {
            throw PrepareCapabilitiesControlError.unknownObserver
        }
        guard request.identity == callbackIdentity,
              let attempt = coordinator.snapshot.attempts.first(where: {
                  $0.identity == callbackIdentity
              })
        else {
            throw PrepareCapabilitiesControlError.staleAttempt
        }
        let progress = try PreparationProgressV1(
            completedBytes: completedBytes,
            fraction: fraction,
            phase: wirePhase(attempt.phase),
            phaseSequence: phaseSequence,
            preparationAttemptID: callbackIdentity.preparationAttemptID,
            preparationGroupID: callbackIdentity.preparationGroupID,
            retryAfterMs: retryAfterMs,
            sharedAcquisition: sharedAcquisition,
            sourceKind: sourceKind,
            stateRevision: stateRevision,
            totalBytes: totalBytes
        )
        return try output.enqueueProgress(progress, for: requestID)
    }

    public mutating func completeAttempt(
        _ key: PreparationAttemptKey,
        resolution: PreparationAttemptResolution,
        successProjection: PreparationSuccessProjection? = nil,
        at instant: MonotonicInstant
    ) throws -> [PrepareCapabilitiesTerminal] {
        let completion = try coordinator.completeAttempt(
            key,
            resolution: resolution,
            at: instant
        )
        return try completion.observerCompletions.compactMap { completion in
            guard let request = active.removeValue(forKey: completion.observerID)
            else {
                return nil
            }
            let terminal = try terminal(
                requestID: completion.observerID,
                request: request,
                observerTerminal: completion.terminal,
                successProjection: successProjection
            )
            _ = try output.enqueueTerminal(terminal)
            return terminal
        }
    }

    public mutating func observerDeadline(
        requestID: CanonicalUUID,
        at instant: MonotonicInstant
    ) throws -> PrepareCapabilitiesTerminal? {
        guard let request = active[requestID] else {
            throw PrepareCapabilitiesControlError.unknownObserver
        }
        guard let completion = try coordinator.checkObserverDeadline(
            observerID: requestID,
            at: instant
        ) else {
            return nil
        }
        active.removeValue(forKey: requestID)
        let terminal = try self.terminal(
            requestID: requestID,
            request: request,
            observerTerminal: completion.terminal,
            successProjection: nil
        )
        _ = try output.enqueueTerminal(terminal)
        return terminal
    }

    public func statuses(
        stateRevision: UInt64,
        lastErrors: [String: StandardErrorV1<PreparationErrorDetailsV1>] = [:]
    ) throws -> [PreparationStatusV1] {
        let snapshot = coordinator.snapshot
        return try groups.values.sorted {
            $0.preparationGroupID.utf8.lexicographicallyPrecedes(
                $1.preparationGroupID.utf8
            )
        }.prefix(8).map { group in
            let capabilityIDs = sortedASCII(group.requiredCapabilityIDs)
            if snapshot.readyPreparationGroupIDs.contains(group.preparationGroupID) {
                return try PreparationStatusV1(
                    capabilityIDs: capabilityIDs,
                    connectionEpoch: snapshot.connectionEpoch,
                    preparationGroupID: group.preparationGroupID,
                    state: .ready
                )
            }
            if let attempt = snapshot.attempts.first(where: {
                $0.identity.preparationGroupID == group.preparationGroupID
            }) {
                let progress = try PreparationProgressV1(
                    phase: wirePhase(attempt.phase),
                    phaseSequence: 0,
                    preparationAttemptID: attempt.identity.preparationAttemptID,
                    preparationGroupID: group.preparationGroupID,
                    stateRevision: stateRevision
                )
                return try PreparationStatusV1(
                    capabilityIDs: capabilityIDs,
                    connectionEpoch: attempt.identity.connectionEpoch,
                    phase: progress.phase,
                    preparationAttemptID: attempt.identity.preparationAttemptID,
                    preparationGroupID: group.preparationGroupID,
                    progress: progress,
                    state: statusState(attempt.phase)
                )
            }
            if let error = lastErrors[group.preparationGroupID] {
                return try PreparationStatusV1(
                    capabilityIDs: capabilityIDs,
                    connectionEpoch: snapshot.connected
                        ? snapshot.connectionEpoch
                        : nil,
                    lastError: error,
                    preparationGroupID: group.preparationGroupID,
                    state: .unavailable
                )
            }
            return try PreparationStatusV1(
                capabilityIDs: capabilityIDs,
                connectionEpoch: snapshot.connected ? snapshot.connectionEpoch : nil,
                preparationGroupID: group.preparationGroupID,
                state: .unknown
            )
        }
    }

    public mutating func drainProgress() -> [(
        requestID: CanonicalUUID,
        progress: PreparationProgressV1
    )] {
        output.drainProgress()
    }

    public mutating func drainTerminals() -> [PrepareCapabilitiesTerminal] {
        output.drainTerminals()
    }

    public static func mappedProtocolError(
        _ error: ControlDispatcherError
    ) -> StandardErrorV1<PreparationErrorDetailsV1>? {
        guard case .requestTracking(.duplicateRequestID) = error else {
            return nil
        }
        return StandardErrorV1(code: "protocolViolation")
    }

    private func terminal(
        requestID: CanonicalUUID,
        request: ActiveRequest,
        observerTerminal: PrepareObserverTerminal,
        successProjection: PreparationSuccessProjection?
    ) throws -> PrepareCapabilitiesTerminal {
        switch observerTerminal {
        case .attempt(.ready):
            guard let successProjection else {
                throw PrepareCapabilitiesControlError.missingSuccessProjection
            }
            return try successTerminal(
                requestID: requestID,
                actionID: request.actionID,
                parentActionID: request.parentActionID,
                value: successResult(
                    groupID: request.identity.preparationGroupID,
                    disposition: .ready,
                    identity: request.identity,
                    projection: successProjection
                )
            )
        case .attempt(.unavailable(let reason)):
            let mapped = mapUnavailable(reason)
            return try failureTerminal(
                requestID: requestID,
                actionID: request.actionID,
                parentActionID: request.parentActionID,
                outcome: .failed,
                code: mapped.code,
                details: mapped.details
            )
        case .attempt(.deviceDisconnected):
            return try failureTerminal(
                requestID: requestID,
                actionID: request.actionID,
                parentActionID: request.parentActionID,
                outcome: .failed,
                code: "deviceDisconnected",
                details: PreparationErrorDetailsV1()
            )
        case .outcomeUnknown(let reason, let runtimeMayContinue, _):
            return try failureTerminal(
                requestID: requestID,
                actionID: request.actionID,
                parentActionID: request.parentActionID,
                outcome: .outcomeUnknown,
                code: "outcomeUnknown",
                details: PreparationErrorDetailsV1(
                    reason: reason,
                    runtimeMayContinue: runtimeMayContinue
                )
            )
        case .released(let reason):
            return try failureTerminal(
                requestID: requestID,
                actionID: request.actionID,
                parentActionID: request.parentActionID,
                outcome: .outcomeUnknown,
                code: "outcomeUnknown",
                details: PreparationErrorDetailsV1(
                    reason: reason.rawValue,
                    runtimeMayContinue: true
                )
            )
        }
    }

    private func successResult(
        groupID: String,
        disposition: PreparationResultDisposition,
        identity: PreparationAttemptIdentity?,
        projection: PreparationSuccessProjection
    ) throws -> PreparationResultV1 {
        guard let group = groups[groupID] else {
            throw PreparationCoordinatorError.unsupportedPreparationGroup
        }
        return try PreparationResultV1(
            assetDisposition: projection.assetDisposition,
            capabilityIDs: sortedASCII(group.requiredCapabilityIDs),
            connectionEpoch: identity?.connectionEpoch
                ?? coordinator.snapshot.connectionEpoch,
            disposition: disposition,
            executorGeneration: identity?.executorGeneration,
            mountDisposition: projection.mountDisposition,
            preparationAttemptID: identity?.preparationAttemptID,
            preparationGroupID: groupID,
            provenance: projection.provenance,
            serviceDisposition: projection.serviceDisposition
        )
    }

    private func successTerminal(
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        parentActionID: CanonicalUUID?,
        value: PreparationResultV1
    ) throws -> PrepareCapabilitiesTerminal {
        PrepareCapabilitiesTerminal(
            actionID: actionID,
            parentActionID: parentActionID,
            requestID: requestID,
            result: try StandardResultV1(
                outcome: .succeeded,
                commitState: .notCommitted,
                value: value
            )
        )
    }

    private func failureTerminal(
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        parentActionID: CanonicalUUID?,
        outcome: StandardOutcome,
        code: String,
        details: PreparationErrorDetailsV1
    ) throws -> PrepareCapabilitiesTerminal {
        PrepareCapabilitiesTerminal(
            actionID: actionID,
            parentActionID: parentActionID,
            requestID: requestID,
            result: try StandardResultV1(
                outcome: outcome,
                commitState: .notCommitted,
                error: StandardErrorV1(code: code, details: details)
            )
        )
    }

    private func mapUnavailable(
        _ reason: String
    ) -> (code: String, details: PreparationErrorDetailsV1) {
        if reason.hasPrefix("preparationTimeout:") {
            return (
                "preparationTimeout",
                PreparationErrorDetailsV1(
                    phase: String(reason.dropFirst("preparationTimeout:".count))
                )
            )
        }
        let allowed: Set<String> = [
            "capabilityUnavailable",
            "developerImageCacheCapacityExceeded",
            "developerImageCandidateIncompatible",
            "developerImageCatalogMismatch",
            "developerImageCatalogUnavailable",
            "developerImageDownloadFailed",
            "developerImageIntegrityFailed",
            "developerImageMountFailed",
            "developerModeRequired",
            "developerServicesUnavailable",
            "developerSupportUnavailable",
            "deviceDisconnected",
            "deviceLocked",
            "deviceNotTrusted",
            "personalizationServiceUnavailable",
            "matchingDDIUnavailable",
            "preparationFailed",
            "preparationTimeout",
            "runtimeFailed",
            "runtimeStopping",
            "unsupportedPreparationGroup",
        ]
        return allowed.contains(reason)
            ? (reason, PreparationErrorDetailsV1())
            : ("preparationFailed", PreparationErrorDetailsV1(reason: reason))
    }

    private func wirePhase(
        _ phase: PreparationAttemptPhase
    ) -> PreparationWirePhase {
        switch phase {
        case .created:
            .checkingDevice
        case .queryingMountedImage:
            .queryingMountedImage
        case .resolvingDeveloperSupport:
            .resolvingDeveloperSupport
        case .waitingForAcquisitionSlot:
            .waitingForAcquisitionSlot
        case .waitingForSharedAcquisition:
            .waitingForSharedAcquisition
        case .downloading:
            .downloading
        case .validating:
            .validating
        case .extracting:
            .extracting
        case .waitingForDeviceClaims, .waitingForGenerationClaims:
            .deviceClaimWait
        case .personalizing:
            .personalizing
        case .uploading:
            .uploading
        case .mounting:
            .mounting
        case .startingGeneration:
            .startingDeviceServices
        case .probingServices:
            .probingServices
        case .terminalReady:
            .ready
        case .terminalUnavailable, .terminalDisconnected:
            .checkingDevice
        }
    }

    private func statusState(
        _ phase: PreparationAttemptPhase
    ) -> PreparationStatusState {
        switch phase {
        case .resolvingDeveloperSupport, .waitingForAcquisitionSlot,
             .waitingForSharedAcquisition, .downloading, .validating, .extracting:
            .acquiring
        case .terminalReady:
            .ready
        case .terminalUnavailable, .terminalDisconnected:
            .unavailable
        default:
            .preparingDevice
        }
    }

    private func sortedASCII(_ values: [String]) -> [String] {
        Array(Set(values)).sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }
    }
}
