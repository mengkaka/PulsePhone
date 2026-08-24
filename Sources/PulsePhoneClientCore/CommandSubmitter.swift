import PulsePhoneSharedDefinitions

public enum CommandSubmissionValidationError: Error, Equatable, Sendable {
    case invalidCommandID
    case invalidArguments
    case invalidTerminal
    case missingTerminal
    case eventAfterTerminal
}

public struct CommandSubmissionIntent: Equatable, Sendable {
    public let requestID: CanonicalUUID
    public let actionID: CanonicalUUID
    public let canonicalUDID: CanonicalUDID
    public let commandID: String
    public let rawArguments: [String: String]

    public init(
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID,
        commandID: String,
        rawArguments: [String: String]
    ) throws {
        let commandBytes = Array(commandID.utf8)
        guard (1...128).contains(commandBytes.count),
              commandBytes.allSatisfy({ (0x21...0x7e).contains($0) })
        else {
            throw CommandSubmissionValidationError.invalidCommandID
        }
        guard rawArguments.count <= 64,
              rawArguments.allSatisfy({ key, value in
                  let keyBytes = Array(key.utf8)
                  return (1...128).contains(keyBytes.count)
                      && keyBytes.allSatisfy { (0x21...0x7e).contains($0) }
                      && value.utf8.count <= 64 * 1_024
                      && !value.utf8.contains(0)
              })
        else {
            throw CommandSubmissionValidationError.invalidArguments
        }
        self.requestID = requestID
        self.actionID = actionID
        self.canonicalUDID = canonicalUDID
        self.commandID = commandID
        self.rawArguments = rawArguments
    }
}

public struct CommandSubmissionTerminal: Equatable, Sendable {
    public let commitState: CommitState
    public let errorCode: String?
    public let outcome: StandardOutcome
    public let routeID: String?

    public init(
        outcome: StandardOutcome,
        commitState: CommitState,
        routeID: String? = nil,
        errorCode: String? = nil
    ) throws {
        let succeeded = outcome == .succeeded
        guard succeeded == (errorCode == nil),
              !succeeded || routeID != nil
        else {
            throw CommandSubmissionValidationError.invalidTerminal
        }
        self.commitState = commitState
        self.errorCode = errorCode
        self.outcome = outcome
        self.routeID = routeID
    }
}

public enum CommandSubmissionEvent: Equatable, Sendable {
    case accepted
    case awaitingPreparation(
        preparationGroupIDs: [String],
        sourceRevision: UInt64
    )
    case preparationReady(
        preparationAttemptID: CanonicalUUID,
        preparationGroupID: String
    )
    case authoritativePlan(
        routeID: String,
        sourceRevision: UInt64,
        resumedAfterPreparation: Bool
    )
    case queued
    case started(routeID: String)
    case terminal(CommandSubmissionTerminal)
}

public protocol CommandSubmissionRuntime: Sendable {
    func submit(_ intent: CommandSubmissionIntent) throws
        -> [CommandSubmissionEvent]
}

public struct CommandSubmissionReceipt: Equatable, Sendable {
    public let events: [CommandSubmissionEvent]
    public let terminal: CommandSubmissionTerminal
}

public struct CommandSubmitter: Sendable {
    private let runtime: any CommandSubmissionRuntime

    public init(runtime: any CommandSubmissionRuntime) {
        self.runtime = runtime
    }

    public func submit(
        _ intent: CommandSubmissionIntent
    ) throws -> CommandSubmissionReceipt {
        let events = try runtime.submit(intent)
        var lifecycle = PreparationAwareSubmission()
        var terminal: CommandSubmissionTerminal?
        for event in events {
            if terminal != nil {
                throw CommandSubmissionValidationError.eventAfterTerminal
            }
            try lifecycle.consume(event)
            if case .terminal(let value) = event {
                terminal = value
            }
        }
        guard let terminal, lifecycle.snapshot.phase == .terminal else {
            throw CommandSubmissionValidationError.missingTerminal
        }
        return CommandSubmissionReceipt(events: events, terminal: terminal)
    }
}
