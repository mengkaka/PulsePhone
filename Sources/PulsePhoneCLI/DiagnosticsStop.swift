import PulsePhoneLogging
import PulsePhoneSharedDefinitions

public enum DiagnosticsStopRuntimePresence: Equatable, Sendable {
    case absent
    case compatible
    case incompatible
}

public enum DiagnosticsStopRoute: Equatable, Sendable {
    case noActiveDiagnostics
    case runtimeStop
    case unavailable
}

public struct DiagnosticsStopCommandResult: Codable, Equatable, Sendable {
    public let absolutePath: String
    public let completeness: String
    public let sessionID: String
}

public enum DiagnosticsStopCommand {
    public static let runtimeActivationRequested = false
    public static let workDeadlineNanoseconds: UInt64 = 5_000_000_000

    public static func route(
        runtimePresence: DiagnosticsStopRuntimePresence
    ) -> DiagnosticsStopRoute {
        switch runtimePresence {
        case .absent: .noActiveDiagnostics
        case .compatible: .runtimeStop
        case .incompatible: .unavailable
        }
    }

    public static func render(
        _ result: DiagnosticLogFinalization,
        canonicalUDID: CanonicalUDID,
        outputMode: CLIOutputMode
    ) throws -> CLITerminalOutput {
        try CLIOutputAdapter(mode: outputMode).success(
            commandID: "diagnostics.stop",
            target: .device(canonicalUDID),
            result: DiagnosticsStopCommandResult(
                absolutePath: result.absolutePath,
                completeness: result.completeness.rawValue,
                sessionID: result.sessionID.description
            ),
            human: "Diagnostics stopped: \(result.absolutePath)"
        )
    }
}
