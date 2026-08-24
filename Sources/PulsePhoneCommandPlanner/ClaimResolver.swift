import PulsePhoneCommandCatalog

public enum ClaimResolutionError: Error, Equatable, Sendable {
  case missingArgument(String)
  case unresolvedPlaceholder(String)
  case conflictingAccess(String)
}

public enum ClaimResolver {
  public static func materialize(
    template: ResourceClaimTemplateDescriptor,
    arguments: NormalizedArgumentsV1
  ) throws -> [MaterializedResourceClaim] {
    try normalizeClaims(
      template.claims.map { claim in
        var resourceID = claim.resourceIDTemplate
        if resourceID.contains("{bundleID}") {
          guard let bundleID = arguments.string("bundleID") else {
            throw ClaimResolutionError.missingArgument("bundleID")
          }
          resourceID = resourceID.replacingOccurrences(of: "{bundleID}", with: bundleID)
        }
        guard !resourceID.contains("{") && !resourceID.contains("}") else {
          throw ClaimResolutionError.unresolvedPlaceholder(resourceID)
        }
        return MaterializedResourceClaim(
          accessMode: claim.accessMode,
          phase: claim.phase,
          resourceID: resourceID
        )
      }
    )
  }

  public static func candidateClaims(
    routeID: String,
    kind: PlanKind,
    preparationGroupID: String?
  ) throws -> [MaterializedResourceClaim] {
    var claims: [MaterializedResourceClaim] = []
    if kind == .oneShot {
      let executorID =
        routeID.split(separator: ".", maxSplits: 1).first.map(String.init)
        ?? routeID
      claims.append(
        MaterializedResourceClaim(
          accessMode: .capacity,
          phase: .running,
          resourceID: "executor.\(executorID).oneshot-capacity-slot"
        )
      )
    }
    if routeID.hasPrefix("direct.") || routeID.hasPrefix("legacy.") {
      claims.append(
        MaterializedResourceClaim(
          accessMode: .exclusive,
          phase: kind == .stream ? .stream : .running,
          resourceID: "executor.direct.process-slot"
        )
      )
    }
    if routeID == "coredevice.normalTouch"
      || routeID.hasPrefix("coredevice.button.")
      || routeID.hasPrefix("coredevice.keyboard.")
      || routeID == "coredevice.keyboardMacro"
      || routeID.hasPrefix("coredevice.pasteboard")
    {
      claims.append(
        MaterializedResourceClaim(
          accessMode: .exclusive,
          phase: kind == .stream ? .stream : .running,
          resourceID: "executor.coredevice.input-channel"
        )
      )
    }
    if preparationGroupID == "prep.coredevice.v2"
      || preparationGroupID == "prep.legacy.developer.v2"
    {
      claims.append(
        MaterializedResourceClaim(
          accessMode: .shared,
          phase: kind == .stream ? .stream : .running,
          resourceID: "device.developer-environment"
        )
      )
    }
    return try normalizeClaims(claims)
  }

  private static func normalizeClaims(
    _ claims: [MaterializedResourceClaim]
  ) throws -> [MaterializedResourceClaim] {
    let grouped = Dictionary(grouping: claims) {
      "\($0.phase.rawValue)|\($0.resourceID)"
    }
    for (_, entries) in grouped where Set(entries.map(\.accessMode)).count > 1 {
      throw ClaimResolutionError.conflictingAccess(entries[0].resourceID)
    }
    return Array(Set(claims)).sorted {
      let lhs = "\($0.phase.rawValue)|\($0.accessMode.rawValue)|\($0.resourceID)"
      let rhs = "\($1.phase.rawValue)|\($1.accessMode.rawValue)|\($1.resourceID)"
      return lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
  }
}
