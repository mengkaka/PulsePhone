import PulsePhoneSharedDefinitions

enum FaultTarget: String, Equatable, Sendable {
    case device
    case harness
    case helper
    case peer
}

enum ScriptedFault: Equatable, Sendable {
    case crash(exitCode: Int32)
    case detach
    case eof
    case malformed(bytes: [UInt8])
    case slowPeer(maximumBytesPerDrain: Int, stallNanoseconds: UInt64)
    case timeout(deadlineID: String)
}

struct FaultStep: Equatable, Sendable {
    let sequence: UInt64
    let scheduledAt: MonotonicInstant
    let target: FaultTarget
    let fault: ScriptedFault
}

enum FaultScriptError: Error, Equatable {
    case duplicateDeadlineID(String)
    case emptyDeadlineID
    case emptyMalformedPayload
    case invalidCrashExitCode
    case invalidSlowPeerLimit
    case nonContiguousSequence(expected: UInt64, actual: UInt64)
    case nonMonotonicSchedule
    case targetMismatch(sequence: UInt64)
}

struct FaultScript: Equatable, Sendable {
    let steps: [FaultStep]

    init(steps: [FaultStep]) throws {
        var previousInstant = MonotonicInstant(nanoseconds: 0)
        var deadlineIDs = Set<String>()
        for (index, step) in steps.enumerated() {
            let expected = UInt64(index)
            guard step.sequence == expected else {
                throw FaultScriptError.nonContiguousSequence(
                    expected: expected,
                    actual: step.sequence
                )
            }
            if index > 0, step.scheduledAt < previousInstant {
                throw FaultScriptError.nonMonotonicSchedule
            }
            try Self.validate(step, deadlineIDs: &deadlineIDs)
            previousInstant = step.scheduledAt
        }
        self.steps = steps
    }

    private static func validate(
        _ step: FaultStep,
        deadlineIDs: inout Set<String>
    ) throws {
        let targetIsValid: Bool
        switch step.fault {
        case .crash(let exitCode):
            guard exitCode != 0 else {
                throw FaultScriptError.invalidCrashExitCode
            }
            targetIsValid = step.target == .helper
        case .detach:
            targetIsValid = step.target == .device
        case .eof, .malformed, .slowPeer:
            targetIsValid = step.target == .peer
        case .timeout(let deadlineID):
            guard !deadlineID.isEmpty else {
                throw FaultScriptError.emptyDeadlineID
            }
            guard deadlineIDs.insert(deadlineID).inserted else {
                throw FaultScriptError.duplicateDeadlineID(deadlineID)
            }
            targetIsValid = step.target == .harness
        }
        guard targetIsValid else {
            throw FaultScriptError.targetMismatch(sequence: step.sequence)
        }
        switch step.fault {
        case .malformed(let bytes) where bytes.isEmpty:
            throw FaultScriptError.emptyMalformedPayload
        case .slowPeer(let maximumBytesPerDrain, _) where maximumBytesPerDrain <= 0:
            throw FaultScriptError.invalidSlowPeerLimit
        default:
            break
        }
    }
}
