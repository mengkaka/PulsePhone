import PulsePhoneClientCore
import PulsePhoneCommandPlanner
import PulsePhoneSharedDefinitions

public struct TextTypeCommand: Sendable {
    private let submitter: CommandSubmitter

    public init(submitter: CommandSubmitter) {
        self.submitter = submitter
    }

    public func run(
        text: String,
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID,
        outputMode: CLIOutputMode
    ) throws -> CLITerminalOutput {
        let arguments = try ArgumentNormalizer.normalize(
            schemaID: "utf8Text.v1",
            raw: ["text": text]
        )
        guard case .string(let normalizedText)? = arguments.values["text"] else {
            throw ArgumentNormalizationError.invalid("text")
        }
        let intent = try CommandSubmissionIntent(
            requestID: requestID,
            actionID: actionID,
            canonicalUDID: canonicalUDID,
            commandID: "text.type",
            rawArguments: ["text": normalizedText]
        )
        let receipt = try submitter.submit(intent)
        let adapter = CLIOutputAdapter(mode: outputMode)
        if receipt.terminal.outcome == .succeeded {
            return try adapter.success(
                commandID: "text.type",
                target: .device(canonicalUDID),
                result: TextTypeCommandResult(),
                human: "Text paste dispatched"
            )
        }
        let family: ErrorFamily = receipt.terminal.outcome == .outcomeUnknown
            ? .unknownOutcome
            : .knownCommandFailure
        return try adapter.failure(
            family: family,
            commandID: "text.type",
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

public struct TextTypeCommandResult: Codable, Equatable, Sendable {
    public let disposition: String

    public init(disposition: String = "pasteDispatched") {
        self.disposition = disposition
    }
}
