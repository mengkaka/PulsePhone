import PulsePhoneCommandPlanner
import PulsePhoneSharedDefinitions

public enum RuntimeCoordinationError: Error, Equatable, Sendable {
    case invalidLifecycleTransition
    case invalidConnectionState
    case invalidIdentifier
    case capacityExceeded
    case staleBoundary
    case revisionOverflow
}

public struct RuntimeCallbackIdentity: Equatable, Sendable {
    public let runtimeEpoch: UInt64
    public let connectionEpoch: UInt64?
    public let executorGeneration: UInt64?
    public let preparationAttemptID: String?
    public let attemptID: String?
    public let deliveryAttemptID: String?

    public init(
        runtimeEpoch: UInt64,
        connectionEpoch: UInt64? = nil,
        executorGeneration: UInt64? = nil,
        preparationAttemptID: String? = nil,
        attemptID: String? = nil,
        deliveryAttemptID: String? = nil
    ) {
        self.runtimeEpoch = runtimeEpoch
        self.connectionEpoch = connectionEpoch
        self.executorGeneration = executorGeneration
        self.preparationAttemptID = preparationAttemptID
        self.attemptID = attemptID
        self.deliveryAttemptID = deliveryAttemptID
    }
}

public enum RuntimeExternalBoundaryKind: String, Equatable, Sendable {
    case helperIO
    case deviceIO
    case socketIO
    case fileIO
}

public struct RuntimeExternalBoundaryToken: Equatable, Sendable {
    public let boundaryID: CanonicalUUID
    public let kind: RuntimeExternalBoundaryKind
    public let identity: RuntimeCallbackIdentity
    public let openedAtStateRevision: StateRevision
}

public enum RuntimeBoundaryCommit: Sendable {
    case noStateChange
    case condition(locked: Bool, trusted: Bool, liveAttached: Bool)
    case capabilities([String: CapabilityAvailability])
    case preparation([String: RuntimePreparationState])
    case geometry(DisplayGeometrySnapshot?)
}

public enum RuntimeCallbackDisposition: Equatable, Sendable {
    case committed(RuntimeStateSnapshot)
    case stale(RuntimeStateSnapshot)
}

public actor RuntimeCoordinationActor {
    private let canonicalUDID: CanonicalUDID
    private let runtimeEpoch: UInt64
    private let processID: Int32
    private let boundaryIDFactory: @Sendable () -> CanonicalUUID

    private var lifecycleState: RuntimeLifecycleState = .starting
    private var terminationCause: RuntimeTerminationCause?
    private var connected = false
    private var connectionEpoch: UInt64?
    private var facts: DeviceFactsSnapshot?
    private var locked = false
    private var trusted = false
    private var liveAttached = false
    private var capabilities = [String: CapabilityAvailability]()
    private var preparations = [String: RuntimePreparationState]()
    private var geometry: DisplayGeometrySnapshot?
    private var revisions = RuntimeStateRevisions()
    private var activeBoundaries = [CanonicalUUID: RuntimeExternalBoundaryToken]()

    public init(
        canonicalUDID: CanonicalUDID,
        runtimeEpoch: UInt64,
        processID: Int32,
        boundaryIDFactory: @escaping @Sendable () -> CanonicalUUID
    ) {
        self.canonicalUDID = canonicalUDID
        self.runtimeEpoch = runtimeEpoch
        self.processID = processID
        self.boundaryIDFactory = boundaryIDFactory
    }

    public func snapshot() -> RuntimeStateSnapshot {
        makeSnapshot()
    }

    public func markReady() throws -> RuntimeStateSnapshot {
        guard lifecycleState == .starting else {
            throw RuntimeCoordinationError.invalidLifecycleTransition
        }
        lifecycleState = .ready
        try advanceStateRevision()
        return makeSnapshot()
    }

    public func beginQuiescing() throws -> RuntimeStateSnapshot {
        guard lifecycleState == .ready else {
            throw RuntimeCoordinationError.invalidLifecycleTransition
        }
        lifecycleState = .quiescing
        try advance(revision: &revisions.quiescing)
        try advanceStateRevision()
        return makeSnapshot()
    }

    public func markStopped(
        cause: RuntimeTerminationCause
    ) throws -> RuntimeStateSnapshot {
        guard lifecycleState == .quiescing else {
            throw RuntimeCoordinationError.invalidLifecycleTransition
        }
        lifecycleState = .stopped
        terminationCause = cause
        try advanceStateRevision()
        return makeSnapshot()
    }

    public func updateConnection(
        connected: Bool,
        connectionEpoch: UInt64,
        facts: DeviceFactsSnapshot?
    ) throws -> RuntimeStateSnapshot {
        guard lifecycleState == .ready || lifecycleState == .quiescing else {
            throw RuntimeCoordinationError.invalidLifecycleTransition
        }
        guard connected || facts == nil else {
            throw RuntimeCoordinationError.invalidConnectionState
        }
        try validateFacts(facts)
        if let currentEpoch = self.connectionEpoch {
            guard connectionEpoch >= currentEpoch else {
                throw RuntimeCoordinationError.invalidConnectionState
            }
            if self.connected != connected {
                guard connectionEpoch > currentEpoch else {
                    throw RuntimeCoordinationError.invalidConnectionState
                }
            }
        }
        let connectionChanged = self.connected != connected
            || self.connectionEpoch != connectionEpoch
        let factsChanged = self.facts != facts
        guard !factsChanged || connectionChanged else {
            throw RuntimeCoordinationError.invalidConnectionState
        }
        guard connectionChanged || factsChanged else {
            return makeSnapshot()
        }
        let capabilitiesInvalidated = !connected && !capabilities.isEmpty
        let preparationsInvalidated = !connected && !preparations.isEmpty
        let geometryInvalidated = !connected && geometry != nil
        self.connected = connected
        self.connectionEpoch = connectionEpoch
        self.facts = facts
        if !connected {
            capabilities.removeAll()
            preparations.removeAll()
            geometry = nil
        }
        if connectionChanged {
            try advance(revision: &revisions.connection)
        }
        if factsChanged {
            try advance(revision: &revisions.facts)
        }
        if capabilitiesInvalidated {
            try advance(revision: &revisions.capability)
        }
        if preparationsInvalidated {
            try advance(revision: &revisions.preparation)
        }
        if geometryInvalidated {
            try advance(revision: &revisions.geometry)
        }
        try advanceStateRevision()
        return makeSnapshot()
    }

    public func updateCondition(
        locked: Bool,
        trusted: Bool,
        liveAttached: Bool
    ) throws -> RuntimeStateSnapshot {
        try requireMutableLifecycle()
        guard self.locked != locked
                || self.trusted != trusted
                || self.liveAttached != liveAttached
        else {
            return makeSnapshot()
        }
        self.locked = locked
        self.trusted = trusted
        self.liveAttached = liveAttached
        try advance(revision: &revisions.condition)
        try advanceStateRevision()
        return makeSnapshot()
    }

    public func updateCapabilities(
        _ values: [String: CapabilityAvailability]
    ) throws -> RuntimeStateSnapshot {
        try requireMutableLifecycle()
        guard values.count <= 256 else {
            throw RuntimeCoordinationError.capacityExceeded
        }
        try validateIdentifiers(values.keys)
        try validateCapabilityValues(values.values)
        guard connected || values.isEmpty else {
            throw RuntimeCoordinationError.invalidConnectionState
        }
        guard capabilities != values else {
            return makeSnapshot()
        }
        capabilities = values
        try advance(revision: &revisions.capability)
        try advanceStateRevision()
        return makeSnapshot()
    }

    public func updatePreparations(
        _ values: [String: RuntimePreparationState]
    ) throws -> RuntimeStateSnapshot {
        try requireMutableLifecycle()
        guard values.count <= 8 else {
            throw RuntimeCoordinationError.capacityExceeded
        }
        try validateIdentifiers(values.keys)
        guard preparations != values else {
            return makeSnapshot()
        }
        preparations = values
        try advance(revision: &revisions.preparation)
        try advanceStateRevision()
        return makeSnapshot()
    }

    public func updateGeometry(
        _ value: DisplayGeometrySnapshot?
    ) throws -> RuntimeStateSnapshot {
        try requireMutableLifecycle()
        guard connected || value == nil else {
            throw RuntimeCoordinationError.invalidConnectionState
        }
        guard geometry != value else {
            return makeSnapshot()
        }
        geometry = value
        try advance(revision: &revisions.geometry)
        try advanceStateRevision()
        return makeSnapshot()
    }

    public func beginExternalBoundary(
        kind: RuntimeExternalBoundaryKind,
        identity: RuntimeCallbackIdentity
    ) throws -> RuntimeExternalBoundaryToken {
        guard identity.runtimeEpoch == runtimeEpoch,
              identity.connectionEpoch == nil
                || identity.connectionEpoch == connectionEpoch
        else {
            throw RuntimeCoordinationError.staleBoundary
        }
        try validateCallbackIdentity(identity)
        let token = RuntimeExternalBoundaryToken(
            boundaryID: boundaryIDFactory(),
            kind: kind,
            identity: identity,
            openedAtStateRevision: revisions.state
        )
        guard activeBoundaries[token.boundaryID] == nil else {
            throw RuntimeCoordinationError.invalidIdentifier
        }
        activeBoundaries[token.boundaryID] = token
        try advanceStateRevision()
        return token
    }

    public func commitExternalBoundary(
        _ token: RuntimeExternalBoundaryToken,
        commit: RuntimeBoundaryCommit
    ) throws -> RuntimeCallbackDisposition {
        guard let active = activeBoundaries[token.boundaryID], active == token else {
            return .stale(makeSnapshot())
        }
        activeBoundaries.removeValue(forKey: token.boundaryID)
        let currentIdentity = token.identity.runtimeEpoch == runtimeEpoch
            && (token.identity.connectionEpoch == nil
                || token.identity.connectionEpoch == connectionEpoch)
        guard currentIdentity else {
            try advanceStateRevision()
            return .stale(makeSnapshot())
        }

        let stateBeforeCommit = revisions.state
        switch commit {
        case .noStateChange:
            try advanceStateRevision()
        case .condition(let locked, let trusted, let liveAttached):
            _ = try updateCondition(
                locked: locked,
                trusted: trusted,
                liveAttached: liveAttached
            )
            if stateBeforeCommit == revisions.state {
                try advanceStateRevision()
            }
        case .capabilities(let values):
            _ = try updateCapabilities(values)
            if stateBeforeCommit == revisions.state {
                try advanceStateRevision()
            }
        case .preparation(let values):
            _ = try updatePreparations(values)
            if stateBeforeCommit == revisions.state {
                try advanceStateRevision()
            }
        case .geometry(let value):
            _ = try updateGeometry(value)
            if stateBeforeCommit == revisions.state {
                try advanceStateRevision()
            }
        }
        return .committed(makeSnapshot())
    }

    private func makeSnapshot() -> RuntimeStateSnapshot {
        RuntimeStateSnapshot(
            canonicalUDID: canonicalUDID,
            runtimeEpoch: runtimeEpoch,
            processID: processID,
            lifecycleState: lifecycleState,
            terminationCause: terminationCause,
            connected: connected,
            connectionEpoch: connectionEpoch,
            facts: facts,
            condition: DeviceConditionSnapshot(
                connected: connected,
                liveAttached: liveAttached,
                locked: locked,
                runtimeConnectionState: .compatible,
                trusted: trusted
            ),
            capabilities: capabilities.keys.sorted().map {
                RuntimeCapabilityEntry(
                    capabilityID: $0,
                    availability: capabilities[$0]!
                )
            },
            preparations: preparations.keys.sorted().map {
                RuntimePreparationEntry(
                    preparationGroupID: $0,
                    state: preparations[$0]!
                )
            },
            geometry: geometry,
            activeExternalBoundaryCount: activeBoundaries.count,
            revisions: revisions
        )
    }

    private func validateIdentifiers<S: Sequence>(
        _ identifiers: S
    ) throws where S.Element == String {
        guard identifiers.allSatisfy({ identifier in
            let bytes = Array(identifier.utf8)
            return (1...256).contains(bytes.count)
                && bytes.allSatisfy { (0x21...0x7e).contains($0) }
        }) else {
            throw RuntimeCoordinationError.invalidIdentifier
        }
    }

    private func validateFacts(_ facts: DeviceFactsSnapshot?) throws {
        guard let facts else {
            return
        }
        guard facts.transportIDs.count <= 16 else {
            throw RuntimeCoordinationError.capacityExceeded
        }
        try validateIdentifiers([facts.deviceClass])
        try validateIdentifiers(facts.transportIDs)
    }

    private func validateCapabilityValues<S: Sequence>(
        _ values: S
    ) throws where S.Element == CapabilityAvailability {
        for value in values {
            if case .unavailable(let reason) = value {
                try validateIdentifiers([reason])
            }
        }
    }

    private func validateCallbackIdentity(
        _ identity: RuntimeCallbackIdentity
    ) throws {
        try validateIdentifiers([
            identity.preparationAttemptID,
            identity.attemptID,
            identity.deliveryAttemptID,
        ].compactMap { $0 })
    }

    private func requireMutableLifecycle() throws {
        guard lifecycleState == .ready || lifecycleState == .quiescing else {
            throw RuntimeCoordinationError.invalidLifecycleTransition
        }
    }

    private func advance(revision: inout StateRevision) throws {
        do {
            revision = try revision.advanced()
        } catch {
            throw RuntimeCoordinationError.revisionOverflow
        }
    }

    private func advanceStateRevision() throws {
        try advance(revision: &revisions.state)
    }
}
