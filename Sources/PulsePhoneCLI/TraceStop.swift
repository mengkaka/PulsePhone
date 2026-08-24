import PulsePhoneLogging
import PulsePhoneSharedDefinitions

public enum TraceStopRuntimePresence: Equatable, Sendable {
    case absent
    case compatible
    case incompatible
}

public enum TraceStopRoute: Equatable, Sendable {
    case bootstrapStopAndFinalize
    case noActiveTrace
    case runtimeStop
}

public struct TraceStopCommandResult: Codable, Equatable, Sendable {
    public let absolutePath: String
    public let completeness: String
    public let traceID: String
}

public enum TraceStopCommand {
    public static let runtimeActivationRequested = false
    public static let workDeadlineNanoseconds: UInt64 = 5_000_000_000

    public static func route(
        runtimePresence: TraceStopRuntimePresence
    ) -> TraceStopRoute {
        switch runtimePresence {
        case .absent: .noActiveTrace
        case .compatible: .runtimeStop
        case .incompatible: .bootstrapStopAndFinalize
        }
    }

    public static func render(
        _ result: ReplayTraceFinalization,
        canonicalUDID: CanonicalUDID,
        outputMode: CLIOutputMode
    ) throws -> CLITerminalOutput {
        try CLIOutputAdapter(mode: outputMode).success(
            commandID: "trace.stop",
            target: .device(canonicalUDID),
            result: TraceStopCommandResult(
                absolutePath: result.absolutePath,
                completeness: result.completeness.rawValue,
                traceID: result.traceID.description
            ),
            human: "Trace stopped: \(result.absolutePath)"
        )
    }
}
