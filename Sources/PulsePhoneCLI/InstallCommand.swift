import PulsePhoneClientCore
import PulsePhoneCommandPlanner
import PulsePhoneSharedDefinitions

public struct InstallCommand: Sendable {
    private let submitter: CommandSubmitter

    public init(submitter: CommandSubmitter) {
        self.submitter = submitter
    }

    public func run(
        ipaPath: String,
        installedBundleID: String,
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID,
        outputMode: CLIOutputMode
    ) throws -> CLITerminalOutput {
        let arguments = try ArgumentNormalizer.normalize(
            schemaID: "ipaPath.v1",
            raw: ["ipaPath": ipaPath]
        )
        guard case .string(let canonicalPath)? = arguments.values["ipaPath"] else {
            throw ArgumentNormalizationError.invalid("ipaPath")
        }
        let intent = try CommandSubmissionIntent(
            requestID: requestID,
            actionID: actionID,
            canonicalUDID: canonicalUDID,
            commandID: "app.install",
            rawArguments: ["ipaPath": canonicalPath]
        )
        let receipt = try submitter.submit(intent)
        let adapter = CLIOutputAdapter(mode: outputMode)
        if receipt.terminal.outcome == .succeeded {
            return try adapter.success(
                commandID: "app.install",
                target: .device(canonicalUDID),
                result: AppOperationCommandResult(
                    bundleID: installedBundleID,
                    disposition: "installed"
                ),
                human: "Installed \(installedBundleID)"
            )
        }
        return try failure(
            receipt: receipt,
            adapter: adapter,
            commandID: "app.install",
            canonicalUDID: canonicalUDID
        )
    }
}

struct AppOperationCommandResult: Codable, Equatable, Sendable {
    let bundleID: String
    let disposition: String
}

func appOperationFailure(
    receipt: CommandSubmissionReceipt,
    adapter: CLIOutputAdapter,
    commandID: String,
    canonicalUDID: CanonicalUDID
) throws -> CLITerminalOutput {
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

private func failure(
    receipt: CommandSubmissionReceipt,
    adapter: CLIOutputAdapter,
    commandID: String,
    canonicalUDID: CanonicalUDID
) throws -> CLITerminalOutput {
    try appOperationFailure(
        receipt: receipt,
        adapter: adapter,
        commandID: commandID,
        canonicalUDID: canonicalUDID
    )
}
