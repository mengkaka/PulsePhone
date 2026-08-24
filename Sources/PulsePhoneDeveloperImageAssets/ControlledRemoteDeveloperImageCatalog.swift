import Dispatch
import Foundation
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneSharedDefinitions

public enum ControlledRemoteDeveloperImageCatalogError: Error, Equatable, Sendable {
  case archiveIntegrityFailed
  case catalogRejected
  case networkUnavailable
  case sourceRejected
}

/// The owner-approved remote DDI source. This is intentionally a narrow
/// configuration rather than a general-purpose remote catalog mechanism.
public struct ControlledRemoteDeveloperImageCatalogConfiguration: Equatable, Sendable {
  public static let release = Self(
    catalogURL: "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/developer-image-catalog.v1.json",
    catalogRevisionPrefix: "mengkaka-release-",
    archiveURLPrefix: "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/"
  )

  public let archiveURLPrefix: String
  public let catalogRevisionPrefix: String
  public let catalogURL: String

  public init(
    catalogURL: String,
    catalogRevisionPrefix: String,
    archiveURLPrefix: String
  ) {
    self.catalogURL = catalogURL
    self.catalogRevisionPrefix = catalogRevisionPrefix
    self.archiveURLPrefix = archiveURLPrefix
  }

  func validatesCatalogURL(_ value: URL) -> Bool {
    value.absoluteString == catalogURL
  }

  func validatesArchiveURL(_ value: String) -> Bool {
    guard value.hasPrefix(archiveURLPrefix),
      let components = URLComponents(string: value),
      components.scheme == "https",
      components.host == "raw.githubusercontent.com",
      components.port == nil,
      components.user == nil,
      components.password == nil,
      components.fragment == nil,
      components.query == nil
    else {
      return false
    }
    return value.dropFirst(archiveURLPrefix.count).allSatisfy {
      $0.isASCII && $0 != "/" && $0 != "\\"
    }
  }

  func validates(_ catalog: DeveloperImageCatalogV1) -> Bool {
    guard catalog.catalogRevision.hasPrefix(catalogRevisionPrefix) else {
      return false
    }
    return catalog.entries.allSatisfy { entry in
      entry.sourceURLs.allSatisfy(validatesArchiveURL)
    }
  }
}

public struct ControlledRemoteDeveloperImageCatalog: Sendable {
  public typealias DataFetcher = @Sendable (URL, UInt64) throws -> Data
  public typealias CatalogValidator = @Sendable (DeveloperImageCatalogV1) throws -> Void

  public let configuration: ControlledRemoteDeveloperImageCatalogConfiguration
  private let fetch: DataFetcher

  public init(
    configuration: ControlledRemoteDeveloperImageCatalogConfiguration = .release
  ) {
    self.init(configuration: configuration, fetch: BoundedHTTPSDataFetcher.fetch)
  }

  public init(
    configuration: ControlledRemoteDeveloperImageCatalogConfiguration,
    fetch: @escaping DataFetcher
  ) {
    self.configuration = configuration
    self.fetch = fetch
  }

  /// Resolves only an exact matching catalog. A valid cached catalog is used
  /// if the controlled source cannot be reached on this invocation.
  public func matchingCatalog(
    assetStore: DeveloperImageAssetStore,
    osMajor: UInt64,
    buildID: String,
    validateCatalog: CatalogValidator
  ) throws -> DeveloperImageCatalogV1? {
    let cached = try cachedMatchingCatalog(
      assetStore: assetStore,
      osMajor: osMajor,
      buildID: buildID,
      validateCatalog: validateCatalog
    )
    do {
      guard let catalogURL = URL(string: configuration.catalogURL),
        configuration.validatesCatalogURL(catalogURL)
      else {
        throw ControlledRemoteDeveloperImageCatalogError.sourceRejected
      }
      let bytes = try fetch(catalogURL, UInt64(DeveloperImageCatalog.maximumCanonicalBytes))
      let catalog = try DeveloperImageCatalog.decodeCanonical([UInt8](bytes))
      guard configuration.validates(catalog) else {
        throw ControlledRemoteDeveloperImageCatalogError.catalogRejected
      }
      try validateCatalog(catalog)
      _ = try assetStore.createOrValidateCatalog(catalog)
      if DeveloperImageCompatibility.exactEntry(
        in: catalog,
        osMajor: osMajor,
        buildID: buildID
      ) != nil {
        return catalog
      }
      return cached
    } catch let error as ControlledRemoteDeveloperImageCatalogError {
      if let cached { return cached }
      throw error
    } catch is DeveloperImageCatalogError {
      if let cached { return cached }
      throw ControlledRemoteDeveloperImageCatalogError.catalogRejected
    } catch is DeveloperImageAssetStoreError {
      if let cached { return cached }
      throw ControlledRemoteDeveloperImageCatalogError.catalogRejected
    } catch {
      if let cached { return cached }
      throw ControlledRemoteDeveloperImageCatalogError.networkUnavailable
    }
  }

  @discardableResult
  public func acquire(
    catalog: DeveloperImageCatalogV1,
    entryID: String,
    assetStore: DeveloperImageAssetStore
  ) throws -> DeveloperImagePublishedAsset {
    guard let entry = catalog.entries.first(where: { $0.entryID == entryID }),
      entry.sourceURLs.allSatisfy(configuration.validatesArchiveURL),
      !entry.sourceURLs.isEmpty
    else {
      throw ControlledRemoteDeveloperImageCatalogError.sourceRejected
    }
    var terminalError = ControlledRemoteDeveloperImageCatalogError.networkUnavailable
    for sourceURL in entry.sourceURLs {
      guard let url = URL(string: sourceURL) else {
        terminalError = .sourceRejected
        continue
      }
      do {
        let archive = try fetch(url, entry.archiveSize)
        guard UInt64(archive.count) == entry.archiveSize,
          StableBytes.sha256Hex(archive) == entry.archiveSHA256
        else {
          terminalError = .archiveIntegrityFailed
          continue
        }
        let entries = try DeveloperImageUSTARArchive.parse(
          archive,
          expectedPaths: Set(entry.files.map(\.archiveRelativePath)),
          extractedUpperBound: entry.extractedUpperBound
        )
        return try assetStore.publish(
          catalog: catalog,
          entryID: entry.entryID,
          archiveEntries: entries
        )
      } catch let error as ControlledRemoteDeveloperImageCatalogError {
        terminalError = error
      } catch is DeveloperImageAssetStoreError {
        throw ControlledRemoteDeveloperImageCatalogError.archiveIntegrityFailed
      } catch {
        terminalError = .networkUnavailable
      }
    }
    throw terminalError
  }

  private func cachedMatchingCatalog(
    assetStore: DeveloperImageAssetStore,
    osMajor: UInt64,
    buildID: String,
    validateCatalog: CatalogValidator
  ) throws -> DeveloperImageCatalogV1? {
    let catalogs = try assetStore.acceptedCatalogs()
      .filter(configuration.validates)
      .sorted { $0.catalogRevision > $1.catalogRevision }
    for catalog in catalogs {
      try validateCatalog(catalog)
      if DeveloperImageCompatibility.exactEntry(
        in: catalog,
        osMajor: osMajor,
        buildID: buildID
      ) != nil {
        return catalog
      }
    }
    return nil
  }
}

public enum DeveloperImageUSTARArchive {
  private static let blockSize = 512
  private static let checksumRange = 148..<156
  private static let magicRange = 257..<263
  private static let nameRange = 0..<100
  private static let prefixRange = 345..<500
  private static let sizeRange = 124..<136
  private static let typeOffset = 156
  private static let versionRange = 263..<265

  public static func parse(
    _ archive: Data,
    expectedPaths: Set<String>,
    extractedUpperBound: UInt64
  ) throws -> [DeveloperImageArchiveEntry] {
    guard !expectedPaths.isEmpty,
      archive.count >= blockSize * 2,
      archive.count % blockSize == 0
    else {
      throw ControlledRemoteDeveloperImageCatalogError.archiveIntegrityFailed
    }
    var offset = 0
    var extractedBytes: UInt64 = 0
    var entries: [DeveloperImageArchiveEntry] = []
    var paths = Set<String>()
    while offset < archive.count {
      let header = Array(archive[offset..<(offset + blockSize)])
      if header.allSatisfy({ $0 == 0 }) {
        guard archive.count - offset >= blockSize * 2,
          archive[offset...].allSatisfy({ $0 == 0 }),
          paths == expectedPaths
        else {
          throw ControlledRemoteDeveloperImageCatalogError.archiveIntegrityFailed
        }
        return entries
      }
      let expectedChecksum = try octal(header[checksumRange])
      guard Array(header[magicRange]) == Array("ustar\0".utf8),
        Array(header[versionRange]) == Array("00".utf8),
        header[prefixRange].allSatisfy({ $0 == 0 }),
        header[typeOffset] == 0 || header[typeOffset] == 48,
        try checksum(header) == expectedChecksum
      else {
        throw ControlledRemoteDeveloperImageCatalogError.archiveIntegrityFailed
      }
      let path = try pathName(header[nameRange])
      guard expectedPaths.contains(path), paths.insert(path).inserted else {
        throw ControlledRemoteDeveloperImageCatalogError.archiveIntegrityFailed
      }
      let fileSize = try octal(header[sizeRange])
      guard fileSize <= UInt64(Int.max) else {
        throw ControlledRemoteDeveloperImageCatalogError.archiveIntegrityFailed
      }
      let payloadStart = try adding(offset, blockSize)
      let payloadEnd = try adding(payloadStart, Int(fileSize))
      let paddedEnd = try adding(payloadStart, paddedBlockSize(fileSize))
      guard payloadEnd <= archive.count,
        paddedEnd <= archive.count,
        archive[payloadEnd..<paddedEnd].allSatisfy({ $0 == 0 }),
        entries.count < expectedPaths.count,
        extractedBytes <= extractedUpperBound,
        fileSize <= extractedUpperBound - extractedBytes
      else {
        throw ControlledRemoteDeveloperImageCatalogError.archiveIntegrityFailed
      }
      entries.append(DeveloperImageArchiveEntry(
        path: path,
        kind: .regularFile,
        bytes: Data(archive[payloadStart..<payloadEnd])
      ))
      extractedBytes += UInt64(fileSize)
      offset = paddedEnd
    }
    throw ControlledRemoteDeveloperImageCatalogError.archiveIntegrityFailed
  }

  private static func checksum(_ header: [UInt8]) throws -> UInt64 {
    guard header.count == blockSize else {
      throw ControlledRemoteDeveloperImageCatalogError.archiveIntegrityFailed
    }
    return header.enumerated().reduce(UInt64(0)) { partial, element in
      partial + UInt64(checksumRange.contains(element.offset) ? 32 : element.element)
    }
  }

  private static func octal(_ field: ArraySlice<UInt8>) throws -> UInt64 {
    var value: UInt64 = 0
    var sawDigit = false
    var terminated = false
    for byte in field {
      if (48...55).contains(byte), !terminated {
        let (next, overflow) = value.multipliedReportingOverflow(by: 8)
        guard !overflow else {
          throw ControlledRemoteDeveloperImageCatalogError.archiveIntegrityFailed
        }
        let (sum, sumOverflow) = next.addingReportingOverflow(UInt64(byte - 48))
        guard !sumOverflow else {
          throw ControlledRemoteDeveloperImageCatalogError.archiveIntegrityFailed
        }
        value = sum
        sawDigit = true
      } else if byte == 0 || byte == 32 {
        terminated = true
      } else {
        throw ControlledRemoteDeveloperImageCatalogError.archiveIntegrityFailed
      }
    }
    guard sawDigit else {
      throw ControlledRemoteDeveloperImageCatalogError.archiveIntegrityFailed
    }
    return value
  }

  private static func pathName(_ field: ArraySlice<UInt8>) throws -> String {
    let bytes = Array(field)
    guard let terminator = bytes.firstIndex(of: 0), terminator > 0,
      bytes[terminator...].allSatisfy({ $0 == 0 }),
      bytes[..<terminator].allSatisfy({ (33...126).contains($0) }),
      let value = String(bytes: bytes[..<terminator], encoding: .ascii)
    else {
      throw ControlledRemoteDeveloperImageCatalogError.archiveIntegrityFailed
    }
    return value
  }

  private static func paddedBlockSize(_ value: UInt64) throws -> Int {
    let padded = try adding(value, UInt64(blockSize - 1)) / UInt64(blockSize)
    let bytes = try multiplying(padded, UInt64(blockSize))
    guard bytes <= UInt64(Int.max) else {
      throw ControlledRemoteDeveloperImageCatalogError.archiveIntegrityFailed
    }
    return Int(bytes)
  }

  private static func adding(_ lhs: Int, _ rhs: Int) throws -> Int {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else {
      throw ControlledRemoteDeveloperImageCatalogError.archiveIntegrityFailed
    }
    return value
  }

  private static func adding(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else {
      throw ControlledRemoteDeveloperImageCatalogError.archiveIntegrityFailed
    }
    return value
  }

  private static func multiplying(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
    let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    guard !overflow else {
      throw ControlledRemoteDeveloperImageCatalogError.archiveIntegrityFailed
    }
    return value
  }
}

enum BoundedHTTPSDataFetcher {
  static let timeout: TimeInterval = 75

  static func fetch(url: URL, maximumBytes: UInt64) throws -> Data {
    guard url.scheme == "https", maximumBytes <= UInt64(Int.max) else {
      throw ControlledRemoteDeveloperImageCatalogError.sourceRejected
    }
    let collector = BoundedHTTPSDataCollector(url: url, maximumBytes: maximumBytes)
    let configuration = sessionConfiguration()
    let session = URLSession(
      configuration: configuration,
      delegate: collector,
      delegateQueue: nil
    )
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = timeout
    let task = session.dataTask(with: request)
    task.resume()
    defer { session.invalidateAndCancel() }
    guard collector.wait(timeout: timeout) else {
      task.cancel()
      throw ControlledRemoteDeveloperImageCatalogError.networkUnavailable
    }
    return try collector.result()
  }

  static func sessionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    // Keep the system proxy route: URL, TLS, response, and archive integrity
    // validation still constrain the accepted asset, while clearing this value
    // breaks hosts whose only outbound HTTPS route is an approved proxy.
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpCookieStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    return configuration
  }
}

private final class BoundedHTTPSDataCollector: NSObject, URLSessionDataDelegate,
  URLSessionTaskDelegate, @unchecked Sendable
{
  private let completion = DispatchSemaphore(value: 0)
  private var data = Data()
  private var error: ControlledRemoteDeveloperImageCatalogError?
  private let lock = NSLock()
  private let maximumBytes: UInt64
  private let url: URL

  init(url: URL, maximumBytes: UInt64) {
    self.maximumBytes = maximumBytes
    self.url = url
  }

  func wait(timeout: TimeInterval) -> Bool {
    completion.wait(timeout: .now() + timeout) == .success
  }

  func result() throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    guard error == nil else {
      throw error!
    }
    return data
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
    guard let response = response as? HTTPURLResponse,
      response.statusCode == 200,
      response.url == url,
      response.expectedContentLength < 0
        || UInt64(response.expectedContentLength) <= maximumBytes
    else {
      fail(.networkUnavailable, task: dataTask)
      completionHandler(.cancel)
      return
    }
    completionHandler(.allow)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard error == nil,
      UInt64(self.data.count) <= maximumBytes,
      UInt64(data.count) <= maximumBytes - UInt64(self.data.count)
    else {
      error = .networkUnavailable
      dataTask.cancel()
      return
    }
    self.data.append(data)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    lock.lock()
    if self.error == nil, error != nil {
      self.error = .networkUnavailable
    }
    lock.unlock()
    completion.signal()
  }

  private func fail(
    _ error: ControlledRemoteDeveloperImageCatalogError,
    task: URLSessionTask
  ) {
    lock.lock()
    if self.error == nil {
      self.error = error
    }
    lock.unlock()
    task.cancel()
  }
}
