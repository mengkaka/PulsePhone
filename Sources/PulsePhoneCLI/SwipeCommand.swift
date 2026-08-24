import PulsePhoneClientCore
import PulsePhoneSharedDefinitions

public struct SwipeCommand: Sendable {
    private let runner: LinearGestureCommandRunner

    public init(submitter: CommandSubmitter) {
        self.runner = LinearGestureCommandRunner(submitter: submitter)
    }

    public func run(
        from: String,
        to: String,
        durationMilliseconds: String,
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID,
        outputMode: CLIOutputMode
    ) throws -> CLITerminalOutput {
        try runner.run(
            commandID: "touch.swipe",
            verb: "Swiped",
            from: from,
            to: to,
            durationMilliseconds: durationMilliseconds,
            requestID: requestID,
            actionID: actionID,
            canonicalUDID: canonicalUDID,
            outputMode: outputMode
        )
    }
}
