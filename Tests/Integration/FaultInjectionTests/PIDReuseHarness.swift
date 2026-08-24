import Darwin
import PulsePhoneRuntimeKernel
import PulsePhoneSharedDefinitions

struct RecoverySignal: Equatable {
    let pid: pid_t
    let signal: Int32
}

final class ScriptedRuntimeRecoverySystem: VerifiedRecoveryProcessSystem,
    @unchecked Sendable
{
    var runtimeObservations = [RecoveryProcessObservation.gone]
    var helperObservations = [pid_t: [RecoveryProcessObservation]]()
    private(set) var signals = [RecoverySignal]()

    func observeRuntime(
        _ identity: RuntimeRecoveryIdentity
    ) -> RecoveryProcessObservation {
        next(&runtimeObservations)
    }

    func observeHelper(
        _ identity: HelperProcessIdentity
    ) -> RecoveryProcessObservation {
        guard var observations = helperObservations[identity.pid] else {
            return .identityMismatch
        }
        let observation = next(&observations)
        helperObservations[identity.pid] = observations
        return observation
    }

    func signalHelperProcessGroup(
        _ identity: HelperProcessIdentity,
        signal: Int32
    ) throws {
        signals.append(RecoverySignal(pid: identity.pid, signal: signal))
    }

    private func next(
        _ observations: inout [RecoveryProcessObservation]
    ) -> RecoveryProcessObservation {
        guard let first = observations.first else { return .identityMismatch }
        if observations.count > 1 {
            observations.removeFirst()
        }
        return first
    }
}

struct DeterministicRecoveryPoller: RecoveryPolling, Sendable {
    let maximumAttempts: Int

    func waitUntil(
        timeout: MonotonicDuration,
        condition: () throws -> Bool
    ) throws -> Bool {
        for _ in 0..<maximumAttempts {
            if try condition() { return true }
        }
        return try condition()
    }
}
