import PulsePhoneSharedDefinitions

public enum PreparationProgressPhase: String, CaseIterable, Hashable, Sendable {
    case checkingDevice
    case queryingMountedImage
    case resolvingDeveloperSupport
    case waitingForAcquisitionSlot
    case waitingForSharedAcquisition
    case downloading
    case validating
    case extracting
    case personalizing
    case uploading
    case mounting
    case startingDeviceServices
    case probingServices
    case ready
}

public struct PrepareObserverIdentity: Equatable, Sendable {
    public let requestID: CanonicalUUID
    public let actionID: CanonicalUUID
    public let observerID: CanonicalUUID
    public let ownerClientInstanceID: CanonicalUUID

    public init(
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        observerID: CanonicalUUID,
        ownerClientInstanceID: CanonicalUUID
    ) {
        self.requestID = requestID
        self.actionID = actionID
        self.observerID = observerID
        self.ownerClientInstanceID = ownerClientInstanceID
    }
}

public enum PrepareObserverReleaseReason: String, Equatable, Sendable {
    case observationTimeout
    case interrupted
    case clientGone
}

public enum PrepareObserverTerminal: Equatable, Sendable {
    case attempt(PreparationAttemptResolution)
    case outcomeUnknown(
        reason: String,
        runtimeMayContinue: Bool,
        exitCode: Int
    )
    case released(PrepareObserverReleaseReason)
}

public enum PrepareObserverError: Error, Equatable, Sendable {
    case clockMovedBackwards
    case alreadyTerminal
}

public struct PrepareObserverSnapshot: Equatable, Sendable {
    public let identity: PrepareObserverIdentity
    public let startedAt: MonotonicInstant
    public let deadline: MonotonicInstant
    public let lastProgress: PreparationProgressPhase?
    public let terminal: PrepareObserverTerminal?
}

public struct PrepareObserver: Sendable {
    public static let observationTimeout = MonotonicDuration(
        nanoseconds: 20 * 60 * 1_000_000_000
    )

    public let identity: PrepareObserverIdentity
    public let startedAt: MonotonicInstant
    public let deadline: MonotonicInstant
    private var lastProgress: PreparationProgressPhase?
    private var terminal: PrepareObserverTerminal?

    public init(
        identity: PrepareObserverIdentity,
        startedAt: MonotonicInstant
    ) throws {
        self.identity = identity
        self.startedAt = startedAt
        self.deadline = try startedAt.advanced(by: Self.observationTimeout)
    }

    public var snapshot: PrepareObserverSnapshot {
        PrepareObserverSnapshot(
            identity: identity,
            startedAt: startedAt,
            deadline: deadline,
            lastProgress: lastProgress,
            terminal: terminal
        )
    }

    public mutating func recordProgress(
        _ phase: PreparationProgressPhase,
        at instant: MonotonicInstant
    ) throws {
        guard terminal == nil else {
            throw PrepareObserverError.alreadyTerminal
        }
        guard instant >= startedAt else {
            throw PrepareObserverError.clockMovedBackwards
        }
        lastProgress = phase
    }

    @discardableResult
    public mutating func finish(
        _ value: PrepareObserverTerminal,
        at instant: MonotonicInstant
    ) throws -> PrepareObserverTerminal {
        guard terminal == nil else {
            throw PrepareObserverError.alreadyTerminal
        }
        guard instant >= startedAt else {
            throw PrepareObserverError.clockMovedBackwards
        }
        terminal = value
        return value
    }

    public mutating func checkDeadline(
        at instant: MonotonicInstant
    ) throws -> PrepareObserverTerminal? {
        guard terminal == nil else { return nil }
        guard instant >= startedAt else {
            throw PrepareObserverError.clockMovedBackwards
        }
        guard instant >= deadline else { return nil }
        let value = PrepareObserverTerminal.outcomeUnknown(
            reason: "preparationObserverDeadlineExceeded",
            runtimeMayContinue: true,
            exitCode: 7
        )
        terminal = value
        return value
    }
}
