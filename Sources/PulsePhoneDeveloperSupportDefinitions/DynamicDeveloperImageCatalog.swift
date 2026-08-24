import Foundation
import PulsePhoneSharedDefinitions

public enum DynamicDeveloperImageCatalogError: Error, Equatable, Sendable {
  case duplicate(String)
  case invalidCanonicalDocument
  case invalidContentManifest
  case invalidField(String)
  case invalidRevision
  case missingReference(String)
}

public enum DynamicDeveloperImageAssetKind: String, Equatable, Sendable {
  case baseImage
  case developerDiskImage
}

public struct DynamicDeveloperImageBaseAssetV1: Codable, Equatable, Sendable {
  public let archiveSHA256: String
  public let archiveSize: UInt64
  public let baseAssetID: String
  public let contentManifestSHA256: String
  public let sourceURL: String
}

public struct DynamicDeveloperDiskImageAssetV1: Codable, Equatable, Sendable {
  public let archiveSHA256: String
  public let archiveSize: UInt64
  public let contentManifestSHA256: String
  public let ddiVersion: String
  public let sourceURL: String
}

public struct DynamicDeveloperImageCatalogEntryV1: Codable, Equatable, Sendable {
  public let baseAssetID: String
  public let buildID: String
  public let iosVersion: String
}

public struct DynamicDeveloperImageCatalogV1: Codable, Equatable, Sendable {
  public let baseAssets: [DynamicDeveloperImageBaseAssetV1]
  public let catalogEntry: [DynamicDeveloperImageCatalogEntryV1]
  public let catalogRevision: String
  public let defaultCandidateBaseAssetID: String
  public let developerDiskImages: [DynamicDeveloperDiskImageAssetV1]
  public let schemaVersion: UInt64
}

/// A selected asset intentionally includes only values that were authenticated
/// by the pinned catalog snapshot. It is the bridge between selection and
/// acquisition; callers must not infer a source or a different asset from it.
public struct DynamicDeveloperImageAssetReference: Equatable, Sendable {
  public let archiveSHA256: String
  public let archiveSize: UInt64
  public let assetID: String
  public let contentManifestSHA256: String
  public let ddiVersion: String?
  public let kind: DynamicDeveloperImageAssetKind
  public let sourceURL: String

  public init(
    archiveSHA256: String,
    archiveSize: UInt64,
    assetID: String,
    contentManifestSHA256: String,
    ddiVersion: String?,
    kind: DynamicDeveloperImageAssetKind,
    sourceURL: String
  ) {
    self.archiveSHA256 = archiveSHA256
    self.archiveSize = archiveSize
    self.assetID = assetID
    self.contentManifestSHA256 = contentManifestSHA256
    self.ddiVersion = ddiVersion
    self.kind = kind
    self.sourceURL = sourceURL
  }
}

public enum DynamicDeveloperImageSelectionProvenance: String, Equatable, Sendable {
  case defaultCandidate
  case localValidated
  case remoteVerified
}

public struct DynamicDeveloperImageSelection: Equatable, Sendable {
  public let asset: DynamicDeveloperImageAssetReference
  public let provenance: DynamicDeveloperImageSelectionProvenance

  public init(
    asset: DynamicDeveloperImageAssetReference,
    provenance: DynamicDeveloperImageSelectionProvenance
  ) {
    self.asset = asset
    self.provenance = provenance
  }
}

public struct DynamicDeveloperImageCatalogIdentity: Equatable, Sendable {
  public let canonicalSHA256: String
  public let revision: String

  public init(canonicalSHA256: String, revision: String) {
    self.canonicalSHA256 = canonicalSHA256
    self.revision = revision
  }
}

public struct DynamicDeveloperImageCatalogSnapshot: Equatable, Sendable {
  public let catalog: DynamicDeveloperImageCatalogV1
  public let identity: DynamicDeveloperImageCatalogIdentity
  public let staleCatalog: Bool

  public init(
    catalog: DynamicDeveloperImageCatalogV1,
    identity: DynamicDeveloperImageCatalogIdentity,
    staleCatalog: Bool
  ) {
    self.catalog = catalog
    self.identity = identity
    self.staleCatalog = staleCatalog
  }
}

public struct DynamicDeveloperImageContentFile: Codable, Equatable, Sendable {
  public let path: String
  public let sha256: String
  public let size: UInt64

  public init(path: String, sha256: String, size: UInt64) {
    self.path = path
    self.sha256 = sha256
    self.size = size
  }
}

public enum DynamicDeveloperImageContentManifest {
  public static func canonicalBytes(
    _ files: [DynamicDeveloperImageContentFile]
  ) throws -> [UInt8] {
    guard !files.isEmpty,
      files.map(\.path) == files.map(\.path).sorted(by: asciiLessThan),
      Set(files.map(\.path)).count == files.count
    else {
      throw DynamicDeveloperImageCatalogError.invalidContentManifest
    }
    for file in files {
      guard allowedPaths.contains(file.path), file.size > 0,
        StableBytes.isLowercaseHex(file.sha256, byteCount: 32)
      else {
        throw DynamicDeveloperImageCatalogError.invalidContentManifest
      }
    }
    // RepositoryCanonicalJSON currently models canonical documents as object
    // roots. The published content-manifest contract is deliberately a JSON
    // array, whose elements contain only UTF-8 strings and safe integers.
    return [UInt8](try JSONEncoder.sorted.encode(files))
  }

  public static func sha256(_ files: [DynamicDeveloperImageContentFile]) throws -> String {
    StableBytes.sha256Hex(Data(try canonicalBytes(files)))
  }

  public static func requiredPaths(for kind: DynamicDeveloperImageAssetKind) -> Set<String> {
    switch kind {
    case .baseImage:
      return ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache"]
    case .developerDiskImage:
      return ["DeveloperDiskImage.dmg", "DeveloperDiskImage.dmg.signature"]
    }
  }

  private static let allowedPaths: Set<String> = [
    "BuildManifest.plist",
    "DeveloperDiskImage.dmg",
    "DeveloperDiskImage.dmg.signature",
    "Image.dmg",
    "Image.dmg.trustcache",
  ]

  private static func asciiLessThan(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
  }
}

public enum DynamicDeveloperImageCatalog {
  public static let schemaVersion: UInt64 = 1
  public static let maximumCanonicalBytes = DeveloperImageCatalog.maximumCanonicalBytes

  public static func decodeCanonical(
    _ bytes: [UInt8]
  ) throws -> DynamicDeveloperImageCatalogV1 {
    guard bytes.count <= maximumCanonicalBytes else {
      throw DynamicDeveloperImageCatalogError.invalidCanonicalDocument
    }
    let document: RepositoryCanonicalJSONDocument
    do {
      document = try RepositoryCanonicalJSON.validateCanonicalDocument(
        bytes,
        maximumByteCount: maximumCanonicalBytes
      )
    } catch {
      throw DynamicDeveloperImageCatalogError.invalidCanonicalDocument
    }
    try validateShape(document.root)
    let catalog: DynamicDeveloperImageCatalogV1
    do {
      catalog = try JSONDecoder().decode(DynamicDeveloperImageCatalogV1.self, from: Data(bytes))
    } catch {
      throw DynamicDeveloperImageCatalogError.invalidCanonicalDocument
    }
    try validate(catalog)
    return catalog
  }

  public static func canonicalBytes(
    _ catalog: DynamicDeveloperImageCatalogV1
  ) throws -> [UInt8] {
    let encoded = try JSONEncoder.sorted.encode(catalog)
    do {
      let canonical = try RepositoryCanonicalJSON.validateCanonicalDocument(
        [UInt8](encoded),
        maximumByteCount: maximumCanonicalBytes
      )
      let decoded = try decodeCanonical(canonical.exactBytes)
      guard decoded == catalog else {
        throw DynamicDeveloperImageCatalogError.invalidCanonicalDocument
      }
      return canonical.exactBytes
    } catch let error as DynamicDeveloperImageCatalogError {
      throw error
    } catch {
      throw DynamicDeveloperImageCatalogError.invalidCanonicalDocument
    }
  }

  public static func identity(
    catalog: DynamicDeveloperImageCatalogV1
  ) throws -> DynamicDeveloperImageCatalogIdentity {
    DynamicDeveloperImageCatalogIdentity(
      canonicalSHA256: StableBytes.sha256Hex(Data(try canonicalBytes(catalog))),
      revision: catalog.catalogRevision
    )
  }

  /// Preserves the authenticated identity of a canonical snapshot whose
  /// deprecated fields are intentionally ignored by the current model.
  public static func identity(
    catalog: DynamicDeveloperImageCatalogV1,
    canonicalBytes: [UInt8]
  ) throws -> DynamicDeveloperImageCatalogIdentity {
    guard try decodeCanonical(canonicalBytes) == catalog else {
      throw DynamicDeveloperImageCatalogError.invalidCanonicalDocument
    }
    return DynamicDeveloperImageCatalogIdentity(
      canonicalSHA256: StableBytes.sha256Hex(Data(canonicalBytes)),
      revision: catalog.catalogRevision
    )
  }

  public static func isStrictlyNewerRevision(_ lhs: String, than rhs: String) -> Bool {
    guard let left = revisionParts(lhs), let right = revisionParts(rhs) else { return false }
    if left.date != right.date { return left.date > right.date }
    if left.sequence.count != right.sequence.count {
      return left.sequence.count > right.sequence.count
    }
    return left.sequence.utf8.lexicographicallyPrecedes(right.sequence.utf8) == false
      && left.sequence != right.sequence
  }

  public static func compareRevisions(_ lhs: String, _ rhs: String) -> ComparisonResult? {
    guard let left = revisionParts(lhs), let right = revisionParts(rhs) else { return nil }
    if left.date != right.date { return left.date < right.date ? .orderedAscending : .orderedDescending }
    if left.sequence.count != right.sequence.count {
      return left.sequence.count < right.sequence.count ? .orderedAscending : .orderedDescending
    }
    if left.sequence == right.sequence { return .orderedSame }
    return left.sequence.utf8.lexicographicallyPrecedes(right.sequence.utf8)
      ? .orderedAscending
      : .orderedDescending
  }

  public static func exactBaseAsset(
    in catalog: DynamicDeveloperImageCatalogV1,
    buildID: String
  ) -> DynamicDeveloperImageSelection? {
    guard let entry = catalog.catalogEntry.first(where: { $0.buildID == buildID }),
      let base = catalog.baseAssets.first(where: { $0.baseAssetID == entry.baseAssetID })
    else { return nil }
    return DynamicDeveloperImageSelection(
      asset: baseReference(base),
      provenance: .remoteVerified
    )
  }

  public static func baseAsset(
    in catalog: DynamicDeveloperImageCatalogV1,
    baseAssetID: String,
    provenance: DynamicDeveloperImageSelectionProvenance
  ) -> DynamicDeveloperImageSelection? {
    guard let base = catalog.baseAssets.first(where: { $0.baseAssetID == baseAssetID }) else {
      return nil
    }
    return DynamicDeveloperImageSelection(asset: baseReference(base), provenance: provenance)
  }

  public static func classicDDI(
    in catalog: DynamicDeveloperImageCatalogV1,
    iosVersion: String
  ) -> DynamicDeveloperImageAssetReference? {
    guard let requested = semanticVersion(iosVersion) else { return nil }
    if let exact = catalog.developerDiskImages.first(where: { $0.ddiVersion == iosVersion }) {
      return classicReference(exact)
    }
    guard requested.count == 3 else { return nil }
    let minor = requested.prefix(2).map(String.init).joined(separator: ".")
    guard let fallback = catalog.developerDiskImages.first(where: { $0.ddiVersion == minor }) else {
      return nil
    }
    return classicReference(fallback)
  }

  private static func validate(_ catalog: DynamicDeveloperImageCatalogV1) throws {
    guard catalog.schemaVersion == schemaVersion,
      revisionParts(catalog.catalogRevision) != nil,
      validIdentifier(catalog.defaultCandidateBaseAssetID),
      catalog.baseAssets.map(\.baseAssetID) == catalog.baseAssets.map(\.baseAssetID).sorted(by: asciiLessThan),
      catalog.developerDiskImages.map(\.ddiVersion)
        == catalog.developerDiskImages.map(\.ddiVersion).sorted(by: semanticVersionLessThan),
      catalog.catalogEntry.map(\.buildID) == catalog.catalogEntry.map(\.buildID).sorted(by: asciiLessThan),
      Set(catalog.baseAssets.map(\.baseAssetID)).count == catalog.baseAssets.count,
      Set(catalog.developerDiskImages.map(\.ddiVersion)).count == catalog.developerDiskImages.count,
      Set(catalog.catalogEntry.map(\.buildID)).count == catalog.catalogEntry.count,
      catalog.baseAssets.contains(where: { $0.baseAssetID == catalog.defaultCandidateBaseAssetID })
    else {
      throw DynamicDeveloperImageCatalogError.invalidField("catalog")
    }
    for asset in catalog.baseAssets {
      try validate(asset)
    }
    for asset in catalog.developerDiskImages {
      try validate(asset)
    }
    for entry in catalog.catalogEntry {
      guard validIdentifier(entry.baseAssetID), validBuildID(entry.buildID),
        semanticVersion(entry.iosVersion) != nil,
        catalog.baseAssets.contains(where: { $0.baseAssetID == entry.baseAssetID })
      else {
        throw DynamicDeveloperImageCatalogError.invalidField("catalogEntry")
      }
    }
  }

  private static func validate(_ asset: DynamicDeveloperImageBaseAssetV1) throws {
    guard validIdentifier(asset.baseAssetID) else {
      throw DynamicDeveloperImageCatalogError.invalidField("baseAssetID")
    }
    try validateAsset(
      archiveSHA256: asset.archiveSHA256,
      archiveSize: asset.archiveSize,
      contentManifestSHA256: asset.contentManifestSHA256,
      sourceURL: asset.sourceURL
    )
  }

  private static func validate(_ asset: DynamicDeveloperDiskImageAssetV1) throws {
    guard semanticVersion(asset.ddiVersion) != nil else {
      throw DynamicDeveloperImageCatalogError.invalidField("ddiVersion")
    }
    try validateAsset(
      archiveSHA256: asset.archiveSHA256,
      archiveSize: asset.archiveSize,
      contentManifestSHA256: asset.contentManifestSHA256,
      sourceURL: asset.sourceURL
    )
  }

  private static func validateAsset(
    archiveSHA256: String,
    archiveSize: UInt64,
    contentManifestSHA256: String,
    sourceURL: String
  ) throws {
    guard StableBytes.isLowercaseHex(archiveSHA256, byteCount: 32),
      StableBytes.isLowercaseHex(contentManifestSHA256, byteCount: 32),
      archiveSize > 0,
      archiveSize <= 9_007_199_254_740_991
    else {
      throw DynamicDeveloperImageCatalogError.invalidField("asset")
    }
    do {
      try DeveloperImageSourcePolicy.validateApprovedRemoteURL(sourceURL)
    } catch {
      throw DynamicDeveloperImageCatalogError.invalidField("sourceURL")
    }
  }

  private static func validateShape(_ root: RepositoryJSONObject) throws {
    let topLevel: Set<String> = [
      "baseAssets", "catalogEntry", "catalogRevision", "defaultCandidateBaseAssetID",
      "developerDiskImages", "schemaVersion",
    ]
    guard Set(root.members.map(\.key)) == topLevel,
      let baseAssets = root["baseAssets"]?.arrayValue,
      let diskImages = root["developerDiskImages"]?.arrayValue,
      let entries = root["catalogEntry"]?.arrayValue
    else {
      throw DynamicDeveloperImageCatalogError.invalidField("catalog")
    }
    let baseKeys: Set<String> = [
      "archiveSHA256", "archiveSize", "baseAssetID", "contentManifestSHA256", "sourceURL",
    ]
    let diskKeys: Set<String> = [
      "archiveSHA256", "archiveSize", "contentManifestSHA256", "ddiVersion", "sourceURL",
    ]
    // Keep last-known-good v1 snapshots readable across this schema cleanup.
    // The removed key has no runtime meaning and must not direct host lookup.
    let legacyDiskKeys = diskKeys.union(["xcodeDDIVersion"])
    let entryKeys: Set<String> = ["baseAssetID", "buildID", "iosVersion"]
    guard baseAssets.allSatisfy({ $0.objectValue.map { Set($0.members.map(\.key)) == baseKeys } ?? false }),
      diskImages.allSatisfy({
        $0.objectValue.map {
          let keys = Set($0.members.map(\.key))
          return keys == diskKeys || keys == legacyDiskKeys
        } ?? false
      }),
      entries.allSatisfy({ $0.objectValue.map { Set($0.members.map(\.key)) == entryKeys } ?? false })
    else {
      throw DynamicDeveloperImageCatalogError.invalidField("asset")
    }
  }

  private static func baseReference(
    _ asset: DynamicDeveloperImageBaseAssetV1
  ) -> DynamicDeveloperImageAssetReference {
    DynamicDeveloperImageAssetReference(
      archiveSHA256: asset.archiveSHA256,
      archiveSize: asset.archiveSize,
      assetID: asset.baseAssetID,
      contentManifestSHA256: asset.contentManifestSHA256,
      ddiVersion: nil,
      kind: .baseImage,
      sourceURL: asset.sourceURL
    )
  }

  private static func classicReference(
    _ asset: DynamicDeveloperDiskImageAssetV1
  ) -> DynamicDeveloperImageAssetReference {
    DynamicDeveloperImageAssetReference(
      archiveSHA256: asset.archiveSHA256,
      archiveSize: asset.archiveSize,
      assetID: asset.ddiVersion,
      contentManifestSHA256: asset.contentManifestSHA256,
      ddiVersion: asset.ddiVersion,
      kind: .developerDiskImage,
      sourceURL: asset.sourceURL
    )
  }

  private static func revisionParts(_ value: String) -> (date: String, sequence: String)? {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2,
      parts[0].utf8.count == 10,
      parts[0].utf8.enumerated().allSatisfy({ index, byte in
        switch index {
        case 4, 7: return byte == 0x2d
        default: return (0x30...0x39).contains(byte)
        }
      }),
      let year = Int(parts[0].prefix(4)), let month = Int(parts[0].dropFirst(5).prefix(2)),
      let day = Int(parts[0].suffix(2)), year > 0, (1...12).contains(month),
      let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day)),
      Calendar(identifier: .gregorian).component(.day, from: date) == day,
      !parts[1].isEmpty, parts[1].allSatisfy({ $0 >= "0" && $0 <= "9" }),
      parts[1] != "0", !parts[1].hasPrefix("0")
    else { return nil }
    return (String(parts[0]), String(parts[1]))
  }

  private static func semanticVersion(_ value: String) -> [UInt64]? {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    let values = parts.map { UInt64($0) }
    guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty }),
      parts.allSatisfy({ $0.allSatisfy({ $0 >= "0" && $0 <= "9" }) }),
      parts.allSatisfy({ $0 == "0" || !$0.hasPrefix("0") }),
      values.allSatisfy({ $0 != nil })
    else { return nil }
    return values.compactMap { $0 }
  }

  private static func semanticVersionLessThan(_ lhs: String, _ rhs: String) -> Bool {
    guard let left = semanticVersion(lhs), let right = semanticVersion(rhs) else {
      return asciiLessThan(lhs, rhs)
    }
    for index in 0..<max(left.count, right.count) {
      let a = index < left.count ? left[index] : 0
      let b = index < right.count ? right[index] : 0
      if a != b { return a < b }
    }
    return false
  }

  private static func validIdentifier(_ value: String) -> Bool {
    let bytes = value.utf8
    return !bytes.isEmpty && bytes.count <= 256 && bytes.allSatisfy {
      (0x30...0x39).contains($0) || (0x41...0x5a).contains($0)
        || (0x61...0x7a).contains($0) || $0 == 0x2d || $0 == 0x2e
    }
  }

  private static func validBuildID(_ value: String) -> Bool {
    let bytes = value.utf8
    return !bytes.isEmpty && bytes.count <= 128 && bytes.allSatisfy {
      (0x30...0x39).contains($0) || (0x41...0x5a).contains($0)
        || (0x61...0x7a).contains($0)
    }
  }

  private static func asciiLessThan(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
  }
}

private extension JSONEncoder {
  static var sorted: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}
