import Foundation
import PulsePhoneSharedDefinitions

struct CommandMatrixCoverageFixture: Decodable {
  struct Counts: Decodable {
    let features: Int
    let guiToolbarWindow: Int
    let ownerBoundInteractions: Int
    let productActions: Int
    let publicCLIVariants: Int
    let supportingActions: Int
  }

  struct ProductProfile: Decodable, Equatable {
    let commandID: String
    let executionProfileID: String
    let loggingProfileID: String
  }

  struct ScopeRow: Decodable, Equatable {
    let id: String
    let scope: String
  }

  struct GUISurfaceRow: Decodable, Equatable {
    let commandID: String
    let kind: String
    let order: UInt64?
  }

  let counts: Counts
  let featureScopes: [ScopeRow]
  let guiOwnerBoundCommandIDs: [String]
  let guiSurfaceRows: [GUISurfaceRow]
  let guiToolbarWindowCommandIDs: [String]
  let productProfiles: [ProductProfile]
  let productScopeCommandIDs: [String]
  let publicCLICommandIDs: [String]
  let schemaVersion: UInt64
  let supportingScopes: [ScopeRow]
}

struct NegativeExposureFixture: Decodable {
  let excludedEntries: [String]
  let forbiddenCLIVariants: [String]
  let forbiddenCommandIDs: [String]
  let forbiddenGUISurfaceCommandIDs: [String]
  let internalOnlyIDs: [String]
  let schemaVersion: UInt64
}

enum CommandMatrixCoverageSupport {
  static let coverageFixtureRelativePath =
    "Fixtures/catalog/coverage/command-matrix-coverage.v1.json"
  static let negativeFixtureRelativePath =
    "Fixtures/catalog/coverage/negative-exposure.v1.json"

  static func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  static func loadCoverage() throws -> CommandMatrixCoverageFixture {
    try load(CommandMatrixCoverageFixture.self, relativePath: coverageFixtureRelativePath)
  }

  static func loadNegative() throws -> NegativeExposureFixture {
    try load(NegativeExposureFixture.self, relativePath: negativeFixtureRelativePath)
  }

  static func loadCanonicalObject(_ relativePath: String) throws -> RepositoryJSONObject {
    let data = try Data(
      contentsOf: repositoryRoot().appendingPathComponent(relativePath)
    )
    return try RepositoryCanonicalJSON.validateCanonicalDocument(
      [UInt8](data),
      maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
    ).root
  }

  private static func load<T: Decodable>(
    _ type: T.Type,
    relativePath: String
  ) throws -> T {
    let data = try Data(
      contentsOf: repositoryRoot().appendingPathComponent(relativePath)
    )
    _ = try RepositoryCanonicalJSON.validateCanonicalDocument(
      [UInt8](data),
      maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
    )
    return try JSONDecoder().decode(type, from: data)
  }
}
