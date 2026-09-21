import Darwin
import Foundation
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneSharedDefinitions

public enum DynamicDeveloperImageCatalogStoreError: Error, Equatable, Sendable {
  case candidateIncompatible
  case catalogMismatch
  case catalogUnavailable
  case networkUnavailable
  case sourceRejected
}

public struct DynamicDeveloperImageCatalogStoreConfiguration: Equatable, Sendable {
  private static let releaseCatalogURL = "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/developer-image-catalog.v1.json"
  private static let releaseArchiveURLPrefix = "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/"
  private static let devCatalogURL = "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/dev/PulsePhone/developer-image-catalog.v1.json"
  private static let devArchiveURLPrefix = "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/dev/PulsePhone/archives/"

  public static let release = Self(
    catalogURL: releaseCatalogURL,
    archiveURLPrefixes: [releaseArchiveURLPrefix],
    catalogDirectoryName: "Catalog"
  )

  public static let dev = Self(
    catalogURL: devCatalogURL,
    archiveURLPrefixes: [devArchiveURLPrefix, releaseArchiveURLPrefix],
    catalogDirectoryName: "Catalog-dev"
  )

  public let archiveURLPrefixes: [String]
  public let catalogURL: String
  private let catalogDirectoryNameValue: String

  public var archiveURLPrefix: String {
    archiveURLPrefixes.first ?? ""
  }

  public init(catalogURL: String, archiveURLPrefix: String) {
    self.init(
      catalogURL: catalogURL,
      archiveURLPrefixes: [archiveURLPrefix],
      catalogDirectoryName: "Catalog"
    )
  }

  public init(catalogURL: String, archiveURLPrefixes: [String]) {
    self.init(
      catalogURL: catalogURL,
      archiveURLPrefixes: archiveURLPrefixes,
      catalogDirectoryName: "Catalog"
    )
  }

  private init(
    catalogURL: String,
    archiveURLPrefixes: [String],
    catalogDirectoryName: String
  ) {
    self.catalogURL = catalogURL
    self.archiveURLPrefixes = archiveURLPrefixes
    self.catalogDirectoryNameValue = catalogDirectoryName
  }

  var catalogDirectoryName: String { catalogDirectoryNameValue }

  public static func selected(useDevCatalog: Bool) -> Self {
    useDevCatalog ? .dev : .release
  }

  func validatesCatalogURL(_ url: URL) -> Bool {
    url.absoluteString == catalogURL
      && url.scheme == "https"
      && url.host == "raw.githubusercontent.com"
      && url.user == nil
      && url.password == nil
      && url.port == nil
      && url.query == nil
      && url.fragment == nil
  }

  func validatesArchiveURL(_ value: String) -> Bool {
    guard let archiveURLPrefix = archiveURLPrefixes.first(where: value.hasPrefix),
      let url = URL(string: value), url.scheme == "https",
      url.host == "raw.githubusercontent.com", url.user == nil,
      url.password == nil, url.port == nil, url.query == nil, url.fragment == nil
    else { return false }
    let components = value.dropFirst(archiveURLPrefix.count)
      .split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 2,
      components[0] == "baseAssets" || components[0] == "DDI",
      !components[1].isEmpty
    else { return false }
    return components[1].allSatisfy { $0.isASCII && $0 != "\\" }
  }
}

public struct DynamicDeveloperImageCatalogHTTPResponse: Sendable {
  public let data: Data
  public let etag: String?
  public let statusCode: Int

  public init(data: Data = Data(), etag: String?, statusCode: Int) {
    self.data = data
    self.etag = etag
    self.statusCode = statusCode
  }
}

public struct DynamicDeveloperImageCatalogMetadataV1: Codable, Equatable, Sendable {
  public let catalogCanonicalSHA256: String
  public let catalogRevision: String
  public let catalogURL: String
  public let etag: String?
  public let expiresAt: String
  public let fetchedAt: String
  public let schemaVersion: UInt64

  public init(
    catalogCanonicalSHA256: String,
    catalogRevision: String,
    catalogURL: String,
    etag: String?,
    expiresAt: String,
    fetchedAt: String,
    schemaVersion: UInt64 = 1
  ) {
    self.catalogCanonicalSHA256 = catalogCanonicalSHA256
    self.catalogRevision = catalogRevision
    self.catalogURL = catalogURL
    self.etag = etag
    self.expiresAt = expiresAt
    self.fetchedAt = fetchedAt
    self.schemaVersion = schemaVersion
  }
}

/// Host-private evidence that a default BaseImage candidate completed the full
/// preparation service profile for one exact build. It is deliberately not a
/// remote catalogEntry and never changes the owner-controlled catalog.
public struct DynamicDeveloperImageLocalCandidateRecordV1: Codable, Equatable, Sendable {
  public let baseAssetID: String
  public let baseContentManifestSHA256: String
  public let buildID: String
  public let catalogCanonicalSHA256: String
  public let catalogRevision: String
  public let iosVersion: String
  public let observedAt: String
  public let result: String
  public let schemaVersion: UInt64
  public let serviceProfileID: String

  public init(
    baseAssetID: String,
    baseContentManifestSHA256: String,
    buildID: String,
    catalogCanonicalSHA256: String,
    catalogRevision: String,
    iosVersion: String,
    observedAt: String,
    result: String = "mountAndProfileReady",
    schemaVersion: UInt64 = 1,
    serviceProfileID: String
  ) {
    self.baseAssetID = baseAssetID
    self.baseContentManifestSHA256 = baseContentManifestSHA256
    self.buildID = buildID
    self.catalogCanonicalSHA256 = catalogCanonicalSHA256
    self.catalogRevision = catalogRevision
    self.iosVersion = iosVersion
    self.observedAt = observedAt
    self.result = result
    self.schemaVersion = schemaVersion
    self.serviceProfileID = serviceProfileID
  }
}

/// Owns the private dynamic catalog cache. Its paired catalog/metadata files
/// are validated together under one flock; an interrupted two-file update is
/// recovered from last-known-good rather than guessed from a partial state.
public final class DynamicDeveloperImageCatalogStore: @unchecked Sendable {
  public typealias HTTPFetcher = @Sendable (
    _ url: URL,
    _ ifNoneMatch: String?
  ) throws -> DynamicDeveloperImageCatalogHTTPResponse
  public typealias Now = @Sendable () -> Date

  public let configuration: DynamicDeveloperImageCatalogStoreConfiguration
  public let rootURL: URL

  private let fetch: HTTPFetcher
  private let now: Now
  private let posix: AssetStorePOSIX

  public convenience init(
    rootURL: URL,
    configuration: DynamicDeveloperImageCatalogStoreConfiguration = .release
  ) throws {
    try self.init(
      rootURL: rootURL,
      configuration: configuration,
      fetch: DynamicDeveloperImageCatalogHTTPFetcher.fetch,
      now: Date.init
    )
  }

  public init(
    rootURL: URL,
    configuration: DynamicDeveloperImageCatalogStoreConfiguration,
    fetch: @escaping HTTPFetcher,
    now: @escaping Now
  ) throws {
    let standardized = rootURL.standardizedFileURL
    self.rootURL = standardized.deletingLastPathComponent()
      .resolvingSymlinksInPath()
      .appendingPathComponent(standardized.lastPathComponent, isDirectory: true)
    self.configuration = configuration
    self.fetch = fetch
    self.now = now
    self.posix = AssetStorePOSIX()
    guard let url = URL(string: configuration.catalogURL),
      configuration.validatesCatalogURL(url)
    else {
      throw DynamicDeveloperImageCatalogStoreError.sourceRejected
    }
    try bootstrap()
  }

  /// Resolves one immutable catalog snapshot. `forceRefresh` is intended for
  /// diagnostic callers; preparation uses the normal one-hour freshness rule.
  public func snapshot(forceRefresh: Bool = false) throws -> DynamicDeveloperImageCatalogSnapshot {
    let lock = try posix.openLock(catalogLockPath, operation: LOCK_EX)
    defer {
      _ = flock(lock, LOCK_UN)
      Darwin.close(lock)
    }

    let current = try loadPair(directory: catalogPath)
    if let current, !forceRefresh, let expiresAt = current.metadata.expiresAtDate,
      expiresAt > now()
    {
      return DynamicDeveloperImageCatalogSnapshot(
        catalog: current.catalog,
        identity: current.identity,
        staleCatalog: false
      )
    }

    let etag = current?.metadata.etag
    do {
      guard let url = URL(string: configuration.catalogURL), configuration.validatesCatalogURL(url) else {
        throw DynamicDeveloperImageCatalogStoreError.sourceRejected
      }
      let response = try fetch(url, etag)
      switch response.statusCode {
      case 304:
        guard let current else {
          throw DynamicDeveloperImageCatalogStoreError.catalogUnavailable
        }
        let metadata = makeMetadata(
          identity: current.identity,
          etag: response.etag ?? current.metadata.etag
        )
        try publishPair(
          catalog: current.catalog,
          catalogBytes: current.catalogBytes,
          metadata: metadata,
          previous: current
        )
        return DynamicDeveloperImageCatalogSnapshot(
          catalog: current.catalog,
          identity: current.identity,
          staleCatalog: false
        )
      case 200:
        let catalog = try DynamicDeveloperImageCatalog.decodeCanonical([UInt8](response.data))
        guard validates(catalog) else {
          throw DynamicDeveloperImageCatalogStoreError.catalogMismatch
        }
        let catalogBytes = [UInt8](response.data)
        let identity = try DynamicDeveloperImageCatalog.identity(
          catalog: catalog,
          canonicalBytes: catalogBytes
        )
        if let current, let order = DynamicDeveloperImageCatalog.compareRevisions(
          identity.revision, current.identity.revision
        ) {
          if order == .orderedAscending {
            throw DynamicDeveloperImageCatalogStoreError.catalogMismatch
          }
          if order == .orderedSame && identity.canonicalSHA256 != current.identity.canonicalSHA256 {
            throw DynamicDeveloperImageCatalogStoreError.catalogMismatch
          }
        } else if current != nil {
          throw DynamicDeveloperImageCatalogStoreError.catalogMismatch
        }
        let metadata = makeMetadata(identity: identity, etag: response.etag)
        try publishPair(
          catalog: catalog,
          catalogBytes: response.data,
          metadata: metadata,
          previous: current
        )
        return DynamicDeveloperImageCatalogSnapshot(
          catalog: catalog,
          identity: identity,
          staleCatalog: false
        )
      default:
        throw DynamicDeveloperImageCatalogStoreError.networkUnavailable
      }
    } catch {
      let fallback: LoadedPair?
      if let current {
        fallback = current
      } else {
        fallback = try loadPair(directory: lastKnownGoodPath)
      }
      if let fallback {
        return DynamicDeveloperImageCatalogSnapshot(
          catalog: fallback.catalog,
          identity: fallback.identity,
          staleCatalog: true
        )
      }
      switch error {
      case let error as DynamicDeveloperImageCatalogStoreError:
        if error == .catalogMismatch { throw error }
        throw DynamicDeveloperImageCatalogStoreError.catalogUnavailable
      case is DynamicDeveloperImageCatalogError:
        throw DynamicDeveloperImageCatalogStoreError.catalogMismatch
      default:
        throw DynamicDeveloperImageCatalogStoreError.catalogUnavailable
      }
    }
  }

  public func localCandidate(
    buildID: String,
    snapshot: DynamicDeveloperImageCatalogSnapshot
  ) throws -> DynamicDeveloperImageSelection? {
    guard validBuildID(buildID) else {
      throw DynamicDeveloperImageCatalogStoreError.candidateIncompatible
    }
    guard let record = try localCandidateRecords(snapshot: snapshot).first(where: {
      $0.buildID == buildID
    }), let selection = DynamicDeveloperImageCatalog.baseAsset(
      in: snapshot.catalog,
      baseAssetID: record.baseAssetID,
      provenance: .localValidated
    ), selection.asset.contentManifestSHA256 == record.baseContentManifestSHA256
    else { return nil }
    return selection
  }

  /// Returns only active, fully verified local observations. Records whose
  /// asset is no longer declared by the active snapshot are deliberately
  /// omitted so diagnostics cannot turn stale local data into a backdoor.
  public func localCandidateRecords(
    snapshot: DynamicDeveloperImageCatalogSnapshot
  ) throws -> [DynamicDeveloperImageLocalCandidateRecordV1] {
    let lock = try posix.openLock(candidateLockPath, operation: LOCK_SH)
    defer {
      _ = flock(lock, LOCK_UN)
      Darwin.close(lock)
    }
    let directories = try FileManager.default.contentsOfDirectory(atPath: candidateRootPath)
      .filter(validBuildID)
      .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    var newest = [String: DynamicDeveloperImageLocalCandidateRecordV1]()
    for buildID in directories {
      let directory = candidateDirectory(buildID: buildID)
      guard FileManager.default.fileExists(atPath: directory) else { continue }
      do {
        try posix.validateDirectory(directory)
      } catch {
        continue
      }
      let names = try FileManager.default.contentsOfDirectory(atPath: directory)
        .filter { $0.hasSuffix(".json") }
        .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
      for name in names {
        let hash = String(name.dropLast(".json".utf8.count))
        guard StableBytes.isLowercaseHex(hash, byteCount: 32),
          let record = try loadCandidateRecord(path: directory + "/" + name),
          record.buildID == buildID,
          record.baseContentManifestSHA256 == hash,
          record.result == "mountAndProfileReady",
          record.schemaVersion == 1,
          record.observedAtDate != nil,
          snapshot.catalog.baseAssets.contains(where: {
            $0.baseAssetID == record.baseAssetID
              && $0.contentManifestSHA256 == record.baseContentManifestSHA256
          })
        else { continue }
        if let existing = newest[buildID], existing.observedAt >= record.observedAt {
          continue
        }
        newest[buildID] = record
      }
    }
    return newest.values.sorted { $0.buildID.utf8.lexicographicallyPrecedes($1.buildID.utf8) }
  }

  public func recordSuccessfulDefaultCandidate(
    iosVersion: String,
    buildID: String,
    selection: DynamicDeveloperImageSelection,
    snapshot: DynamicDeveloperImageCatalogSnapshot,
    serviceProfileID: String
  ) throws {
    guard selection.provenance == .defaultCandidate,
      selection.asset.kind == .baseImage,
      validBuildID(buildID), validText(iosVersion), validText(serviceProfileID),
      snapshot.catalog.baseAssets.contains(where: {
        $0.baseAssetID == selection.asset.assetID
          && $0.contentManifestSHA256 == selection.asset.contentManifestSHA256
      })
    else {
      throw DynamicDeveloperImageCatalogStoreError.candidateIncompatible
    }
    let lock = try posix.openLock(candidateLockPath, operation: LOCK_EX)
    defer {
      _ = flock(lock, LOCK_UN)
      Darwin.close(lock)
    }
    let directory = candidateDirectory(buildID: buildID)
    try posix.ensureDirectory(directory)
    let record = DynamicDeveloperImageLocalCandidateRecordV1(
      baseAssetID: selection.asset.assetID,
      baseContentManifestSHA256: selection.asset.contentManifestSHA256,
      buildID: buildID,
      catalogCanonicalSHA256: snapshot.identity.canonicalSHA256,
      catalogRevision: snapshot.identity.revision,
      iosVersion: iosVersion,
      observedAt: Self.format(now()),
      serviceProfileID: serviceProfileID
    )
    try posix.atomicWrite(
      try canonicalData(record),
      to: directory + "/" + selection.asset.contentManifestSHA256 + ".json"
    )
  }

  private struct LoadedPair {
    let catalog: DynamicDeveloperImageCatalogV1
    let catalogBytes: Data
    let identity: DynamicDeveloperImageCatalogIdentity
    let metadata: DynamicDeveloperImageCatalogMetadataV1
  }

  private var catalogPath: String {
    rootURL.appendingPathComponent(
      configuration.catalogDirectoryName,
      isDirectory: true
    ).path
  }
  private var catalogFilePath: String {
    catalogPath + "/developer-image-catalog.v1.json"
  }
  private var metadataPath: String { catalogPath + "/metadata.json" }
  private var catalogLockPath: String { catalogPath + "/.lock" }
  private var lastKnownGoodPath: String { catalogPath + "/last-known-good" }
  private var candidateRootPath: String { rootURL.path + "/CatalogEntry" }
  private var candidateLockPath: String { candidateRootPath + "/.lock" }

  private func bootstrap() throws {
    try posix.ensureDirectory(rootURL.path)
    try posix.ensureDirectory(catalogPath)
    try posix.ensureDirectory(lastKnownGoodPath)
    try posix.ensureDirectory(candidateRootPath)
    let lock = try posix.openLock(catalogLockPath, operation: LOCK_EX)
    _ = flock(lock, LOCK_UN)
    Darwin.close(lock)
    let candidateLock = try posix.openLock(candidateLockPath, operation: LOCK_EX)
    _ = flock(candidateLock, LOCK_UN)
    Darwin.close(candidateLock)
  }

  private func loadPair(directory: String) throws -> LoadedPair? {
    let catalogFile = directory + "/developer-image-catalog.v1.json"
    let metadataFile = directory + "/metadata.json"
    let catalogExists = FileManager.default.fileExists(atPath: catalogFile)
    let metadataExists = FileManager.default.fileExists(atPath: metadataFile)
    guard catalogExists || metadataExists else { return nil }
    guard catalogExists && metadataExists else { return nil }
    do {
      let catalogBytes = try posix.readRegularFile(
        catalogFile,
        maximumBytes: UInt64(DynamicDeveloperImageCatalog.maximumCanonicalBytes)
      )
      let catalog = try DynamicDeveloperImageCatalog.decodeCanonical([UInt8](catalogBytes))
      let identity = try DynamicDeveloperImageCatalog.identity(
        catalog: catalog,
        canonicalBytes: [UInt8](catalogBytes)
      )
      let metadataBytes = try posix.readRegularFile(
        metadataFile,
        maximumBytes: UInt64(DynamicDeveloperImageCatalog.maximumCanonicalBytes)
      )
      _ = try RepositoryCanonicalJSON.validateCanonicalDocument(
        [UInt8](metadataBytes),
        maximumByteCount: DynamicDeveloperImageCatalog.maximumCanonicalBytes
      )
      let metadata = try JSONDecoder().decode(
        DynamicDeveloperImageCatalogMetadataV1.self,
        from: metadataBytes
      )
      guard metadata.schemaVersion == 1,
        metadata.catalogURL == configuration.catalogURL,
        metadata.catalogRevision == identity.revision,
        metadata.catalogCanonicalSHA256 == identity.canonicalSHA256,
        metadata.fetchedAtDate != nil,
        metadata.expiresAtDate != nil,
        metadata.etag.map({ !$0.isEmpty }) ?? true
      else {
        return nil
      }
      return LoadedPair(
        catalog: catalog,
        catalogBytes: catalogBytes,
        identity: identity,
        metadata: metadata
      )
    } catch {
      return nil
    }
  }

  private func publishPair(
    catalog: DynamicDeveloperImageCatalogV1,
    catalogBytes: Data,
    metadata: DynamicDeveloperImageCatalogMetadataV1,
    previous: LoadedPair?
  ) throws {
    guard try DynamicDeveloperImageCatalog.decodeCanonical([UInt8](catalogBytes)) == catalog else {
      throw DynamicDeveloperImageCatalogStoreError.catalogMismatch
    }
    let metadataBytes = try canonicalData(metadata)
    if let previous {
      try posix.atomicWrite(
        previous.catalogBytes,
        to: lastKnownGoodPath + "/developer-image-catalog.v1.json"
      )
      try posix.atomicWrite(try canonicalData(previous.metadata), to: lastKnownGoodPath + "/metadata.json")
    }
    try posix.atomicWrite(catalogBytes, to: catalogFilePath)
    try posix.atomicWrite(metadataBytes, to: metadataPath)
    try posix.fsyncDirectory(catalogPath)
  }

  private func validates(_ catalog: DynamicDeveloperImageCatalogV1) -> Bool {
    catalog.baseAssets.allSatisfy { configuration.validatesArchiveURL($0.sourceURL) }
      && catalog.developerDiskImages.allSatisfy { configuration.validatesArchiveURL($0.sourceURL) }
  }

  private func makeMetadata(
    identity: DynamicDeveloperImageCatalogIdentity,
    etag: String?
  ) -> DynamicDeveloperImageCatalogMetadataV1 {
    let fetchedAt = now()
    return DynamicDeveloperImageCatalogMetadataV1(
      catalogCanonicalSHA256: identity.canonicalSHA256,
      catalogRevision: identity.revision,
      catalogURL: configuration.catalogURL,
      etag: etag,
      expiresAt: Self.format(fetchedAt.addingTimeInterval(60 * 60)),
      fetchedAt: Self.format(fetchedAt)
    )
  }

  private func canonicalData<Value: Encodable>(_ value: Value) throws -> Data {
    let data = try JSONEncoder.sorted.encode(value)
    return Data(try RepositoryCanonicalJSON.validateCanonicalDocument(
      [UInt8](data),
      maximumByteCount: DynamicDeveloperImageCatalog.maximumCanonicalBytes
    ).exactBytes)
  }

  private func candidateDirectory(buildID: String) -> String {
    candidateRootPath + "/" + buildID
  }

  private func loadCandidateRecord(
    path: String
  ) throws -> DynamicDeveloperImageLocalCandidateRecordV1? {
    do {
      let bytes = try posix.readRegularFile(
        path,
        maximumBytes: UInt64(DynamicDeveloperImageCatalog.maximumCanonicalBytes)
      )
      _ = try RepositoryCanonicalJSON.validateCanonicalDocument(
        [UInt8](bytes),
        maximumByteCount: DynamicDeveloperImageCatalog.maximumCanonicalBytes
      )
      return try JSONDecoder().decode(DynamicDeveloperImageLocalCandidateRecordV1.self, from: bytes)
    } catch {
      return nil
    }
  }

  private func validBuildID(_ value: String) -> Bool {
    let bytes = value.utf8
    return !bytes.isEmpty && bytes.count <= 128 && bytes.allSatisfy {
      (0x30...0x39).contains($0) || (0x41...0x5a).contains($0)
        || (0x61...0x7a).contains($0)
    }
  }

  private func validText(_ value: String) -> Bool {
    let bytes = value.utf8
    return !bytes.isEmpty && bytes.count <= 256 && bytes.allSatisfy {
      (0x21...0x7e).contains($0)
    }
  }

  private static func format(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}

private extension DynamicDeveloperImageCatalogMetadataV1 {
  var fetchedAtDate: Date? { DynamicDeveloperImageCatalogStore.date(from: fetchedAt) }
  var expiresAtDate: Date? { DynamicDeveloperImageCatalogStore.date(from: expiresAt) }
}

private extension DynamicDeveloperImageLocalCandidateRecordV1 {
  var observedAtDate: Date? { DynamicDeveloperImageCatalogStore.date(from: observedAt) }
}

private extension DynamicDeveloperImageCatalogStore {
  static func date(from value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
  }
}

private enum DynamicDeveloperImageCatalogHTTPFetcher {
  static func fetch(
    url: URL,
    ifNoneMatch: String?
  ) throws -> DynamicDeveloperImageCatalogHTTPResponse {
    let collector = DynamicCatalogHTTPCollector(url: url)
    let configuration = BoundedHTTPSDataFetcher.sessionConfiguration()
    let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = BoundedHTTPSDataFetcher.timeout
    if let ifNoneMatch { request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match") }
    let task = session.dataTask(with: request)
    task.resume()
    defer { session.invalidateAndCancel() }
    guard collector.wait(timeout: BoundedHTTPSDataFetcher.timeout) else {
      task.cancel()
      throw DynamicDeveloperImageCatalogStoreError.networkUnavailable
    }
    return try collector.result()
  }
}

private final class DynamicCatalogHTTPCollector: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate,
  @unchecked Sendable
{
  private let completion = DispatchSemaphore(value: 0)
  private var data = Data()
  private var etag: String?
  private var error: DynamicDeveloperImageCatalogStoreError?
  private let lock = NSLock()
  private let url: URL
  private var statusCode: Int?

  init(url: URL) { self.url = url }

  func wait(timeout: TimeInterval) -> Bool {
    completion.wait(timeout: .now() + timeout) == .success
  }

  func result() throws -> DynamicDeveloperImageCatalogHTTPResponse {
    lock.lock()
    defer { lock.unlock() }
    if let error { throw error }
    guard let statusCode else { throw DynamicDeveloperImageCatalogStoreError.networkUnavailable }
    return DynamicDeveloperImageCatalogHTTPResponse(data: data, etag: etag, statusCode: statusCode)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    fail(.sourceRejected, task: task)
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let response = response as? HTTPURLResponse, response.url == url,
      response.statusCode == 200 || response.statusCode == 304,
      response.expectedContentLength < 0
        || UInt64(response.expectedContentLength)
          <= UInt64(DynamicDeveloperImageCatalog.maximumCanonicalBytes)
    else {
      fail(.networkUnavailable, task: dataTask)
      completionHandler(.cancel)
      return
    }
    lock.lock()
    statusCode = response.statusCode
    etag = response.value(forHTTPHeaderField: "ETag")
    lock.unlock()
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    defer { lock.unlock() }
    guard error == nil,
      data.count <= DynamicDeveloperImageCatalog.maximumCanonicalBytes - self.data.count
    else {
      error = .networkUnavailable
      dataTask.cancel()
      return
    }
    self.data.append(data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    if self.error == nil, error != nil { self.error = .networkUnavailable }
    lock.unlock()
    completion.signal()
  }

  private func fail(_ error: DynamicDeveloperImageCatalogStoreError, task: URLSessionTask) {
    lock.lock()
    if self.error == nil { self.error = error }
    lock.unlock()
    task.cancel()
  }
}

private extension JSONEncoder {
  static var sorted: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}
