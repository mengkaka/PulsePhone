import PulsePhoneLogging
import PulsePhoneSharedDefinitions

public struct LogsMaintenanceCommandResult: Codable, Equatable, Sendable {
    public let deletedByteCount: UInt64
    public let deletedCount: Int
    public let failedCount: Int
    public let scanComplete: Bool
    public let skippedCount: Int
}

public enum LogsPruneCommand {
    public static let runtimeActivationRequested = false

    public static func exitCode(
        for result: ActionLogMaintenanceResult
    ) -> Int32 {
        result.outcome == .succeeded ? 0 : 6
    }

    public static func humanSummary(
        _ result: ActionLogMaintenanceResult
    ) -> String {
        "deleted=\(result.deletedFileCount) skipped=\(result.skippedCount) failed=\(result.failedCount) scanComplete=\(result.scanComplete)"
    }

    public static func runProduction(
        maintenance: ProductionActionLogMaintenance,
        outputMode: CLIOutputMode
    ) throws -> CLITerminalOutput {
        try renderProductionLogMaintenance(
            commandID: "logs.prune",
            target: .global,
            result: maintenance.prune(),
            outputMode: outputMode
        )
    }
}

func renderProductionLogMaintenance(
    commandID: String,
    target: CLIOutputTarget,
    result: ActionLogMaintenanceResult,
    outputMode: CLIOutputMode
) throws -> CLITerminalOutput {
    let adapter = CLIOutputAdapter(mode: outputMode)
    guard result.outcome == .succeeded else {
        return try adapter.failure(
            family: .knownCommandFailure,
            commandID: commandID,
            target: target,
            error: CLIErrorPayload(
                code: "partialFailure",
                message: LogsPruneCommand.humanSummary(result)
            )
        )
    }
    return try adapter.success(
        commandID: commandID,
        target: target,
        result: LogsMaintenanceCommandResult(
            deletedByteCount: result.deletedByteCount,
            deletedCount: result.deletedFileCount,
            failedCount: result.failedCount,
            scanComplete: result.scanComplete,
            skippedCount: result.skippedCount
        ),
        human: LogsPruneCommand.humanSummary(result)
    )
}
