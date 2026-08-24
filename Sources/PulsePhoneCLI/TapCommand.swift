import PulsePhoneClientCore
import PulsePhoneCommandPlanner
import PulsePhoneSharedDefinitions

public struct TapCommand: Sendable {
    private let submitter: CommandSubmitter

    public init(submitter: CommandSubmitter) {
        self.submitter = submitter
    }

    public func run(
        point: String,
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID,
        outputMode: CLIOutputMode
    ) throws -> CLITerminalOutput {
        let arguments = try ArgumentNormalizer.normalize(
            schemaID: "normalizedPoint.v1",
            raw: ["point": point]
        )
        guard case .point(let normalized)? = arguments.values["point"] else {
            throw ArgumentNormalizationError.invalid("point")
        }
        let canonicalPoint = "\(normalized.x),\(normalized.y)"
        let intent = try CommandSubmissionIntent(
            requestID: requestID,
            actionID: actionID,
            canonicalUDID: canonicalUDID,
            commandID: "touch.tap",
            rawArguments: ["point": canonicalPoint]
        )
        let receipt = try submitter.submit(intent)
        let adapter = CLIOutputAdapter(mode: outputMode)
        if receipt.terminal.outcome == .succeeded {
            return try adapter.success(
                commandID: "touch.tap",
                target: .device(canonicalUDID),
                result: TapCommandResult(),
                human: "Tapped at \(canonicalPoint)"
            )
        }
        let family: ErrorFamily = receipt.terminal.outcome == .outcomeUnknown
            ? .unknownOutcome
            : .knownCommandFailure
        return try adapter.failure(
            family: family,
            commandID: "touch.tap",
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

public struct TapCommandResult: Codable, Equatable, Sendable {
    public let disposition: String

    public init(disposition: String = "acknowledged") {
        self.disposition = disposition
    }
}
