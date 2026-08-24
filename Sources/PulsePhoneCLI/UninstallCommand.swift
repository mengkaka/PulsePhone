import PulsePhoneClientCore
import PulsePhoneCommandPlanner
import PulsePhoneSharedDefinitions

public struct UninstallCommand: Sendable {
    private let submitter: CommandSubmitter

    public init(submitter: CommandSubmitter) {
        self.submitter = submitter
    }

    public func run(
        bundleID: String,
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID,
        outputMode: CLIOutputMode
    ) throws -> CLITerminalOutput {
        let arguments = try ArgumentNormalizer.normalize(
            schemaID: "bundleID.v1",
            raw: ["bundleID": bundleID]
        )
        guard case .string(let canonicalBundleID)? = arguments.values["bundleID"] else {
            throw ArgumentNormalizationError.invalid("bundleID")
        }
        let intent = try CommandSubmissionIntent(
            requestID: requestID,
            actionID: actionID,
            canonicalUDID: canonicalUDID,
            commandID: "app.uninstall",
            rawArguments: ["bundleID": canonicalBundleID]
        )
        let receipt = try submitter.submit(intent)
        let adapter = CLIOutputAdapter(mode: outputMode)
        if receipt.terminal.outcome == .succeeded {
            return try adapter.success(
                commandID: "app.uninstall",
                target: .device(canonicalUDID),
                result: AppOperationCommandResult(
                    bundleID: canonicalBundleID,
                    disposition: "uninstalled"
                ),
                human: "Uninstalled \(canonicalBundleID)"
            )
        }
        return try appOperationFailure(
            receipt: receipt,
            adapter: adapter,
            commandID: "app.uninstall",
            canonicalUDID: canonicalUDID
        )
    }
}
