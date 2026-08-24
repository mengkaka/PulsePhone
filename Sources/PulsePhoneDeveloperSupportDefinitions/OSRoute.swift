import PulsePhoneCommandCatalog

public enum DeveloperSupportOSRoutingError: Error, Equatable, Sendable {
  case ambiguousTargetDefault(TargetOSProfileID)
  case routeMismatch(TargetOSProfileID)
  case unsupportedOSMajor(UInt64)
}

public struct DeveloperSupportOSRoute: Equatable, Sendable {
  public let maximumMajorExclusive: UInt64?
  public let minimumMajor: UInt64
  public let preparationGroupID: String
  public let profileID: TargetOSProfileID
  public let route: PreparationRoute

  public init(
    maximumMajorExclusive: UInt64?,
    minimumMajor: UInt64,
    preparationGroupID: String,
    profileID: TargetOSProfileID,
    route: PreparationRoute
  ) {
    self.maximumMajorExclusive = maximumMajorExclusive
    self.minimumMajor = minimumMajor
    self.preparationGroupID = preparationGroupID
    self.profileID = profileID
    self.route = route
  }
}

public enum DeveloperSupportOSRouting {
  public static func resolve(
    osMajor: UInt64,
    executionCatalog: ExecutionProfileCatalogV1
  ) throws -> DeveloperSupportOSRoute {
    let bounds: (TargetOSProfileID, UInt64, UInt64?, PreparationRoute)
    switch osMajor {
    case 14..<17:
      bounds = (.legacyClassic, 14, 17, .classic)
    case 17...:
      bounds = (.modernRSD, 17, nil, .personalized)
    default:
      throw DeveloperSupportOSRoutingError.unsupportedOSMajor(osMajor)
    }

    let groups = executionCatalog.preparationGroups.filter {
      $0.targetDefaultOSProfileIDs.contains(bounds.0)
    }
    guard groups.count == 1 else {
      throw DeveloperSupportOSRoutingError.ambiguousTargetDefault(bounds.0)
    }
    let group = groups[0]
    guard group.route == bounds.3 else {
      throw DeveloperSupportOSRoutingError.routeMismatch(bounds.0)
    }
    return DeveloperSupportOSRoute(
      maximumMajorExclusive: bounds.2,
      minimumMajor: bounds.1,
      preparationGroupID: group.preparationGroupID,
      profileID: bounds.0,
      route: group.route
    )
  }
}
