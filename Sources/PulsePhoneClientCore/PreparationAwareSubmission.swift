public enum PreparationAwareSubmissionError: Error, Equatable, Sendable {
    case invalidTransition
    case staleReplan
    case routeMismatch
}

public enum PreparationAwareSubmissionPhase: Equatable, Sendable {
    case received
    case accepted
    case awaitingPreparation
    case preparationReady
    case planned
    case queued
    case running
    case terminal
}

public struct PreparationAwareSubmissionSnapshot: Equatable, Sendable {
    public let phase: PreparationAwareSubmissionPhase
    public let waitingSourceRevision: UInt64?
    public let plannedRouteID: String?
    public let terminal: CommandSubmissionTerminal?
}

public struct PreparationAwareSubmission: Sendable {
    private var phase: PreparationAwareSubmissionPhase = .received
    private var waitingSourceRevision: UInt64?
    private var plannedRouteID: String?
    private var terminal: CommandSubmissionTerminal?

    public init() {}

    public var snapshot: PreparationAwareSubmissionSnapshot {
        PreparationAwareSubmissionSnapshot(
            phase: phase,
            waitingSourceRevision: waitingSourceRevision,
            plannedRouteID: plannedRouteID,
            terminal: terminal
        )
    }

    public mutating func consume(
        _ event: CommandSubmissionEvent
    ) throws {
        switch event {
        case .accepted:
            try require(.received)
            phase = .accepted
        case .awaitingPreparation(let groupIDs, let sourceRevision):
            try require(.accepted)
            guard !groupIDs.isEmpty,
                  groupIDs == Array(Set(groupIDs)).sorted(by: asciiLessThan)
            else {
                throw PreparationAwareSubmissionError.invalidTransition
            }
            waitingSourceRevision = sourceRevision
            phase = .awaitingPreparation
        case .preparationReady:
            try require(.awaitingPreparation)
            phase = .preparationReady
        case .authoritativePlan(
            let routeID,
            let sourceRevision,
            let resumedAfterPreparation
        ):
            if phase == .accepted {
                guard !resumedAfterPreparation else {
                    throw PreparationAwareSubmissionError.invalidTransition
                }
            } else {
                try require(.preparationReady)
                guard resumedAfterPreparation,
                      sourceRevision != waitingSourceRevision
                else {
                    throw PreparationAwareSubmissionError.staleReplan
                }
            }
            guard !routeID.isEmpty else {
                throw PreparationAwareSubmissionError.invalidTransition
            }
            plannedRouteID = routeID
            phase = .planned
        case .queued:
            try require(.planned)
            phase = .queued
        case .started(let routeID):
            try require(.queued)
            guard routeID == plannedRouteID else {
                throw PreparationAwareSubmissionError.routeMismatch
            }
            phase = .running
        case .terminal(let value):
            guard phase == .running || phase == .queued else {
                throw PreparationAwareSubmissionError.invalidTransition
            }
            if let routeID = value.routeID,
               routeID != plannedRouteID
            {
                throw PreparationAwareSubmissionError.routeMismatch
            }
            terminal = value
            phase = .terminal
        }
    }

    private func require(
        _ expected: PreparationAwareSubmissionPhase
    ) throws {
        guard phase == expected else {
            throw PreparationAwareSubmissionError.invalidTransition
        }
    }

    private func asciiLessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}
