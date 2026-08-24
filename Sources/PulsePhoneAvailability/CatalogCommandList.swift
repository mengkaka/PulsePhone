import PulsePhoneCommandCatalog

public struct CatalogCommandList: Equatable, Sendable {
  public let commandIDs: [String]

  public init(catalog: ExecutionProfileCatalogV1) {
    self.commandIDs = catalog.commandCatalog.productActions.map(\.commandID)
  }
}
