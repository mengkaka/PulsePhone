import PulsePhoneClientCore
import PulsePhoneSharedDefinitions

struct SystemButtonCommandRunner: Sendable {
    let submitter: CommandSubmitter

    func run(
        commandID: String,
        human: String,
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID,
        outputMode: CLIOutputMode
    ) throws -> CLITerminalOutput {
        let intent = try CommandSubmissionIntent(
            requestID: requestID,
            actionID: actionID,
            canonicalUDID: canonicalUDID,
            commandID: commandID,
            rawArguments: [:]
        )
        let receipt = try submitter.submit(intent)
        let adapter = CLIOutputAdapter(mode: outputMode)
        if receipt.terminal.outcome == .succeeded {
            return try adapter.success(
                commandID: commandID,
                target: .device(canonicalUDID),
                result: SystemButtonCommandResult(),
                human: human
            )
        }
        let family: ErrorFamily = receipt.terminal.outcome == .outcomeUnknown
            ? .unknownOutcome
            : .knownCommandFailure
        return try adapter.failure(
            family: family,
            commandID: commandID,
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

public struct AppSwitcherCommand: Sendable {
    private let runner: SystemButtonCommandRunner

    public init(submitter: CommandSubmitter) {
        self.runner = SystemButtonCommandRunner(submitter: submitter)
    }

    public func run(
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID,
        outputMode: CLIOutputMode
    ) throws -> CLITerminalOutput {
        try runner.run(
            commandID: "button.appSwitcher",
            human: "App Switcher opened",
            requestID: requestID,
            actionID: actionID,
            canonicalUDID: canonicalUDID,
            outputMode: outputMode
        )
    }
}

public struct SystemButtonCommandResult: Codable, Equatable, Sendable {
    public let disposition: String

    public init(disposition: String = "acknowledged") {
        self.disposition = disposition
    }
}
