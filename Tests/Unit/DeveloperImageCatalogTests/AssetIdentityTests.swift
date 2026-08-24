import Foundation
import XCTest
@testable import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneSharedDefinitions

final class AssetIdentityTests: XCTestCase {
  func testContentManifestKeyAndCanonicalRoleLayout() throws {
    let root = repositoryRoot()
    let data = try Data(
      contentsOf: root.appendingPathComponent(
        "Fixtures/developer-support/asset-content/manifest.v1.json"
      )
    )
    _ = try RepositoryCanonicalJSON.validateCanonicalDocument(
      [UInt8](data),
      maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
    )
    let manifest = try JSONDecoder().decode(AssetContentManifestV1.self, from: data)
    _ = try manifest.validated()
    let assetKey = try manifest.assetKey
    XCTAssertEqual(
      assetKey,
      "d06f562e388cd054396420e95c2af601ca2f678a59e1596fc6c647098252ee9d"
    )
    XCTAssertEqual([UInt8](data), try manifest.canonicalBytes)
    XCTAssertEqual(
      try DeveloperImageAssetIdentity.canonicalRoleRelativePath(
        assetKey: assetKey,
        fileRole: "classic.image"
      ),
      "assets/\(assetKey)/roles/classic.image"
    )
  }

  func testRolesAndManifestBoundsFailClosed() throws {
    XCTAssertThrowsError(
      try DeveloperImageAssetIdentity.canonicalRoleRelativePath(
        assetKey: String(repeating: "a", count: 64),
        fileRole: "../classic.image"
      )
    )
    let duplicate = AssetContentManifestV1(
      files: [
        AssetContentFileV1(
          fileRole: "classic.image",
          sha256: String(repeating: "a", count: 64),
          size: 1
        ),
        AssetContentFileV1(
          fileRole: "classic.image",
          sha256: String(repeating: "b", count: 64),
          size: 1
        ),
      ],
      imageKind: .classic
    )
    XCTAssertThrowsError(try duplicate.validated())
  }

  private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
