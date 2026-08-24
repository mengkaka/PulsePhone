import Foundation
import XCTest
@testable import PulsePhoneDeveloperSupportDefinitions

final class CompatibilityTests: XCTestCase {
  func testRevisionOrHashMismatchIsIncompatible() {
    let current = DeveloperImageCompatibilityTuple(
      hash: String(repeating: "a", count: 64),
      revision: "catalog.v1"
    )
    XCTAssertEqual(
      DeveloperImageCompatibility.compare(client: current, runtime: current),
      .compatible
    )
    XCTAssertEqual(
      DeveloperImageCompatibility.compare(
        client: current,
        runtime: DeveloperImageCompatibilityTuple(
          hash: String(repeating: "b", count: 64),
          revision: "catalog.v1"
        )
      ),
      .incompatible
    )
    XCTAssertEqual(
      DeveloperImageCompatibility.compare(
        client: current,
        runtime: DeveloperImageCompatibilityTuple(
          hash: current.hash,
          revision: "catalog.v2"
        )
      ),
      .incompatible
    )
  }

  func testExactBuildMappingAndSourceGuardsRejectFallbacks() throws {
    let data = try Data(
      contentsOf: repositoryRoot().appendingPathComponent(
        "Fixtures/catalog/developer-image/catalog.v1.json"
      )
    )
    let catalog = try DeveloperImageCatalog.decodeCanonical([UInt8](data))
    XCTAssertEqual(
      DeveloperImageCompatibility.exactEntry(
        in: catalog,
        osMajor: 16,
        buildID: "20H350"
      )?.entryID,
      "classic.ios16.20H350"
    )
    XCTAssertNil(
      DeveloperImageCompatibility.exactEntry(
        in: catalog,
        osMajor: 16,
        buildID: "20H349"
      )
    )
    XCTAssertThrowsError(
      try DeveloperImageSourcePolicy.validateApprovedRemoteURL("file:///tmp/image.zip")
    )
    XCTAssertThrowsError(
      try DeveloperImageSourcePolicy.validateApprovedRemoteURL(
        "https://user@example.com/image.zip"
      )
    )
    XCTAssertEqual(
      try DeveloperImageSourcePolicy.sourceURLIdentityHash(
        "https://developer-support.pulsephone.invalid/ios16/DeveloperDiskImage.zip"
      ),
      "8f04f67bfa476b27e6788c96f1eeee6b4bc234f6b59634623b659488c62925f2"
    )
  }

  func testProvenanceHasOnlyApprovedAndMountedUnknown() throws {
    let data = try Data(
      contentsOf: repositoryRoot().appendingPathComponent(
        "Fixtures/developer-support/privacy/provenance.v1.json"
      )
    )
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    XCTAssertEqual(
      object?["allowed"] as? [String],
      DeveloperSupportProvenance.allCases.map(\.rawValue)
    )
  }

  private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
