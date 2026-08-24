import Foundation
import PulsePhoneSharedDefinitions

public struct RuntimeStatusCompatibilityIdentity: Equatable, Sendable {
    public let executionCatalogHash: String
    public let runtimeCompatibilityID: String

    public init(
        runtimeCompatibilityID: String,
        executionCatalogHash: String
    ) {
        self.runtimeCompatibilityID = runtimeCompatibilityID
        self.executionCatalogHash = executionCatalogHash
    }

    /// Compatibility for static-status test fixtures. Dynamic catalog state is
    /// not a Runtime status compatibility identity.
    public init(
        runtimeCompatibilityID: String,
        executionCatalogHash: String,
        developerImageCatalogRevision _: String,
        developerImageCatalogHash _: String
    ) {
        self.init(
            runtimeCompatibilityID: runtimeCompatibilityID,
            executionCatalogHash: executionCatalogHash
        )
    }
}

public struct RuntimePreparationProjection: Equatable, Sendable {
    public let preparationGroupID: String
    public let state: String

    public init(preparationGroupID: String, state: String) {
        self.preparationGroupID = preparationGroupID
        self.state = state
    }
}

public struct RuntimeFullStatus: Equatable, Sendable {
    public let compatibility: RuntimeStatusCompatibilityIdentity
    public let preparations: [RuntimePreparationProjection]
    public let runtimeEpoch: UInt64

    public init(
        compatibility: RuntimeStatusCompatibilityIdentity,
        preparations: [RuntimePreparationProjection],
        runtimeEpoch: UInt64
    ) {
        self.compatibility = compatibility
        self.preparations = preparations
        self.runtimeEpoch = runtimeEpoch
    }
}

public struct RuntimeLiteStatus: Equatable, Sendable {
    public let blockers: [String]
    public let canonicalUDID: CanonicalUDID
    public let compatibility: RuntimeStatusCompatibilityIdentity
    public let runtimeEpoch: UInt64
    public let socketBasenameMatchesTarget: Bool

    public init(
        canonicalUDID: CanonicalUDID,
        compatibility: RuntimeStatusCompatibilityIdentity,
        runtimeEpoch: UInt64,
        blockers: [String],
        socketBasenameMatchesTarget: Bool
    ) {
        self.canonicalUDID = canonicalUDID
        self.compatibility = compatibility
        self.runtimeEpoch = runtimeEpoch
        self.blockers = blockers
        self.socketBasenameMatchesTarget = socketBasenameMatchesTarget
    }
}

public enum RuntimeStatusProbeKind: Equatable, Sendable {
    case full(RuntimeFullStatus)
    case lite(RuntimeLiteStatus)
    case noSocket(RuntimeGenerationClassification)
    case timedOut
}

public struct RuntimeStatusProbe: Equatable, Sendable {
    public let canonicalUDID: CanonicalUDID
    public let kind: RuntimeStatusProbeKind

    public init(canonicalUDID: CanonicalUDID, kind: RuntimeStatusProbeKind) {
        self.canonicalUDID = canonicalUDID
        self.kind = kind
    }
}

public enum RuntimeStatusAggregationError: Error, Equatable, Sendable {
    case duplicateTarget
    case liteTargetMismatch
    case itemTooLarge
}

public struct RuntimeStatusTargetProjection: Codable, Equatable, Sendable {
    public let canonicalUDID: String
    public let state: String

    public init(canonicalUDID: String, state: String) {
        self.canonicalUDID = canonicalUDID
        self.state = state
    }
}

public struct RuntimeStatusAggregate: Equatable, Sendable {
    public let targets: [RuntimeStatusTargetProjection]
    public let truncated: Bool

    public init(targets: [RuntimeStatusTargetProjection], truncated: Bool) {
        self.targets = targets
        self.truncated = truncated
    }
}

public enum AggregateTargetDisposition: String, Codable, Sendable {
    case completed
    case interrupted
    case mutatingSubmittedOutcomeUnknown
    case notSubmitted
    case readOnlyInFlightTimedOut
}

public struct AggregateTargetInput: Codable, Equatable, Sendable {
    public let canonicalUDID: String
    public let disposition: AggregateTargetDisposition

    public init(
        canonicalUDID: String,
        disposition: AggregateTargetDisposition
    ) {
        self.canonicalUDID = canonicalUDID
        self.disposition = disposition
    }
}

public struct AggregateTargetOutput: Codable, Equatable, Sendable {
    public let canonicalUDID: String
    public let state: String
}

public struct AggregateDispositionProjection: Codable, Equatable, Sendable {
    public let exitCode: Int32
    public let outcome: String
    public let targets: [AggregateTargetOutput]
}

public enum RuntimeStatusAggregator {
    public static let maximumItemBytes = 2 * 1_024
    public static let maximumResultBytes = 1 * 1_024 * 1_024
    public static let maximumTargets = 256
    public static let maximumFanout = 8

    public static func aggregate(
        _ probes: [RuntimeStatusProbe],
        expectedCompatibility: RuntimeStatusCompatibilityIdentity
    ) throws -> RuntimeStatusAggregate {
        let sorted = probes.sorted {
            $0.canonicalUDID < $1.canonicalUDID
        }
        guard Set(sorted.map(\.canonicalUDID)).count == sorted.count else {
            throw RuntimeStatusAggregationError.duplicateTarget
        }
        var projections = [RuntimeStatusTargetProjection]()
        var truncated = sorted.count > maximumTargets
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for probe in sorted.prefix(maximumTargets) {
            let projection = try project(
                probe,
                expectedCompatibility: expectedCompatibility
            )
            guard try encoder.encode(projection).count <= maximumItemBytes else {
                throw RuntimeStatusAggregationError.itemTooLarge
            }
            projections.append(projection)
            let aggregate = RuntimeStatusCommandWireResult(
                targets: projections,
                truncated: truncated
            )
            if try encoder.encode(aggregate).count > maximumResultBytes {
                projections.removeLast()
                truncated = true
                break
            }
        }
        return RuntimeStatusAggregate(targets: projections, truncated: truncated)
    }

    public static func projectDispositions(
        _ inputs: [AggregateTargetInput]
    ) -> AggregateDispositionProjection {
        let outputs = inputs.sorted { $0.canonicalUDID < $1.canonicalUDID }.map {
            input -> AggregateTargetOutput in
            let state: String
            switch input.disposition {
            case .completed: state = "completed"
            case .interrupted: state = "interrupted"
            case .mutatingSubmittedOutcomeUnknown: state = "outcomeUnknown"
            case .notSubmitted: state = "notStarted"
            case .readOnlyInFlightTimedOut: state = "timedOut"
            }
            return AggregateTargetOutput(
                canonicalUDID: input.canonicalUDID,
                state: state
            )
        }
        let dispositions = Set(inputs.map(\.disposition))
        if dispositions.contains(.interrupted) {
            return AggregateDispositionProjection(
                exitCode: 130,
                outcome: "interrupted",
                targets: outputs
            )
        }
        if dispositions.contains(.mutatingSubmittedOutcomeUnknown) {
            return AggregateDispositionProjection(
                exitCode: 7,
                outcome: "outcomeUnknown",
                targets: outputs
            )
        }
        if dispositions.contains(.notSubmitted)
            || dispositions.contains(.readOnlyInFlightTimedOut)
        {
            return AggregateDispositionProjection(
                exitCode: 6,
                outcome: "partial",
                targets: outputs
            )
        }
        return AggregateDispositionProjection(
            exitCode: 0,
            outcome: "succeeded",
            targets: outputs
        )
    }

    private static func project(
        _ probe: RuntimeStatusProbe,
        expectedCompatibility: RuntimeStatusCompatibilityIdentity
    ) throws -> RuntimeStatusTargetProjection {
        let state: String
        switch probe.kind {
        case .full(let status):
            guard status.compatibility == expectedCompatibility else {
                state = "incompatible"
                break
            }
            state = status.preparations.contains(where: { $0.state != "ready" })
                ? "fullPreparing"
                : "full"
        case .lite(let status):
            guard status.canonicalUDID == probe.canonicalUDID,
                  status.socketBasenameMatchesTarget
            else {
                throw RuntimeStatusAggregationError.liteTargetMismatch
            }
            state = status.compatibility == expectedCompatibility
                ? "lite"
                : "incompatible"
        case .noSocket(let classification):
            switch classification {
            case .absent: state = "notRunning"
            case .exiting: state = "generationBusy:runtimeExiting"
            case .orphanHelpers: state = "generationBusy:orphanHelpers"
            case .identityUnknown: state = "generationBusy:identityUnknown"
            case .alive: state = "generationBusy:runtimeAliveWithoutSocket"
            }
        case .timedOut:
            state = "timedOut"
        }
        return RuntimeStatusTargetProjection(
            canonicalUDID: probe.canonicalUDID.rawValue,
            state: state
        )
    }
}

private struct RuntimeStatusCommandWireResult: Encodable {
    let targets: [RuntimeStatusTargetProjection]
    let truncated: Bool
}
