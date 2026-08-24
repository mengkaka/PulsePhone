import PulsePhoneCommandPlanner

public enum StateRevisionError: Error, Equatable, Sendable {
    case overflow
}

public struct StateRevision: Hashable, Comparable, Sendable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64 = 0) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public func advanced() throws -> StateRevision {
        let (value, overflow) = rawValue.addingReportingOverflow(1)
        guard !overflow else {
            throw StateRevisionError.overflow
        }
        return StateRevision(value)
    }
}

public enum RuntimeAvailabilityRevisionKind: String, CaseIterable, Sendable {
    case connection
    case condition
    case capability
    case preparation
    case geometry
    case quiescing
}

public struct RuntimeStateRevisions: Equatable, Sendable {
    public internal(set) var state: StateRevision
    public internal(set) var connection: StateRevision
    public internal(set) var facts: StateRevision
    public internal(set) var condition: StateRevision
    public internal(set) var capability: StateRevision
    public internal(set) var preparation: StateRevision
    public internal(set) var geometry: StateRevision
    public internal(set) var quiescing: StateRevision

    public init(
        state: StateRevision = StateRevision(),
        connection: StateRevision = StateRevision(),
        facts: StateRevision = StateRevision(),
        condition: StateRevision = StateRevision(),
        capability: StateRevision = StateRevision(),
        preparation: StateRevision = StateRevision(),
        geometry: StateRevision = StateRevision(),
        quiescing: StateRevision = StateRevision()
    ) {
        self.state = state
        self.connection = connection
        self.facts = facts
        self.condition = condition
        self.capability = capability
        self.preparation = preparation
        self.geometry = geometry
        self.quiescing = quiescing
    }

    public var planning: PlanningRevisions {
        PlanningRevisions(
            capability: capability.rawValue,
            condition: condition.rawValue,
            connection: connection.rawValue,
            geometry: geometry.rawValue,
            preparation: preparation.rawValue,
            quiescing: quiescing.rawValue
        )
    }
}
