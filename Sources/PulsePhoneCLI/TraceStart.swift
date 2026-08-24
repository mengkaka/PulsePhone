import PulsePhoneClientCore
import PulsePhoneSharedDefinitions

public struct TraceStartCommandResult: Codable, Equatable, Sendable {
    public let absolutePath: String
    public let traceID: String
}

public enum TraceStartCommand {
    public static let runtimeActivationRequested = true
    public static let workDeadlineNanoseconds: UInt64 = 5_000_000_000

    public static func render(
        _ result: ReplayTraceStartResult,
        canonicalUDID: CanonicalUDID,
        outputMode: CLIOutputMode
    ) throws -> CLITerminalOutput {
        try CLIOutputAdapter(mode: outputMode).success(
            commandID: "trace.start",
            target: .device(canonicalUDID),
            result: TraceStartCommandResult(
                absolutePath: result.absolutePath,
                traceID: result.traceID.description
            ),
            human: "Trace started: \(result.absolutePath)"
        )
    }
}
