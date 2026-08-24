import Darwin
import Foundation
import PulsePhoneDeveloperSupportDefinitions

public enum DeveloperImageAssetStoreError: Error, Equatable, Sendable {
  case capacityExceeded
  case catalogMismatch
  case integrityMismatch(String)
  case invalidArchive(String)
  case invalidAssetKey
  case invalidCatalogEntry(String)
  case invalidPartialState
  case invalidPreparationRehydrationEligibility
  case lockUnavailable(String)
  case sourceUnavailable
  case systemCall(operation: String, errno: Int32)
  case unsafeNode(String)
}

public struct DeveloperImageAssetStoreLimits: Equatable, Sendable {
  public let softTargetBytes: UInt64
  public let hardCapBytes: UInt64
  public let maximumCatalogBytes: UInt64
  public let maximumCatalogCount: Int
  public let maximumCatalogTotalBytes: UInt64

  public init(
    softTargetBytes: UInt64 = DeveloperImageCatalog.storeSoftTargetBytes,
    hardCapBytes: UInt64 = DeveloperImageCatalog.storeHardCapBytes,
    maximumCatalogBytes: UInt64 = UInt64(DeveloperImageCatalog.maximumCanonicalBytes),
    maximumCatalogCount: Int = DeveloperImageCatalog.maximumRevisionFiles,
    maximumCatalogTotalBytes: UInt64 = UInt64(DeveloperImageCatalog.maximumCatalogBytes)
  ) {
    self.softTargetBytes = softTargetBytes
    self.hardCapBytes = hardCapBytes
    self.maximumCatalogBytes = maximumCatalogBytes
    self.maximumCatalogCount = maximumCatalogCount
    self.maximumCatalogTotalBytes = maximumCatalogTotalBytes
  }

  public func validated() throws -> DeveloperImageAssetStoreLimits {
    guard softTargetBytes <= hardCapBytes,
      maximumCatalogBytes <= hardCapBytes,
      maximumCatalogCount > 0,
      maximumCatalogTotalBytes <= hardCapBytes
    else {
      throw DeveloperImageAssetStoreError.capacityExceeded
    }
    return self
  }
}

public struct DeveloperImageStoreAccounting: Equatable, Sendable {
  public let assetBytes: UInt64
  public let catalogBytes: UInt64
  public let downloadBytes: UInt64
  public let metadataBytes: UInt64

  public init(
    assetBytes: UInt64,
    catalogBytes: UInt64,
    downloadBytes: UInt64,
    metadataBytes: UInt64
  ) {
    self.assetBytes = assetBytes
    self.catalogBytes = catalogBytes
    self.downloadBytes = downloadBytes
    self.metadataBytes = metadataBytes
  }

  public var totalBytes: UInt64 {
    assetBytes + catalogBytes + downloadBytes + metadataBytes
  }
}

/// A non-authoritative, host-private eligibility record. It only permits a
/// fresh Runtime to attempt an actual mounted-image and service-warm check.
/// It never proves that a device is ready on its own.
public struct DeveloperSupportRehydrationEligibilityReceipt: Codable, Equatable, Sendable {
  public let buildVersion: String
  public let preparationGroupID: String
  public let productType: String
  public let productVersion: String
  public let schemaVersion: UInt64
  public let targetIdentityHash: String

  public init(
    buildVersion: String,
    preparationGroupID: String,
    productType: String,
    productVersion: String,
    targetIdentityHash: String,
    schemaVersion: UInt64 = 1
  ) {
    self.buildVersion = buildVersion
    self.preparationGroupID = preparationGroupID
    self.productType = productType
    self.productVersion = productVersion
    self.schemaVersion = schemaVersion
    self.targetIdentityHash = targetIdentityHash
  }
}

public enum DeveloperImageArchiveEntryKind: String, Codable, Sendable {
  case blockDevice
  case characterDevice
  case directory
  case hardLink
  case regularFile
  case symbolicLink
}

public struct DeveloperImageArchiveEntry: Equatable, Sendable {
  public let bytes: Data
  public let kind: DeveloperImageArchiveEntryKind
  public let path: String

  public init(path: String, kind: DeveloperImageArchiveEntryKind, bytes: Data = Data()) {
    self.path = path
    self.kind = kind
    self.bytes = bytes
  }
}

public enum DeveloperImagePublishFault: Equatable, Sendable {
  case none
  case afterFirstRoleFsync
  case beforeAtomicRename
}

public struct DeveloperImagePublishedAsset: Equatable, Sendable {
  public let assetKey: String
  public let roleRelativePaths: [String: String]

  public init(assetKey: String, roleRelativePaths: [String: String]) {
    self.assetKey = assetKey
    self.roleRelativePaths = roleRelativePaths
  }
}

public enum PartialDownloadAdoption: Equatable, Sendable {
  case absent
  case adopted(PartialDownloadStateV1)
  case discarded
}

public final class DeveloperImageRoleFile: @unchecked Sendable {
  public let fileRole: String
  public let size: UInt64
  private var descriptor: Int32

  init(fileRole: String, size: UInt64, descriptor: Int32) {
    self.fileRole = fileRole
    self.size = size
    self.descriptor = descriptor
  }

  deinit {
    if descriptor >= 0 {
      Darwin.close(descriptor)
    }
  }

  public func withUnsafeFileDescriptor<Result>(
    _ body: (Int32) throws -> Result
  ) rethrows -> Result {
    try body(descriptor)
  }
}

public final class DeveloperImageAssetLease: @unchecked Sendable {
  public let assetKey: String
  public let roleFiles: [String: DeveloperImageRoleFile]
  private var lockDescriptor: Int32

  init(
    assetKey: String,
    roleFiles: [String: DeveloperImageRoleFile],
    lockDescriptor: Int32
  ) {
    self.assetKey = assetKey
    self.roleFiles = roleFiles
    self.lockDescriptor = lockDescriptor
  }

  deinit {
    if lockDescriptor >= 0 {
      _ = flock(lockDescriptor, LOCK_UN)
      Darwin.close(lockDescriptor)
    }
  }
}

public enum DeveloperImageSourceKind: String, Codable, Sendable {
  case alreadyMounted
  case approvedRemote
  case selectedReleaseXcode
  case typedUnavailable
  case verifiedCache
}

public struct DeveloperImageSourceResolution: Equatable, Sendable {
  public let kind: DeveloperImageSourceKind
  public let remoteSourceIndex: UInt64?
  public let xcodeRolePaths: [String: String]

  public init(
    kind: DeveloperImageSourceKind,
    remoteSourceIndex: UInt64? = nil,
    xcodeRolePaths: [String: String] = [:]
  ) {
    self.kind = kind
    self.remoteSourceIndex = remoteSourceIndex
    self.xcodeRolePaths = xcodeRolePaths
  }
}

public struct SelectedXcodeRoleFile: Equatable, Sendable {
  public let path: String
  public let sha256: String
  public let size: UInt64

  public init(path: String, sha256: String, size: UInt64) {
    self.path = path
    self.sha256 = sha256
    self.size = size
  }
}

public struct SelectedXcodePair: Equatable, Sendable {
  public let buildID: String
  public let ddiVersion: String
  public let roleFiles: [String: SelectedXcodeRoleFile]

  public init(buildID: String, ddiVersion: String, roleFiles: [String: SelectedXcodeRoleFile]) {
    self.buildID = buildID
    self.ddiVersion = ddiVersion
    self.roleFiles = roleFiles
  }
}

public struct SelectedXcodeSnapshot: Equatable, Sendable {
  public let appPath: String
  public let bundleIdentifier: String
  public let developerPath: String
  public let gatekeeperAccepted: Bool
  public let licenseType: String
  public let pairs: [SelectedXcodePair]
  public let signatureValid: Bool

  public init(
    appPath: String,
    bundleIdentifier: String,
    developerPath: String,
    gatekeeperAccepted: Bool,
    licenseType: String,
    pairs: [SelectedXcodePair],
    signatureValid: Bool
  ) {
    self.appPath = appPath
    self.bundleIdentifier = bundleIdentifier
    self.developerPath = developerPath
    self.gatekeeperAccepted = gatekeeperAccepted
    self.licenseType = licenseType
    self.pairs = pairs
    self.signatureValid = signatureValid
  }
}
