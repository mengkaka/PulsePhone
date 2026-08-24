import PulsePhoneHostPaths
import PulsePhoneRuntimeKernel
import PulsePhoneSharedDefinitions

public protocol RuntimeDeadGenerationRecovering: Sendable {
    func recover(
        canonicalUDID: CanonicalUDID,
        runtimeExecutablePath: String,
        whileHolding bootstrapLock: BootstrapLock
    ) throws -> Bool
}

public struct ProductionRuntimeDeadGenerationRecoverer:
    RuntimeDeadGenerationRecovering,
    Sendable
{
    public init() {}

    public func recover(
        canonicalUDID: CanonicalUDID,
        runtimeExecutablePath: String,
        whileHolding bootstrapLock: BootstrapLock
    ) throws -> Bool {
        try DeadRuntimeGenerationRecovery().recover(
            canonicalUDID: canonicalUDID,
            runtimeExecutablePath: runtimeExecutablePath,
            whileHolding: bootstrapLock
        ) == .recovered
    }
}
