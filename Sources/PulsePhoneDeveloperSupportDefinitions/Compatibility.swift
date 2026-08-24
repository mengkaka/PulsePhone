import PulsePhoneCommandCatalog

public enum DeveloperImageCompatibilityDisposition: Equatable, Sendable {
  case compatible
  case incompatible
}

public struct DeveloperImageCompatibilityTuple: Equatable, Sendable {
  public let hash: String
  public let revision: String

  public init(hash: String, revision: String) {
    self.hash = hash
    self.revision = revision
  }
}

public struct DeveloperSupportCrossSetProjectionV1: Equatable, Sendable {
  public let compatibilityRuleIDs: [String]
  public let developerImageCatalogHash: String
  public let developerImageCatalogRevision: String
  public let pendingSameIdentityBinding: Bool
  public let preparationGroupIDs: [String]
  public let schemaIDs: [String]
}

public enum DeveloperImageCompatibility {
  public static func compare(
    client: DeveloperImageCompatibilityTuple,
    runtime: DeveloperImageCompatibilityTuple
  ) -> DeveloperImageCompatibilityDisposition {
    client == runtime ? .compatible : .incompatible
  }

  public static func partialProjection(
    catalog: DeveloperImageCatalogV1,
    executionCatalog: ExecutionProfileCatalogV1
  ) throws -> DeveloperSupportCrossSetProjectionV1 {
    try DeveloperImageCatalog.validateCompatibilityRules(
      catalog: catalog,
      executionCatalog: executionCatalog
    )
    let identity = try DeveloperImageCatalog.identity(catalog: catalog)
    return DeveloperSupportCrossSetProjectionV1(
      compatibilityRuleIDs: Array(Set(catalog.entries.map(\.compatibilityRuleID))).sorted(),
      developerImageCatalogHash: identity.hash,
      developerImageCatalogRevision: identity.revision,
      pendingSameIdentityBinding: true,
      preparationGroupIDs: executionCatalog.preparationGroups.map(\.preparationGroupID).sorted(),
      schemaIDs: [
        "assetContentManifest.v1", "developerImageCacheIndex.v1",
        "developerImageCatalog.v1", "developerSupportProvenance.v1",
        "partialDownloadState.v1", "preparationGroup.v1",
      ]
    )
  }

  public static func exactEntry(
    in catalog: DeveloperImageCatalogV1,
    osMajor: UInt64,
    buildID: String
  ) -> DeveloperImageCatalogEntryV1? {
    let matches = catalog.entries.filter { entry in
      entry.deviceOSRange.minimumMajor <= osMajor
        && (entry.deviceOSRange.maximumMajorExclusive.map { osMajor < $0 } ?? true)
        && entry.deviceOSRange.exactBuilds.contains(buildID)
    }
    return matches.count == 1 ? matches[0] : nil
  }
}
