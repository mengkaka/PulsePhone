import PulsePhoneSharedDefinitions

public enum RuntimeActivityEvent: String, Equatable, Sendable {
    case validatedCLICommandIntent
    case acceptedPrepareCapabilities
    case prepareProgress
    case prepareCompletion
    case runtimeHealth
    case runtimeStatus
    case liveAttach
    case liveActivity
    case streamFrame
    case guiAction
    case commandCompletion
}

public enum RuntimeActivityDisposition: Equatable, Sendable {
    case refreshed(MonotonicInstant)
    case ignored
}

public enum RuntimeQuiesceTrigger: String, Equatable, Sendable {
    case manualStop
    case automaticIdle
    case incompatibleRetire
    case fatal
}

public enum RuntimeIdleCoordinatorError: Error, Equatable, Sendable {
    case invalidLifecycleState
    case clockMovedBackwards
}

public enum RuntimeQuiesceDisposition: Equatable, Sendable {
    case quiescing(RuntimeQuiesceTrigger)
    case alreadyQuiescing
    case alreadyStopped
    case notIdle(until: MonotonicInstant)
    case blocked([StopBlocker])
}

public struct RuntimeIdleSnapshot: Equatable, Sendable {
    public let runtimeReadyAt: MonotonicInstant
    public let lastCLIActivityAt: MonotonicInstant?
    public let idleReferenceAt: MonotonicInstant
    public let automaticIdleDeadline: MonotonicInstant
}

public struct RuntimeInhibitorReleaseDisposition: Equatable, Sendable {
    public let release: ShutdownInhibitorRelease
    public let idleReevaluation: RuntimeQuiesceDisposition?
}

public struct RuntimeIdleCoordinator: Sendable {
    public static let automaticIdleInterval = MonotonicDuration(
        nanoseconds: 10 * 60 * 1_000_000_000
    )

    private let runtimeReadyAt: MonotonicInstant
    private let idleInterval: MonotonicDuration
    private var lastCLIActivityAt: MonotonicInstant?
    private var lastBlockerReleasedAt: MonotonicInstant?

    public init(
        runtimeReadyAt: MonotonicInstant,
        idleInterval: MonotonicDuration = Self.automaticIdleInterval
    ) throws {
        _ = try runtimeReadyAt.advanced(by: idleInterval)
        self.runtimeReadyAt = runtimeReadyAt
        self.idleInterval = idleInterval
    }

    public var snapshot: RuntimeIdleSnapshot {
        let reference = max(lastCLIActivityAt ?? runtimeReadyAt, lastBlockerReleasedAt ?? runtimeReadyAt)
        return RuntimeIdleSnapshot(
            runtimeReadyAt: runtimeReadyAt,
            lastCLIActivityAt: lastCLIActivityAt,
            idleReferenceAt: reference,
            automaticIdleDeadline: try! reference.advanced(by: idleInterval)
        )
    }

    @discardableResult
    public mutating func recordActivity(
        _ event: RuntimeActivityEvent,
        at instant: MonotonicInstant
    ) throws -> RuntimeActivityDisposition {
        guard event == .validatedCLICommandIntent
                || event == .acceptedPrepareCapabilities
        else {
            return .ignored
        }
        let reference = snapshot.idleReferenceAt
        guard instant >= reference else {
            throw RuntimeIdleCoordinatorError.clockMovedBackwards
        }
        _ = try instant.advanced(by: idleInterval)
        lastCLIActivityAt = instant
        return .refreshed(instant)
    }

    public mutating func attemptQuiesce(
        trigger: RuntimeQuiesceTrigger,
        at instant: MonotonicInstant,
        lifecycleState: inout RuntimeLifecycleState,
        inhibitors: inout ShutdownInhibitorRegistry
    ) throws -> RuntimeQuiesceDisposition {
        switch lifecycleState {
        case .starting:
            throw RuntimeIdleCoordinatorError.invalidLifecycleState
        case .quiescing:
            return .alreadyQuiescing
        case .stopped:
            return .alreadyStopped
        case .ready:
            break
        }

        if trigger == .fatal {
            inhibitors.closeAdmission()
            lifecycleState = .quiescing
            return .quiescing(trigger)
        }

        if trigger == .automaticIdle {
            let current = snapshot
            guard instant >= current.idleReferenceAt else {
                throw RuntimeIdleCoordinatorError.clockMovedBackwards
            }
            guard instant >= current.automaticIdleDeadline else {
                return .notIdle(until: current.automaticIdleDeadline)
            }
        }

        let blockers = inhibitors.snapshot.blockers
        guard blockers.isEmpty else {
            return .blocked(blockers)
        }
        try inhibitors.closeAdmissionIfEmpty()
        lifecycleState = .quiescing
        return .quiescing(trigger)
    }

    public mutating func releaseInhibitorAndReevaluateIdle(
        _ token: ShutdownInhibitorToken,
        at instant: MonotonicInstant,
        lifecycleState: inout RuntimeLifecycleState,
        inhibitors: inout ShutdownInhibitorRegistry
    ) throws -> RuntimeInhibitorReleaseDisposition {
        let release = try inhibitors.release(token)
        guard release.becameEmpty, lifecycleState == .ready else {
            return RuntimeInhibitorReleaseDisposition(
                release: release,
                idleReevaluation: nil
            )
        }
        guard instant >= snapshot.idleReferenceAt else {
            throw RuntimeIdleCoordinatorError.clockMovedBackwards
        }
        _ = try instant.advanced(by: idleInterval)
        lastBlockerReleasedAt = instant
        let reevaluation = try attemptQuiesce(
            trigger: .automaticIdle,
            at: instant,
            lifecycleState: &lifecycleState,
            inhibitors: &inhibitors
        )
        return RuntimeInhibitorReleaseDisposition(
            release: release,
            idleReevaluation: reevaluation
        )
    }
}
