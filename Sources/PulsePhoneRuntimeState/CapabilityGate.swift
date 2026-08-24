import PulsePhoneCommandPlanner

public struct CapabilityGateWaiter: Equatable, Sendable {
    public let commandID: String
    public let rawArguments: [String: String]
    public let sourceRevisions: PlanningRevisions

    public init(
        commandID: String,
        rawArguments: [String: String],
        sourceRevisions: PlanningRevisions
    ) {
        self.commandID = commandID
        self.rawArguments = rawArguments
        self.sourceRevisions = sourceRevisions
    }
}

public enum CapabilityGate {
    public static let completionMode = "resumePlanning"

    public static func resumePlanning(
        waiter: CapabilityGateWaiter,
        planner: CommandPlanner,
        refreshedContext: RuntimePlanningContext
    ) throws -> PlanningResult {
        try planner.resumePlanning(
            commandID: waiter.commandID,
            rawArguments: waiter.rawArguments,
            refreshedContext: refreshedContext
        )
    }
}
