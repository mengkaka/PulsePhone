import PulsePhoneClientCore
import PulsePhoneCommandPlanner
import PulsePhoneSharedDefinitions

public struct RotateCommand: Sendable {
    private let submitter: CommandSubmitter

    public init(submitter: CommandSubmitter) {
        self.submitter = submitter
    }

    public func run(
        direction: String,
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID,
        outputMode: CLIOutputMode
    ) throws -> CLITerminalOutput {
        let arguments = try ArgumentNormalizer.normalize(
            schemaID: "rotateDirection.v2",
            raw: ["direction": direction]
        )
        guard case .string(let canonicalDirection)? = arguments.values["direction"] else {
            throw ArgumentNormalizationError.invalid("direction")
        }
        let intent = try CommandSubmissionIntent(
            requestID: requestID,
            actionID: actionID,
            canonicalUDID: canonicalUDID,
            commandID: "device.rotate",
            rawArguments: ["direction": canonicalDirection]
        )
        let receipt = try submitter.submit(intent)
        let adapter = CLIOutputAdapter(mode: outputMode)
        if receipt.terminal.outcome == .succeeded {
            return try adapter.success(
                commandID: "device.rotate",
                target: .device(canonicalUDID),
                result: RotateCommandResult(),
                human: "Completed one \(canonicalDirection) quarter-turn"
            )
        }
        let family: ErrorFamily = receipt.terminal.outcome == .outcomeUnknown
            ? .unknownOutcome
            : .knownCommandFailure
        return try adapter.failure(
            family: family,
            commandID: "device.rotate",
            target: .device(canonicalUDID),
            error: CLIErrorPayload(
                code: receipt.terminal.errorCode ?? "internalFailure"
            ),
            metadata: CLIOutputMetadata(
                runtimeMayContinue: family == .unknownOutcome ? true : nil
            )
        )
    }
}

public struct RotateCommandResult: Codable, Equatable, Sendable {
    public let disposition: String

    public init(disposition: String = "acknowledged") {
        self.disposition = disposition
    }
}
