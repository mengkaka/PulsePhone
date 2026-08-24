import PulsePhoneSharedDefinitions

public enum PreparationAttemptPhase: String, CaseIterable, Hashable, Sendable {
    case created
    case queryingMountedImage
    case resolvingDeveloperSupport
    case waitingForAcquisitionSlot
    case waitingForSharedAcquisition
    case downloading
    case validating
    case extracting
    case waitingForDeviceClaims
    case waitingForGenerationClaims
    case personalizing
    case uploading
    case mounting
    case startingGeneration
    case probingServices
    case terminalReady
    case terminalUnavailable
    case terminalDisconnected

    public var isTerminal: Bool {
        switch self {
        case .terminalReady, .terminalUnavailable, .terminalDisconnected:
            true
        default:
            false
        }
    }
}

public enum PreparationDeadlinePhase: String, CaseIterable, Hashable, Sendable {
    case catalogSourceResolution
    case httpRequestPerSource
    case downloadNoProgress
    case acquisitionSlotWait
    case assetAcquisition
    case validationAndExtraction
    case mountedStateQuery
    case personalizationTSS
    case deviceClaimWait
    case personalizeUploadMount
    case helperHello
    case warmGeneration
    case preparationAttemptAbsolute
}

public enum PreparationDeadlinePolicy {
    public static func duration(
        for phase: PreparationDeadlinePhase
    ) -> MonotonicDuration {
        let seconds: UInt64
        switch phase {
        case .catalogSourceResolution, .mountedStateQuery:
            seconds = 10
        case .httpRequestPerSource, .personalizationTSS, .warmGeneration:
            seconds = 30
        case .downloadNoProgress:
            seconds = 60
        case .acquisitionSlotWait, .assetAcquisition:
            seconds = 15 * 60
        case .validationAndExtraction:
            seconds = 2 * 60
        case .deviceClaimWait, .personalizeUploadMount:
            seconds = 5 * 60
        case .helperHello:
            seconds = 2
        case .preparationAttemptAbsolute:
            seconds = 40 * 60
        }
        return MonotonicDuration(nanoseconds: seconds * 1_000_000_000)
    }
}

public struct PreparationAttemptIdentity: Equatable, Hashable, Sendable {
    public let runtimeEpoch: UInt64
    public let connectionEpoch: UInt64
    public let preparationGroupID: String
    public let preparationAttemptID: CanonicalUUID
    public let executorGeneration: UInt64?

    public init(
        runtimeEpoch: UInt64,
        connectionEpoch: UInt64,
        preparationGroupID: String,
        preparationAttemptID: CanonicalUUID,
        executorGeneration: UInt64? = nil
    ) throws {
        _ = try PreparationAttemptKey(
            runtimeEpoch: runtimeEpoch,
            connectionEpoch: connectionEpoch,
            preparationGroupID: preparationGroupID
        )
        self.runtimeEpoch = runtimeEpoch
        self.connectionEpoch = connectionEpoch
        self.preparationGroupID = preparationGroupID
        self.preparationAttemptID = preparationAttemptID
        self.executorGeneration = executorGeneration
    }

    public var key: PreparationAttemptKey {
        try! PreparationAttemptKey(
            runtimeEpoch: runtimeEpoch,
            connectionEpoch: connectionEpoch,
            preparationGroupID: preparationGroupID
        )
    }

    public func withExecutorGeneration(
        _ value: UInt64
    ) throws -> Self {
        try Self(
            runtimeEpoch: runtimeEpoch,
            connectionEpoch: connectionEpoch,
            preparationGroupID: preparationGroupID,
            preparationAttemptID: preparationAttemptID,
            executorGeneration: value
        )
    }
}

public enum PreparationAttemptError: Error, Equatable, Sendable {
    case invalidTransition
    case terminalAttempt
    case clockMovedBackwards
    case executorGenerationChanged
    case deadlineNotActive
}

public struct PreparationAttemptSnapshot: Equatable, Sendable {
    public let identity: PreparationAttemptIdentity
    public let phase: PreparationAttemptPhase
    public let startedAt: MonotonicInstant
    public let phaseStartedAt: MonotonicInstant
    public let activeDeadlines: [PreparationDeadlinePhase: MonotonicInstant]
    public let terminalReason: String?
}

public struct PreparationAttempt: Sendable {
    private(set) public var identity: PreparationAttemptIdentity
    private(set) public var phase: PreparationAttemptPhase
    public let startedAt: MonotonicInstant
    private var phaseStartedAt: MonotonicInstant
    private var activeDeadlines: [PreparationDeadlinePhase: MonotonicInstant]
    private var terminalReason: String?

    public init(
        identity: PreparationAttemptIdentity,
        startedAt: MonotonicInstant
    ) throws {
        self.identity = identity
        self.phase = .created
        self.startedAt = startedAt
        self.phaseStartedAt = startedAt
        self.activeDeadlines = [
            .preparationAttemptAbsolute: try startedAt.advanced(
                by: PreparationDeadlinePolicy.duration(
                    for: .preparationAttemptAbsolute
                )
            ),
        ]
    }

    public var snapshot: PreparationAttemptSnapshot {
        PreparationAttemptSnapshot(
            identity: identity,
            phase: phase,
            startedAt: startedAt,
            phaseStartedAt: phaseStartedAt,
            activeDeadlines: activeDeadlines,
            terminalReason: terminalReason
        )
    }

    public mutating func setExecutorGeneration(
        _ value: UInt64
    ) throws {
        guard !phase.isTerminal else {
            throw PreparationAttemptError.terminalAttempt
        }
        if let current = identity.executorGeneration {
            guard current == value else {
                throw PreparationAttemptError.executorGenerationChanged
            }
            return
        }
        identity = try identity.withExecutorGeneration(value)
    }

    public func accepts(
        _ callback: PreparationAttemptIdentity,
        requiresExecutorGeneration: Bool
    ) -> Bool {
        guard callback.runtimeEpoch == identity.runtimeEpoch,
              callback.connectionEpoch == identity.connectionEpoch,
              callback.preparationGroupID == identity.preparationGroupID,
              callback.preparationAttemptID == identity.preparationAttemptID
        else {
            return false
        }
        if requiresExecutorGeneration {
            return identity.executorGeneration != nil
                && callback.executorGeneration == identity.executorGeneration
        }
        return callback.executorGeneration == nil
            || callback.executorGeneration == identity.executorGeneration
    }

    public mutating func transition(
        to next: PreparationAttemptPhase,
        at instant: MonotonicInstant
    ) throws {
        guard !phase.isTerminal else {
            throw PreparationAttemptError.terminalAttempt
        }
        guard instant >= phaseStartedAt else {
            throw PreparationAttemptError.clockMovedBackwards
        }
        guard next != phase else { return }
        guard Self.allowedTransitions[phase, default: []].contains(next) else {
            throw PreparationAttemptError.invalidTransition
        }
        phase = next
        phaseStartedAt = instant
        if next.isTerminal {
            activeDeadlines.removeAll()
        }
    }

    @discardableResult
    public mutating func beginDeadline(
        _ deadlinePhase: PreparationDeadlinePhase,
        at instant: MonotonicInstant
    ) throws -> MonotonicInstant {
        guard !phase.isTerminal else {
            throw PreparationAttemptError.terminalAttempt
        }
        guard instant >= startedAt else {
            throw PreparationAttemptError.clockMovedBackwards
        }
        if let current = activeDeadlines[deadlinePhase] {
            return current
        }
        let deadline = try instant.advanced(
            by: PreparationDeadlinePolicy.duration(for: deadlinePhase)
        )
        activeDeadlines[deadlinePhase] = deadline
        return deadline
    }

    public mutating func endDeadline(
        _ deadlinePhase: PreparationDeadlinePhase
    ) throws {
        guard deadlinePhase != .preparationAttemptAbsolute,
              activeDeadlines.removeValue(forKey: deadlinePhase) != nil
        else {
            throw PreparationAttemptError.deadlineNotActive
        }
    }

    public func expiredDeadline(
        at instant: MonotonicInstant
    ) throws -> PreparationDeadlinePhase? {
        guard instant >= startedAt else {
            throw PreparationAttemptError.clockMovedBackwards
        }
        return activeDeadlines
            .filter { instant >= $0.value }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key.rawValue.utf8.lexicographicallyPrecedes(
                    rhs.key.rawValue.utf8
                )
            }
            .first?.key
    }

    public mutating func finishReady(
        at instant: MonotonicInstant
    ) throws {
        try transition(to: .terminalReady, at: instant)
    }

    public mutating func finishUnavailable(
        reason: String,
        at instant: MonotonicInstant
    ) throws {
        try transition(to: .terminalUnavailable, at: instant)
        terminalReason = reason
    }

    public mutating func finishDisconnected(
        at instant: MonotonicInstant
    ) throws {
        try transition(to: .terminalDisconnected, at: instant)
        terminalReason = "deviceDisconnected"
    }

    private static let allowedTransitions: [
        PreparationAttemptPhase: Set<PreparationAttemptPhase>
    ] = [
        .created: [.queryingMountedImage, .terminalUnavailable, .terminalDisconnected],
        .queryingMountedImage: [
            .resolvingDeveloperSupport, .waitingForDeviceClaims,
            .waitingForGenerationClaims, .terminalReady, .terminalUnavailable,
            .terminalDisconnected,
        ],
        .resolvingDeveloperSupport: [
            .waitingForAcquisitionSlot, .waitingForSharedAcquisition,
            .downloading, .validating, .waitingForDeviceClaims,
            .terminalUnavailable, .terminalDisconnected,
        ],
        .waitingForAcquisitionSlot: [
            .waitingForSharedAcquisition, .downloading, .terminalUnavailable,
            .terminalDisconnected,
        ],
        .waitingForSharedAcquisition: [
            .validating, .queryingMountedImage, .terminalUnavailable,
            .terminalDisconnected,
        ],
        .downloading: [
            .validating, .terminalUnavailable, .terminalDisconnected,
        ],
        .validating: [
            .extracting, .queryingMountedImage, .terminalUnavailable,
            .terminalDisconnected,
        ],
        .extracting: [
            .queryingMountedImage, .terminalUnavailable, .terminalDisconnected,
        ],
        .waitingForDeviceClaims: [
            .personalizing, .uploading, .mounting, .startingGeneration,
            .probingServices, .terminalUnavailable, .terminalDisconnected,
        ],
        .waitingForGenerationClaims: [
            .startingGeneration, .probingServices, .terminalUnavailable,
            .terminalDisconnected,
        ],
        .personalizing: [
            .uploading, .mounting, .terminalUnavailable, .terminalDisconnected,
        ],
        .uploading: [.mounting, .terminalUnavailable, .terminalDisconnected],
        .mounting: [
            .startingGeneration, .probingServices, .terminalUnavailable,
            .terminalDisconnected,
        ],
        .startingGeneration: [
            .probingServices, .terminalUnavailable, .terminalDisconnected,
        ],
        .probingServices: [
            .terminalReady, .terminalUnavailable, .terminalDisconnected,
        ],
    ]
}
