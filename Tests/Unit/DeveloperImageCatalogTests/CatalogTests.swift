import Foundation
import XCTest
import PulsePhoneCommandCatalog
@testable import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneSharedDefinitions

final class DeveloperImageCatalogTests: XCTestCase {
  func testCanonicalCatalogIdentityAndCrossSetReferences() throws {
    let root = repositoryRoot()
    let tracked = try DeveloperImageCatalog.load(repositoryRoot: root)
    let trackedIdentity = try DeveloperImageCatalog.identity(catalog: tracked)
    XCTAssertEqual(tracked.schemaVersion, 1)
    XCTAssertEqual(tracked.entries.count, 1)
    XCTAssertEqual(trackedIdentity.revision, "developer-image-catalog.v3-20260802")
    XCTAssertEqual(
      trackedIdentity.hash,
      "e7eafcb5a22d06137882dd97edb42404daadc4445c0cf6aaa179d4b90c8651a3"
    )
    let approved = try XCTUnwrap(tracked.entries.first)
    XCTAssertEqual(approved.buildID, "20D67")
    XCTAssertEqual(approved.ddiVersion, "16.1")
    XCTAssertEqual(approved.deviceOSRange.exactBuilds, ["20D67"])
    XCTAssertEqual(approved.evidenceState, .verified)
    XCTAssertEqual(approved.sourceURLs, [])
    XCTAssertEqual(
      approved.requiredServices,
      [
        "com.apple.instruments.remoteserver.DVTSecureSocketProxy",
        "com.apple.mobile.screenshotr",
      ]
    )
    XCTAssertEqual(approved.files.count, 2)
    XCTAssertEqual(approved.files[0].fileRole, "classic.image")
    XCTAssertEqual(approved.files[0].size, 8_469_173)
    XCTAssertEqual(
      approved.files[0].sha256,
      "cc76842f3bc22260ef46f3c0ef3e23d2c84c59f5eca5f10b077b8fb65aa08cde"
    )
    XCTAssertEqual(approved.files[1].fileRole, "classic.signature")
    XCTAssertEqual(approved.files[1].size, 128)
    XCTAssertEqual(
      approved.files[1].sha256,
      "db34174c2e0ec9be471d09a9cb6e57dd1afa0431458b71be38db4b1fe550a8d9"
    )

    let fixtureData = try Data(
      contentsOf: root.appendingPathComponent("Fixtures/catalog/developer-image/catalog.v1.json")
    )
    let catalog = try DeveloperImageCatalog.decodeCanonical([UInt8](fixtureData))
    let executionCatalog = try ExecutionProfileCatalog.load(repositoryRoot: root)
    try DeveloperImageCatalog.validateCompatibilityRules(
      catalog: catalog,
      executionCatalog: executionCatalog
    )
    let projection = try DeveloperImageCompatibility.partialProjection(
      catalog: catalog,
      executionCatalog: executionCatalog
    )
    let expected = try loadObject("Fixtures/catalog/developer-image/expected.v1.json")
    XCTAssertEqual(
      projection.developerImageCatalogHash,
      expected["developerImageCatalogHash"]?.stringValue
    )
    XCTAssertEqual(
      projection.developerImageCatalogRevision,
      expected["developerImageCatalogRevision"]?.stringValue
    )
    XCTAssertTrue(projection.pendingSameIdentityBinding)
    XCTAssertEqual(projection.preparationGroupIDs.count, 3)
    XCTAssertEqual(projection.schemaIDs.count, 6)
  }

  func testRevisionIdentityIsImmutableAndContentAddressed() throws {
    let bytes = try Data(
      contentsOf: repositoryRoot().appendingPathComponent(
        "Fixtures/catalog/developer-image/catalog.v1.json"
      )
    )
    let first = try DeveloperImageCatalog.decodeCanonical([UInt8](bytes))
    let second = try DeveloperImageCatalog.decodeCanonical([UInt8](bytes))
    XCTAssertEqual(
      try DeveloperImageCatalog.identity(catalog: first),
      try DeveloperImageCatalog.identity(catalog: second)
    )
    XCTAssertEqual(try first.entries[0].assetManifest.assetKey,
      "d06f562e388cd054396420e95c2af601ca2f678a59e1596fc6c647098252ee9d")

    var changed = bytes
    changed[changed.count - 1] = 0x0a
    XCTAssertThrowsError(try DeveloperImageCatalog.decodeCanonical([UInt8](changed)))
  }

  func testDeveloperSupportSchemasAreCanonicalAndClosed() throws {
    let expected: [String: String] = [
      "asset-content-manifest.v1.schema.json": "assetContentManifest.v1",
      "cache-index.v1.schema.json": "developerImageCacheIndex.v1",
      "developer-image-catalog.v1.schema.json": "developerImageCatalog.v1",
      "developer-support-provenance.v1.schema.json": "developerSupportProvenance.v1",
      "partial-download-state.v1.schema.json": "partialDownloadState.v1",
      "preparation-group.v1.schema.json": "preparationGroup.v1",
    ]
    for (name, schemaID) in expected {
      let object = try loadObject("Schemas/developer-support/\(name)")
      XCTAssertEqual(object["$id"]?.stringValue, schemaID)
      XCTAssertEqual(
        object["$schema"]?.stringValue,
        "https://json-schema.org/draft/2020-12/schema"
      )
      if name != "developer-support-provenance.v1.schema.json" {
        guard case .bool(false)? = object["additionalProperties"] else {
          return XCTFail("schema must be closed: \(name)")
        }
      }
    }
  }

  private func loadObject(_ relativePath: String) throws -> RepositoryJSONObject {
    let data = try Data(contentsOf: repositoryRoot().appendingPathComponent(relativePath))
    return try RepositoryCanonicalJSON.validateCanonicalDocument(
      [UInt8](data),
      maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
    ).root
  }

  private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
