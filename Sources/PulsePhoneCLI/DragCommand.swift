import PulsePhoneClientCore
import PulsePhoneCommandPlanner
import PulsePhoneSharedDefinitions

struct LinearGestureCommandRunner: Sendable {
    let submitter: CommandSubmitter

    func run(
        commandID: String,
        verb: String,
        from: String,
        to: String,
        durationMilliseconds: String,
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID,
        outputMode: CLIOutputMode
    ) throws -> CLITerminalOutput {
        let arguments = try ArgumentNormalizer.normalize(
            schemaID: "linearGesture.v1",
            raw: [
                "durationMs": durationMilliseconds,
                "from": from,
                "to": to,
            ]
        )
        guard case .uint64(let duration)? = arguments.values["durationMs"],
              case .point(let normalizedFrom)? = arguments.values["from"],
              case .point(let normalizedTo)? = arguments.values["to"]
        else {
            throw ArgumentNormalizationError.invalid("linearGesture")
        }
        let canonicalFrom = "\(normalizedFrom.x),\(normalizedFrom.y)"
        let canonicalTo = "\(normalizedTo.x),\(normalizedTo.y)"
        let intent = try CommandSubmissionIntent(
            requestID: requestID,
            actionID: actionID,
            canonicalUDID: canonicalUDID,
            commandID: commandID,
            rawArguments: [
                "durationMs": String(duration),
                "from": canonicalFrom,
                "to": canonicalTo,
            ]
        )
        let receipt = try submitter.submit(intent)
        let adapter = CLIOutputAdapter(mode: outputMode)
        if receipt.terminal.outcome == .succeeded {
            return try adapter.success(
                commandID: commandID,
                target: .device(canonicalUDID),
                result: LinearGestureCommandResult(),
                human: "\(verb) from \(canonicalFrom) to \(canonicalTo) in \(duration) ms"
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

public struct DragCommand: Sendable {
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
            commandID: "touch.drag",
            verb: "Dragged",
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

public struct LinearGestureCommandResult: Codable, Equatable, Sendable {
    public let disposition: String

    public init(disposition: String = "acknowledged") {
        self.disposition = disposition
    }
}
