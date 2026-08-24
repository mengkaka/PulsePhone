import PulsePhoneCommandPlanner

public enum ImplicitPreparationCommandShape: Equatable, Sendable {
    case finiteOneShot
    case stream
}

public enum ImplicitPreparationDisposition: Equatable, Sendable {
    case awaitingPreparation(
        completionMode: String,
        persistence: String,
        preparationGroupIDs: [String]
    )
    case failFast(reason: String)
    case submitImmediately
    case submitResumed
}

public enum ImplicitPreparationIntegrationError: Error, Equatable, Sendable {
    case alreadyBegun
    case groupMismatch
    case invalidGroupSet
    case invalidTransition
    case nonMonotonicRevisions
    case notReadyAfterRefresh
}

public struct ImplicitPreparationIntegration: Sendable {
    public let commandID: String
    public let initialRevisions: PlanningRevisions
    public let manualPrepareRequired = false
    public let shape: ImplicitPreparationCommandShape

    private let initialAvailability: PlanningAvailability
    private var disposition: ImplicitPreparationDisposition?
    private var waitingGroupIDs = [String]()

    public init(
        commandID: String,
        shape: ImplicitPreparationCommandShape,
        availability: PlanningAvailability,
        revisions: PlanningRevisions
    ) {
        self.commandID = commandID
        self.shape = shape
        self.initialAvailability = availability
        self.initialRevisions = revisions
    }

    public mutating func begin(
        otherPreparingGroupIDs: [String] = []
    ) throws -> ImplicitPreparationDisposition {
        guard disposition == nil else {
            throw ImplicitPreparationIntegrationError.alreadyBegun
        }
        try Self.requireGroupSet(otherPreparingGroupIDs, allowEmpty: true)
        let value: ImplicitPreparationDisposition
        switch initialAvailability {
        case .available:
            value = .submitImmediately
        case .preparable(let groupIDs):
            try Self.requireGroupSet(groupIDs, allowEmpty: false)
            switch shape {
            case .finiteOneShot:
                waitingGroupIDs = groupIDs
                value = .awaitingPreparation(
                    completionMode: "resumePlanning",
                    persistence: "epochBound",
                    preparationGroupIDs: groupIDs
                )
            case .stream:
                value = .failFast(reason: "capabilityPreparing")
            }
        case .unavailable(let reason), .unknown(let reason):
            value = .failFast(reason: reason)
        }
        disposition = value
        return value
    }

    public mutating func preparationReadyAndReplanned(
        preparationGroupID: String,
        refreshedAvailability: PlanningAvailability,
        refreshedRevisions: PlanningRevisions
    ) throws -> ImplicitPreparationDisposition {
        guard case .awaitingPreparation? = disposition else {
            throw ImplicitPreparationIntegrationError.invalidTransition
        }
        guard waitingGroupIDs.contains(preparationGroupID) else {
            throw ImplicitPreparationIntegrationError.groupMismatch
        }
        guard Self.strictlyAdvances(
            from: initialRevisions,
            to: refreshedRevisions
        ) else {
            throw ImplicitPreparationIntegrationError.nonMonotonicRevisions
        }
        guard refreshedAvailability == .available else {
            throw ImplicitPreparationIntegrationError.notReadyAfterRefresh
        }
        disposition = .submitResumed
        return .submitResumed
    }

    private static func requireGroupSet(
        _ groupIDs: [String],
        allowEmpty: Bool
    ) throws {
        guard (allowEmpty || !groupIDs.isEmpty),
              Set(groupIDs).count == groupIDs.count,
              groupIDs == groupIDs.sorted(by: asciiLessThan)
        else {
            throw ImplicitPreparationIntegrationError.invalidGroupSet
        }
    }

    private static func strictlyAdvances(
        from old: PlanningRevisions,
        to new: PlanningRevisions
    ) -> Bool {
        let oldValues = [
            old.capability, old.condition, old.connection, old.geometry,
            old.preparation, old.quiescing,
        ]
        let newValues = [
            new.capability, new.condition, new.connection, new.geometry,
            new.preparation, new.quiescing,
        ]
        return zip(oldValues, newValues).allSatisfy { $1 >= $0 }
            && zip(oldValues, newValues).contains { $1 > $0 }
    }

    private static func asciiLessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}
