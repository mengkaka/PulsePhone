import PulsePhoneSharedDefinitions

public enum OperationPhase: String, Equatable, Sendable {
    case received
    case planning
    case awaitingCapability
    case pending
    case running
    case cleaning
    case terminal
}

public enum StreamLifecycleSubstate: String, Equatable, Sendable {
    case opening
    case open
    case closing
}

public enum OperationAcceptedBoundary: String, Equatable, Sendable {
    case pending
    case running
}

public enum OperationLifecycleError: Error, Equatable, Sendable {
    case invalidTransition(from: OperationPhase, to: OperationPhase)
    case actionIdentityAlreadyAssigned
    case actionIdentityMissing
    case invalidIdentifier
    case invalidBindings
    case streamSubstateRequired
    case streamSubstateForbidden
    case cleanupRequired
    case cleanupNotRequired
    case invalidPreRunningOutcome
}

public struct OperationRuntimeBindings: Equatable, Sendable {
    public let attemptID: String
    public let executorGeneration: UInt64
    public let leaseIDs: [String]

    public init(
        attemptID: String,
        executorGeneration: UInt64,
        leaseIDs: [String]
    ) throws {
        guard Self.validIdentifier(attemptID),
              !leaseIDs.isEmpty,
              leaseIDs == leaseIDs.sorted(),
              Set(leaseIDs).count == leaseIDs.count,
              leaseIDs.allSatisfy(Self.validIdentifier)
        else {
            throw OperationLifecycleError.invalidBindings
        }
        self.attemptID = attemptID
        self.executorGeneration = executorGeneration
        self.leaseIDs = leaseIDs
    }

    private static func validIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...256).contains(bytes.count)
            && bytes.allSatisfy { (0x21...0x7e).contains($0) }
    }
}

public struct OperationCleaningContext: Equatable, Sendable {
    public let commitState: CommitState
    public let terminalCause: OperationTerminalCause
    public let bindings: OperationRuntimeBindings
}

public enum CleaningStartDisposition: Equatable, Sendable {
    case started(OperationCleaningContext)
    case joined(OperationCleaningContext)
    case alreadyTerminal(AtomicTerminalBundle)
}

public struct OperationLifecycleSnapshot: Equatable, Sendable {
    public let requestID: CanonicalUUID
    public let executionKind: OperationExecutionKind
    public let phase: OperationPhase
    public let streamSubstate: StreamLifecycleSubstate?
    public let actionID: CanonicalUUID?
    public let acceptedBoundary: OperationAcceptedBoundary?
    public let inhibitorTokenID: String?
    public let runtimeBindings: OperationRuntimeBindings?
    public let cleaningContext: OperationCleaningContext?
    public let terminalBundle: AtomicTerminalBundle?
}

public struct OperationLifecycle: Sendable {
    public let requestID: CanonicalUUID
    public let executionKind: OperationExecutionKind

    private var phase: OperationPhase = .received
    private var streamSubstate: StreamLifecycleSubstate?
    private var actionID: CanonicalUUID?
    private var acceptedBoundary: OperationAcceptedBoundary?
    private var inhibitorTokenID: String?
    private var runtimeBindings: OperationRuntimeBindings?
    private var cleaningContext: OperationCleaningContext?
    private var terminalBundle: AtomicTerminalBundle?

    public init(
        requestID: CanonicalUUID,
        executionKind: OperationExecutionKind
    ) {
        self.requestID = requestID
        self.executionKind = executionKind
    }

    public var snapshot: OperationLifecycleSnapshot {
        OperationLifecycleSnapshot(
            requestID: requestID,
            executionKind: executionKind,
            phase: phase,
            streamSubstate: streamSubstate,
            actionID: actionID,
            acceptedBoundary: acceptedBoundary,
            inhibitorTokenID: inhibitorTokenID,
            runtimeBindings: runtimeBindings,
            cleaningContext: cleaningContext,
            terminalBundle: terminalBundle
        )
    }

    @discardableResult
    public mutating func beginPlanning(
        actionID: CanonicalUUID
    ) throws -> OperationLifecycleSnapshot {
        guard phase == .received else {
            throw invalidTransition(to: .planning)
        }
        guard self.actionID == nil else {
            throw OperationLifecycleError.actionIdentityAlreadyAssigned
        }
        self.actionID = actionID
        phase = .planning
        return snapshot
    }

    @discardableResult
    public mutating func awaitCapability() throws -> OperationLifecycleSnapshot {
        guard executionKind == .oneShot else {
            throw OperationLifecycleError.streamSubstateForbidden
        }
        guard phase == .planning else {
            throw invalidTransition(to: .awaitingCapability)
        }
        phase = .awaitingCapability
        return snapshot
    }

    @discardableResult
    public mutating func resumePlanning() throws -> OperationLifecycleSnapshot {
        guard phase == .awaitingCapability else {
            throw invalidTransition(to: .planning)
        }
        phase = .planning
        return snapshot
    }

    @discardableResult
    public mutating func acceptPending(
        inhibitorTokenID: String
    ) throws -> OperationLifecycleSnapshot {
        guard executionKind == .oneShot else {
            throw OperationLifecycleError.streamSubstateForbidden
        }
        guard phase == .planning else {
            throw invalidTransition(to: .pending)
        }
        try assignAcceptedOwnership(
            boundary: .pending,
            inhibitorTokenID: inhibitorTokenID
        )
        phase = .pending
        return snapshot
    }

    @discardableResult
    public mutating func acceptRunning(
        inhibitorTokenID: String,
        bindings: OperationRuntimeBindings
    ) throws -> OperationLifecycleSnapshot {
        guard phase == .planning else {
            throw invalidTransition(to: .running)
        }
        try assignAcceptedOwnership(
            boundary: .running,
            inhibitorTokenID: inhibitorTokenID
        )
        runtimeBindings = bindings
        phase = .running
        streamSubstate = executionKind == .stream ? .opening : nil
        return snapshot
    }

    @discardableResult
    public mutating func startRunning(
        bindings: OperationRuntimeBindings
    ) throws -> OperationLifecycleSnapshot {
        guard executionKind == .oneShot else {
            throw OperationLifecycleError.streamSubstateForbidden
        }
        guard phase == .pending else {
            throw invalidTransition(to: .running)
        }
        runtimeBindings = bindings
        phase = .running
        return snapshot
    }

    @discardableResult
    public mutating func markStreamOpen() throws -> OperationLifecycleSnapshot {
        guard executionKind == .stream else {
            throw OperationLifecycleError.streamSubstateRequired
        }
        guard phase == .running, streamSubstate == .opening else {
            throw invalidTransition(to: .running)
        }
        streamSubstate = .open
        return snapshot
    }

    public mutating func beginCleaning(
        commitState: CommitState,
        terminalCause: OperationTerminalCause
    ) throws -> CleaningStartDisposition {
        if let terminalBundle {
            return .alreadyTerminal(terminalBundle)
        }
        if let cleaningContext {
            return .joined(cleaningContext)
        }
        guard phase == .running, let runtimeBindings else {
            throw OperationLifecycleError.cleanupNotRequired
        }
        let context = OperationCleaningContext(
            commitState: commitState,
            terminalCause: terminalCause,
            bindings: runtimeBindings
        )
        cleaningContext = context
        phase = .cleaning
        if executionKind == .stream {
            streamSubstate = .closing
        }
        return .started(context)
    }

    public mutating func commitPreRunningTerminal(
        outcome: StandardOutcome,
        terminalCause: OperationTerminalCause,
        resultDelivery: OperationResultDelivery,
        actionIDIfNeeded: CanonicalUUID? = nil
    ) throws -> TerminalCommitDisposition {
        if let terminalBundle {
            return .alreadyTerminal(terminalBundle)
        }
        switch phase {
        case .received, .planning, .awaitingCapability, .pending:
            break
        case .running, .cleaning:
            throw OperationLifecycleError.cleanupRequired
        case .terminal:
            preconditionFailure("terminal phase requires bundle")
        }
        switch outcome {
        case .failed, .cancelled, .outcomeUnknown:
            break
        case .succeeded, .partial:
            throw OperationLifecycleError.invalidPreRunningOutcome
        }
        if actionID == nil {
            guard let actionIDIfNeeded else {
                throw OperationLifecycleError.actionIdentityMissing
            }
            actionID = actionIDIfNeeded
        } else if let actionIDIfNeeded, actionIDIfNeeded != actionID {
            throw OperationLifecycleError.actionIdentityAlreadyAssigned
        }
        let bundle = try makeTerminalBundle(
            outcome: outcome,
            commitState: .notCommitted,
            terminalCause: terminalCause,
            resultDelivery: resultDelivery,
            cleanupDisposition: .notRequired,
            releasedLeaseIDs: [],
            releasedInhibitorTokenID: inhibitorTokenID
        )
        commitTerminal(bundle)
        return .committed(bundle)
    }

    public mutating func completeCleanup(
        outcome: StandardOutcome,
        resultDelivery: OperationResultDelivery,
        cleanupDisposition: OperationCleanupDisposition
    ) throws -> TerminalCommitDisposition {
        if let terminalBundle {
            return .alreadyTerminal(terminalBundle)
        }
        guard phase == .cleaning, let cleaningContext else {
            throw OperationLifecycleError.cleanupNotRequired
        }
        guard cleanupDisposition == .acknowledged
                || cleanupDisposition == .fenced
        else {
            throw OperationLifecycleError.cleanupRequired
        }
        let bundle = try makeTerminalBundle(
            outcome: outcome,
            commitState: cleaningContext.commitState,
            terminalCause: cleaningContext.terminalCause,
            resultDelivery: resultDelivery,
            cleanupDisposition: cleanupDisposition,
            releasedLeaseIDs: cleaningContext.bindings.leaseIDs,
            releasedInhibitorTokenID: inhibitorTokenID
        )
        commitTerminal(bundle)
        return .committed(bundle)
    }

    private mutating func assignAcceptedOwnership(
        boundary: OperationAcceptedBoundary,
        inhibitorTokenID: String
    ) throws {
        guard actionID != nil else {
            throw OperationLifecycleError.actionIdentityMissing
        }
        guard Self.validIdentifier(inhibitorTokenID) else {
            throw OperationLifecycleError.invalidIdentifier
        }
        acceptedBoundary = boundary
        self.inhibitorTokenID = inhibitorTokenID
    }

    private func makeTerminalBundle(
        outcome: StandardOutcome,
        commitState: CommitState,
        terminalCause: OperationTerminalCause,
        resultDelivery: OperationResultDelivery,
        cleanupDisposition: OperationCleanupDisposition,
        releasedLeaseIDs: [String],
        releasedInhibitorTokenID: String?
    ) throws -> AtomicTerminalBundle {
        guard let actionID else {
            throw OperationLifecycleError.actionIdentityMissing
        }
        return AtomicTerminalBundle(
            requestID: requestID,
            actionID: actionID,
            executionKind: executionKind,
            accepted: acceptedBoundary != nil,
            outcome: outcome,
            commitState: commitState,
            terminalCause: terminalCause,
            resultDelivery: resultDelivery,
            cleanupDisposition: cleanupDisposition,
            releasedLeaseIDs: releasedLeaseIDs,
            releasedInhibitorTokenID: releasedInhibitorTokenID
        )
    }

    private mutating func commitTerminal(_ bundle: AtomicTerminalBundle) {
        terminalBundle = bundle
        phase = .terminal
        streamSubstate = nil
        inhibitorTokenID = nil
        runtimeBindings = nil
        cleaningContext = nil
    }

    private func invalidTransition(
        to target: OperationPhase
    ) -> OperationLifecycleError {
        .invalidTransition(from: phase, to: target)
    }

    private static func validIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...256).contains(bytes.count)
            && bytes.allSatisfy { (0x21...0x7e).contains($0) }
    }
}
