import PulsePhoneCommandCatalog
import PulsePhoneCommandPlanner

public struct EffectiveCommandAvailabilityEntry: Equatable, Sendable {
  public let commandID: String
  public let state: PlanningAvailability

  public init(commandID: String, state: PlanningAvailability) {
    self.commandID = commandID
    self.state = state
  }
}

public struct EffectiveCommandAvailability: Equatable, Sendable {
  public let entries: [EffectiveCommandAvailabilityEntry]
  public let revisions: PlanningRevisions

  public init(
    catalog: ExecutionProfileCatalogV1,
    planner: CommandPlanner,
    context: RuntimePlanningContext
  ) throws {
    self.entries = try catalog.commandCatalog.productActions.map { command in
      EffectiveCommandAvailabilityEntry(
        commandID: command.commandID,
        state: try planner.availability(
          commandID: command.commandID,
          context: context
        )
      )
    }
    self.revisions = context.revisions
  }
}
