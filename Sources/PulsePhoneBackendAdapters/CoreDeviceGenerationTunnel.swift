public struct CoreDeviceGenerationIdentity: Equatable, Hashable, Sendable {
    public let runtimeEpoch: UInt64
    public let connectionEpoch: UInt64
    public let executorGeneration: UInt64

    public init(
        runtimeEpoch: UInt64,
        connectionEpoch: UInt64,
        executorGeneration: UInt64
    ) {
        self.runtimeEpoch = runtimeEpoch
        self.connectionEpoch = connectionEpoch
        self.executorGeneration = executorGeneration
    }
}

public enum CoreDeviceGenerationAction: String, Equatable, Sendable {
    case spawnHelper
    case startTunnel
    case openServices
    case publishReady
    case closeServices
    case closeTunnel
    case terminateHelper
}

public struct CoreDeviceGenerationCommand: Equatable, Sendable {
    public let identity: CoreDeviceGenerationIdentity
    public let action: CoreDeviceGenerationAction

    public init(
        identity: CoreDeviceGenerationIdentity,
        action: CoreDeviceGenerationAction
    ) {
        self.identity = identity
        self.action = action
    }
}

public enum CoreDeviceGenerationRetirementReason: String, Equatable, Sendable {
    case detach
    case fatal
    case incompatible
    case quiesce
}

public struct CoreDeviceGenerationRetirementPlan: Equatable, Sendable {
    public let identity: CoreDeviceGenerationIdentity
    public let reason: CoreDeviceGenerationRetirementReason
    public let commands: [CoreDeviceGenerationCommand]
    public let fatalFailStopRequired: Bool

    public init(
        identity: CoreDeviceGenerationIdentity,
        reason: CoreDeviceGenerationRetirementReason,
        commands: [CoreDeviceGenerationCommand],
        fatalFailStopRequired: Bool
    ) {
        self.identity = identity
        self.reason = reason
        self.commands = commands
        self.fatalFailStopRequired = fatalFailStopRequired
    }
}
