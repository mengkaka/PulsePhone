public enum LiveCloseStage: String, Equatable, Sendable {
    case closeConnection
    case completed
    case detachLive
    case stopMedia
    case streamCleanup
}

public enum LiveCloseError: Error, Equatable, Sendable {
    case deadlineExceeded(stage: LiveCloseStage)
    case deadlineOverflow
}

public struct LiveCloseDeadline: Equatable, Sendable {
    public static let durationNanoseconds: UInt64 = 5_000_000_000

    public let deadlineNanoseconds: UInt64

    public init(startedAtNanoseconds: UInt64) throws {
        let (deadline, overflow) = startedAtNanoseconds.addingReportingOverflow(
            Self.durationNanoseconds
        )
        guard !overflow else { throw LiveCloseError.deadlineOverflow }
        self.deadlineNanoseconds = deadline
    }

    public func check(
        stage: LiveCloseStage,
        atNanoseconds now: UInt64
    ) throws {
        guard now < deadlineNanoseconds else {
            throw LiveCloseError.deadlineExceeded(stage: stage)
        }
    }
}
