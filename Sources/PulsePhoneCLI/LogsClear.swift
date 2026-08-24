import PulsePhoneLogging
import PulsePhoneSharedDefinitions

public enum LogsClearError: Error, Equatable, Sendable {
    case duplicateTarget
    case targetLimitExceeded
}

public enum LogsClearCommand {
    public static let maximumTargetCount = 256

    public static func fixedTargetSnapshot(
        _ targets: [CanonicalUDID]
    ) throws -> [CanonicalUDID] {
        guard targets.count <= maximumTargetCount else {
            throw LogsClearError.targetLimitExceeded
        }
        guard Set(targets).count == targets.count else {
            throw LogsClearError.duplicateTarget
        }
        return targets.sorted()
    }

    public static func route(
        runtimePresence: ActionLogRuntimePresence
    ) -> ActionLogClearRoute {
        ActionLogClearPlanner.route(runtimePresence: runtimePresence)
    }

    public static func exitCode(
        completed: Int,
        failed: Int,
        unknown: Int
    ) -> Int32 {
        if unknown > 0 { return 7 }
        if failed > 0 { return 6 }
        return completed >= 0 ? 0 : 6
    }

    public static func runProductionAll(
        maintenance: ProductionActionLogMaintenance,
        outputMode: CLIOutputMode
    ) throws -> CLITerminalOutput {
        try renderProductionLogMaintenance(
            commandID: "logs.clear.all",
            target: .global,
            result: maintenance.clearAll(),
            outputMode: outputMode
        )
    }

    public static func runProductionDevice(
        canonicalUDID: CanonicalUDID,
        maintenance: ProductionActionLogMaintenance,
        outputMode: CLIOutputMode
    ) throws -> CLITerminalOutput {
        try renderProductionLogMaintenance(
            commandID: "logs.clear.device",
            target: .device(canonicalUDID),
            result: maintenance.clear(canonicalUDID: canonicalUDID),
            outputMode: outputMode
        )
    }
}
