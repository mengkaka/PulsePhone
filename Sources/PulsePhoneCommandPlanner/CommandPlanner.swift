import PulsePhoneCommandCatalog

public enum CommandPlannerError: Error, Equatable, Sendable {
  case unknownCommand(String)
  case missingCandidate(String)
  case invalidCandidateGroupMapping(String)
}

public struct CommandPlanner: Sendable {
  private let catalog: ExecutionProfileCatalogV1
  private let productsByID: [String: ExpandedProductCommandDescriptor]

  public init(catalog: ExecutionProfileCatalogV1) {
    self.catalog = catalog
    self.productsByID = Dictionary(
      uniqueKeysWithValues: catalog.expandedProductActions.map {
        ($0.command.commandID, $0)
      }
    )
  }

  public func plan(
    commandID: String,
    rawArguments: [String: String],
    context: RuntimePlanningContext
  ) throws -> PlanningResult {
    guard let row = productsByID[commandID] else {
      throw CommandPlannerError.unknownCommand(commandID)
    }
    let arguments = try ArgumentNormalizer.normalize(
      schemaID: row.command.argumentSchemaID,
      raw: rawArguments
    )
    switch readiness(for: row, context: context) {
    case .available:
      break
    case .preparable(let groupIDs):
      return .awaitingPreparation(
        AwaitingPreparationPlan(
          commandID: commandID,
          completionMode: "resumePlanning",
          preparationGroupIDs: groupIDs,
          sourceRevisions: context.revisions
        )
      )
    case .unavailable(let reason):
      return .unavailable(reason: reason)
    case .unknown(let reason):
      return .unknown(reason: reason)
    }

    let kind: PlanKind
    switch row.command.category {
    case .oneShot:
      kind = .oneShot
    case .stream:
      kind = .stream
    case .control, .hybrid, .local:
      return .notRuntimePlannable(row.command.category)
    }
    let commonClaims = try ClaimResolver.materialize(
      template: row.resourceClaimTemplate,
      arguments: arguments
    )
    let selectedCandidates = try candidateDescriptors(for: row, context: context)
    guard !selectedCandidates.isEmpty else {
      return .unavailable(reason: "noCompatibleCandidate")
    }
    let candidates = try selectedCandidates.enumerated().map { index, descriptor in
      let candidateClaims = try ClaimResolver.candidateClaims(
        routeID: descriptor.routeID,
        kind: kind,
        preparationGroupID: descriptor.group?.preparationGroupID
      )
      let hasNextCandidate = selectedCandidates.indices.contains(index + 1)
      let fallbackSafe =
        row.policyBindings.fallbackPolicyID
        == "fallback.os-disjoint-precommit-only.v1"
        && hasNextCandidate
      return CandidatePlan(
        backendPayload: arguments,
        candidateClaims: candidateClaims,
        executorOperationID: descriptor.routeID,
        fallbackDisposition: fallbackSafe ? .safe : .terminal,
        preparationGroupID: descriptor.group?.preparationGroupID,
        requiredCapabilityIDs: descriptor.group?.requiredCapabilityIDs ?? [],
        routeID: descriptor.routeID
      )
    }
    return .planned(
      ExecutionPlan(
        candidates: candidates,
        cleanupPolicyID: row.policyBindings.cleanupPolicyID,
        commandID: commandID,
        commonClaims: commonClaims,
        deadlinePolicyID: row.policyBindings.deadlinePolicyID,
        kind: kind,
        ownerDisconnectPolicyID: row.policyBindings.ownerDisconnectPolicyID,
        queuePolicyID: row.policyBindings.queuePolicyID,
        sourceRevisions: context.revisions
      )
    )
  }

  public func resumePlanning(
    commandID: String,
    rawArguments: [String: String],
    refreshedContext: RuntimePlanningContext
  ) throws -> PlanningResult {
    try plan(
      commandID: commandID,
      rawArguments: rawArguments,
      context: refreshedContext
    )
  }

  public func availability(
    commandID: String,
    context: RuntimePlanningContext
  ) throws -> PlanningAvailability {
    guard let row = productsByID[commandID] else {
      throw CommandPlannerError.unknownCommand(commandID)
    }
    return readiness(for: row, context: context)
  }

  private func readiness(
    for row: ExpandedProductCommandDescriptor,
    context: RuntimePlanningContext
  ) -> PlanningAvailability {
    switch CommandCompatibility.evaluate(
      rule: row.compatibilityRule,
      facts: context.facts
    ) {
    case .compatible:
      break
    case .incompatible(let reason):
      return .unavailable(reason: reason)
    case .unknown(let reason):
      return .unknown(reason: reason)
    }
    if row.command.category != .local && context.quiescing {
      return .unavailable(reason: "runtimeStopping")
    }
    if row.command.category == .oneShot || row.command.category == .stream {
      guard context.condition.connected else {
        return .unavailable(reason: "deviceDisconnected")
      }
      guard context.condition.trusted else {
        return .unavailable(reason: "deviceNotTrusted")
      }
      guard !context.condition.locked else {
        return .unavailable(reason: "deviceLocked")
      }
    }
    if row.command.category == .stream && !context.condition.liveAttached {
      return .unavailable(reason: "liveNotAttached")
    }
    if row.resourceClaimTemplate.claims.contains(where: {
      $0.resourceIDTemplate == "device.display-geometry"
    }), context.geometry == nil {
      return .unknown(reason: "displayGeometryUnavailable")
    }
    if let activationFailure = activationFailure(
      policyID: row.policyBindings.runtimeActivationPolicyID,
      connectionState: context.condition.runtimeConnectionState
    ) {
      return .unavailable(reason: activationFailure)
    }
    guard row.command.category == .oneShot || row.command.category == .stream else {
      return .available
    }

    var preparableGroups = Set<String>()
    var terminalReasons: [String] = []
    var hasAvailableCandidate = false
    do {
      for descriptor in try candidateDescriptors(for: row, context: context) {
        let capabilityStates =
          descriptor.group?.requiredCapabilityIDs.map {
            context.capabilities[$0] ?? .unknown
          } ?? []
        if capabilityStates.allSatisfy({ state in
          if case .available = state { return true }
          return false
        }) {
          hasAvailableCandidate = true
          continue
        }
        for state in capabilityStates {
          switch state {
          case .available:
            break
          case .preparing, .unknown:
            if let groupID = descriptor.group?.preparationGroupID {
              preparableGroups.insert(groupID)
            }
          case .unavailable(let reason):
            terminalReasons.append(reason)
          }
        }
      }
    } catch {
      return .unavailable(reason: "invalidCandidateGroupMapping")
    }
    if hasAvailableCandidate {
      return .available
    }
    if !preparableGroups.isEmpty {
      if row.command.category == .stream {
        return .unavailable(reason: "capabilityPreparing")
      }
      return .preparable(
        groupIDs: preparableGroups.sorted(by: CommandCatalog.asciiLessThan)
      )
    }
    return .unavailable(reason: terminalReasons.sorted().first ?? "capabilityUnavailable")
  }

  private func candidateDescriptors(
    for row: ExpandedProductCommandDescriptor,
    context: RuntimePlanningContext
  ) throws -> [(routeID: String, group: PreparationGroupDescriptor?)] {
    let routeIDs = row.policyBindings.candidateOrderIDs
    if row.command.category == .oneShot || row.command.category == .stream {
      guard !routeIDs.isEmpty else {
        throw CommandPlannerError.missingCandidate(row.command.commandID)
      }
    }
    return try routeIDs.enumerated().compactMap { index, routeID in
      guard routeIsCompatible(routeID, facts: context.facts) else {
        return nil
      }
      return (routeID, try preparationGroup(for: routeID, index: index, row: row))
    }
  }

  private func preparationGroup(
    for routeID: String,
    index: Int,
    row: ExpandedProductCommandDescriptor
  ) throws -> PreparationGroupDescriptor? {
    let groups = row.preparationGroups
    if groups.isEmpty {
      return nil
    }
    if groups.count == 1 {
      return groups[0]
    }
    if groups.count == row.policyBindings.candidateOrderIDs.count {
      return groups[index]
    }
    let expectedID: String?
    if routeID.hasPrefix("coredevice.") {
      expectedID = "prep.coredevice.v2"
    } else if routeID.hasPrefix("direct.") {
      expectedID = "prep.direct.lockdown.v1"
    } else if routeID.hasPrefix("legacy.") {
      expectedID = "prep.legacy.developer.v2"
    } else {
      expectedID = nil
    }
    if let expectedID,
      let group = groups.first(where: { $0.preparationGroupID == expectedID })
    {
      return group
    }
    throw CommandPlannerError.invalidCandidateGroupMapping(row.command.commandID)
  }

  private func routeIsCompatible(
    _ routeID: String,
    facts: DeviceFactsSnapshot?
  ) -> Bool {
    guard let facts else {
      return false
    }
    if routeID.hasPrefix("coredevice.") {
      return facts.osMajor >= 17
    }
    if routeID.hasPrefix("legacy.") {
      return facts.osMajor >= 14 && facts.osMajor < 17
    }
    if routeID.hasPrefix("direct.") {
      return facts.osMajor >= 14
    }
    return true
  }

  private func activationFailure(
    policyID: String,
    connectionState: RuntimeConnectionState
  ) -> String? {
    switch policyID {
    case "activation.existing-compatible.v1", "activation.existing-live-runtime.v1",
      "activation.existing-only.v1":
      return connectionState == .compatible ? nil : "runtimeNotRunning"
    case "activation.bootstrap-existing.v1":
      return connectionState == .absent ? "runtimeNotRunning" : nil
    case "activation.existing-or-bootstrap.v1":
      return nil
    default:
      return nil
    }
  }
}
