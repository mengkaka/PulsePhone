import PulsePhoneSharedDefinitions

public enum OperationExecutionKind: String, Equatable, Sendable {
    case oneShot
    case stream
}

public enum OperationResultDelivery: String, Equatable, Sendable {
    case reliableEnqueued
    case clientGone
}

public enum OperationCleanupDisposition: String, Equatable, Sendable {
    case notRequired
    case acknowledged
    case fenced
}

public enum OperationTerminalCause: String, Equatable, Sendable {
    case backendResult
    case clientCancelled
    case ownerDisconnected
    case deadlineExceeded
    case deviceDisconnected
    case runtimeAbort
    case rejected
}

public struct AtomicTerminalBundle: Equatable, Sendable {
    public let requestID: CanonicalUUID
    public let actionID: CanonicalUUID
    public let executionKind: OperationExecutionKind
    public let accepted: Bool
    public let outcome: StandardOutcome
    public let commitState: CommitState
    public let terminalCause: OperationTerminalCause
    public let resultDelivery: OperationResultDelivery
    public let cleanupDisposition: OperationCleanupDisposition
    public let releasedLeaseIDs: [String]
    public let releasedInhibitorTokenID: String?

    init(
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        executionKind: OperationExecutionKind,
        accepted: Bool,
        outcome: StandardOutcome,
        commitState: CommitState,
        terminalCause: OperationTerminalCause,
        resultDelivery: OperationResultDelivery,
        cleanupDisposition: OperationCleanupDisposition,
        releasedLeaseIDs: [String],
        releasedInhibitorTokenID: String?
    ) {
        self.requestID = requestID
        self.actionID = actionID
        self.executionKind = executionKind
        self.accepted = accepted
        self.outcome = outcome
        self.commitState = commitState
        self.terminalCause = terminalCause
        self.resultDelivery = resultDelivery
        self.cleanupDisposition = cleanupDisposition
        self.releasedLeaseIDs = releasedLeaseIDs
        self.releasedInhibitorTokenID = releasedInhibitorTokenID
    }
}

public enum TerminalCommitDisposition: Equatable, Sendable {
    case committed(AtomicTerminalBundle)
    case alreadyTerminal(AtomicTerminalBundle)
}
