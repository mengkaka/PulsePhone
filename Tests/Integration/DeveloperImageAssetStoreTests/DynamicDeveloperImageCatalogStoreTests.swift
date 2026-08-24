import Foundation
@testable import PulsePhoneDeveloperImageAssets
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneSharedDefinitions
import XCTest

final class DynamicDeveloperImageCatalogStoreTests: XCTestCase {
  func testReleaseArchiveDirectoryAdmissionUsesBaseAssetsAndDDIOnly() {
    let prefix = "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/"
    let configuration = DynamicDeveloperImageCatalogStoreConfiguration.release

    XCTAssertTrue(configuration.validatesArchiveURL(prefix + "baseAssets/base.26.5.tar"))
    XCTAssertTrue(configuration.validatesArchiveURL(prefix + "DDI/16.3-test.tar"))
    XCTAssertFalse(configuration.validatesArchiveURL(prefix + "developerDiskImages/16.3-test.tar"))
    XCTAssertFalse(configuration.validatesArchiveURL(prefix + "DDI/nested/16.3-test.tar"))
  }

  func testSelectedXcodeInventoryCommandHasBoundedTimeout() {
    let started = Date()
    let result = SelectedXcodeDynamicAssetInventory.command(
      "/bin/sleep",
      ["2"],
      timeout: .milliseconds(50)
    )

    XCTAssertNil(result)
    XCTAssertLessThan(Date().timeIntervalSince(started), 1)
  }

  func testContentManifestCanonicalVectorMatchesGoHelpers() throws {
    let files = [
      DynamicDeveloperImageContentFile(
        path: "BuildManifest.plist",
        sha256: "0d88148fc3bff2ea9f23785b42a583ce7d299f3998f2c447a7959a756f679724",
        size: 805_005
      ),
      DynamicDeveloperImageContentFile(
        path: "Image.dmg",
        sha256: "2663caa3008f256f413931dd30c518c7701fc1a91bc15052705303e85c994a69",
        size: 15_687_680
      ),
      DynamicDeveloperImageContentFile(
        path: "Image.dmg.trustcache",
        sha256: "a7bffc13ed8d058c3670220ced9c37aa8e8b90a11273ab2b9c0202da5e92ffd6",
        size: 1_895
      ),
    ]
    XCTAssertEqual(
      try DynamicDeveloperImageContentManifest.sha256(files),
      "2fcc544d8d4eaee948a56815604efb72d2425878d6248cb347ae6195f355cac5"
    )
  }

  func testCatalogSelectsExactClassicFallbackAndDefaultCandidate() throws {
    let catalog = try decodeCatalog(revision: "2026-08-22.1")

    let exact = try XCTUnwrap(
      DynamicDeveloperImageCatalog.exactBaseAsset(in: catalog, buildID: "23F84")
    )
    XCTAssertEqual(exact.provenance, .remoteVerified)
    XCTAssertEqual(exact.asset.assetID, "base.26.5.xcode-27A5218g")

    let fallback = try XCTUnwrap(
      DynamicDeveloperImageCatalog.classicDDI(in: catalog, iosVersion: "16.3.1")
    )
    XCTAssertEqual(fallback.ddiVersion, "16.3")
    XCTAssertEqual(fallback.kind, .developerDiskImage)

    let candidate = try XCTUnwrap(DynamicDeveloperImageCatalog.baseAsset(
      in: catalog,
      baseAssetID: catalog.defaultCandidateBaseAssetID,
      provenance: .defaultCandidate
    ))
    XCTAssertEqual(candidate.provenance, .defaultCandidate)
    XCTAssertEqual(
      try DynamicDeveloperImageCatalog.identity(catalog: catalog).canonicalSHA256,
      StableBytes.sha256Hex(Data(try DynamicDeveloperImageCatalog.canonicalBytes(catalog)))
    )
  }

  func testLegacyCatalogIgnoresDeprecatedXcodeDirectoryKey() throws {
    let data = try catalogData(revision: "2026-08-22.1")
    var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var diskImages = try XCTUnwrap(root["developerDiskImages"] as? [[String: Any]])
    diskImages[0]["xcodeDDIVersion"] = "16.1"
    root["developerDiskImages"] = diskImages
    let legacy = try JSONSerialization.data(
      withJSONObject: root,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )

    let catalog = try DynamicDeveloperImageCatalog.decodeCanonical([UInt8](legacy))
    XCTAssertEqual(
      try DynamicDeveloperImageCatalog.identity(
        catalog: catalog,
        canonicalBytes: [UInt8](legacy)
      ).canonicalSHA256,
      StableBytes.sha256Hex(legacy)
    )
    XCTAssertEqual(
      try XCTUnwrap(
        DynamicDeveloperImageCatalog.classicDDI(in: catalog, iosVersion: "16.3.1")
      ).ddiVersion,
      "16.3"
    )
  }

  func testStorePreservesLegacyCatalogIdentityAcrossRefresh() throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_785_000_000))
    let legacy = try legacyCatalogData(revision: "2026-08-22.5")
    let expectedHash = StableBytes.sha256Hex(legacy)
    let remote = TestRemote([
      .init(data: legacy, etag: "\"legacy\"", statusCode: 200),
      .init(data: Data(), etag: "\"legacy\"", statusCode: 304),
    ])
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("pulsephone-legacy-catalog-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try DynamicDeveloperImageCatalogStore(
      rootURL: root,
      configuration: configuration,
      fetch: remote.fetch,
      now: clock.now
    )

    XCTAssertEqual(try store.snapshot().identity.canonicalSHA256, expectedHash)
    clock.advance(seconds: 3_601)
    XCTAssertEqual(try store.snapshot().identity.canonicalSHA256, expectedHash)

    let reloaded = try DynamicDeveloperImageCatalogStore(
      rootURL: root,
      configuration: configuration,
      fetch: TestRemote([]).fetch,
      now: clock.now
    )
    XCTAssertEqual(try reloaded.snapshot().identity.canonicalSHA256, expectedHash)
  }

  func testStoreUsesETagLKGAndRejectsRollbackWithoutReplacingCurrentSnapshot() throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_785_000_000))
    let remote = TestRemote([
      .init(data: try catalogData(revision: "2026-08-22.1"), etag: "\"v1\"", statusCode: 200),
      .init(data: Data(), etag: "\"v1\"", statusCode: 304),
      .init(data: try catalogData(revision: "2026-08-21.9"), etag: "\"old\"", statusCode: 200),
      .init(data: try catalogData(revision: "2026-08-22.2"), etag: "\"v2\"", statusCode: 200),
    ])
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("pulsephone-dynamic-catalog-\(UUID().uuidString)")
    let store = try DynamicDeveloperImageCatalogStore(
      rootURL: root,
      configuration: configuration,
      fetch: remote.fetch,
      now: clock.now
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }

    let first = try store.snapshot()
    XCTAssertFalse(first.staleCatalog)
    XCTAssertEqual(first.identity.revision, "2026-08-22.1")

    clock.advance(seconds: 3_601)
    let notModified = try store.snapshot()
    XCTAssertFalse(notModified.staleCatalog)
    XCTAssertEqual(notModified.identity, first.identity)
    XCTAssertEqual(remote.observedETags, [nil, "\"v1\""])

    clock.advance(seconds: 3_601)
    let rollback = try store.snapshot()
    XCTAssertTrue(rollback.staleCatalog)
    XCTAssertEqual(rollback.identity, first.identity)

    clock.advance(seconds: 3_601)
    let updated = try store.snapshot()
    XCTAssertFalse(updated.staleCatalog)
    XCTAssertEqual(updated.identity.revision, "2026-08-22.2")
  }

  func testContentAddressedBaseImageCacheValidatesArchiveAndCacheHit() throws {
    let files = [
      ("BuildManifest.plist", Data("manifest".utf8)),
      ("Image.dmg", Data("image".utf8)),
      ("Image.dmg.trustcache", Data("trust".utf8)),
    ]
    let archive = makeUSTAR(entries: files)
    let contentFiles = files.map {
      DynamicDeveloperImageContentFile(
        path: $0.0,
        sha256: StableBytes.sha256Hex($0.1),
        size: UInt64($0.1.count)
      )
    }.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    let reference = DynamicDeveloperImageAssetReference(
      archiveSHA256: StableBytes.sha256Hex(archive),
      archiveSize: UInt64(archive.count),
      assetID: "base.26.5.xcode-27A5218g",
      contentManifestSHA256: try DynamicDeveloperImageContentManifest.sha256(contentFiles),
      ddiVersion: nil,
      kind: .baseImage,
      sourceURL: "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/baseAssets/base.26.5.xcode-27A5218g-test.tar"
    )
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("pulsephone-dynamic-cache-\(UUID().uuidString)")
    let cache = try DynamicDeveloperImageAssetCache(
      rootURL: root,
      configuration: configuration,
      fetch: { _, _ in archive }
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }

    let published = try cache.publish(reference, archive: archive)
    try assertExternalSharedLockCanOpen(cache: cache, reference: reference, lease: published)
    let cached = try XCTUnwrap(cache.openVerified(reference))
    XCTAssertEqual(cached.contentManifestSHA256, reference.contentManifestSHA256)
    XCTAssertEqual(cached.roleFiles["personalized.image"]?.size, 5)

    var corrupt = archive
    corrupt[0] ^= 0x01
    let corruptedArchive = corrupt
    let otherRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("pulsephone-dynamic-cache-corrupt-\(UUID().uuidString)")
    let other = try DynamicDeveloperImageAssetCache(
      rootURL: otherRoot,
      configuration: configuration,
      fetch: { _, _ in corruptedArchive }
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: otherRoot) }
    XCTAssertThrowsError(try other.acquireRemote(reference)) { error in
      XCTAssertEqual(error as? DynamicDeveloperImageAssetCacheError, .archiveIntegrityFailed)
    }

    let remoteRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("pulsephone-dynamic-cache-remote-\(UUID().uuidString)")
    let remote = try DynamicDeveloperImageAssetCache(
      rootURL: remoteRoot,
      configuration: configuration,
      fetch: { _, _ in archive }
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: remoteRoot) }
    let remotelyAcquired = try remote.acquireRemote(reference)
    try assertExternalSharedLockCanOpen(
      cache: remote,
      reference: reference,
      lease: remotelyAcquired
    )
  }

  func testContentAddressedBaseImageCacheImportsCatalogMatchedLocalContent() throws {
    let files = [
      ("BuildManifest.plist", Data("manifest".utf8)),
      ("Image.dmg", Data("image".utf8)),
      ("Image.dmg.trustcache", Data("trust".utf8)),
    ]
    let contentFiles = files.map {
      DynamicDeveloperImageContentFile(
        path: $0.0,
        sha256: StableBytes.sha256Hex($0.1),
        size: UInt64($0.1.count)
      )
    }.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    let reference = DynamicDeveloperImageAssetReference(
      archiveSHA256: String(repeating: "a", count: 64),
      archiveSize: 42,
      assetID: "base.local-import",
      contentManifestSHA256: try DynamicDeveloperImageContentManifest.sha256(contentFiles),
      ddiVersion: nil,
      kind: .baseImage,
      sourceURL: "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/baseAssets/base.local-import.tar"
    )
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("pulsephone-dynamic-local-import-\(UUID().uuidString)")
    let cache = try DynamicDeveloperImageAssetCache(
      rootURL: root,
      configuration: configuration,
      fetch: { _, _ in XCTFail("local import must not fetch the remote archive"); return Data() }
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }

    let imported = try cache.importVerifiedContent(reference, files: Dictionary(uniqueKeysWithValues: files))
    XCTAssertEqual(imported.contentManifestSHA256, reference.contentManifestSHA256)
    XCTAssertEqual(imported.roleFiles["personalized.trustCache"]?.size, 5)
    try assertExternalSharedLockCanOpen(cache: cache, reference: reference, lease: imported)

    var mismatched = Dictionary(uniqueKeysWithValues: files)
    mismatched["Image.dmg"] = Data("other".utf8)
    let otherRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("pulsephone-dynamic-local-mismatch-\(UUID().uuidString)")
    let other = try DynamicDeveloperImageAssetCache(
      rootURL: otherRoot,
      configuration: configuration,
      fetch: { _, _ in Data() }
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: otherRoot) }
    XCTAssertThrowsError(try other.importVerifiedContent(reference, files: mismatched)) { error in
      XCTAssertEqual(error as? DynamicDeveloperImageAssetCacheError, .contentManifestMismatch)
    }
  }

  func testLocalCandidateRecordIsBuildOnlyAndRequiresActiveBaseAsset() throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_785_000_000))
    let remote = TestRemote([
      .init(data: try catalogData(revision: "2026-08-22.1"), etag: nil, statusCode: 200),
    ])
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("pulsephone-dynamic-candidate-\(UUID().uuidString)")
    let store = try DynamicDeveloperImageCatalogStore(
      rootURL: root,
      configuration: configuration,
      fetch: remote.fetch,
      now: clock.now
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let snapshot = try store.snapshot()
    let candidate = try XCTUnwrap(DynamicDeveloperImageCatalog.baseAsset(
      in: snapshot.catalog,
      baseAssetID: snapshot.catalog.defaultCandidateBaseAssetID,
      provenance: .defaultCandidate
    ))

    try store.recordSuccessfulDefaultCandidate(
      iosVersion: "26.6",
      buildID: "23G80",
      selection: candidate,
      snapshot: snapshot,
      serviceProfileID: "developer-image.prepare.v1"
    )
    let local = try XCTUnwrap(store.localCandidate(buildID: "23G80", snapshot: snapshot))
    XCTAssertEqual(local.provenance, .localValidated)
    XCTAssertEqual(local.asset, candidate.asset)
    XCTAssertNil(try store.localCandidate(buildID: "23G81", snapshot: snapshot))
    XCTAssertThrowsError(try store.recordSuccessfulDefaultCandidate(
      iosVersion: "26.5.2",
      buildID: "23F84",
      selection: DynamicDeveloperImageSelection(
        asset: candidate.asset,
        provenance: .remoteVerified
      ),
      snapshot: snapshot,
      serviceProfileID: "developer-image.prepare.v1"
    ))
  }

  func testReadOnlyDiagnosticsClassifyVerifiedLocalCandidateAndUnsupported() throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_785_000_000))
    let remote = TestRemote([
      .init(data: try catalogData(revision: "2026-08-22.1"), etag: nil, statusCode: 200),
    ])
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("pulsephone-dynamic-diagnostics-\(UUID().uuidString)")
    let store = try DynamicDeveloperImageCatalogStore(
      rootURL: root,
      configuration: configuration,
      fetch: remote.fetch,
      now: clock.now
    )
    let cache = try DynamicDeveloperImageAssetCache(
      rootURL: root,
      configuration: configuration,
      fetch: { _, _ in XCTFail("diagnostics must not download archives"); return Data() }
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let diagnostics = DynamicDeveloperImageDiagnostics(
      catalogStore: store,
      assetCache: cache,
      xcodeMatcher: { _ in false }
    )

    let list = try diagnostics.list()
    XCTAssertEqual(list.records.count, 2)
    XCTAssertEqual(list.defaultCandidate.state, .candidateOnly)
    XCTAssertEqual(list.defaultCandidate.sources, [.approvedRemote])
    XCTAssertEqual(list.records.map(\.mappingStatus), [.remoteVerified, .remoteVerified])

    let verified = try diagnostics.check(
      iosVersion: "26.5.2",
      buildID: "23F84",
      developerServicesReady: false
    )
    XCTAssertEqual(verified.status, .verifiedAvailable)
    XCTAssertEqual(verified.mappingStatus, .remoteVerified)
    XCTAssertEqual(verified.sources, [.approvedRemote])

    let snapshot = try store.snapshot()
    let candidate = try XCTUnwrap(DynamicDeveloperImageCatalog.baseAsset(
      in: snapshot.catalog,
      baseAssetID: snapshot.catalog.defaultCandidateBaseAssetID,
      provenance: .defaultCandidate
    ))
    try store.recordSuccessfulDefaultCandidate(
      iosVersion: "26.6",
      buildID: "23G80",
      selection: candidate,
      snapshot: snapshot,
      serviceProfileID: "prep.coredevice.v2"
    )
    let local = try diagnostics.check(
      iosVersion: "26.6",
      buildID: "23G80",
      developerServicesReady: false
    )
    XCTAssertEqual(local.status, .locallyValidatedAvailable)
    XCTAssertEqual(local.mappingStatus, .localValidated)

    let candidateOnly = try diagnostics.check(
      iosVersion: "26.7",
      buildID: "23H1",
      developerServicesReady: false
    )
    XCTAssertEqual(candidateOnly.status, .candidateAvailable)
    XCTAssertEqual(candidateOnly.mappingStatus, .defaultCandidate)

    let unsupported = try diagnostics.check(
      iosVersion: "13.7",
      buildID: "17H35",
      developerServicesReady: false
    )
    XCTAssertEqual(unsupported.status, .unsupported)
    XCTAssertNil(unsupported.mappingStatus)
  }

  private let configuration = DynamicDeveloperImageCatalogStoreConfiguration(
    catalogURL: "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/catalog-test.json",
    archiveURLPrefix: "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/"
  )

  private func assertExternalSharedLockCanOpen(
    cache: DynamicDeveloperImageAssetCache,
    reference: DynamicDeveloperImageAssetReference,
    lease: DynamicDeveloperImageAssetLease
  ) throws {
    let path = cache.rootURL
      .appendingPathComponent("locks/\(reference.contentManifestSHA256).lock").path
    try withExtendedLifetime(lease) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
      process.arguments = [
        "-MFcntl=:flock",
        "-e",
        "open(my $fh, '+<', $ARGV[0]) or exit 2; flock($fh, LOCK_SH | LOCK_NB) or exit 3; exit 0;",
        path,
      ]
      try process.run()
      process.waitUntilExit()
      XCTAssertEqual(process.terminationStatus, 0)
    }
  }

  private func decodeCatalog(revision: String) throws -> DynamicDeveloperImageCatalogV1 {
    try DynamicDeveloperImageCatalog.decodeCanonical([UInt8](try catalogData(revision: revision)))
  }

  private func catalogData(revision: String) throws -> Data {
    let baseURL = "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/baseAssets/base.26.5.xcode-27A5218g-aaaaaaaa.tar"
    let ddiURL = "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/DDI/16.3-bbbbbbbb.tar"
    let object: [String: Any] = [
      "baseAssets": [[
        "archiveSHA256": String(repeating: "a", count: 64),
        "archiveSize": 10,
        "baseAssetID": "base.26.5.xcode-27A5218g",
        "contentManifestSHA256": String(repeating: "b", count: 64),
        "sourceURL": baseURL,
      ]],
      "catalogEntry": [[
        "baseAssetID": "base.26.5.xcode-27A5218g",
        "buildID": "23F84",
        "iosVersion": "26.5.2",
      ]],
      "catalogRevision": revision,
      "defaultCandidateBaseAssetID": "base.26.5.xcode-27A5218g",
      "developerDiskImages": [[
        "archiveSHA256": String(repeating: "c", count: 64),
        "archiveSize": 10,
        "contentManifestSHA256": String(repeating: "d", count: 64),
        "ddiVersion": "16.3",
        "sourceURL": ddiURL,
      ]],
      "schemaVersion": 1,
    ]
    return try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
  }

  private func legacyCatalogData(revision: String) throws -> Data {
    let data = try catalogData(revision: revision)
    var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var diskImages = try XCTUnwrap(root["developerDiskImages"] as? [[String: Any]])
    diskImages[0]["xcodeDDIVersion"] = "16.1"
    root["developerDiskImages"] = diskImages
    return try JSONSerialization.data(
      withJSONObject: root,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
  }

  private func makeUSTAR(entries: [(String, Data)]) -> Data {
    var archive = Data()
    for (name, bytes) in entries {
      var header = [UInt8](repeating: 0, count: 512)
      header.replaceSubrange(0..<name.utf8.count, with: name.utf8)
      writeOctal(0o644, to: &header, range: 100..<108)
      writeOctal(0, to: &header, range: 108..<116)
      writeOctal(0, to: &header, range: 116..<124)
      writeOctal(UInt64(bytes.count), to: &header, range: 124..<136)
      writeOctal(0, to: &header, range: 136..<148)
      header.replaceSubrange(148..<156, with: [UInt8](repeating: 32, count: 8))
      header[156] = 0
      header.replaceSubrange(257..<263, with: Array("ustar\0".utf8))
      header.replaceSubrange(263..<265, with: Array("00".utf8))
      writeOctal(header.reduce(UInt64(0)) { $0 + UInt64($1) }, to: &header, range: 148..<156)
      archive.append(contentsOf: header)
      archive.append(bytes)
      archive.append(Data(repeating: 0, count: (512 - bytes.count % 512) % 512))
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

private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(_ value: Date) { self.value = value }

  func advance(seconds: TimeInterval) {
    lock.lock()
    value = value.addingTimeInterval(seconds)
    lock.unlock()
  }

  var now: @Sendable () -> Date {
    { [self] in
      lock.lock()
      defer { lock.unlock() }
      return value
    }
  }
}

private final class TestRemote: @unchecked Sendable {
  private let lock = NSLock()
  private var responses: [DynamicDeveloperImageCatalogHTTPResponse]
  private(set) var observedETags = [String?]()

  init(_ responses: [DynamicDeveloperImageCatalogHTTPResponse]) {
    self.responses = responses
  }

  var fetch: DynamicDeveloperImageCatalogStore.HTTPFetcher {
    { [self] _, etag in
      lock.lock()
      defer { lock.unlock() }
      observedETags.append(etag)
      guard !responses.isEmpty else { throw TestRemoteError.exhausted }
      return responses.removeFirst()
    }
  }
}

private enum TestRemoteError: Error {
  case exhausted
}
