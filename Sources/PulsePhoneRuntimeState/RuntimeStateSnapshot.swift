import PulsePhoneCommandPlanner
import PulsePhoneSharedDefinitions

public enum RuntimeLifecycleState: String, Equatable, Sendable {
    case starting
    case ready
    case quiescing
    case stopped
}

public enum RuntimeTerminationCause: String, Equatable, Sendable {
    case expected
    case fatal
}

public enum RuntimePreparationState: String, Equatable, Sendable {
    case unknown
    case acquiring
    case preparingDevice
    case ready
    case unavailable
}

public struct RuntimeCapabilityEntry: Equatable, Sendable {
    public let capabilityID: String
    public let availability: CapabilityAvailability

    public init(
        capabilityID: String,
        availability: CapabilityAvailability
    ) {
        self.capabilityID = capabilityID
        self.availability = availability
    }
}

public struct RuntimePreparationEntry: Equatable, Sendable {
    public let preparationGroupID: String
    public let state: RuntimePreparationState

    public init(
        preparationGroupID: String,
        state: RuntimePreparationState
    ) {
        self.preparationGroupID = preparationGroupID
        self.state = state
    }
}

public struct RuntimeStateSnapshot: Equatable, Sendable {
    public let canonicalUDID: CanonicalUDID
    public let runtimeEpoch: UInt64
    public let processID: Int32
    public let lifecycleState: RuntimeLifecycleState
    public let terminationCause: RuntimeTerminationCause?
    public let connected: Bool
    public let connectionEpoch: UInt64?
    public let facts: DeviceFactsSnapshot?
    public let condition: DeviceConditionSnapshot
    public let capabilities: [RuntimeCapabilityEntry]
    public let preparations: [RuntimePreparationEntry]
    public let geometry: DisplayGeometrySnapshot?
    public let activeExternalBoundaryCount: Int
    public let revisions: RuntimeStateRevisions

    public var quiescing: Bool {
        lifecycleState == .quiescing || lifecycleState == .stopped
    }

    public var planningContext: RuntimePlanningContext {
        RuntimePlanningContext(
            capabilities: Dictionary(
                uniqueKeysWithValues: capabilities.map {
                    ($0.capabilityID, $0.availability)
                }
            ),
            condition: condition,
            facts: facts,
            geometry: geometry,
            quiescing: quiescing,
            revisions: revisions.planning
        )
    }
}
