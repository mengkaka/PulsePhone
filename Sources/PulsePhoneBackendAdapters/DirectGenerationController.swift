public enum DirectGenerationState: String, Equatable, Sendable {
    case spawning
    case handshaking
    case running
    case cleaning
    case reaping
    case retired
}

public enum DirectGenerationControllerError: Error, Equatable, Sendable {
    case invalidIdentifier
    case noActiveConnection
    case wrongConnectionEpoch
    case runtimeNotAcceptingWork
    case invalidTransition
    case requestMismatch
    case generationOverflow
}

public struct DirectGenerationSnapshot: Equatable, Sendable {
    public let identity: DirectGenerationIdentity
    public let state: DirectGenerationState
    public let operationKind: DirectGenerationOperationKind
    public let requestID: String
    public let attemptID: String
    public let exclusiveClaimIDs: [String]
}

public struct DirectProcessSlotSnapshot: Equatable, Sendable {
    public let runtimeEpoch: UInt64
    public let connectionEpoch: UInt64?
    public let activeGeneration: DirectGenerationSnapshot?
    public let acceptingWork: Bool
    public let nextExecutorGeneration: UInt64
}

public enum DirectSlotClaimDisposition: Equatable, Sendable {
    case claimed(DirectGenerationCommand, DirectProcessSlotSnapshot)
    case busy(DirectGenerationSnapshot, DirectProcessSlotSnapshot)
}

public enum DirectGenerationCallbackDisposition: Equatable, Sendable {
    case advance(DirectGenerationCommand, DirectProcessSlotSnapshot)
    case completed(DirectGenerationSnapshot, DirectProcessSlotSnapshot)
    case staleIgnored(DirectProcessSlotSnapshot)
}

public enum DirectAttachDisposition: Equatable, Sendable {
    case attached(DirectProcessSlotSnapshot)
    case unchanged(DirectProcessSlotSnapshot)
    case staleIgnored(DirectProcessSlotSnapshot)
    case cleanupRequired(DirectGenerationCommand, DirectProcessSlotSnapshot)
}

public struct DirectProcessSlotController: Sendable {
    private struct Record: Sendable {
        let identity: DirectGenerationIdentity
        var state: DirectGenerationState
        let operationKind: DirectGenerationOperationKind
        let requestID: String
        let attemptID: String

        var snapshot: DirectGenerationSnapshot {
            DirectGenerationSnapshot(
                identity: identity,
                state: state,
                operationKind: operationKind,
                requestID: requestID,
                attemptID: attemptID,
                exclusiveClaimIDs: operationKind.exclusiveClaimIDs
            )
        }
    }

    public let runtimeEpoch: UInt64
    private var connectionEpoch: UInt64?
    private var activeGeneration: Record?
    private var acceptingWork = true
    private var nextExecutorGeneration: UInt64

    public init(runtimeEpoch: UInt64, firstExecutorGeneration: UInt64 = 1) throws {
        guard firstExecutorGeneration > 0 else {
            throw DirectGenerationControllerError.generationOverflow
        }
        self.runtimeEpoch = runtimeEpoch
        self.nextExecutorGeneration = firstExecutorGeneration
    }

    public var snapshot: DirectProcessSlotSnapshot {
        DirectProcessSlotSnapshot(
            runtimeEpoch: runtimeEpoch,
            connectionEpoch: connectionEpoch,
            activeGeneration: activeGeneration?.snapshot,
            acceptingWork: acceptingWork,
            nextExecutorGeneration: nextExecutorGeneration
        )
    }

    @discardableResult
    public mutating func observeAttach(
        connectionEpoch: UInt64
    ) -> DirectAttachDisposition {
        guard connectionEpoch > 0 else {
            return .staleIgnored(snapshot)
        }
        if let current = self.connectionEpoch {
            if connectionEpoch < current {
                return .staleIgnored(snapshot)
            }
            if connectionEpoch == current {
                return .unchanged(snapshot)
            }
        }
        self.connectionEpoch = connectionEpoch
        guard let generation = activeGeneration else {
            return .attached(snapshot)
        }
        let command = beginCleanup(generation)
        return .cleanupRequired(command, snapshot)
    }

    public mutating func claim(
        operationKind: DirectGenerationOperationKind,
        requestID: String,
        attemptID: String,
        connectionEpoch: UInt64
    ) throws -> DirectSlotClaimDisposition {
        guard Self.validIdentifier(requestID), Self.validIdentifier(attemptID) else {
            throw DirectGenerationControllerError.invalidIdentifier
        }
        guard acceptingWork else {
            throw DirectGenerationControllerError.runtimeNotAcceptingWork
        }
        guard let currentEpoch = self.connectionEpoch else {
            throw DirectGenerationControllerError.noActiveConnection
        }
        guard connectionEpoch == currentEpoch else {
            throw DirectGenerationControllerError.wrongConnectionEpoch
        }
        if let activeGeneration {
            return .busy(activeGeneration.snapshot, snapshot)
        }

        let identity = DirectGenerationIdentity(
            runtimeEpoch: runtimeEpoch,
            connectionEpoch: connectionEpoch,
            executorGeneration: nextExecutorGeneration
        )
        let (next, overflow) = nextExecutorGeneration.addingReportingOverflow(1)
        guard !overflow, next > 0 else {
            throw DirectGenerationControllerError.generationOverflow
        }
        nextExecutorGeneration = next
        activeGeneration = Record(
            identity: identity,
            state: .spawning,
            operationKind: operationKind,
            requestID: requestID,
            attemptID: attemptID
        )
        return .claimed(
            DirectGenerationCommand(
                identity: identity,
                action: .spawnHelper,
                requestID: requestID
            ),
            snapshot
        )
    }

    public mutating func receiveHello(
        identity: DirectGenerationIdentity
    ) throws -> DirectGenerationCallbackDisposition {
        guard var generation = matching(identity) else {
            return .staleIgnored(snapshot)
        }
        if generation.state == .cleaning || generation.state == .reaping {
            return .staleIgnored(snapshot)
        }
        guard generation.state == .spawning else {
            throw DirectGenerationControllerError.invalidTransition
        }
        generation.state = .handshaking
        activeGeneration = generation
        return .advance(
            DirectGenerationCommand(
                identity: identity,
                action: .sendHelloAccepted,
                requestID: generation.requestID
            ),
            snapshot
        )
    }

    public mutating func receiveReady(
        identity: DirectGenerationIdentity
    ) throws -> DirectGenerationCallbackDisposition {
        guard var generation = matching(identity) else {
            return .staleIgnored(snapshot)
        }
        if generation.state == .cleaning || generation.state == .reaping {
            return .staleIgnored(snapshot)
        }
        guard generation.state == .handshaking else {
            throw DirectGenerationControllerError.invalidTransition
        }
        generation.state = .running
        activeGeneration = generation
        return .advance(
            DirectGenerationCommand(
                identity: identity,
                action: .sendRequest,
                requestID: generation.requestID
            ),
            snapshot
        )
    }

    public mutating func receiveResult(
        identity: DirectGenerationIdentity,
        requestID: String
    ) throws -> DirectGenerationCallbackDisposition {
        guard let generation = matching(identity) else {
            return .staleIgnored(snapshot)
        }
        guard generation.requestID == requestID else {
            throw DirectGenerationControllerError.requestMismatch
        }
        if generation.state == .cleaning || generation.state == .reaping {
            return .staleIgnored(snapshot)
        }
        guard generation.state == .running else {
            throw DirectGenerationControllerError.invalidTransition
        }
        let command = beginCleanup(generation)
        return .advance(command, snapshot)
    }

    public mutating func completeCleanup(
        identity: DirectGenerationIdentity,
        requestID: String
    ) throws -> DirectGenerationCallbackDisposition {
        guard var generation = matching(identity) else {
            return .staleIgnored(snapshot)
        }
        guard generation.requestID == requestID else {
            throw DirectGenerationControllerError.requestMismatch
        }
        if generation.state == .reaping {
            return .staleIgnored(snapshot)
        }
        guard generation.state == .cleaning else {
            throw DirectGenerationControllerError.invalidTransition
        }
        generation.state = .reaping
        activeGeneration = generation
        return .advance(
            DirectGenerationCommand(
                identity: identity,
                action: .reapHelper,
                requestID: requestID
            ),
            snapshot
        )
    }

    public mutating func completeReap(
        identity: DirectGenerationIdentity,
        requestID: String
    ) throws -> DirectGenerationCallbackDisposition {
        guard var generation = matching(identity) else {
            return .staleIgnored(snapshot)
        }
        guard generation.requestID == requestID else {
            throw DirectGenerationControllerError.requestMismatch
        }
        guard generation.state == .reaping else {
            throw DirectGenerationControllerError.invalidTransition
        }
        generation.state = .retired
        activeGeneration = nil
        return .completed(generation.snapshot, snapshot)
    }

    public mutating func observeDetach(
        connectionEpoch: UInt64
    ) -> DirectGenerationCallbackDisposition {
        guard self.connectionEpoch == connectionEpoch else {
            return .staleIgnored(snapshot)
        }
        self.connectionEpoch = nil
        guard let generation = activeGeneration else {
            return .staleIgnored(snapshot)
        }
        return .advance(beginCleanup(generation), snapshot)
    }

    public mutating func beginFatalShutdown(
    ) -> DirectGenerationCallbackDisposition {
        acceptingWork = false
        guard let generation = activeGeneration else {
            return .staleIgnored(snapshot)
        }
        return .advance(beginCleanup(generation), snapshot)
    }

    private func matching(_ identity: DirectGenerationIdentity) -> Record? {
        guard let activeGeneration,
              activeGeneration.identity == identity
        else {
            return nil
        }
        return activeGeneration
    }

    private mutating func beginCleanup(
        _ record: Record
    ) -> DirectGenerationCommand {
        var generation = record
        let action: DirectGenerationAction = generation.state == .reaping
            ? .reapHelper
            : .beginCleanup
        if generation.state != .cleaning && generation.state != .reaping {
            generation.state = .cleaning
            activeGeneration = generation
        }
        return DirectGenerationCommand(
            identity: generation.identity,
            action: action,
            requestID: generation.requestID
        )
    }

    private static func validIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...128).contains(bytes.count)
            && bytes.allSatisfy { (0x21...0x7e).contains($0) }
    }
}
