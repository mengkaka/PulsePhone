import PulsePhoneClientCore
import PulsePhoneSharedDefinitions
import PulsePhoneWire

public struct DevicePrepareCommandResult: Codable, Equatable, Sendable {
    public let assetDisposition: String
    public let capabilityIDs: [String]
    public let capabilityResults: [PreparationCapabilityResultV1]
    public let disposition: String
    public let mountDisposition: String
    public let preparationGroupID: String
    public let provenance: String
    public let serviceDisposition: String
}

public enum DevicePrepareCommandUpdate: Equatable, Sendable {
    case progress(CLIOutputChunk)
    case terminal(CLITerminalOutput)
}

public struct DevicePrepareCommand: Sendable {
    public static let commandID = "device.prepare"

    public init() {}

    public func begin(
        snapshot: USBDiscoverySnapshot,
        explicitTarget: CanonicalUDID? = nil,
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        startedAt: MonotonicInstant,
        outputMode: CLIOutputMode
    ) throws -> DevicePrepareCommandSession {
        let selected = try DeviceTargetSelector.select(
            explicit: explicitTarget,
            from: snapshot
        )
        let request = PrepareObserverClientRequest(
            canonicalUDID: selected.device.canonicalUDID,
            requestID: requestID,
            actionID: actionID
        )
        return try DevicePrepareCommandSession(
            client: PrepareObserverClient(
                request: request,
                startedAt: startedAt
            ),
            outputMode: outputMode,
            targetSelectionSource: selected.source
        )
    }
}

public struct DevicePrepareCommandSession: Sendable {
    public let request: PrepareObserverClientRequest
    public let targetSelectionSource: DeviceTargetSelectionSource

    private var client: PrepareObserverClient
    private let outputMode: CLIOutputMode

    init(
        client: PrepareObserverClient,
        outputMode: CLIOutputMode,
        targetSelectionSource: DeviceTargetSelectionSource
    ) throws {
        self.request = client.request
        self.client = client
        self.outputMode = outputMode
        self.targetSelectionSource = targetSelectionSource
    }

    public mutating func receiveProgress(
        _ progress: PrepareObserverProgressProjection,
        at instant: MonotonicInstant
    ) throws -> DevicePrepareCommandUpdate {
        try render(try client.receiveProgress(progress, at: instant))
    }

    public mutating func receiveTerminal(
        _ terminal: PrepareObserverInboundTerminal,
        at instant: MonotonicInstant
    ) throws -> DevicePrepareCommandUpdate {
        try render(try client.receiveTerminal(terminal, at: instant))
    }

    public mutating func checkDeadline(
        at instant: MonotonicInstant
    ) throws -> DevicePrepareCommandUpdate? {
        guard let update = try client.checkDeadline(at: instant) else {
            return nil
        }
        return try render(update)
    }

    public mutating func receiveSIGINT(
        at instant: MonotonicInstant
    ) throws -> DevicePrepareCommandUpdate? {
        guard let update = try client.interrupt(at: instant) else {
            return nil
        }
        return try render(update)
    }

    private func render(
        _ update: PrepareObserverClientUpdate
    ) throws -> DevicePrepareCommandUpdate {
        let adapter = CLIOutputAdapter(mode: outputMode)
        switch update {
        case .progress(let progress):
            var message = "Preparing \(request.canonicalUDID): \(progress.phase)"
            if let fraction = progress.fraction {
                message += " \(Int((fraction * 100).rounded(.down)))%"
            }
            return .progress(adapter.progress(message))
        case .terminal(let terminal):
            if let result = terminal.result {
                let projection = DevicePrepareCommandResult(
                    assetDisposition: result.assetDisposition,
                    capabilityIDs: result.capabilityIDs,
                    capabilityResults: result.capabilityResults,
                    disposition: result.disposition,
                    mountDisposition: result.mountDisposition,
                    preparationGroupID: result.preparationGroupID,
                    provenance: result.provenance,
                    serviceDisposition: result.serviceDisposition
                )
                let ready = result.disposition == "alreadyReady"
                    ? "already ready"
                    : "ready"
                let optionalUnavailable = result.capabilityResults
                    .filter {
                        $0.requirement == .optional
                            && $0.state == .unavailable
                    }
                    .map(\.capabilityID)
                let human = optionalUnavailable.isEmpty
                    ? "\(request.canonicalUDID) is \(ready)"
                    : "\(request.canonicalUDID) is \(ready); optional capabilities unavailable: \(optionalUnavailable.joined(separator: ","))"
                return .terminal(try adapter.success(
                    commandID: DevicePrepareCommand.commandID,
                    target: .device(request.canonicalUDID),
                    result: projection,
                    human: human
                ))
            }
            guard let error = terminal.error else {
                throw CLIOutputAdapterError.invalidEnvelope
            }
            return .terminal(try adapter.failure(
                family: error.family,
                commandID: DevicePrepareCommand.commandID,
                target: .device(request.canonicalUDID),
                error: CLIErrorPayload(
                    code: error.code,
                    message: error.message,
                    reason: error.reason
                ),
                metadata: CLIOutputMetadata(
                    runtimeMayContinue: terminal.runtimeMayContinue
                )
            ))
        }
    }
}
