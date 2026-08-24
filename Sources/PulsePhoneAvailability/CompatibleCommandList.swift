import PulsePhoneCommandCatalog
import PulsePhoneCommandPlanner

public struct CompatibleCommandEntry: Equatable, Sendable {
  public let commandID: String
  public let disposition: CompatibilityDisposition

  public init(commandID: String, disposition: CompatibilityDisposition) {
    self.commandID = commandID
    self.disposition = disposition
  }
}

public struct CompatibleCommandList: Equatable, Sendable {
  public let entries: [CompatibleCommandEntry]

  public init(catalog: ExecutionProfileCatalogV1, facts: DeviceFactsSnapshot?) {
    self.entries = catalog.expandedProductActions.map { row in
      CompatibleCommandEntry(
        commandID: row.command.commandID,
        disposition: CommandCompatibility.evaluate(
          rule: row.compatibilityRule,
          facts: facts
        )
      )
    }
  }
}
