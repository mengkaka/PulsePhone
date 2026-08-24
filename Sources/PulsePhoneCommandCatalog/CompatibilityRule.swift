public enum CompatibilityParameterValue: Equatable, Sendable {
  case bool(Bool)
  case string(String)
  case strings([String])
  case uint64(UInt64)
}

public struct CompatibilityRuleDescriptor: Equatable, Sendable {
  public let parameters: [String: CompatibilityParameterValue]
  public let ruleID: String
  public let ruleVersion: UInt64

  public init(
    parameters: [String: CompatibilityParameterValue],
    ruleID: String,
    ruleVersion: UInt64
  ) {
    self.parameters = parameters
    self.ruleID = ruleID
    self.ruleVersion = ruleVersion
  }
}
