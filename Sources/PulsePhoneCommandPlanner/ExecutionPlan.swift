import PulsePhoneCommandCatalog
import PulsePhoneSharedDefinitions

public enum PlanKind: String, Sendable {
  case oneShot
  case stream
}

public enum CandidateFallbackDisposition: String, Sendable {
  case safe
  case terminal
}

public struct MaterializedResourceClaim: Equatable, Hashable, Sendable {
  public let accessMode: ResourceAccessMode
  public let phase: ResourceClaimPhase
  public let resourceID: String

  public init(
    accessMode: ResourceAccessMode,
    phase: ResourceClaimPhase,
    resourceID: String
  ) {
    self.accessMode = accessMode
    self.phase = phase
    self.resourceID = resourceID
  }
}

public struct CandidatePlan: Equatable, Sendable {
  public let backendPayload: NormalizedArgumentsV1
  public let candidateClaims: [MaterializedResourceClaim]
  public let executorOperationID: String
  public let fallbackDisposition: CandidateFallbackDisposition
  public let preparationGroupID: String?
  public let requiredCapabilityIDs: [String]
  public let routeID: String

  public init(
    backendPayload: NormalizedArgumentsV1,
    candidateClaims: [MaterializedResourceClaim],
    executorOperationID: String,
    fallbackDisposition: CandidateFallbackDisposition,
    preparationGroupID: String?,
    requiredCapabilityIDs: [String],
    routeID: String
  ) {
    self.backendPayload = backendPayload
    self.candidateClaims = candidateClaims
    self.executorOperationID = executorOperationID
    self.fallbackDisposition = fallbackDisposition
    self.preparationGroupID = preparationGroupID
    self.requiredCapabilityIDs = requiredCapabilityIDs
    self.routeID = routeID
  }
}

public struct ExecutionPlan: Equatable, Sendable {
  public let candidates: [CandidatePlan]
  public let cleanupPolicyID: String
  public let commandID: String
  public let commonClaims: [MaterializedResourceClaim]
  public let deadlinePolicyID: String
  public let kind: PlanKind
  public let ownerDisconnectPolicyID: String
  public let queuePolicyID: String
  public let sourceRevisions: PlanningRevisions

  public init(
    candidates: [CandidatePlan],
    cleanupPolicyID: String,
    commandID: String,
    commonClaims: [MaterializedResourceClaim],
    deadlinePolicyID: String,
    kind: PlanKind,
    ownerDisconnectPolicyID: String,
    queuePolicyID: String,
    sourceRevisions: PlanningRevisions
  ) {
    self.candidates = candidates
    self.cleanupPolicyID = cleanupPolicyID
    self.commandID = commandID
    self.commonClaims = commonClaims
    self.deadlinePolicyID = deadlinePolicyID
    self.kind = kind
    self.ownerDisconnectPolicyID = ownerDisconnectPolicyID
    self.queuePolicyID = queuePolicyID
    self.sourceRevisions = sourceRevisions
  }
}

public struct AwaitingPreparationPlan: Equatable, Sendable {
  public let commandID: String
  public let completionMode: String
  public let preparationGroupIDs: [String]
  public let sourceRevisions: PlanningRevisions

  public init(
    commandID: String,
    completionMode: String,
    preparationGroupIDs: [String],
    sourceRevisions: PlanningRevisions
  ) {
    self.commandID = commandID
    self.completionMode = completionMode
    self.preparationGroupIDs = preparationGroupIDs
    self.sourceRevisions = sourceRevisions
  }
}

public enum PlanningResult: Equatable, Sendable {
  case awaitingPreparation(AwaitingPreparationPlan)
  case notRuntimePlannable(CommandCategory)
  case planned(ExecutionPlan)
  case unavailable(reason: String)
  case unknown(reason: String)
}

public enum PlanningAvailability: Equatable, Sendable {
  case available
  case preparable(groupIDs: [String])
  case unavailable(reason: String)
  case unknown(reason: String)
}

public enum FallbackSelection {
  public static func nextCandidate(
    in plan: ExecutionPlan,
    after routeID: String,
    commitState: CommitState,
    observedDisposition: CandidateFallbackDisposition,
    nextClaimsImmediatelyAvailable: Bool
  ) -> CandidatePlan? {
    guard commitState == .notCommitted,
      observedDisposition == .safe,
      nextClaimsImmediatelyAvailable,
      let index = plan.candidates.firstIndex(where: { $0.routeID == routeID }),
      plan.candidates[index].fallbackDisposition == .safe,
      plan.candidates.indices.contains(index + 1)
    else {
      return nil
    }
    return plan.candidates[index + 1]
  }
}
