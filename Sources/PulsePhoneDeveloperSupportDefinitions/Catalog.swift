import Darwin
import Foundation
import PulsePhoneCommandCatalog
import PulsePhoneSharedDefinitions

public enum DeveloperImageCatalogError: Error, Equatable, Sendable {
  case duplicateEntry(String)
  case invalidCanonicalDocument
  case invalidEntry(String)
  case invalidField(String)
  case invalidRevision
  case missing(String)
  case sizeCapExceeded(String)
  case unknownCompatibilityRule(String)
  case unsafeNode(String)
}

public enum DeveloperImageEvidenceState: String, Codable, Sendable {
  case target
  case verified
}

public struct DeveloperImageOSRangeV1: Codable, Equatable, Sendable {
  public let exactBuilds: [String]
  public let maximumMajorExclusive: UInt64?
  public let minimumMajor: UInt64
}

public struct DeveloperImageCatalogFileV1: Codable, Equatable, Sendable {
  public let archiveRelativePath: String
  public let fileRole: String
  public let sha256: String
  public let size: UInt64
}

public struct DeveloperImageCatalogEntryV1: Codable, Equatable, Sendable {
  public let archiveSHA256: String
  public let archiveSize: UInt64
  public let buildID: String
  public let compatibilityRuleID: String
  public let ddiVersion: String
  public let deviceOSRange: DeveloperImageOSRangeV1
  public let entryID: String
  public let evidenceState: DeveloperImageEvidenceState
  public let extractedUpperBound: UInt64
  public let files: [DeveloperImageCatalogFileV1]
  public let imageKind: DeveloperImageKind
  public let requiredServices: [String]
  public let sourceURLs: [String]

  public var assetManifest: AssetContentManifestV1 {
    AssetContentManifestV1(
      files: files.map {
        AssetContentFileV1(fileRole: $0.fileRole, sha256: $0.sha256, size: $0.size)
      },
      imageKind: imageKind
    )
  }
}

public struct DeveloperImageCatalogV1: Codable, Equatable, Sendable {
  public let catalogRevision: String
  public let entries: [DeveloperImageCatalogEntryV1]
  public let schemaVersion: UInt64
}

public struct DeveloperImageCatalogIdentity: Equatable, Sendable {
  public static let domainID = "pulsephone.developer-image-catalog.v1"

  public let hash: String
  public let revision: String
}

public enum DeveloperImageCatalog {
  public static let registryRelativePath = "Registries/developer-image-catalog.v1.json"
  public static let schemaRelativePath =
    "Schemas/developer-support/developer-image-catalog.v1.schema.json"
  public static let maximumCanonicalBytes = 4 * 1_024 * 1_024
  public static let maximumEntries = 4_096
  public static let maximumRevisionFiles = 64
  public static let maximumCatalogBytes = 64 * 1_024 * 1_024
  public static let storeSoftTargetBytes: UInt64 = 6 * 1_024 * 1_024 * 1_024
  public static let storeHardCapBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024

  public static func load(repositoryRoot: URL) throws -> DeveloperImageCatalogV1 {
    let relativePath = registryRelativePath
    let url = repositoryRoot.appendingPathComponent(relativePath)
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
      throw DeveloperImageCatalogError.missing(relativePath)
    }
    guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_nlink == 1 else {
      throw DeveloperImageCatalogError.unsafeNode(relativePath)
    }
    return try decodeCanonical([UInt8](Data(contentsOf: url, options: [.mappedIfSafe])))
  }

  public static func decodeCanonical(_ bytes: [UInt8]) throws -> DeveloperImageCatalogV1 {
    guard bytes.count <= maximumCanonicalBytes else {
      throw DeveloperImageCatalogError.sizeCapExceeded("canonical bytes")
    }
    let document: RepositoryCanonicalJSONDocument
    do {
      document = try RepositoryCanonicalJSON.validateCanonicalDocument(
        bytes,
        maximumByteCount: maximumCanonicalBytes
      )
    } catch {
      throw DeveloperImageCatalogError.invalidCanonicalDocument
    }
    try validateShape(document.root)
    let catalog = try JSONDecoder().decode(DeveloperImageCatalogV1.self, from: Data(bytes))
    try validate(catalog)
    return catalog
  }

  public static func identity(
    catalog: DeveloperImageCatalogV1
  ) throws -> DeveloperImageCatalogIdentity {
    let bytes = try canonicalBytes(catalog)
    return DeveloperImageCatalogIdentity(
      hash: try StableBytes.domainSeparatedSHA256Hex(
        domainID: DeveloperImageCatalogIdentity.domainID,
        payload: bytes
      ),
      revision: catalog.catalogRevision
    )
  }

  public static func canonicalBytes(_ catalog: DeveloperImageCatalogV1) throws -> [UInt8] {
    let data = try JSONEncoder.sorted.encode(catalog)
    let document = try RepositoryCanonicalJSON.validateCanonicalDocument(
      [UInt8](data),
      maximumByteCount: maximumCanonicalBytes
    )
    return document.exactBytes
  }

  public static func validateCompatibilityRules(
    catalog: DeveloperImageCatalogV1,
    executionCatalog: ExecutionProfileCatalogV1
  ) throws {
    let ruleIDs = Set(executionCatalog.compatibilityRules.map(\.ruleID))
    for entry in catalog.entries where !ruleIDs.contains(entry.compatibilityRuleID) {
      throw DeveloperImageCatalogError.unknownCompatibilityRule(entry.compatibilityRuleID)
    }
  }

  private static func validate(_ catalog: DeveloperImageCatalogV1) throws {
    guard catalog.schemaVersion == 1 else {
      throw DeveloperImageCatalogError.invalidField("schemaVersion")
    }
    let revisionBytes = Array(catalog.catalogRevision.utf8)
    guard (1...256).contains(revisionBytes.count),
      revisionBytes.allSatisfy({ (0x21...0x7e).contains($0) })
    else {
      throw DeveloperImageCatalogError.invalidRevision
    }
    guard catalog.entries.count <= maximumEntries else {
      throw DeveloperImageCatalogError.sizeCapExceeded("entries")
    }
    let sortedIDs = catalog.entries.map(\.entryID).sorted(by: asciiLessThan)
    guard sortedIDs == catalog.entries.map(\.entryID) else {
      throw DeveloperImageCatalogError.invalidEntry("entry order")
    }
    guard Set(sortedIDs).count == sortedIDs.count else {
      throw DeveloperImageCatalogError.duplicateEntry("entryID")
    }
    for entry in catalog.entries {
      try validate(entry)
    }
  }

  private static func validate(_ entry: DeveloperImageCatalogEntryV1) throws {
    let validMajorRange = entry.deviceOSRange.maximumMajorExclusive.map {
      $0 > entry.deviceOSRange.minimumMajor
    } ?? true
    guard StableBytes.isLowercaseHex(entry.archiveSHA256, byteCount: 32),
      entry.archiveSize > 0,
      entry.archiveSize <= storeHardCapBytes,
      entry.extractedUpperBound >= entry.files.reduce(0, { $0 + $1.size }),
      entry.extractedUpperBound <= storeHardCapBytes,
      entry.sourceURLs.count <= 3,
      Set(entry.sourceURLs).count == entry.sourceURLs.count,
      entry.requiredServices == entry.requiredServices.sorted(by: asciiLessThan),
      Set(entry.requiredServices).count == entry.requiredServices.count,
      entry.deviceOSRange.exactBuilds
        == entry.deviceOSRange.exactBuilds.sorted(by: asciiLessThan),
      Set(entry.deviceOSRange.exactBuilds).count == entry.deviceOSRange.exactBuilds.count,
      validMajorRange
    else {
      throw DeveloperImageCatalogError.invalidEntry(entry.entryID)
    }
    for url in entry.sourceURLs {
      try DeveloperImageSourcePolicy.validateApprovedRemoteURL(url)
    }
    for file in entry.files {
      try DeveloperImageAssetIdentity.validate(role: file.fileRole)
      guard StableBytes.isLowercaseHex(file.sha256, byteCount: 32), file.size > 0,
        isSafeArchivePath(file.archiveRelativePath)
      else {
        throw DeveloperImageCatalogError.invalidEntry(entry.entryID)
      }
    }
    _ = try entry.assetManifest.validated()
  }

  private static func validateShape(_ root: RepositoryJSONObject) throws {
    guard Set(root.members.map(\.key)) == ["catalogRevision", "entries", "schemaVersion"],
      let entries = root["entries"]?.arrayValue
    else {
      throw DeveloperImageCatalogError.invalidField("catalog")
    }
    let entryKeys: Set<String> = [
      "archiveSHA256", "archiveSize", "buildID", "compatibilityRuleID",
      "ddiVersion", "deviceOSRange", "entryID", "evidenceState",
      "extractedUpperBound", "files", "imageKind", "requiredServices", "sourceURLs",
    ]
    for value in entries {
      guard let entry = value.objectValue, Set(entry.members.map(\.key)) == entryKeys else {
        throw DeveloperImageCatalogError.invalidField("entry")
      }
    }
  }

  private static func isSafeArchivePath(_ value: String) -> Bool {
    !value.isEmpty && !value.hasPrefix("/") && !value.contains("..")
      && !value.contains("\\") && value.utf8.count <= 4_096
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
