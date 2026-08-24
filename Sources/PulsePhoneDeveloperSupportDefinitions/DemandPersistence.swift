import PulsePhoneCommandCatalog

public enum PreparationDemandOrigin: String, Codable, Sendable {
  case explicitPrepare
  case finiteCommand
  case livePrewarm
}

public enum DemandPersistence: String, Codable, Sendable {
  case epochBound
  case persistentAcrossReconnect
}

public enum PreparationDemandAuthorityError: Error, Equatable, Sendable {
  case callerSelectedPersistence
  case callerSelectedPreparationGroup
  case invalidCandidatePreparationGroup(String)
  case missingCandidatePreparationGroup
}

public struct PreparationDemandDescriptor: Equatable, Sendable {
  public let origin: PreparationDemandOrigin
  public let persistence: DemandPersistence
  public let preparationGroupID: String

  public init(
    origin: PreparationDemandOrigin,
    persistence: DemandPersistence,
    preparationGroupID: String
  ) {
    self.origin = origin
    self.persistence = persistence
    self.preparationGroupID = preparationGroupID
  }
}

public enum PreparationDemandAuthority {
  public static func derive(
    origin: PreparationDemandOrigin,
    osMajor: UInt64,
    executionCatalog: ExecutionProfileCatalogV1,
    candidatePreparationGroupID: String? = nil,
    callerSelectedPreparationGroupID: String? = nil,
    callerSelectedPersistence: DemandPersistence? = nil
  ) throws -> PreparationDemandDescriptor {
    guard callerSelectedPreparationGroupID == nil else {
      throw PreparationDemandAuthorityError.callerSelectedPreparationGroup
    }
    guard callerSelectedPersistence == nil else {
      throw PreparationDemandAuthorityError.callerSelectedPersistence
    }

    let persistence: DemandPersistence
    let preparationGroupID: String
    switch origin {
    case .explicitPrepare:
      persistence = .epochBound
      preparationGroupID = try DeveloperSupportOSRouting.resolve(
        osMajor: osMajor,
        executionCatalog: executionCatalog
      ).preparationGroupID
    case .finiteCommand:
      persistence = .epochBound
      guard let candidatePreparationGroupID else {
        throw PreparationDemandAuthorityError.missingCandidatePreparationGroup
      }
      guard executionCatalog.preparationGroups.contains(where: {
        $0.preparationGroupID == candidatePreparationGroupID
      }) else {
        throw PreparationDemandAuthorityError.invalidCandidatePreparationGroup(
          candidatePreparationGroupID
        )
      }
      preparationGroupID = candidatePreparationGroupID
    case .livePrewarm:
      persistence = .persistentAcrossReconnect
      preparationGroupID = try DeveloperSupportOSRouting.resolve(
        osMajor: osMajor,
        executionCatalog: executionCatalog
      ).preparationGroupID
    }

    return PreparationDemandDescriptor(
      origin: origin,
      persistence: persistence,
      preparationGroupID: preparationGroupID
    )
  }
}
