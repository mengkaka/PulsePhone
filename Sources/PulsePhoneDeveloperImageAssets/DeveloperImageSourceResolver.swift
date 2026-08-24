import Foundation
import PulsePhoneDeveloperSupportDefinitions

public enum DeveloperImageSourceResolver {
  public static func resolve(
    entry: DeveloperImageCatalogEntryV1,
    alreadyMounted: Bool,
    verifiedCacheAvailable: Bool,
    selectedXcode: SelectedXcodeSnapshot?,
    networkAvailable: Bool
  ) throws -> DeveloperImageSourceResolution {
    if alreadyMounted {
      return DeveloperImageSourceResolution(kind: .alreadyMounted)
    }
    if verifiedCacheAvailable {
      return DeveloperImageSourceResolution(kind: .verifiedCache)
    }
    if let selectedXcode,
      let rolePaths = try validatedXcodeRolePaths(snapshot: selectedXcode, entry: entry)
    {
      return DeveloperImageSourceResolution(
        kind: .selectedReleaseXcode,
        xcodeRolePaths: rolePaths
      )
    }
    if networkAvailable, !entry.sourceURLs.isEmpty {
      return DeveloperImageSourceResolution(kind: .approvedRemote, remoteSourceIndex: 0)
    }
    return DeveloperImageSourceResolution(kind: .typedUnavailable)
  }

  public static func validatedXcodeRolePaths(
    snapshot: SelectedXcodeSnapshot,
    entry: DeveloperImageCatalogEntryV1
  ) throws -> [String: String]? {
    guard snapshot.bundleIdentifier == "com.apple.dt.Xcode",
      snapshot.licenseType == "GM",
      snapshot.signatureValid,
      snapshot.gatekeeperAccepted,
      snapshot.appPath.hasPrefix("/"),
      snapshot.developerPath == snapshot.appPath + "/Contents/Developer",
      !snapshot.appPath.lowercased().contains("beta"),
      !snapshot.appPath.lowercased().contains("preview")
    else {
      return nil
    }
    guard let pair = snapshot.pairs.first(where: {
      $0.ddiVersion == entry.ddiVersion && $0.buildID == entry.buildID
    }) else {
      return nil
    }
    let base = snapshot.developerPath
      + "/Platforms/iPhoneOS.platform/DeviceSupport/"
      + entry.ddiVersion + "/"
    var result: [String: String] = [:]
    for file in entry.files {
      guard let expectedPath = selectedXcodeRolePath(
        developerPath: snapshot.developerPath,
        ddiVersion: entry.ddiVersion,
        fileRole: file.fileRole
      ) else {
        return nil
      }
      guard let candidate = pair.roleFiles[file.fileRole],
        candidate.size == file.size,
        candidate.sha256 == file.sha256,
        candidate.path.hasPrefix(base),
        !candidate.path.dropFirst(base.count).contains("/"),
        candidate.path == expectedPath
      else {
        return nil
      }
      result[file.fileRole] = candidate.path
    }
    guard Set(result.keys) == Set(entry.files.map(\.fileRole)) else { return nil }
    return result
  }

  public static func selectedXcodeRolePath(
    developerPath: String,
    ddiVersion: String,
    fileRole: String
  ) -> String? {
    let base = developerPath
      + "/Platforms/iPhoneOS.platform/DeviceSupport/"
      + ddiVersion + "/"
    switch DeveloperImageFileRole(rawValue: fileRole) {
    case .classicImage:
      return base + "DeveloperDiskImage.dmg"
    case .classicSignature:
      return base + "DeveloperDiskImage.dmg.signature"
    case .personalizedBuildManifest:
      return base + "BuildManifest.plist"
    case .personalizedImage:
      return base + "DeveloperDiskImage.dmg"
    case .personalizedTrustCache:
      return base + "DeveloperDiskImage.dmg.trustcache"
    case nil:
      return nil
    }
  }
}

public enum DeveloperImageRemoteAcquisitionPlanner {
  public static func nextSourceIndex(
    entry: DeveloperImageCatalogEntryV1,
    afterFailedSourceIndex: UInt64?
  ) -> UInt64? {
    let next = afterFailedSourceIndex.map { $0 + 1 } ?? 0
    return next < UInt64(entry.sourceURLs.count) ? next : nil
  }

  public static func mayResume(
    state: PartialDownloadStateV1,
    entry: DeveloperImageCatalogEntryV1,
    catalogIdentity: DeveloperImageCatalogIdentity,
    sourceIndex: UInt64,
    partialFileSize: UInt64
  ) throws -> Bool {
    let assetKey = try entry.assetManifest.assetKey
    guard sourceIndex < UInt64(entry.sourceURLs.count) else { return false }
    return try DeveloperImageSourcePolicy.mayAdopt(
      state: state,
      partialFileSize: partialFileSize,
      catalogIdentity: catalogIdentity,
      entryID: entry.entryID,
      assetKey: assetKey
    )
      && state.archiveSize == entry.archiveSize
      && state.archiveSHA256 == entry.archiveSHA256
      && state.sourceIndex == sourceIndex
      && state.sourceURLIdentityHash
        == DeveloperImageSourcePolicy.sourceURLIdentityHash(entry.sourceURLs[Int(sourceIndex)])
      && state.strongETag != nil
  }
}

public enum DeveloperImageRemoteTransferMode: String, Equatable, Sendable {
  case initial
  case resume
}

public struct DeveloperImageRemoteTransferRequest: Equatable, Sendable {
  public let ifRange: String?
  public let mode: DeveloperImageRemoteTransferMode
  public let offset: UInt64
  public let sourceIndex: UInt64
  public let sourceURL: String

  public init(
    ifRange: String?,
    mode: DeveloperImageRemoteTransferMode,
    offset: UInt64,
    sourceIndex: UInt64,
    sourceURL: String
  ) {
    self.ifRange = ifRange
    self.mode = mode
    self.offset = offset
    self.sourceIndex = sourceIndex
    self.sourceURL = sourceURL
  }
}

public struct DeveloperImageRemoteResponseHead: Equatable, Sendable {
  public let contentLength: UInt64
  public let contentRangeStart: UInt64?
  public let statusCode: Int
  public let strongETag: String?

  public init(
    contentLength: UInt64,
    contentRangeStart: UInt64?,
    statusCode: Int,
    strongETag: String?
  ) {
    self.contentLength = contentLength
    self.contentRangeStart = contentRangeStart
    self.statusCode = statusCode
    self.strongETag = strongETag
  }
}

public struct DeveloperImageRemoteAttemptLedger: Equatable, Sendable {
  private var initialSources = Set<UInt64>()
  private var resumeSources = Set<UInt64>()
  private var sourceIndex: UInt64 = 0

  public init() {}

  public mutating func nextRequest(
    entry: DeveloperImageCatalogEntryV1,
    resumableState: PartialDownloadStateV1?
  ) throws -> DeveloperImageRemoteTransferRequest? {
    while sourceIndex < UInt64(entry.sourceURLs.count) {
      let index = sourceIndex
      let url = entry.sourceURLs[Int(index)]
      if let resumableState,
        resumableState.sourceIndex == index,
        resumableState.sourceURLIdentityHash
          == (try DeveloperImageSourcePolicy.sourceURLIdentityHash(url)),
        let etag = resumableState.strongETag,
        resumableState.receivedBytes > 0,
        !resumeSources.contains(index)
      {
        resumeSources.insert(index)
        return DeveloperImageRemoteTransferRequest(
          ifRange: etag,
          mode: .resume,
          offset: resumableState.receivedBytes,
          sourceIndex: index,
          sourceURL: url
        )
      }
      if !initialSources.contains(index) {
        initialSources.insert(index)
        return DeveloperImageRemoteTransferRequest(
          ifRange: nil,
          mode: .initial,
          offset: 0,
          sourceIndex: index,
          sourceURL: url
        )
      }
      sourceIndex += 1
    }
    return nil
  }

  public mutating func rejectResumeAndRestartSource(
    _ request: DeveloperImageRemoteTransferRequest
  ) {
    guard request.mode == .resume else { return }
    sourceIndex = request.sourceIndex
  }
}

public struct DeveloperImageRemoteTransferValidator: Sendable {
  public static let maximumChunkBytes = 1_048_576

  public let archiveSize: UInt64
  public let request: DeveloperImageRemoteTransferRequest
  public let response: DeveloperImageRemoteResponseHead
  public private(set) var receivedBytes: UInt64

  public init(
    archiveSize: UInt64,
    request: DeveloperImageRemoteTransferRequest,
    response: DeveloperImageRemoteResponseHead
  ) throws {
    let remaining = archiveSize >= request.offset ? archiveSize - request.offset : 0
    let validHead: Bool
    switch request.mode {
    case .initial:
      validHead = request.offset == 0
        && request.ifRange == nil
        && response.statusCode == 200
        && (response.contentRangeStart == nil || response.contentRangeStart == 0)
    case .resume:
      validHead = request.offset > 0
        && request.ifRange != nil
        && response.statusCode == 206
        && response.contentRangeStart == request.offset
        && response.strongETag == request.ifRange
    }
    guard validHead, response.contentLength <= remaining else {
      throw DeveloperImageAssetStoreError.invalidPartialState
    }
    self.archiveSize = archiveSize
    self.request = request
    self.response = response
    self.receivedBytes = request.offset
  }

  public mutating func acceptChunk(byteCount: Int) throws {
    guard (1...Self.maximumChunkBytes).contains(byteCount) else {
      throw DeveloperImageAssetStoreError.capacityExceeded
    }
    let count = UInt64(byteCount)
    guard receivedBytes <= archiveSize, count <= archiveSize - receivedBytes else {
      throw DeveloperImageAssetStoreError.capacityExceeded
    }
    receivedBytes += count
  }

  public func requireComplete() throws {
    guard receivedBytes == archiveSize else {
      throw DeveloperImageAssetStoreError.integrityMismatch("archive size")
    }
  }
}
