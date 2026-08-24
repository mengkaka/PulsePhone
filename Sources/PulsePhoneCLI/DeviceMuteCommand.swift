import PulsePhoneClientCore
import PulsePhoneSharedDefinitions

public struct DeviceMuteCommand: Sendable {
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
            commandID: "button.mute",
            human: "Device Mute pressed",
            requestID: requestID,
            actionID: actionID,
            canonicalUDID: canonicalUDID,
            outputMode: outputMode
        )
    }
}
