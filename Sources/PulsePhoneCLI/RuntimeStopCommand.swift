import PulsePhoneClientCore
import PulsePhoneSharedDefinitions

public enum RuntimeStopGenerationState: Equatable, Sendable {
    case absent
    case compatible
    case exiting
    case identityUnknown
    case incompatible
    case orphanHelpers
}

public enum RuntimeStopRequestKind: Equatable, Sendable {
    case retireIfIdle
    case stopIfIdle
}

public enum RuntimeStopCommandError: Error, Equatable, Sendable {
    case generationBusy(RuntimeStopGenerationState)
    case runtimeBlocked
    case runtimeLockStillBusy
    case socketDidNotClose
}

public protocol RuntimeStopBackend: Sendable {
    func acquireBootstrapLock(canonicalUDID: CanonicalUDID) throws
    func releaseBootstrapLock()
    func recheck(canonicalUDID: CanonicalUDID) throws -> RuntimeStopGenerationState
    func waitOrRecover(
        canonicalUDID: CanonicalUDID,
        state: RuntimeStopGenerationState
    ) throws -> Bool
    func requestStop(
        canonicalUDID: CanonicalUDID,
        kind: RuntimeStopRequestKind
    ) throws -> Bool
    func waitForSocketEOF(canonicalUDID: CanonicalUDID) throws -> Bool
    func probeRuntimeLockReleased(canonicalUDID: CanonicalUDID) throws -> Bool
}

public struct RuntimeStopCommandResult: Codable, Equatable, Sendable {
    public let disposition: String
    public let stoppedTargetCount: Int

    public init(disposition: String, stoppedTargetCount: Int) {
        self.disposition = disposition
        self.stoppedTargetCount = stoppedTargetCount
    }
}

public struct RuntimeStopCommand: Sendable {
    private let backend: any RuntimeStopBackend

    public init(backend: any RuntimeStopBackend) {
        self.backend = backend
    }

    public func run(
        canonicalUDID: CanonicalUDID,
        outputMode: CLIOutputMode
    ) throws -> CLITerminalOutput {
        try backend.acquireBootstrapLock(canonicalUDID: canonicalUDID)
        defer { backend.releaseBootstrapLock() }
        var state = try backend.recheck(canonicalUDID: canonicalUDID)
        if state == .absent {
            return try render(
                canonicalUDID: canonicalUDID,
                disposition: "alreadyStopped",
                stoppedTargetCount: 0,
                outputMode: outputMode
            )
        }
        if state == .identityUnknown {
            throw RuntimeStopCommandError.generationBusy(state)
        }
        if state == .exiting || state == .orphanHelpers {
            guard try backend.waitOrRecover(
                canonicalUDID: canonicalUDID,
                state: state
            ) else {
                throw RuntimeStopCommandError.generationBusy(state)
            }
            state = try backend.recheck(canonicalUDID: canonicalUDID)
            if state == .absent {
                return try render(
                    canonicalUDID: canonicalUDID,
                    disposition: "alreadyStopped",
                    stoppedTargetCount: 0,
                    outputMode: outputMode
                )
            }
        }
        let kind: RuntimeStopRequestKind
        switch state {
        case .compatible: kind = .stopIfIdle
        case .incompatible: kind = .retireIfIdle
        default: throw RuntimeStopCommandError.generationBusy(state)
        }
        guard try backend.requestStop(
            canonicalUDID: canonicalUDID,
            kind: kind
        ) else {
            throw RuntimeStopCommandError.runtimeBlocked
        }
        guard try backend.waitForSocketEOF(canonicalUDID: canonicalUDID) else {
            throw RuntimeStopCommandError.socketDidNotClose
        }
        guard try backend.probeRuntimeLockReleased(canonicalUDID: canonicalUDID) else {
            throw RuntimeStopCommandError.runtimeLockStillBusy
        }
        return try render(
            canonicalUDID: canonicalUDID,
            disposition: "stopped",
            stoppedTargetCount: 1,
            outputMode: outputMode
        )
    }

    private func render(
        canonicalUDID: CanonicalUDID,
        disposition: String,
        stoppedTargetCount: Int,
        outputMode: CLIOutputMode
    ) throws -> CLITerminalOutput {
        try CLIOutputAdapter(mode: outputMode).success(
            commandID: "runtime.stop",
            target: .device(canonicalUDID),
            result: RuntimeStopCommandResult(
                disposition: disposition,
                stoppedTargetCount: stoppedTargetCount
            ),
            human: disposition == "stopped" ? "Stopped" : "Already stopped"
        )
    }
}
