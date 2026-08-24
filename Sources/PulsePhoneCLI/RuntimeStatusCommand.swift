import PulsePhoneClientCore
import PulsePhoneSharedDefinitions

public protocol RuntimeStatusProviding: Sendable {
    func globalProbes() throws -> [RuntimeStatusProbe]
    func deviceProbe(canonicalUDID: CanonicalUDID) throws -> RuntimeStatusProbe
}

public struct RuntimeStatusCommandResult: Codable, Equatable, Sendable {
    public let targets: [RuntimeStatusTargetProjection]
    public let truncated: Bool

    public init(
        targets: [RuntimeStatusTargetProjection],
        truncated: Bool
    ) {
        self.targets = targets
        self.truncated = truncated
    }
}

public struct RuntimeStatusCommand: Sendable {
    private let compatibility: RuntimeStatusCompatibilityIdentity
    private let provider: any RuntimeStatusProviding

    public init(
        compatibility: RuntimeStatusCompatibilityIdentity,
        provider: any RuntimeStatusProviding
    ) {
        self.compatibility = compatibility
        self.provider = provider
    }

    public func runGlobal(
        outputMode: CLIOutputMode
    ) throws -> CLITerminalOutput {
        try render(
            commandID: "runtime.status.global",
            probes: provider.globalProbes(),
            target: .global,
            outputMode: outputMode
        )
    }

    public func runDevice(
        canonicalUDID: CanonicalUDID,
        outputMode: CLIOutputMode
    ) throws -> CLITerminalOutput {
        try render(
            commandID: "runtime.status.device",
            probes: [provider.deviceProbe(canonicalUDID: canonicalUDID)],
            target: .device(canonicalUDID),
            outputMode: outputMode
        )
    }

    private func render(
        commandID: String,
        probes: [RuntimeStatusProbe],
        target: CLIOutputTarget,
        outputMode: CLIOutputMode
    ) throws -> CLITerminalOutput {
        let aggregate = try RuntimeStatusAggregator.aggregate(
            probes,
            expectedCompatibility: compatibility
        )
        let result = RuntimeStatusCommandResult(
            targets: aggregate.targets,
            truncated: aggregate.truncated
        )
        let human = aggregate.targets.map {
            "\($0.canonicalUDID): \($0.state)"
        }.joined(separator: "\n")
        return try CLIOutputAdapter(mode: outputMode).success(
            commandID: commandID,
            target: target,
            result: result,
            human: human
        )
    }
}
