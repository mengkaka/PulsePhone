public enum CleanupHandoffState: String, Equatable, Sendable {
    case pending
    case acknowledged
    case fenced
    case timedOut
}

public enum CleanupHandoffError: Error, Equatable, Sendable {
    case invalidDeadline
    case alreadyResolved
}

public struct CleanupHandoff: Equatable, Sendable {
    public static let timeoutNanoseconds: UInt64 = 2_000_000_000

    public let operationID: String
    public let attemptID: String
    public let executorGeneration: UInt64
    public let startedAtNanoseconds: UInt64
    public let deadlineNanoseconds: UInt64
    public private(set) var state: CleanupHandoffState

    public init(
        operationID: String,
        attemptID: String,
        executorGeneration: UInt64,
        startedAtNanoseconds: UInt64
    ) throws {
        let (deadline, overflow) = startedAtNanoseconds.addingReportingOverflow(
            Self.timeoutNanoseconds
        )
        guard !overflow else {
            throw CleanupHandoffError.invalidDeadline
        }
        self.operationID = operationID
        self.attemptID = attemptID
        self.executorGeneration = executorGeneration
        self.startedAtNanoseconds = startedAtNanoseconds
        self.deadlineNanoseconds = deadline
        self.state = .pending
    }

    public mutating func acknowledge() throws {
        guard state == .pending else {
            throw CleanupHandoffError.alreadyResolved
        }
        state = .acknowledged
    }

    public mutating func fence() throws {
        guard state == .pending else {
            throw CleanupHandoffError.alreadyResolved
        }
        state = .fenced
    }

    @discardableResult
    public mutating func evaluateTimeout(at nowNanoseconds: UInt64) -> Bool {
        guard state == .pending, nowNanoseconds >= deadlineNanoseconds else {
            return false
        }
        state = .timedOut
        return true
    }
}
