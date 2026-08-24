import Foundation
import PulsePhoneDeveloperImageAssets
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneSharedDefinitions

public enum PersonalizedDeveloperSupportError: Error, Equatable, Sendable {
  case invalidCatalogReference
  case invalidTransition
  case missingPersonalizedRole(String)
  case unsupportedImageKind
}

public enum PersonalizedDeveloperSupportOperation: String, Equatable, Sendable {
  case queryMounted
  case requestTSS
  case mount
  case probeServices
}

public struct PersonalizedHelperDeviceContext: Equatable, Sendable {
  public let connectionEpoch: UInt64

  public init(connectionEpoch: UInt64) {
    self.connectionEpoch = connectionEpoch
  }
}

public struct PersonalizedHelperBackendPayload: Equatable, Sendable {
  public let assetContentManifestSHA256: String
  public let catalogCanonicalSHA256: String
  public let catalogRevision: String
  public let deviceContext: PersonalizedHelperDeviceContext
  public let fileRoles: [String]
  public let operation: PersonalizedDeveloperSupportOperation
  public let preparationAttemptID: CanonicalUUID
  public let preparationGroupID: String

  public init(
    assetContentManifestSHA256: String,
    catalogCanonicalSHA256: String,
    catalogRevision: String,
    deviceContext: PersonalizedHelperDeviceContext,
    fileRoles: [String],
    operation: PersonalizedDeveloperSupportOperation,
    preparationAttemptID: CanonicalUUID,
    preparationGroupID: String
  ) {
    self.assetContentManifestSHA256 = assetContentManifestSHA256
    self.catalogCanonicalSHA256 = catalogCanonicalSHA256
    self.catalogRevision = catalogRevision
    self.deviceContext = deviceContext
    self.fileRoles = fileRoles
    self.operation = operation
    self.preparationAttemptID = preparationAttemptID
    self.preparationGroupID = preparationGroupID
  }
}

public enum PersonalizedHelperRequestFactory {
  /// Compatibility adapter retained only while Runtime's pre-release static
  /// fixtures are being migrated. Production preparation uses the snapshot
  /// overload below and never uses this path.
  public static func make(
    operation: PersonalizedDeveloperSupportOperation,
    catalog: DeveloperImageCatalogV1,
    entryID: String,
    connectionEpoch: UInt64,
    preparationAttemptID: CanonicalUUID
  ) throws -> PersonalizedHelperBackendPayload {
    guard let entry = catalog.entries.first(where: { $0.entryID == entryID }),
      entry.imageKind == .personalized
    else { throw PersonalizedDeveloperSupportError.invalidCatalogReference }
    // The legacy catalog fixture predates dynamic BaseImage naming. Its
    // archive paths are not a protocol input: the helper always receives
    // the fixed dynamic role paths below. Keep this adapter aligned with
    // the production snapshot path rather than deriving a manifest from
    // historical archive layout.
    let contentFiles = try normalizedContentFiles(for: entry)
    let contentManifestSHA256 =
      try DynamicDeveloperImageContentManifest
      .sha256(contentFiles)
    let catalogSHA256 = StableBytes.sha256Hex(
      Data(
        try DeveloperImageCatalog.canonicalBytes(catalog)
      ))
    let asset = DynamicDeveloperImageAssetReference(
      archiveSHA256: entry.archiveSHA256,
      archiveSize: entry.archiveSize,
      assetID: entry.entryID,
      contentManifestSHA256: contentManifestSHA256,
      ddiVersion: entry.ddiVersion,
      kind: .baseImage,
      sourceURL: entry.sourceURLs.first
        ?? "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/baseAssets/fixture.tar"
    )
    // The static fixture is intentionally not a valid dynamic catalog, so
    // construct the normalized payload directly rather than selecting it.
    return try makePayload(
      operation: operation, asset: asset, catalogSHA256: catalogSHA256,
      revision: catalog.catalogRevision, connectionEpoch: connectionEpoch,
      preparationAttemptID: preparationAttemptID
    )
  }

  public static func make(
    operation: PersonalizedDeveloperSupportOperation,
    snapshot: DynamicDeveloperImageCatalogSnapshot,
    selection: DynamicDeveloperImageSelection,
    connectionEpoch: UInt64,
    preparationAttemptID: CanonicalUUID
  ) throws -> PersonalizedHelperBackendPayload {
    guard selection.asset.kind == .baseImage,
      snapshot.catalog.baseAssets.contains(where: {
        $0.baseAssetID == selection.asset.assetID
          && $0.contentManifestSHA256
            == selection.asset.contentManifestSHA256
      })
    else {
      throw PersonalizedDeveloperSupportError.invalidCatalogReference
    }
    return try makePayload(
      operation: operation,
      asset: selection.asset,
      catalogSHA256: snapshot.identity.canonicalSHA256,
      revision: snapshot.identity.revision,
      connectionEpoch: connectionEpoch,
      preparationAttemptID: preparationAttemptID
    )
  }

  private static func makePayload(
    operation: PersonalizedDeveloperSupportOperation,
    asset: DynamicDeveloperImageAssetReference,
    catalogSHA256: String,
    revision: String,
    connectionEpoch: UInt64,
    preparationAttemptID: CanonicalUUID
  ) throws -> PersonalizedHelperBackendPayload {
    let requiredRoles: [String]
    switch operation {
    case .queryMounted, .probeServices:
      requiredRoles = []
    case .requestTSS:
      requiredRoles = [
        DeveloperImageFileRole.personalizedBuildManifest.rawValue,
        DeveloperImageFileRole.personalizedImage.rawValue,
      ]
    case .mount:
      requiredRoles = [
        DeveloperImageFileRole.personalizedBuildManifest.rawValue,
        DeveloperImageFileRole.personalizedImage.rawValue,
        DeveloperImageFileRole.personalizedTrustCache.rawValue,
      ]
    }
    return PersonalizedHelperBackendPayload(
      assetContentManifestSHA256: asset.contentManifestSHA256,
      catalogCanonicalSHA256: catalogSHA256,
      catalogRevision: revision,
      deviceContext: PersonalizedHelperDeviceContext(
        connectionEpoch: connectionEpoch
      ),
      fileRoles: requiredRoles,
      operation: operation,
      preparationAttemptID: preparationAttemptID,
      preparationGroupID: "prep.coredevice.v2"
    )
  }

  private static func normalizedContentFiles(
    for entry: DeveloperImageCatalogEntryV1
  ) throws -> [DynamicDeveloperImageContentFile] {
    let required: [(DeveloperImageFileRole, String)] = [
      (.personalizedBuildManifest, "BuildManifest.plist"),
      (.personalizedImage, "Image.dmg"),
      (.personalizedTrustCache, "Image.dmg.trustcache"),
    ]
    return try required.map { role, path in
      guard let file = entry.files.first(where: { $0.fileRole == role.rawValue }) else {
        throw PersonalizedDeveloperSupportError.missingPersonalizedRole(
          role.rawValue
        )
      }
      return DynamicDeveloperImageContentFile(
        path: path,
        sha256: file.sha256,
        size: file.size
      )
    }
  }
}

public enum PersonalizedManifestSource: String, Equatable, Sendable {
  case reusableDeviceManifest
  case appleTSS
}

public enum PersonalizedPreparationPhase: String, Equatable, Sendable {
  case queryMounted
  case requestManifest
  case mount
  case warmGeneration
  case ready
}

public struct PersonalizedPreparationSnapshot: Equatable, Sendable {
  public let phase: PersonalizedPreparationPhase
  public let provenance: DeveloperSupportProvenance?

  public init(
    phase: PersonalizedPreparationPhase,
    provenance: DeveloperSupportProvenance? = nil
  ) {
    self.phase = phase
    self.provenance = provenance
  }
}

public enum PersonalizedPreparationEvent: Equatable, Sendable {
  case mountedObserved(knownApproved: Bool)
  case mountAbsent
  case manifestReady(PersonalizedManifestSource)
  case mountCompleted
  case generationReady
}

public enum PersonalizedPreparationStateMachine {
  public static func advance(
    _ snapshot: PersonalizedPreparationSnapshot,
    event: PersonalizedPreparationEvent
  ) throws -> PersonalizedPreparationSnapshot {
    switch (snapshot.phase, event) {
    case (.queryMounted, .mountedObserved(let knownApproved)):
      return PersonalizedPreparationSnapshot(
        phase: .warmGeneration,
        provenance: knownApproved ? .approved : .mountedUnknownUnverified
      )
    case (.queryMounted, .mountAbsent):
      return PersonalizedPreparationSnapshot(phase: .requestManifest)
    case (.requestManifest, .manifestReady):
      return PersonalizedPreparationSnapshot(phase: .mount)
    case (.mount, .mountCompleted):
      return PersonalizedPreparationSnapshot(
        phase: .warmGeneration,
        provenance: .approved
      )
    case (.warmGeneration, .generationReady):
      return PersonalizedPreparationSnapshot(
        phase: .ready,
        provenance: snapshot.provenance
      )
    default:
      throw PersonalizedDeveloperSupportError.invalidTransition
    }
  }
}

public enum PersonalizedDeveloperSupportDecision: Equatable, Sendable {
  case reuseMounted(DeveloperSupportProvenance)
  case resolveSource(DeveloperImageSourceResolution)
}

public enum PersonalizedDeveloperSupportPlanner {
  public static func decide(
    entry: DeveloperImageCatalogEntryV1,
    mounted: Bool,
    knownApprovedMount: Bool,
    verifiedCacheAvailable: Bool,
    selectedXcode: SelectedXcodeSnapshot?,
    networkAvailable: Bool
  ) throws -> PersonalizedDeveloperSupportDecision {
    guard entry.imageKind == .personalized else {
      throw PersonalizedDeveloperSupportError.unsupportedImageKind
    }
    if mounted {
      return .reuseMounted(
        knownApprovedMount ? .approved : .mountedUnknownUnverified
      )
    }
    return .resolveSource(
      try DeveloperImageSourceResolver.resolve(
        entry: entry,
        alreadyMounted: false,
        verifiedCacheAvailable: verifiedCacheAvailable,
        selectedXcode: selectedXcode,
        networkAvailable: networkAvailable
      )
    )
  }
}
