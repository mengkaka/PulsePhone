import PulsePhoneClientCore
import PulsePhoneSharedDefinitions

public struct DiagnosticsStartCommandResult: Codable, Equatable, Sendable {
    public let absolutePath: String
    public let sessionID: String
}

public enum DiagnosticsStartCommand {
    public static let runtimeActivationRequested = true
    public static let workDeadlineNanoseconds: UInt64 = 5_000_000_000

    public static func render(
        _ result: DiagnosticStartResult,
        canonicalUDID: CanonicalUDID,
        outputMode: CLIOutputMode
    ) throws -> CLITerminalOutput {
        try CLIOutputAdapter(mode: outputMode).success(
            commandID: "diagnostics.start",
            target: .device(canonicalUDID),
            result: DiagnosticsStartCommandResult(
                absolutePath: result.absolutePath,
                sessionID: result.sessionID.description
            ),
            human: "Diagnostics started: \(result.absolutePath)"
        )
    }
}
