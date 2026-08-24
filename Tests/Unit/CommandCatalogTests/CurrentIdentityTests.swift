import Foundation
import XCTest
@testable import PulsePhoneCommandCatalog
import PulsePhoneSharedDefinitions

final class CurrentIdentityTests: XCTestCase {
  func testCurrentCommandMatrixArtifactSetAndIdentity() throws {
    let root = repositoryRoot()
    let profile = try loadObject(
      root.appendingPathComponent(
        "Fixtures/developer-support/routing/current-profile.v1.json"
      )
    )
    let paths = try XCTUnwrap(profile["commandMatrixMembers"]?.arrayValue).map {
      try XCTUnwrap($0.stringValue)
    }
    let resolved = try RepositoryContractResolver.resolve(
      repositoryRoot: root,
      setID: "commandMatrix",
      revision: CommandCatalog.matrixRevision,
      relativePaths: paths
    )
    let projection = try Data(
      contentsOf: root.appendingPathComponent(
        "Fixtures/developer-support/routing/command-matrix-artifact-set.v1.json"
      )
    )
    XCTAssertEqual(resolved.canonicalBytes, [UInt8](projection))

    let identity = try loadObject(
      root.appendingPathComponent(
        "Fixtures/developer-support/routing/current-contract-identity.v1.json"
      )
    )
    let commandMatrix = try XCTUnwrap(identity["commandMatrix"]?.objectValue)
    XCTAssertEqual(commandMatrix["revision"]?.stringValue, CommandCatalog.matrixRevision)
    XCTAssertEqual(
      try resolved.domainSeparatedHash(domainID: "pulsephone.command-matrix-set.v1"),
      commandMatrix["sha256"]?.stringValue
    )
  }

  func testCurrentContractVerifierClosesPolicyPublicIDs() throws {
    let process = Process()
    process.currentDirectoryURL = repositoryRoot()
    process.executableURL = repositoryRoot().appendingPathComponent(
      "Scripts/verify-contracts"
    )
    process.arguments = ["current"]
    var environment = ProcessInfo.processInfo.environment
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
    let lastLine = try XCTUnwrap(
      String(decoding: data, as: UTF8.self).split(separator: "\n").last
    )
    let result = try RepositoryCanonicalJSON.validateCanonicalDocument(
      Array(lastLine.utf8),
      maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
    ).root
    XCTAssertEqual(result["outcome"]?.stringValue, "passed")
    XCTAssertEqual(result["profile"]?.stringValue, "current")
    let counts = try XCTUnwrap(result["policyPublicIDCounts"]?.objectValue)
    XCTAssertEqual(try counts["productActions"]?.numberValue?.requireUInt64(), 52)
    XCTAssertEqual(try counts["features"]?.numberValue?.requireUInt64(), 6)
    XCTAssertEqual(try counts["preparationGroups"]?.numberValue?.requireUInt64(), 3)
    XCTAssertEqual(try counts["routes"]?.numberValue?.requireUInt64(), 3)
  }

  private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func loadObject(_ url: URL) throws -> RepositoryJSONObject {
    let data = try Data(contentsOf: url)
    return try RepositoryCanonicalJSON.validateCanonicalDocument(
      [UInt8](data),
      maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
    ).root
  }
}
