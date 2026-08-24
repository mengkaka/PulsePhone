import PulsePhoneSharedDefinitions

public struct StreamSessionPlan: Equatable, Sendable {
    public static let backendOpenTimeoutNanoseconds: UInt64 = 2_000_000_000
    public static let cleanupTimeoutNanoseconds: UInt64 = 2_000_000_000
    public static let frameAcceptedWatchdogNanoseconds: UInt64 = 1_000_000_000

    public let bufferPlan: StreamBufferPlan

    public init(bufferPlan: StreamBufferPlan) {
        self.bufferPlan = bufferPlan
    }
}

public enum StreamSessionError: Error, Equatable, Sendable {
    case buffer(StreamBufferError)
    case frameIdentityMismatch
    case invalidState
}

public struct StreamSessionSnapshot: Equatable, Sendable {
    public let buffer: StreamBufferSnapshot
    public let cleanupCommand: StreamCleanupCommand?
    public let cleanupStartCount: Int
    public let interactionID: CanonicalUUID
    public let lifecycle: OperationLifecycleSnapshot
    public let sessionID: CanonicalUUID
    public let terminal: StreamSessionTerminalSnapshot?
}

public struct StreamSession: Sendable {
    public let interactionID: CanonicalUUID
    public let plan: StreamSessionPlan
    public let sessionID: CanonicalUUID

    private var buffer: StreamFrameBuffer
    private var cleanup = StreamCleanupCoordinator()
    private var lifecycle: OperationLifecycle

    public init(
        openRequestID: CanonicalUUID,
        actionID: CanonicalUUID,
        sessionID: CanonicalUUID,
        interactionID: CanonicalUUID,
        plan: StreamSessionPlan
    ) throws {
        self.sessionID = sessionID
        self.interactionID = interactionID
        self.plan = plan
        self.buffer = StreamFrameBuffer(plan: plan.bufferPlan)
        var lifecycle = OperationLifecycle(
            requestID: openRequestID,
            executionKind: .stream
        )
        try lifecycle.beginPlanning(actionID: actionID)
        self.lifecycle = lifecycle
    }

    public var snapshot: StreamSessionSnapshot {
        StreamSessionSnapshot(
            buffer: buffer.snapshot,
            cleanupCommand: cleanup.activeCommand,
            cleanupStartCount: cleanup.cleanupStartCount,
            interactionID: interactionID,
            lifecycle: lifecycle.snapshot,
            sessionID: sessionID,
            terminal: cleanup.terminalSnapshot
        )
    }

    public mutating func rejectOpen(
        outcome: StandardOutcome = .failed,
        resultDelivery: OperationResultDelivery = .reliableEnqueued
    ) throws -> AtomicTerminalBundle {
        let result = try lifecycle.commitPreRunningTerminal(
            outcome: outcome,
            terminalCause: .rejected,
            resultDelivery: resultDelivery
        )
        switch result {
        case .committed(let bundle), .alreadyTerminal(let bundle):
            return bundle
        }
    }

    public mutating func beginOpening(
        inhibitorTokenID: String,
        bindings: OperationRuntimeBindings
    ) throws {
        try lifecycle.acceptRunning(
            inhibitorTokenID: inhibitorTokenID,
            bindings: bindings
        )
    }

    public mutating func markBackendOpen() throws {
        try lifecycle.markStreamOpen()
    }

    public mutating func submitFrame(
        _ frame: StreamFrameEnvelope
    ) throws {
        guard lifecycle.snapshot.phase == .running,
              let substate = lifecycle.snapshot.streamSubstate,
              substate == .opening || substate == .open
        else {
            throw StreamSessionError.invalidState
        }
        guard frame.sessionID == sessionID,
              frame.interactionID == interactionID
        else {
            throw StreamSessionError.frameIdentityMismatch
        }
        do {
            try buffer.enqueue(frame, whileOpening: substate == .opening)
        } catch let error as StreamBufferError {
            _ = try startCleanup(
                requestID: nil,
                mode: .cancel,
                cause: .runtimeAbort
            )
            throw StreamSessionError.buffer(error)
        }
    }

    public mutating func dequeueFrameForDelivery(
        deliveryAttemptID: String,
        atMonotonicNanoseconds now: UInt64
    ) throws -> StreamFrameDeliveryAttempt? {
        guard lifecycle.snapshot.phase == .running,
              lifecycle.snapshot.streamSubstate == .open
        else {
            throw StreamSessionError.invalidState
        }
        do {
            return try buffer.dequeueForDelivery(
                deliveryAttemptID: deliveryAttemptID,
                atMonotonicNanoseconds: now
            )
        } catch let error as StreamBufferError {
            throw StreamSessionError.buffer(error)
        }
    }

    public mutating func acceptFrame(
        sequence: UInt64,
        deliveryAttemptID: String
    ) throws {
        guard lifecycle.snapshot.phase == .running,
              lifecycle.snapshot.streamSubstate == .open
        else {
            throw StreamSessionError.invalidState
        }
        do {
            try buffer.acceptFrame(
                sequence: sequence,
                deliveryAttemptID: deliveryAttemptID
            )
        } catch let error as StreamBufferError {
            throw StreamSessionError.buffer(error)
        }
    }

    public mutating func evaluateFrameAcceptedWatchdog(
        atMonotonicNanoseconds now: UInt64
    ) throws -> StreamCleanupStartDisposition? {
        guard lifecycle.snapshot.phase == .running else {
            return nil
        }
        guard buffer.oldestFrameAcceptedWatchdogExpired(
            atMonotonicNanoseconds: now,
            timeoutNanoseconds: StreamSessionPlan.frameAcceptedWatchdogNanoseconds
        ) else {
            return nil
        }
        return try startCleanup(
            requestID: nil,
            mode: .cancel,
            cause: .deadlineExceeded
        )
    }

    public mutating func requestClose(
        requestID: CanonicalUUID,
        mode: StreamCloseMode,
        cause: OperationTerminalCause
    ) throws -> StreamCleanupStartDisposition {
        try startCleanup(
            requestID: requestID,
            mode: mode,
            cause: cause
        )
    }

    public mutating func completeCleanup(
        outcome: StandardOutcome,
        resultDelivery: OperationResultDelivery,
        disposition: OperationCleanupDisposition
    ) throws -> StreamSessionTerminalSnapshot {
        let result = try lifecycle.completeCleanup(
            outcome: outcome,
            resultDelivery: resultDelivery,
            cleanupDisposition: disposition
        )
        let bundle: AtomicTerminalBundle
        switch result {
        case .committed(let value), .alreadyTerminal(let value):
            bundle = value
        }
        return try cleanup.complete(terminalBundle: bundle)
    }

    public func closeResponse(
        for requestID: CanonicalUUID
    ) throws -> StreamClosedResponse {
        try cleanup.response(for: requestID)
    }

    private mutating func startCleanup(
        requestID: CanonicalUUID?,
        mode: StreamCloseMode,
        cause: OperationTerminalCause
    ) throws -> StreamCleanupStartDisposition {
        if cleanup.activeCommand != nil || cleanup.terminalSnapshot != nil {
            return cleanup.begin(
                requestID: requestID,
                mode: mode,
                cause: cause,
                lastAcceptedSequence: buffer.snapshot.lastAcceptedSequence,
                droppedFrameCount: 0
            )
        }
        guard lifecycle.snapshot.phase == .running else {
            throw StreamSessionError.invalidState
        }
        _ = try lifecycle.beginCleaning(
            commitState: .notCommitted,
            terminalCause: cause
        )
        let lastAccepted = buffer.snapshot.lastAcceptedSequence
        let dropped = buffer.removeAllOutstandingFrames()
        return cleanup.begin(
            requestID: requestID,
            mode: mode,
            cause: cause,
            lastAcceptedSequence: lastAccepted,
            droppedFrameCount: dropped
        )
    }
}
