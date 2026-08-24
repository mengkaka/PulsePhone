import PulsePhoneClientCore
import PulsePhoneSharedDefinitions

public enum VolumeButtonCommandDirection: Sendable {
    case down
    case up
}

public struct VolumeButtonCommand: Sendable {
    private let direction: VolumeButtonCommandDirection
    private let runner: SystemButtonCommandRunner

    public init(
        direction: VolumeButtonCommandDirection,
        submitter: CommandSubmitter
    ) {
        self.direction = direction
        self.runner = SystemButtonCommandRunner(submitter: submitter)
    }

    public func run(
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID,
        outputMode: CLIOutputMode
    ) throws -> CLITerminalOutput {
        let commandID: String
        let human: String
        switch direction {
        case .up:
            commandID = "button.volumeUp"
            human = "Volume Up pressed"
        case .down:
            commandID = "button.volumeDown"
            human = "Volume Down pressed"
        }
        return try runner.run(
            commandID: commandID,
            human: human,
            requestID: requestID,
            actionID: actionID,
            canonicalUDID: canonicalUDID,
            outputMode: outputMode
        )
    }
}
