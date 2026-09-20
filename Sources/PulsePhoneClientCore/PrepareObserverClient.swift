import PulsePhoneSharedDefinitions
import PulsePhoneWire

public struct PrepareObserverClientRequest: Equatable, Sendable {
    public let actionID: CanonicalUUID
    public let canonicalUDID: CanonicalUDID
    public let requestID: CanonicalUUID

    public init(
        canonicalUDID: CanonicalUDID,
        requestID: CanonicalUUID,
        actionID: CanonicalUUID
    ) {
        self.canonicalUDID = canonicalUDID
        self.requestID = requestID
        self.actionID = actionID
    }
}

public struct PrepareObserverProgressProjection: Equatable, Sendable {
    public let completedBytes: UInt64?
    public let fraction: Double?
    public let phase: String
    public let phaseSequence: UInt64
    public let preparationAttemptID: CanonicalUUID
    public let preparationGroupID: String
    public let stateRevision: UInt64
    public let totalBytes: UInt64?

    public init(
        completedBytes: UInt64? = nil,
        fraction: Double? = nil,
        phase: String,
        phaseSequence: UInt64,
        preparationAttemptID: CanonicalUUID,
        preparationGroupID: String,
        stateRevision: UInt64,
        totalBytes: UInt64? = nil
    ) throws {
        _ = try PreparationProgressV1(
            completedBytes: completedBytes,
            fraction: fraction,
            phase: try Self.phase(rawValue: phase),
            phaseSequence: phaseSequence,
            preparationAttemptID: preparationAttemptID,
            preparationGroupID: preparationGroupID,
            stateRevision: stateRevision,
            totalBytes: totalBytes
        )
        self.completedBytes = completedBytes
        self.fraction = fraction
        self.phase = phase
        self.phaseSequence = phaseSequence
        self.preparationAttemptID = preparationAttemptID
        self.preparationGroupID = preparationGroupID
        self.stateRevision = stateRevision
        self.totalBytes = totalBytes
    }

    private static func phase(
        rawValue: String
    ) throws -> PreparationWirePhase {
        guard let phase = PreparationWirePhase(rawValue: rawValue) else {
            throw PrepareObserverClientError.invalidProgress
        }
        return phase
    }
}

public struct PrepareObserverSuccessProjection: Equatable, Sendable {
    public let assetDisposition: String
    public let capabilityIDs: [String]
    public let capabilityResults: [PreparationCapabilityResultV1]
    public let disposition: String
    public let mountDisposition: String
    public let preparationAttemptID: CanonicalUUID?
    public let preparationGroupID: String
    public let provenance: String
    public let serviceDisposition: String

    public init(
        assetDisposition: String,
        capabilityIDs: [String],
        capabilityResults: [PreparationCapabilityResultV1] = [],
        disposition: String,
        mountDisposition: String,
        preparationAttemptID: CanonicalUUID? = nil,
        preparationGroupID: String,
        provenance: String,
        serviceDisposition: String
    ) throws {
        guard let asset = PreparationAssetDisposition(rawValue: assetDisposition),
              let resultDisposition = PreparationResultDisposition(
                  rawValue: disposition
              ),
              let mount = PreparationMountDisposition(
                  rawValue: mountDisposition
              ),
              let service = PreparationServiceDisposition(
                  rawValue: serviceDisposition
              )
        else {
            throw PrepareObserverClientError.invalidSuccess
        }
        _ = try PreparationResultV1(
            assetDisposition: asset,
            capabilityIDs: capabilityIDs,
            capabilityResults: capabilityResults,
            disposition: resultDisposition,
            mountDisposition: mount,
            preparationAttemptID: preparationAttemptID,
            preparationGroupID: preparationGroupID,
            provenance: provenance,
            serviceDisposition: service
        )
        self.assetDisposition = assetDisposition
        self.capabilityIDs = capabilityIDs
        self.capabilityResults = capabilityResults
        self.disposition = disposition
        self.mountDisposition = mountDisposition
        self.preparationAttemptID = preparationAttemptID
        self.preparationGroupID = preparationGroupID
        self.provenance = provenance
        self.serviceDisposition = serviceDisposition
    }
}

public struct PrepareObserverFailureProjection: Equatable, Sendable {
    public let code: String
    public let family: ErrorFamily
    public let message: String
    public let reason: String?

    public init(code: String, reason: String? = nil) throws {
        guard let errorCode = StandardErrorCode(rawValue: code),
              let descriptor = GeneratedStandardErrorRegistry.descriptors.first(
                  where: { $0.code == errorCode }
              )
        else {
            throw PrepareObserverClientError.unknownErrorCode
        }
        self.code = code
        self.family = descriptor.family
        self.message = descriptor.defaultMessage
        self.reason = reason
    }
}

public enum PrepareObserverInboundTerminal: Equatable, Sendable {
    case failed(PrepareObserverFailureProjection)
    case succeeded(PrepareObserverSuccessProjection)
}

public struct PrepareObserverClientTerminal: Equatable, Sendable {
    public let cancelSharedAttempt: Bool
    public let closeConnection: Bool
    public let error: PrepareObserverFailureProjection?
    public let exitCode: Int32
    public let result: PrepareObserverSuccessProjection?
    public let runtimeMayContinue: Bool

    public init(
        cancelSharedAttempt: Bool,
        closeConnection: Bool,
        error: PrepareObserverFailureProjection?,
        exitCode: Int32,
        result: PrepareObserverSuccessProjection?,
        runtimeMayContinue: Bool
    ) {
        self.cancelSharedAttempt = cancelSharedAttempt
        self.closeConnection = closeConnection
        self.error = error
        self.exitCode = exitCode
        self.result = result
        self.runtimeMayContinue = runtimeMayContinue
    }
}

public enum PrepareObserverClientUpdate: Equatable, Sendable {
    case progress(PrepareObserverProgressProjection)
    case terminal(PrepareObserverClientTerminal)
}

public enum PrepareObserverClientError: Error, Equatable, Sendable {
    case alreadyTerminal
    case attemptMismatch
    case clockMovedBackwards
    case groupMismatch
    case invalidProgress
    case invalidSuccess
    case progressRegressed
    case terminalMismatch
    case unknownErrorCode
}

public struct PrepareObserverClient: Sendable {
    public let request: PrepareObserverClientRequest
    public private(set) var isTerminal = false

    private var lastObservedAt: MonotonicInstant
    private var lastProgress: PrepareObserverProgressProjection?

    public init(
        request: PrepareObserverClientRequest,
        startedAt: MonotonicInstant
    ) throws {
        self.request = request
        self.lastObservedAt = startedAt
    }

    public mutating func receiveProgress(
        _ progress: PrepareObserverProgressProjection,
        at instant: MonotonicInstant
    ) throws -> PrepareObserverClientUpdate {
        try requireActive(at: instant)
        if let current = lastProgress {
            guard progress.preparationGroupID == current.preparationGroupID else {
                throw PrepareObserverClientError.groupMismatch
            }
            guard progress.preparationAttemptID == current.preparationAttemptID else {
                throw PrepareObserverClientError.attemptMismatch
            }
            guard progress.stateRevision >= current.stateRevision,
                  progress.phaseSequence >= current.phaseSequence
            else {
                throw PrepareObserverClientError.progressRegressed
            }
        }
        lastProgress = progress
        lastObservedAt = instant
        return .progress(progress)
    }

    public mutating func receiveTerminal(
        _ terminal: PrepareObserverInboundTerminal,
        at instant: MonotonicInstant
    ) throws -> PrepareObserverClientUpdate {
        try requireActive(at: instant)
        let value: PrepareObserverClientTerminal
        switch terminal {
        case .failed(let failure):
            value = PrepareObserverClientTerminal(
                cancelSharedAttempt: false,
                closeConnection: true,
                error: failure,
                exitCode: failure.family.exitCode,
                result: nil,
                runtimeMayContinue: false
            )
        case .succeeded(let result):
            if let progress = lastProgress {
                guard result.preparationGroupID == progress.preparationGroupID else {
                    throw PrepareObserverClientError.groupMismatch
                }
                guard result.preparationAttemptID
                        == progress.preparationAttemptID
                else {
                    throw PrepareObserverClientError.terminalMismatch
                }
            }
            value = PrepareObserverClientTerminal(
                cancelSharedAttempt: false,
                closeConnection: true,
                error: nil,
                exitCode: 0,
                result: result,
                runtimeMayContinue: false
            )
        }
        isTerminal = true
        lastObservedAt = instant
        return .terminal(value)
    }

    public mutating func checkDeadline(
        at instant: MonotonicInstant
    ) throws -> PrepareObserverClientUpdate? {
        try requireActive(at: instant)
        // Only the Runtime attempt has a deadline. An explicit CLI observer
        // must wait for that shared terminal without creating a local one.
        lastObservedAt = instant
        return nil
    }

    public mutating func interrupt(
        at instant: MonotonicInstant
    ) throws -> PrepareObserverClientUpdate? {
        try requireActive(at: instant)
        lastObservedAt = instant
        return nil
    }

    private func requireActive(at instant: MonotonicInstant) throws {
        guard !isTerminal else { throw PrepareObserverClientError.alreadyTerminal }
        guard instant >= lastObservedAt else {
            throw PrepareObserverClientError.clockMovedBackwards
        }
    }
}
