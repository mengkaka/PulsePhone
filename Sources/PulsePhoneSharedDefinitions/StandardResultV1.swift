public enum StandardOutcome: String, CaseIterable, Sendable {
    case succeeded
    case failed
    case cancelled
    case partial
    case outcomeUnknown
}

public enum CommitState: String, CaseIterable, Sendable {
    case notCommitted
    case committed
    case unknown
}

public enum StandardResultValidationError: Error, Equatable, Sendable {
    case errorForbidden(outcome: StandardOutcome)
    case errorRequired(outcome: StandardOutcome)
    case valueForbidden(outcome: StandardOutcome)
    case valueRequired(outcome: StandardOutcome)
}

public struct StandardResultV1<Value: Sendable, Details: Sendable>: Sendable {
    public let outcome: StandardOutcome
    public let commitState: CommitState?
    public let durationMs: UInt64?
    public let value: Value?
    public let error: StandardErrorV1<Details>?

    public init(
        outcome: StandardOutcome,
        commitState: CommitState? = nil,
        durationMs: UInt64? = nil,
        value: Value? = nil,
        error: StandardErrorV1<Details>? = nil
    ) throws {
        try Self.validate(outcome: outcome, value: value, error: error)
        self.outcome = outcome
        self.commitState = commitState
        self.durationMs = durationMs
        self.value = value
        self.error = error
    }

    private static func validate(
        outcome: StandardOutcome,
        value: Value?,
        error: StandardErrorV1<Details>?
    ) throws {
        switch outcome {
        case .succeeded:
            guard error == nil else {
                throw StandardResultValidationError.errorForbidden(
                    outcome: outcome
                )
            }
        case .failed, .partial, .outcomeUnknown:
            guard error != nil else {
                throw StandardResultValidationError.errorRequired(
                    outcome: outcome
                )
            }
            guard value == nil else {
                throw StandardResultValidationError.valueForbidden(
                    outcome: outcome
                )
            }
        case .cancelled:
            guard value != nil else {
                throw StandardResultValidationError.valueRequired(
                    outcome: outcome
                )
            }
        }
    }
}

extension StandardResultV1: Equatable
where Value: Equatable, Details: Equatable {}
