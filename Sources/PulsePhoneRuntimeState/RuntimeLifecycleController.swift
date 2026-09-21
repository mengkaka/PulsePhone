import Dispatch
import Foundation
import PulsePhoneSharedDefinitions

public enum RuntimeLifecycleActivity: Sendable {
    case validatedCLICommandIntent
    case acceptedPrepareCapabilities
}

public final class RuntimeLifecycleController: @unchecked Sendable {
    public static let defaultIdleGraceNanoseconds: UInt64 = 10 * 60 * 1_000_000_000

    private let clock: any MonotonicClock
    private let idleGraceNanoseconds: UInt64
    public typealias Schedule = @Sendable (UInt64, DispatchWorkItem) -> Void
    private let schedule: Schedule
    private let automaticIdle: @Sendable () -> Void
    private let lock = NSLock()
    private var inhibitors = ShutdownInhibitorRegistry()
    private var timer: DispatchWorkItem?
    private var scheduleGeneration: UInt64 = 0
    private var ready = false
    private var quiescing = false
    private var deadline: MonotonicInstant?

    public init(
        clock: any MonotonicClock = SystemMonotonicClock(),
        idleGraceNanoseconds: UInt64 = RuntimeLifecycleController.defaultIdleGraceNanoseconds,
        schedule: @escaping Schedule = { delay, item in
            DispatchQueue.global(qos: .utility).asyncAfter(
                wallDeadline: .now() + Double(delay) / 1_000_000_000,
                execute: item
            )
        },
        automaticIdle: @escaping @Sendable () -> Void
    ) {
        self.clock = clock
        self.idleGraceNanoseconds = idleGraceNanoseconds
        precondition(idleGraceNanoseconds > 0)
        self.schedule = schedule
        self.automaticIdle = automaticIdle
    }

    public func runtimeReady() {
        lock.withLock {
            guard !ready, !quiescing else { return }
            ready = true
            reevaluateLocked()
        }
    }

    public func recordActivity(_ activity: RuntimeLifecycleActivity) {
        lock.withLock {
            guard ready, !quiescing else { return }
            switch activity {
            case .validatedCLICommandIntent, .acceptedPrepareCapabilities:
                reevaluateLocked()
            }
        }
    }

    public func attachLive(
        liveOwnerID: CanonicalUUID,
        subscriptionID: CanonicalUUID
    ) throws -> ShutdownInhibitorToken {
        try acquire(
            kind: .live,
            ownerClientInstanceID: liveOwnerID,
            sessionID: subscriptionID,
            state: "attached"
        )
    }

    public func openStream(
        sessionID: CanonicalUUID,
        interactionID: CanonicalUUID,
        commandID: String
    ) throws -> ShutdownInhibitorToken {
        try acquire(
            kind: .stream,
            sessionID: sessionID,
            commandID: commandID,
            state: interactionID.canonicalString
        )
    }

    public func acquire(
        kind: ShutdownInhibitorKind,
        ownerClientInstanceID: CanonicalUUID? = nil,
        jobID: String? = nil,
        sessionID: CanonicalUUID? = nil,
        commandID: String? = nil,
        state: String? = nil
    ) throws -> ShutdownInhibitorToken {
        let metadata = try ShutdownInhibitorMetadata(
            kind: kind,
            retryWhen: Self.retryWhen(for: kind),
            ownerClientInstanceID: ownerClientInstanceID,
            jobID: jobID,
            sessionID: sessionID,
            commandID: commandID,
            state: state
        )
        return try lock.withLock {
            guard !quiescing else {
                throw ShutdownInhibitorRegistryError.admissionClosed
            }
            let token = try inhibitors.acquire(
                tokenID: CanonicalUUID(value: UUID()),
                metadata: metadata
            )
            cancelTimerLocked()
            return token
        }
    }

    public func release(_ token: ShutdownInhibitorToken) throws {
        try lock.withLock {
            let release = try inhibitors.release(token)
            if release.becameEmpty { reevaluateLocked() }
        }
    }

    public func beginQuiescing() {
        lock.withLock {
            quiescing = true
            cancelTimerLocked()
            inhibitors.closeAdmission()
        }
    }

    public func attemptStop() -> Bool {
        lock.withLock {
            guard !quiescing, inhibitors.snapshot.tokenCount == 0 else { return false }
            quiescing = true
            cancelTimerLocked()
            inhibitors.closeAdmission()
            return true
        }
    }

    public var idleDeadline: MonotonicInstant? { lock.withLock { deadline } }

    public func shutdown() {
        lock.withLock {
            quiescing = true
            ready = false
            cancelTimerLocked()
        }
    }

    public var blockerSnapshot: ShutdownInhibitorRegistrySnapshot {
        lock.withLock { inhibitors.snapshot }
    }

    private func reevaluateLocked() {
        cancelTimerLocked()
        guard ready, !quiescing, inhibitors.snapshot.blockers.isEmpty else { return }
        deadline = try? clock.now().advanced(by: MonotonicDuration(nanoseconds: idleGraceNanoseconds))
        guard deadline != nil else { return }
        armTimerLocked(after: idleGraceNanoseconds)
    }

    private func armTimerLocked(after delay: UInt64) {
        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        let item = DispatchWorkItem { [weak self] in
            self?.timerFired(generation: generation)
        }
        timer = item
        schedule(delay, item)
    }

    private func timerFired(generation: UInt64) {
        let shouldStop = lock.withLock { () -> Bool in
            guard generation == scheduleGeneration,
                  ready,
                  !quiescing,
                  let deadline,
                  inhibitors.snapshot.blockers.isEmpty
            else { return false }
            let now = clock.now()
            guard now >= deadline else {
                armTimerLocked(after: deadline.nanoseconds - now.nanoseconds)
                return false
            }
            quiescing = true
            timer = nil
            self.deadline = nil
            inhibitors.closeAdmission()
            return true
        }
        if shouldStop { automaticIdle() }
    }

    private func cancelTimerLocked() {
        scheduleGeneration &+= 1
        timer?.cancel()
        timer = nil
        deadline = nil
    }

    private static func retryWhen(
        for kind: ShutdownInhibitorKind
    ) -> ShutdownRetryWhen {
        switch kind {
        case .live: .liveDetached
        case .runningJob, .pendingJob: .jobTerminal
        case .stream: .streamClosed
        case .activeTrace: .traceStopped
        case .assetAcquisition: .acquisitionFinished
        case .preparingCapability: .capabilityResolved
        case .controlMutation: .controlFinished
        case .cleanup: .cleanupFinished
        case .fencing: .stateChanged
        }
    }
}
