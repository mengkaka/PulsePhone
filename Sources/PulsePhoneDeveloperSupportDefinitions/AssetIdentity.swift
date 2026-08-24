import Foundation
import PulsePhoneSharedDefinitions

public enum DeveloperImageAssetError: Error, Equatable, Sendable {
  case duplicateRole(String)
  case invalidAssetKey
  case invalidFileRole(String)
  case invalidSHA256(String)
  case invalidSize(String)
  case tooManyFiles
}

public enum DeveloperImageKind: String, Codable, Sendable {
  case classic
  case personalized
}

public enum DeveloperImageFileRole: String, CaseIterable, Codable, Sendable {
  case classicImage = "classic.image"
  case classicSignature = "classic.signature"
  case personalizedBuildManifest = "personalized.buildManifest"
  case personalizedImage = "personalized.image"
  case personalizedTrustCache = "personalized.trustCache"
}

public struct AssetContentFileV1: Codable, Equatable, Sendable {
  public let fileRole: String
  public let sha256: String
  public let size: UInt64

  public init(fileRole: String, sha256: String, size: UInt64) {
    self.fileRole = fileRole
    self.sha256 = sha256
    self.size = size
  }
}

public struct AssetContentManifestV1: Codable, Equatable, Sendable {
  public static let domainID = "pulsephone.developer-image-asset.v1"

  public let files: [AssetContentFileV1]
  public let imageKind: DeveloperImageKind

  public init(files: [AssetContentFileV1], imageKind: DeveloperImageKind) {
    self.files = files
    self.imageKind = imageKind
  }

  public func validated() throws -> AssetContentManifestV1 {
    guard (1...8).contains(files.count) else {
      throw DeveloperImageAssetError.tooManyFiles
    }
    var roles = Set<String>()
    for file in files {
      try DeveloperImageAssetIdentity.validate(role: file.fileRole)
      guard roles.insert(file.fileRole).inserted else {
        throw DeveloperImageAssetError.duplicateRole(file.fileRole)
      }
      guard StableBytes.isLowercaseHex(file.sha256, byteCount: 32) else {
        throw DeveloperImageAssetError.invalidSHA256(file.fileRole)
      }
      guard file.size > 0 else {
        throw DeveloperImageAssetError.invalidSize(file.fileRole)
      }
    }
    guard files.map(\.fileRole) == files.map(\.fileRole).sorted(by: asciiLessThan) else {
      throw DeveloperImageAssetError.invalidFileRole("order")
    }
    return self
  }

  public var canonicalBytes: [UInt8] {
    get throws {
      let fileValues = try files.map { file in
      RepositoryJSONValue.object(
        try RepositoryJSONObject(members: [
          RepositoryJSONMember(key: "fileRole", value: .string(file.fileRole)),
          RepositoryJSONMember(key: "sha256", value: .string(file.sha256)),
          RepositoryJSONMember(key: "size", value: .number(.uint64(file.size))),
        ])
      )
    }
      let object = try RepositoryJSONObject(members: [
        RepositoryJSONMember(key: "files", value: .array(fileValues)),
        RepositoryJSONMember(key: "imageKind", value: .string(imageKind.rawValue)),
      ])
      return RepositoryCanonicalJSON.encodeDocument(object)
    }
  }

  public var assetKey: String {
    get throws {
      _ = try validated()
      return try StableBytes.domainSeparatedSHA256Hex(
        domainID: Self.domainID,
        payload: try canonicalBytes
      )
    }
  }

  private func asciiLessThan(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
  }
}

public enum DeveloperImageAssetIdentity {
  public static func validate(role: String) throws {
    let bytes = Array(role.utf8)
    guard (1...64).contains(bytes.count),
      let first = bytes.first,
      isAlphaNumeric(first),
      bytes.allSatisfy({ isAlphaNumeric($0) || $0 == 0x2d || $0 == 0x2e })
    else {
      throw DeveloperImageAssetError.invalidFileRole(role)
    }
    guard DeveloperImageFileRole(rawValue: role) != nil else {
      throw DeveloperImageAssetError.invalidFileRole(role)
    }
  }

  public static func canonicalRoleRelativePath(
    assetKey: String,
    fileRole: String
  ) throws -> String {
    guard StableBytes.isLowercaseHex(assetKey, byteCount: 32) else {
      throw DeveloperImageAssetError.invalidAssetKey
    }
    try validate(role: fileRole)
    return "assets/\(assetKey)/roles/\(fileRole)"
  }

  private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte)
      || (0x41...0x5a).contains(byte)
      || (0x61...0x7a).contains(byte)
  }
}
