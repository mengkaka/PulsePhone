import PulsePhoneSharedDefinitions

enum FaultObservation: Equatable, Sendable {
    case deadlineExpired(id: String, at: MonotonicInstant)
    case deviceDetached(previousEpoch: UInt64, newEpoch: UInt64)
    case helperCrashed(generation: UInt64, exitCode: Int32)
    case malformedRejected(byteCount: Int)
    case peerEOF
    case slowPeerConfigured(maximumBytesPerDrain: Int, stalledUntil: MonotonicInstant)
}

enum FaultInjectionHarnessError: Error, Equatable {
    case scriptNotFullyExecuted
}

struct FaultInjectionHarness: Sendable {
    let clock: DeterministicClock
    private let script: FaultScript
    private(set) var peer: FakePeer
    private(set) var helper: FakeHelper
    private(set) var device: FakeDevice
    private(set) var observations = [FaultObservation]()
    private var nextStepIndex = 0

    init(
        script: FaultScript,
        clock: DeterministicClock = DeterministicClock(),
        peer: FakePeer = FakePeer(),
        helper: FakeHelper,
        device: FakeDevice
    ) {
        self.script = script
        self.clock = clock
        self.peer = peer
        self.helper = helper
        self.device = device
    }

    mutating func advance(to instant: MonotonicInstant) throws {
        try clock.advance(to: instant)
        try runDueSteps()
    }

    mutating func runToCompletion() throws {
        for step in script.steps.dropFirst(nextStepIndex) {
            try advance(to: step.scheduledAt)
        }
        guard nextStepIndex == script.steps.count else {
            throw FaultInjectionHarnessError.scriptNotFullyExecuted
        }
    }

    mutating func runDueSteps() throws {
        while nextStepIndex < script.steps.count {
            let step = script.steps[nextStepIndex]
            guard step.scheduledAt <= clock.now() else { return }
            try apply(step)
            nextStepIndex += 1
        }
    }

    private mutating func apply(_ step: FaultStep) throws {
        switch step.fault {
        case .crash(let exitCode):
            try helper.crash(exitCode: exitCode)
            observations.append(.helperCrashed(
                generation: helper.generation,
                exitCode: exitCode
            ))
        case .detach:
            let epochs = try device.detach()
            observations.append(.deviceDetached(
                previousEpoch: epochs.previous,
                newEpoch: epochs.current
            ))
        case .eof:
            try peer.injectEOF()
            observations.append(.peerEOF)
        case .malformed(let bytes):
            try peer.injectMalformed(bytes)
            observations.append(.malformedRejected(byteCount: bytes.count))
        case .slowPeer(let maximumBytesPerDrain, let stallNanoseconds):
            try peer.configureSlowPeer(
                maximumBytesPerDrain: maximumBytesPerDrain,
                stallNanoseconds: stallNanoseconds,
                now: clock.now()
            )
            observations.append(.slowPeerConfigured(
                maximumBytesPerDrain: maximumBytesPerDrain,
                stalledUntil: try clock.now().advanced(
                    by: MonotonicDuration(nanoseconds: stallNanoseconds)
                )
            ))
        case .timeout(let deadlineID):
            observations.append(.deadlineExpired(
                id: deadlineID,
                at: clock.now()
            ))
        }
    }
}
