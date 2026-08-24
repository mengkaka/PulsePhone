import Foundation
import XCTest
@testable import PulsePhoneDeveloperSupportDefinitions

final class SourcePolicyTests: XCTestCase {
  func testPartialStateSourceIdentityAndCacheOrdering() throws {
    let root = repositoryRoot()
    let partialData = try Data(
      contentsOf: root.appendingPathComponent(
        "Fixtures/developer-support/source-policy/partial-state.v1.json"
      )
    )
    let state = try JSONDecoder().decode(PartialDownloadStateV1.self, from: partialData)
    _ = try state.validated(partialFileSize: 1_024)
    XCTAssertTrue(
      try DeveloperImageSourcePolicy.mayAdopt(
        state: state,
        partialFileSize: 1_024,
        catalogIdentity: DeveloperImageCatalogIdentity(
          hash: state.developerImageCatalogHash,
          revision: state.catalogRevision
        ),
        entryID: state.catalogEntryID,
        assetKey: state.assetKey
      )
    )
    XCTAssertFalse(
      try DeveloperImageSourcePolicy.mayAdopt(
        state: state,
        partialFileSize: 1_024,
        catalogIdentity: DeveloperImageCatalogIdentity(
          hash: String(repeating: "0", count: 64),
          revision: state.catalogRevision
        ),
        entryID: state.catalogEntryID,
        assetKey: state.assetKey
      )
    )
    XCTAssertThrowsError(try state.validated(partialFileSize: 1_023))

    let indexData = try Data(
      contentsOf: root.appendingPathComponent(
        "Fixtures/developer-support/source-policy/cache-index.v1.json"
      )
    )
    let index = try JSONDecoder().decode(DeveloperImageCacheIndexV1.self, from: indexData)
    XCTAssertEqual(index.evictionOrder, [
      String(repeating: "1", count: 64),
      String(repeating: "3", count: 64),
      String(repeating: "2", count: 64),
    ])
  }

  func testCatalogAndStoreCapsAreFrozen() throws {
    XCTAssertEqual(DeveloperImageCatalog.maximumCanonicalBytes, 4_194_304)
    XCTAssertEqual(DeveloperImageCatalog.maximumRevisionFiles, 64)
    XCTAssertEqual(DeveloperImageCatalog.maximumCatalogBytes, 67_108_864)
    XCTAssertEqual(DeveloperImageCatalog.storeSoftTargetBytes, 6_442_450_944)
    XCTAssertEqual(DeveloperImageCatalog.storeHardCapBytes, 8_589_934_592)
    XCTAssertEqual(PartialDownloadStateV1.maximumCanonicalBytes, 16_384)
  }

  private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
