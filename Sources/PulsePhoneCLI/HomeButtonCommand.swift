import PulsePhoneClientCore
import PulsePhoneSharedDefinitions

public struct HomeButtonCommand: Sendable {
    private let submitter: CommandSubmitter

    public init(submitter: CommandSubmitter) {
        self.submitter = submitter
    }

    public func run(
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID,
        outputMode: CLIOutputMode
    ) throws -> CLITerminalOutput {
        let intent = try CommandSubmissionIntent(
            requestID: requestID,
            actionID: actionID,
            canonicalUDID: canonicalUDID,
            commandID: "button.home",
            rawArguments: [:]
        )
        let receipt = try submitter.submit(intent)
        let adapter = CLIOutputAdapter(mode: outputMode)
        if receipt.terminal.outcome == .succeeded {
            return try adapter.success(
                commandID: "button.home",
                target: .device(canonicalUDID),
                result: HomeButtonCommandResult(),
                human: "Home button pressed"
            )
        }
        let family: ErrorFamily = receipt.terminal.outcome == .outcomeUnknown
            ? .unknownOutcome
            : .knownCommandFailure
        return try adapter.failure(
            family: family,
            commandID: "button.home",
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

public struct HomeButtonCommandResult: Codable, Equatable, Sendable {
    public let disposition: String

    public init(disposition: String = "acknowledged") {
        self.disposition = disposition
    }
}
