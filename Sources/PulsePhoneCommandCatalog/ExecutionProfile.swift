public enum PlanningAuthority: String, Sendable {
  case client
  case runtime
}

public enum AcceptedWorkPolicy: String, Sendable {
  case clientAggregate
  case continueAfterClientEOF
  case controlTerminal
  case localImmediate
  case ownerBound
}

public enum AutomaticRetryPolicy: String, Sendable {
  case never
  case notApplicable
}

public enum PreparationWaitPolicy: String, Sendable {
  case failFast
  case notApplicable
  case wait
}

public enum SchedulerPolicy: String, Sendable {
  case none
  case oneShotAdmission
  case streamLease
}

public struct ExecutionProfileDescriptor: Equatable, Sendable {
  public let acceptedWorkPolicy: AcceptedWorkPolicy
  public let automaticRetryPolicy: AutomaticRetryPolicy
  public let executionProfileID: String
  public let executionShape: CommandCategory
  public let planningAuthority: PlanningAuthority
  public let preparationWaitPolicy: PreparationWaitPolicy
  public let resultOwner: PlanningAuthority
  public let schedulerPolicy: SchedulerPolicy

  public init(
    acceptedWorkPolicy: AcceptedWorkPolicy,
    automaticRetryPolicy: AutomaticRetryPolicy,
    executionProfileID: String,
    executionShape: CommandCategory,
    planningAuthority: PlanningAuthority,
    preparationWaitPolicy: PreparationWaitPolicy,
    resultOwner: PlanningAuthority,
    schedulerPolicy: SchedulerPolicy
  ) {
    self.acceptedWorkPolicy = acceptedWorkPolicy
    self.automaticRetryPolicy = automaticRetryPolicy
    self.executionProfileID = executionProfileID
    self.executionShape = executionShape
    self.planningAuthority = planningAuthority
    self.preparationWaitPolicy = preparationWaitPolicy
    self.resultOwner = resultOwner
    self.schedulerPolicy = schedulerPolicy
  }
}

public enum ResourceAccessMode: String, Sendable {
  case capacity
  case exclusive
  case shared
}

public enum ResourceClaimPhase: String, Sendable {
  case control
  case devicePreparation
  case hostAcquisition
  case running
  case stream
}

public struct ResourceClaimDescriptor: Equatable, Sendable {
  public let accessMode: ResourceAccessMode
  public let phase: ResourceClaimPhase
  public let resourceIDTemplate: String

  public init(
    accessMode: ResourceAccessMode,
    phase: ResourceClaimPhase,
    resourceIDTemplate: String
  ) {
    self.accessMode = accessMode
    self.phase = phase
    self.resourceIDTemplate = resourceIDTemplate
  }
}

public struct ResourceClaimTemplateDescriptor: Equatable, Sendable {
  public let claims: [ResourceClaimDescriptor]
  public let resourceClaimTemplateID: String

  public init(
    claims: [ResourceClaimDescriptor],
    resourceClaimTemplateID: String
  ) {
    self.claims = claims
    self.resourceClaimTemplateID = resourceClaimTemplateID
  }
}

public struct ExpandedProductCommandDescriptor: Equatable, Sendable {
  public let command: ProductCommandDescriptor
  public let compatibilityRule: CompatibilityRuleDescriptor
  public let executionProfile: ExecutionProfileDescriptor
  public let loggingProfile: LoggingProfileDescriptor
  public let policyBindings: CommandPolicyBindings
  public let preparationGroups: [PreparationGroupDescriptor]
  public let resourceClaimTemplate: ResourceClaimTemplateDescriptor
}

public struct ExpandedSupportingActionDescriptor: Equatable, Sendable {
  public let action: SupportingActionDescriptor
  public let compatibilityRule: CompatibilityRuleDescriptor
  public let policyBindings: CommandPolicyBindings
  public let preparationGroups: [PreparationGroupDescriptor]
  public let resourceClaimTemplate: ResourceClaimTemplateDescriptor
}

public struct ExecutionProfileCatalogV1: Equatable, Sendable {
  public let commandCatalog: CommandCatalogV1
  public let compatibilityRules: [CompatibilityRuleDescriptor]
  public let executionProfiles: [ExecutionProfileDescriptor]
  public let expandedProductActions: [ExpandedProductCommandDescriptor]
  public let expandedSupportingActions: [ExpandedSupportingActionDescriptor]
  public let loggingProfiles: [LoggingProfileDescriptor]
  public let preparationGroups: [PreparationGroupDescriptor]
  public let resourceClaimTemplates: [ResourceClaimTemplateDescriptor]
}
