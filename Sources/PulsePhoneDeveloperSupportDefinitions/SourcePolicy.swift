import Foundation
import PulsePhoneSharedDefinitions

public enum DeveloperImageSourcePolicyError: Error, Equatable, Sendable {
  case invalidPartialState(String)
  case invalidSourceURL
  case sidecarIdentityMismatch
}

public enum DeveloperSupportProvenance: String, CaseIterable, Codable, Sendable {
  case approved
  case mountedUnknownUnverified
}

public struct PartialDownloadStateV1: Codable, Equatable, Sendable {
  public static let maximumCanonicalBytes = 16 * 1_024

  public let acquisitionAttemptID: String
  public let archiveSHA256: String
  public let archiveSize: UInt64
  public let assetKey: String
  public let catalogEntryID: String
  public let catalogRevision: String
  public let developerImageCatalogHash: String
  public let receivedBytes: UInt64
  public let sourceIndex: UInt64
  public let sourceURLIdentityHash: String
  public let strongETag: String?

  public func validated(partialFileSize: UInt64) throws -> PartialDownloadStateV1 {
    guard StableBytes.isLowercaseHex(assetKey, byteCount: 32),
      StableBytes.isLowercaseHex(archiveSHA256, byteCount: 32),
      StableBytes.isLowercaseHex(developerImageCatalogHash, byteCount: 32),
      StableBytes.isLowercaseHex(sourceURLIdentityHash, byteCount: 32),
      sourceIndex < 3,
      receivedBytes == partialFileSize,
      receivedBytes <= archiveSize,
      !acquisitionAttemptID.isEmpty,
      !catalogEntryID.isEmpty,
      !catalogRevision.isEmpty,
      strongETag.map({ !$0.isEmpty && $0.utf8.count <= 1_024 }) ?? true
    else {
      throw DeveloperImageSourcePolicyError.invalidPartialState(catalogEntryID)
    }
    return self
  }
}

public struct DeveloperImageCacheIndexEntryV1: Codable, Equatable, Sendable {
  public let assetKey: String
  public let lastAccessMonotonicNs: UInt64?
}

public struct DeveloperImageCacheIndexV1: Codable, Equatable, Sendable {
  public let entries: [DeveloperImageCacheIndexEntryV1]
  public let schemaVersion: UInt64

  public var evictionOrder: [String] {
    entries.sorted { lhs, rhs in
      switch (lhs.lastAccessMonotonicNs, rhs.lastAccessMonotonicNs) {
      case (nil, nil):
        return lhs.assetKey.utf8.lexicographicallyPrecedes(rhs.assetKey.utf8)
      case (nil, _):
        return true
      case (_, nil):
        return false
      case (.some(let left), .some(let right)):
        return left == right
          ? lhs.assetKey.utf8.lexicographicallyPrecedes(rhs.assetKey.utf8)
          : left < right
      }
    }.map(\.assetKey)
  }
}

public enum DeveloperImageSourcePolicy {
  public static let sourceURLDomainID = "pulsephone.developer-image-source-url.v1"

  public static func validateApprovedRemoteURL(_ value: String) throws {
    guard value.utf8.count <= 4_096,
      let components = URLComponents(string: value),
      components.scheme == "https",
      components.host != nil,
      components.user == nil,
      components.password == nil,
      components.fragment == nil
    else {
      throw DeveloperImageSourcePolicyError.invalidSourceURL
    }
  }

  public static func sourceURLIdentityHash(_ value: String) throws -> String {
    try validateApprovedRemoteURL(value)
    return try StableBytes.domainSeparatedSHA256Hex(
      domainID: sourceURLDomainID,
      payload: value.utf8
    )
  }

  public static func mayAdopt(
    state: PartialDownloadStateV1,
    partialFileSize: UInt64,
    catalogIdentity: DeveloperImageCatalogIdentity,
    entryID: String,
    assetKey: String
  ) throws -> Bool {
    _ = try state.validated(partialFileSize: partialFileSize)
    return state.catalogRevision == catalogIdentity.revision
      && state.developerImageCatalogHash == catalogIdentity.hash
      && state.catalogEntryID == entryID
      && state.assetKey == assetKey
  }
}
