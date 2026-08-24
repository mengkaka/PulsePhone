import PulsePhoneSharedDefinitions

public enum ClientWaitBudgetKind: Equatable, Sendable {
    case nonDDICommand
    case ddiDependentCommand
    case devicePrepare
}

public enum ClientWaitBudgetPhase: Equatable, Sendable {
    case ordinary(deadline: MonotonicInstant)
    case awaitingPreparation
    case prepareObserver(deadline: MonotonicInstant)
    case expired
}

public enum ClientWaitBudgetError: Error, Equatable, Sendable {
    case clockMovedBackwards
    case invalidTransition
}

public enum ClientWaitTimeoutAction: Equatable, Sendable {
    case cancelOwnedPendingWorkAndClose(
        reason: String,
        runtimeMayContinue: Bool
    )
    case closePrepareObserver(
        reason: String,
        runtimeMayContinue: Bool
    )
}

public struct ClientWaitBudget: Sendable {
    public static let ordinaryDuration = MonotonicDuration(
        nanoseconds: 60 * 1_000_000_000
    )
    public static let prepareObserverDuration = MonotonicDuration(
        nanoseconds: 20 * 60 * 1_000_000_000
    )

    public let kind: ClientWaitBudgetKind
    public let startedAt: MonotonicInstant
    private(set) public var phase: ClientWaitBudgetPhase

    public init(kind: ClientWaitBudgetKind, startedAt: MonotonicInstant) throws {
        self.kind = kind
        self.startedAt = startedAt
        switch kind {
        case .nonDDICommand:
            self.phase = .ordinary(
                deadline: try startedAt.advanced(by: Self.ordinaryDuration)
            )
        case .ddiDependentCommand:
            self.phase = .awaitingPreparation
        case .devicePrepare:
            self.phase = .prepareObserver(
                deadline: try startedAt.advanced(
                    by: Self.prepareObserverDuration
                )
            )
        }
    }

    public mutating func capabilityReadyAndReplanned(
        at instant: MonotonicInstant
    ) throws {
        guard instant >= startedAt else {
            throw ClientWaitBudgetError.clockMovedBackwards
        }
        guard kind == .ddiDependentCommand,
              phase == .awaitingPreparation
        else {
            throw ClientWaitBudgetError.invalidTransition
        }
        phase = .ordinary(
            deadline: try instant.advanced(by: Self.ordinaryDuration)
        )
    }

    public mutating func check(
        at instant: MonotonicInstant
    ) throws -> ClientWaitTimeoutAction? {
        guard instant >= startedAt else {
            throw ClientWaitBudgetError.clockMovedBackwards
        }
        switch phase {
        case .awaitingPreparation, .expired:
            return nil
        case .ordinary(let deadline):
            guard instant >= deadline else { return nil }
            phase = .expired
            return .cancelOwnedPendingWorkAndClose(
                reason: "clientWaitDeadlineExceeded",
                runtimeMayContinue: true
            )
        case .prepareObserver(let deadline):
            guard instant >= deadline else { return nil }
            phase = .expired
            return .closePrepareObserver(
                reason: "preparationObserverDeadlineExceeded",
                runtimeMayContinue: true
            )
        }
    }
}
