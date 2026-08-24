import Foundation
@testable import PulsePhoneDeveloperImageAssets
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneSharedDefinitions
import XCTest

final class ControlledRemoteDeveloperImageCatalogTests: XCTestCase {
  func testBoundedHTTPSFetcherRetainsSystemProxySelection() {
    let configuration = BoundedHTTPSDataFetcher.sessionConfiguration()

    XCTAssertNil(configuration.connectionProxyDictionary)
    XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
    XCTAssertNil(configuration.httpCookieStorage)
    XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertNil(configuration.urlCache)
    XCTAssertNil(configuration.urlCredentialStorage)
  }

  func testRemoteCatalogPublishesVerifiedAssetAndFallsBackToCache() throws {
    let files = [
      ("BuildManifest.plist", Data("manifest".utf8)),
      ("Image.dmg", Data("image".utf8)),
      ("Image.dmg.trustcache", Data("trust-cache".utf8)),
    ]
    let archive = makeUSTAR(entries: files)
    let catalogURL = URL(string: "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/catalog-test.json")!
    let archiveURL = URL(string: "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/catalog-test.tar")!
    let catalog = try makeCatalog(
      archive: archive,
      files: files,
      sourceURL: archiveURL.absoluteString
    )
    let payload = RemotePayload(
      catalog: Data(try DeveloperImageCatalog.canonicalBytes(catalog)),
      catalogURL: catalogURL,
      archive: archive,
      archiveURL: archiveURL
    )
    let client = ControlledRemoteDeveloperImageCatalog(
      configuration: configuration(catalogURL: catalogURL),
      fetch: payload.fetch
    )
    let store = try makeStore()
    addTeardownBlock { try? FileManager.default.removeItem(at: store.rootURL) }

    let remote = try XCTUnwrap(client.matchingCatalog(
      assetStore: store,
      osMajor: 26,
      buildID: "23F84",
      validateCatalog: validateCatalog
    ))
    XCTAssertEqual(remote.catalogRevision, catalog.catalogRevision)
    XCTAssertEqual(try store.acceptedCatalogs(), [catalog])

    let published = try client.acquire(
      catalog: remote,
      entryID: "personalized.ios26.23F84",
      assetStore: store
    )
    let lease = try XCTUnwrap(store.openVerifiedAsset(
      catalog: remote,
      entryID: "personalized.ios26.23F84"
    ))
    XCTAssertEqual(lease.assetKey, published.assetKey)
    XCTAssertEqual(lease.roleFiles["personalized.image"]?.size, 5)

    payload.online = false
    let cached = try XCTUnwrap(client.matchingCatalog(
      assetStore: store,
      osMajor: 26,
      buildID: "23F84",
      validateCatalog: validateCatalog
    ))
    XCTAssertEqual(cached, catalog)
  }

  func testRemoteCatalogRejectsUnexpectedArchiveSourceAndBadArchiveHash() throws {
    let files = [
      ("BuildManifest.plist", Data("manifest".utf8)),
      ("Image.dmg", Data("image".utf8)),
      ("Image.dmg.trustcache", Data("trust-cache".utf8)),
    ]
    let archive = makeUSTAR(entries: files)
    let catalogURL = URL(string: "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/catalog-test.json")!
    let archiveURL = URL(string: "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/catalog-test.tar")!
    let catalog = try makeCatalog(
      archive: archive,
      files: files,
      sourceURL: archiveURL.absoluteString
    )
    let payload = RemotePayload(
      catalog: Data(try DeveloperImageCatalog.canonicalBytes(catalog)),
      catalogURL: catalogURL,
      archive: Data(archive.dropLast()),
      archiveURL: archiveURL
    )
    let client = ControlledRemoteDeveloperImageCatalog(
      configuration: configuration(catalogURL: catalogURL),
      fetch: payload.fetch
    )
    let store = try makeStore()
    addTeardownBlock { try? FileManager.default.removeItem(at: store.rootURL) }

    XCTAssertThrowsError(try client.acquire(
      catalog: catalog,
      entryID: "personalized.ios26.23F84",
      assetStore: store
    )) { error in
      XCTAssertEqual(
        error as? ControlledRemoteDeveloperImageCatalogError,
        .archiveIntegrityFailed
      )
    }

    let rejected = try makeCatalog(
      archive: archive,
      files: files,
      sourceURL: "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/unapproved.tar"
    )
    payload.catalog = Data(try DeveloperImageCatalog.canonicalBytes(rejected))
    XCTAssertThrowsError(try client.matchingCatalog(
      assetStore: try makeStore(),
      osMajor: 26,
      buildID: "23F84",
      validateCatalog: validateCatalog
    )) { error in
      XCTAssertEqual(
        error as? ControlledRemoteDeveloperImageCatalogError,
        .catalogRejected
      )
    }
  }

  func testUSTARParserRejectsAppleDoubleAndExtendedHeaders() throws {
    let expected: Set<String> = ["BuildManifest.plist"]
    for type in [UInt8(0), UInt8(120)] {
      let name = type == 0 ? "._BuildManifest.plist" : "BuildManifest.plist"
      let archive = makeUSTAR(entries: [(name, Data("payload".utf8), type)])
      XCTAssertThrowsError(try DeveloperImageUSTARArchive.parse(
        archive,
        expectedPaths: expected,
        extractedUpperBound: 1_024
      )) { error in
        XCTAssertEqual(
          error as? ControlledRemoteDeveloperImageCatalogError,
          .archiveIntegrityFailed
        )
      }
    }
  }

  private func makeCatalog(
    archive: Data,
    files: [(String, Data)],
    sourceURL: String
  ) throws -> DeveloperImageCatalogV1 {
    let archiveFiles = [
      ("BuildManifest.plist", "personalized.buildManifest"),
      ("Image.dmg", "personalized.image"),
      ("Image.dmg.trustcache", "personalized.trustCache"),
    ].map { path, role in
      let bytes = files.first(where: { $0.0 == path })!.1
      return [
        "archiveRelativePath": path,
        "fileRole": role,
        "sha256": StableBytes.sha256Hex(bytes),
        "size": bytes.count,
      ] as [String: Any]
    }
    let object: [String: Any] = [
      "catalogRevision": "mengkaka-release-test.1",
      "entries": [[
        "archiveSHA256": StableBytes.sha256Hex(archive),
        "archiveSize": archive.count,
        "buildID": "23F84",
        "compatibilityRuleID": "compat.preparation.coredevice.v2",
        "ddiVersion": "27A5218g",
        "deviceOSRange": [
          "exactBuilds": ["23F84"],
          "maximumMajorExclusive": 27,
          "minimumMajor": 26,
        ],
        "entryID": "personalized.ios26.23F84",
        "evidenceState": "target",
        "extractedUpperBound": files.reduce(0) { $0 + $1.1.count },
        "files": archiveFiles,
        "imageKind": "personalized",
        "requiredServices": [
          "com.apple.coredevice.appservice",
          "com.apple.coredevice.screencaptureservice",
        ],
        "sourceURLs": [sourceURL],
      ]],
      "schemaVersion": 1,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
    return try DeveloperImageCatalog.decodeCanonical([UInt8](data))
  }

  private func configuration(
    catalogURL: URL
  ) -> ControlledRemoteDeveloperImageCatalogConfiguration {
    ControlledRemoteDeveloperImageCatalogConfiguration(
      catalogURL: catalogURL.absoluteString,
      catalogRevisionPrefix: "mengkaka-release-",
      archiveURLPrefix: "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/"
    )
  }

  private func makeStore() throws -> DeveloperImageAssetStore {
    try DeveloperImageAssetStore(
      rootURL: try temporaryDirectory().appendingPathComponent("DeveloperImages")
    )
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pulsephone-remote-ddi-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }

  private var validateCatalog: ControlledRemoteDeveloperImageCatalog.CatalogValidator {
    { catalog in
      guard catalog.entries.allSatisfy({
        $0.compatibilityRuleID == "compat.preparation.coredevice.v2"
      }) else {
        throw RemoteTestError.invalidCatalog
      }
    }
  }

  private func makeUSTAR(entries: [(String, Data)]) -> Data {
    makeUSTAR(entries: entries.map { ($0.0, $0.1, UInt8(0)) })
  }

  private func makeUSTAR(entries: [(String, Data, UInt8)]) -> Data {
    var archive = Data()
    for (name, bytes, type) in entries {
      var header = [UInt8](repeating: 0, count: 512)
      let nameBytes = Array(name.utf8)
      header.replaceSubrange(0..<nameBytes.count, with: nameBytes)
      writeOctal(0o644, to: &header, range: 100..<108)
      writeOctal(0, to: &header, range: 108..<116)
      writeOctal(0, to: &header, range: 116..<124)
      writeOctal(UInt64(bytes.count), to: &header, range: 124..<136)
      writeOctal(0, to: &header, range: 136..<148)
      header.replaceSubrange(148..<156, with: [UInt8](repeating: 32, count: 8))
      header[156] = type
      header.replaceSubrange(257..<263, with: Array("ustar\0".utf8))
      header.replaceSubrange(263..<265, with: Array("00".utf8))
      let checksum = header.reduce(UInt64(0)) { $0 + UInt64($1) }
      writeOctal(checksum, to: &header, range: 148..<156)
      archive.append(contentsOf: header)
      archive.append(bytes)
      let padding = (512 - bytes.count % 512) % 512
      archive.append(Data(repeating: 0, count: padding))
    }
    archive.append(Data(repeating: 0, count: 1_024))
    return archive
  }

  private func writeOctal(_ value: UInt64, to header: inout [UInt8], range: Range<Int>) {
    let digits = Array(String(value, radix: 8).utf8)
    let padding = range.count - digits.count - 1
    header.replaceSubrange(
      range,
      with: [UInt8](repeating: 48, count: padding) + digits + [0]
    )
  }
}

private enum RemoteTestError: Error {
  case invalidCatalog
}

private final class RemotePayload: @unchecked Sendable {
  private let lock = NSLock()
  var archive: Data
  let archiveURL: URL
  var catalog: Data
  let catalogURL: URL
  var online = true

  init(catalog: Data, catalogURL: URL, archive: Data, archiveURL: URL) {
    self.catalog = catalog
    self.catalogURL = catalogURL
    self.archive = archive
    self.archiveURL = archiveURL
  }

  var fetch: ControlledRemoteDeveloperImageCatalog.DataFetcher {
    { [self] url, _ in
      lock.lock()
      defer { lock.unlock() }
      guard online else { throw RemoteTestError.invalidCatalog }
      if url == catalogURL { return catalog }
      if url == archiveURL { return archive }
      throw RemoteTestError.invalidCatalog
    }
  }
}
