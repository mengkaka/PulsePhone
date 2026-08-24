public enum PreparationRoute: String, Sendable {
  case classic
  case none
  case personalized
}

public enum TargetOSProfileID: String, Sendable {
  case legacyClassic
  case modernRSD
}

public enum PreparationPhaseID: String, Sendable {
  case alreadyMountedGeneration
  case mountGeneration
  case queryMountedState
}

public struct PreparationPhaseClaimBinding: Equatable, Sendable {
  public let phaseID: PreparationPhaseID
  public let resourceClaimTemplateID: String

  public init(
    phaseID: PreparationPhaseID,
    resourceClaimTemplateID: String
  ) {
    self.phaseID = phaseID
    self.resourceClaimTemplateID = resourceClaimTemplateID
  }
}

public struct PreparationGroupDescriptor: Equatable, Sendable {
  public let compatibilityRuleID: String
  public let phaseClaimBindings: [PreparationPhaseClaimBinding]
  public let preparationGroupID: String
  public let releaseScope: ReleaseScope
  public let requiredCapabilityIDs: [String]
  public let route: PreparationRoute
  public let targetDefaultOSProfileIDs: [TargetOSProfileID]

  public init(
    compatibilityRuleID: String,
    phaseClaimBindings: [PreparationPhaseClaimBinding],
    preparationGroupID: String,
    releaseScope: ReleaseScope,
    requiredCapabilityIDs: [String],
    route: PreparationRoute,
    targetDefaultOSProfileIDs: [TargetOSProfileID]
  ) {
    self.compatibilityRuleID = compatibilityRuleID
    self.phaseClaimBindings = phaseClaimBindings
    self.preparationGroupID = preparationGroupID
    self.releaseScope = releaseScope
    self.requiredCapabilityIDs = requiredCapabilityIDs
    self.route = route
    self.targetDefaultOSProfileIDs = targetDefaultOSProfileIDs
  }
}
