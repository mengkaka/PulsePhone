public enum ExecutorGenerationState: String, Equatable, Sendable {
    case preparing
    case ready
    case suspectDisconnect
    case draining
    case terminating
    case retired
}

public enum ExecutorGenerationFailure: String, Equatable, Sendable {
    case cleanupTimeout
    case fatalTransport
}

public enum ExecutorGenerationError: Error, Equatable, Sendable {
    case invalidTransition
    case invalidIdentity
    case duplicateOperation
    case operationNotBound
    case cleanupAlreadyStarted
    case cleanupRequired
    case activeWorkRemains
}

public struct ExecutorGenerationSnapshot: Equatable, Sendable {
    public let runtimeEpoch: UInt64
    public let connectionEpoch: UInt64
    public let executorGeneration: UInt64
    public let state: ExecutorGenerationState
    public let preparationAttemptID: String?
    public let boundOperationIDs: [String]
    public let pendingCleanupOperationIDs: [String]
    public let failure: ExecutorGenerationFailure?
}

public enum ExecutorCallbackDisposition: Equatable, Sendable {
    case stateCommitted(ExecutorGenerationSnapshot)
    case operationSettled(operationID: String, ExecutorGenerationSnapshot)
    case staleIgnored(ExecutorGenerationSnapshot)
}

public struct CleanupTimeoutResult: Equatable, Sendable {
    public let timedOutOperationIDs: [String]
    public let fencedOperationIDs: [String]
    public let fatalFailStopRequired: Bool
    public let snapshot: ExecutorGenerationSnapshot
}

public struct ExecutorGenerationController: Sendable {
    private struct OperationBinding: Equatable, Sendable {
        let operationID: String
        let attemptID: String
    }

    public let runtimeEpoch: UInt64
    public let connectionEpoch: UInt64
    public let executorGeneration: UInt64

    private var state: ExecutorGenerationState
    private var preparationAttemptID: String?
    private var operations = [String: OperationBinding]()
    private var cleanupHandoffs = [String: CleanupHandoff]()
    private var failure: ExecutorGenerationFailure?

    public init(
        runtimeEpoch: UInt64,
        connectionEpoch: UInt64,
        executorGeneration: UInt64,
        preparationAttemptID: String
    ) throws {
        let token = try FenceToken(
            runtimeEpoch: runtimeEpoch,
            connectionEpoch: connectionEpoch,
            executorGeneration: executorGeneration,
            preparationAttemptID: preparationAttemptID
        )
        self.runtimeEpoch = runtimeEpoch
        self.connectionEpoch = connectionEpoch
        self.executorGeneration = executorGeneration
        self.state = .preparing
        self.preparationAttemptID = token.preparationAttemptID
    }

    public var snapshot: ExecutorGenerationSnapshot {
        ExecutorGenerationSnapshot(
            runtimeEpoch: runtimeEpoch,
            connectionEpoch: connectionEpoch,
            executorGeneration: executorGeneration,
            state: state,
            preparationAttemptID: preparationAttemptID,
            boundOperationIDs: operations.keys.sorted(),
            pendingCleanupOperationIDs: cleanupHandoffs
                .filter { $0.value.state == .pending }
                .keys
                .sorted(),
            failure: failure
        )
    }

    public func preparationFenceToken() throws -> FenceToken {
        guard let preparationAttemptID else {
            throw ExecutorGenerationError.invalidIdentity
        }
        return try FenceToken(
            runtimeEpoch: runtimeEpoch,
            connectionEpoch: connectionEpoch,
            executorGeneration: executorGeneration,
            preparationAttemptID: preparationAttemptID
        )
    }

    @discardableResult
    public mutating func commitReady(
        callback token: FenceToken
    ) throws -> ExecutorCallbackDisposition {
        guard matchesGeneration(token),
              token.preparationAttemptID == preparationAttemptID,
              token.operationID == nil,
              state == .preparing
        else {
            return .staleIgnored(snapshot)
        }
        state = .ready
        return .stateCommitted(snapshot)
    }

    public mutating func bindOperation(
        operationID: String,
        attemptID: String
    ) throws -> FenceToken {
        guard state == .ready else {
            throw ExecutorGenerationError.invalidTransition
        }
        let token = try FenceToken(
            runtimeEpoch: runtimeEpoch,
            connectionEpoch: connectionEpoch,
            executorGeneration: executorGeneration,
            operationID: operationID,
            attemptID: attemptID
        )
        guard operations[operationID] == nil else {
            throw ExecutorGenerationError.duplicateOperation
        }
        operations[operationID] = OperationBinding(
            operationID: operationID,
            attemptID: attemptID
        )
        return token
    }

    @discardableResult
    public mutating func settleOperation(
        callback token: FenceToken
    ) -> ExecutorCallbackDisposition {
        guard let binding = matchingBinding(token),
              cleanupHandoffs[binding.operationID] == nil
        else {
            return .staleIgnored(snapshot)
        }
        operations.removeValue(forKey: binding.operationID)
        return .operationSettled(
            operationID: binding.operationID,
            snapshot
        )
    }

    public mutating func beginCleanup(
        callback token: FenceToken,
        startedAtNanoseconds: UInt64
    ) throws -> CleanupHandoff {
        guard let binding = matchingBinding(token) else {
            throw ExecutorGenerationError.operationNotBound
        }
        guard cleanupHandoffs[binding.operationID] == nil else {
            throw ExecutorGenerationError.cleanupAlreadyStarted
        }
        let handoff = try CleanupHandoff(
            operationID: binding.operationID,
            attemptID: binding.attemptID,
            executorGeneration: executorGeneration,
            startedAtNanoseconds: startedAtNanoseconds
        )
        cleanupHandoffs[binding.operationID] = handoff
        return handoff
    }

    @discardableResult
    public mutating func acknowledgeCleanup(
        callback token: FenceToken
    ) throws -> ExecutorCallbackDisposition {
        try resolveCleanup(callback: token, fenced: false)
    }

    @discardableResult
    public mutating func fenceCleanup(
        callback token: FenceToken
    ) throws -> ExecutorCallbackDisposition {
        try resolveCleanup(callback: token, fenced: true)
    }

    public mutating func evaluateCleanupTimeouts(
        at nowNanoseconds: UInt64
    ) -> CleanupTimeoutResult {
        var timedOut = [String]()
        for operationID in cleanupHandoffs.keys.sorted() {
            guard var handoff = cleanupHandoffs[operationID] else {
                continue
            }
            if handoff.evaluateTimeout(at: nowNanoseconds) {
                timedOut.append(operationID)
                cleanupHandoffs[operationID] = handoff
            }
        }
        guard !timedOut.isEmpty else {
            return CleanupTimeoutResult(
                timedOutOperationIDs: [],
                fencedOperationIDs: [],
                fatalFailStopRequired: false,
                snapshot: snapshot
            )
        }

        let fenced = operations.keys.sorted()
        operations.removeAll()
        cleanupHandoffs.removeAll()
        preparationAttemptID = nil
        failure = .cleanupTimeout
        state = .retired
        return CleanupTimeoutResult(
            timedOutOperationIDs: timedOut,
            fencedOperationIDs: fenced,
            fatalFailStopRequired: true,
            snapshot: snapshot
        )
    }

    @discardableResult
    public mutating func markSuspectDisconnect() throws -> ExecutorGenerationSnapshot {
        guard state == .ready else {
            throw ExecutorGenerationError.invalidTransition
        }
        state = .suspectDisconnect
        return snapshot
    }

    @discardableResult
    public mutating func confirmDeviceDisconnected() throws -> ExecutorGenerationSnapshot {
        guard state == .ready || state == .suspectDisconnect else {
            throw ExecutorGenerationError.invalidTransition
        }
        state = .draining
        preparationAttemptID = nil
        return snapshot
    }

    @discardableResult
    public mutating func confirmFatalTransport() throws -> ExecutorGenerationSnapshot {
        guard state == .suspectDisconnect else {
            throw ExecutorGenerationError.invalidTransition
        }
        failure = .fatalTransport
        preparationAttemptID = nil
        state = .terminating
        return snapshot
    }

    @discardableResult
    public mutating func beginTermination() throws -> ExecutorGenerationSnapshot {
        guard state == .preparing
                || state == .draining
                || state == .suspectDisconnect
        else {
            throw ExecutorGenerationError.invalidTransition
        }
        preparationAttemptID = nil
        state = .terminating
        return snapshot
    }

    @discardableResult
    public mutating func retire() throws -> ExecutorGenerationSnapshot {
        guard state == .terminating else {
            throw ExecutorGenerationError.invalidTransition
        }
        guard operations.isEmpty, cleanupHandoffs.isEmpty else {
            throw ExecutorGenerationError.activeWorkRemains
        }
        state = .retired
        return snapshot
    }

    private func matchesGeneration(_ token: FenceToken) -> Bool {
        token.runtimeEpoch == runtimeEpoch
            && token.connectionEpoch == connectionEpoch
            && token.executorGeneration == executorGeneration
    }

    private func matchingBinding(_ token: FenceToken) -> OperationBinding? {
        guard matchesGeneration(token),
              token.preparationAttemptID == nil,
              let operationID = token.operationID,
              let attemptID = token.attemptID,
              let binding = operations[operationID],
              binding.attemptID == attemptID
        else {
            return nil
        }
        return binding
    }

    private mutating func resolveCleanup(
        callback token: FenceToken,
        fenced: Bool
    ) throws -> ExecutorCallbackDisposition {
        guard let binding = matchingBinding(token),
              var handoff = cleanupHandoffs[binding.operationID]
        else {
            return .staleIgnored(snapshot)
        }
        if fenced {
            try handoff.fence()
        } else {
            try handoff.acknowledge()
        }
        cleanupHandoffs.removeValue(forKey: binding.operationID)
        operations.removeValue(forKey: binding.operationID)
        return .operationSettled(
            operationID: binding.operationID,
            snapshot
        )
    }
}
