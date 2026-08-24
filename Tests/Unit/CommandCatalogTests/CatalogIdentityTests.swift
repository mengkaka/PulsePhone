import Foundation
import XCTest
@testable import PulsePhoneCommandCatalog
import PulsePhoneCommandPlanner
import PulsePhoneSharedDefinitions

final class CatalogIdentityTests: XCTestCase {
  private static let projectionFixtureRelativePath =
    "Fixtures/catalog/identity/execution-catalog-projection.v1.json"
  private static let identityFixtureRelativePath =
    "Fixtures/catalog/identity/execution-catalog-identity.v1.json"

  func testCanonicalProjectionAndHashMatchGoldenFixtures() throws {
    let identity = try loadIdentity(repositoryRoot())
    let projectionBytes = try Data(
      contentsOf: repositoryRoot().appendingPathComponent(
        Self.projectionFixtureRelativePath
      )
    )
    XCTAssertEqual([UInt8](projectionBytes), identity.canonicalProjectionBytes)
    let projection = try RepositoryCanonicalJSON.validateCanonicalDocument(
      [UInt8](projectionBytes),
      maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
    )
    XCTAssertEqual(projection.sha256Hex, identity.projectionSHA256)

    let fixture = try loadCanonicalObject(Self.identityFixtureRelativePath)
    XCTAssertEqual(fixture["schemaVersion"]?.numberValue, .uint64(1))
    XCTAssertEqual(
      fixture["domainID"]?.stringValue,
      ExecutionCatalogIdentity.domainID
    )
    XCTAssertEqual(
      fixture["plannerContractVersion"]?.stringValue,
      PlannerContractVersion.current
    )
    XCTAssertEqual(
      fixture["projectionSHA256"]?.stringValue,
      identity.projectionSHA256
    )
    XCTAssertEqual(
      fixture["executionCatalogHash"]?.stringValue,
      identity.executionCatalogHash
    )
    XCTAssertTrue(
      StableBytes.isLowercaseHex(identity.executionCatalogHash, byteCount: 32)
    )

    let requirementExpected = try loadCanonicalObject(
      "Fixtures/requirements/T-009/catalog-planner-registry-hash-consistency-l0/expected.v1.json"
    )
    XCTAssertEqual(requirementExpected["outcome"]?.stringValue, "passed")
    XCTAssertEqual(
      requirementExpected["plannerContractVersion"]?.stringValue,
      identity.plannerContractVersion
    )
    XCTAssertEqual(
      requirementExpected["projectionSHA256"]?.stringValue,
      identity.projectionSHA256
    )
    XCTAssertEqual(
      requirementExpected["executionCatalogHash"]?.stringValue,
      identity.executionCatalogHash
    )
  }

  func testPresentationAndReleaseMetadataDoNotChangeHash() throws {
    let baseline = try loadIdentity(repositoryRoot())
    let root = try copiedContractRoot()
    try replace(
      in: root,
      relativePath: CommandCatalog.registryRelativePath,
      target: "\"cliVariant\":\"install\"",
      replacement: "\"cliVariant\":\"install-presentation\""
    )
    try replace(
      in: root,
      relativePath: CommandCatalog.registryRelativePath,
      target: "\"guiSurface\":{\"kind\":\"toolbar\",\"order\":120}",
      replacement: "\"guiSurface\":{\"kind\":\"toolbar\",\"order\":121}"
    )
    try replace(
      in: root,
      relativePath: CommandCatalog.registryRelativePath,
      target: "\"releaseScope\":\"capability\"",
      replacement: "\"releaseScope\":\"productGate\""
    )

    let changed = try loadIdentity(root)
    XCTAssertEqual(changed.canonicalProjectionBytes, baseline.canonicalProjectionBytes)
    XCTAssertEqual(changed.executionCatalogHash, baseline.executionCatalogHash)
  }

  func testSemanticPolicyCandidateSchemaAndPlannerChangesChangeHash() throws {
    let baseline = try loadIdentity(repositoryRoot())

    let policyRoot = try copiedContractRoot()
    try replace(
      in: policyRoot,
      relativePath: CommandCatalog.registryRelativePath,
      target: "deadline.app-launch.60s.v1",
      replacement: "deadline.app-launch.61s.v1"
    )
    XCTAssertNotEqual(
      try loadIdentity(policyRoot).executionCatalogHash,
      baseline.executionCatalogHash
    )

    let candidateRoot = try copiedContractRoot()
    try replace(
      in: candidateRoot,
      relativePath: CommandCatalog.registryRelativePath,
      target: "[\"coredevice.appLaunch\",\"legacy.dvtLaunch\"]",
      replacement: "[\"legacy.dvtLaunch\",\"coredevice.appLaunch\"]"
    )
    try replace(
      in: candidateRoot,
      relativePath: CommandCatalog.registryRelativePath,
      target: "[\"prep.coredevice.v2\",\"prep.legacy.developer.v2\"]",
      replacement: "[\"prep.legacy.developer.v2\",\"prep.coredevice.v2\"]"
    )
    XCTAssertNotEqual(
      try loadIdentity(candidateRoot).executionCatalogHash,
      baseline.executionCatalogHash
    )

    let schemaRoot = try copiedContractRoot()
    try replace(
      in: schemaRoot,
      relativePath: "Schemas/result-schemas/app-operation.v1.schema.json",
      target: "\"maxLength\":255",
      replacement: "\"maxLength\":254"
    )
    XCTAssertNotEqual(
      try loadIdentity(schemaRoot).executionCatalogHash,
      baseline.executionCatalogHash
    )

    let plannerChanged = try ExecutionCatalogIdentity.load(
      repositoryRoot: repositoryRoot(),
      plannerContract: PlannerContractVersion.identity(
        version: "planner-contract.v3-test"
      )
    )
    XCTAssertNotEqual(plannerChanged.executionCatalogHash, baseline.executionCatalogHash)
  }

  func testDeclarationOrderOfUnorderedSetsDoesNotChangeHash() throws {
    let root = repositoryRoot()
    let catalog = try ExecutionProfileCatalog.load(repositoryRoot: root)
    let baseline = try ExecutionCatalogIdentity.make(
      catalog: catalog,
      repositoryRoot: root,
      plannerContract: PlannerContractVersion.identity()
    )
    let reordered = ExecutionProfileCatalogV1(
      commandCatalog: catalog.commandCatalog,
      compatibilityRules: Array(catalog.compatibilityRules.reversed()),
      executionProfiles: Array(catalog.executionProfiles.reversed()),
      expandedProductActions: Array(catalog.expandedProductActions.reversed()),
      expandedSupportingActions: Array(catalog.expandedSupportingActions.reversed()),
      loggingProfiles: Array(catalog.loggingProfiles.reversed()),
      preparationGroups: Array(catalog.preparationGroups.reversed()),
      resourceClaimTemplates: Array(catalog.resourceClaimTemplates.reversed())
    )
    let changed = try ExecutionCatalogIdentity.make(
      catalog: reordered,
      repositoryRoot: root,
      plannerContract: PlannerContractVersion.identity()
    )
    XCTAssertEqual(changed.canonicalProjectionBytes, baseline.canonicalProjectionBytes)
    XCTAssertEqual(changed.executionCatalogHash, baseline.executionCatalogHash)
  }

  func testRuntimeWireAndStandardErrorSemanticsChangeHash() throws {
    let baseline = try loadIdentity(repositoryRoot())

    let wireRoot = try copiedContractRoot()
    try replace(
      in: wireRoot,
      relativePath: ExecutionCatalogIdentity.runtimeWireSchemaRelativePath,
      target:
        "\"x-pulsephone-deliveryClassSource\":\"streamSessionPlan\",\"x-pulsephone-maxEncodedBytes\":8192",
      replacement:
        "\"x-pulsephone-deliveryClassSource\":\"streamSessionPlan\",\"x-pulsephone-maxEncodedBytes\":8193"
    )
    XCTAssertNotEqual(
      try loadIdentity(wireRoot).executionCatalogHash,
      baseline.executionCatalogHash
    )

    let errorRoot = try copiedContractRoot()
    try replace(
      in: errorRoot,
      relativePath: ExecutionProfileCatalog.standardErrorRegistryRelativePath,
      target: "\"retryable\":true,\"visibility\":\"public\"",
      replacement: "\"retryable\":false,\"visibility\":\"public\""
    )
    XCTAssertNotEqual(
      try loadIdentity(errorRoot).executionCatalogHash,
      baseline.executionCatalogHash
    )
  }

  func testMissingAndUnsafeIdentityContractsFailClosed() throws {
    let missingRoot = try copiedContractRoot()
    try FileManager.default.removeItem(
      at: missingRoot.appendingPathComponent(
        ExecutionCatalogIdentity.runtimeWireSchemaRelativePath
      )
    )
    XCTAssertThrowsError(try loadIdentity(missingRoot))

    let unsafeRoot = try copiedContractRoot()
    let source = unsafeRoot.appendingPathComponent(
      "Schemas/details-schemas/limit.v1.schema.json"
    )
    try FileManager.default.linkItem(
      at: source,
      to: unsafeRoot.appendingPathComponent(
        "Schemas/details-schemas/limit-hardlink.v1.schema.json"
      )
    )
    XCTAssertThrowsError(try loadIdentity(unsafeRoot))
  }

  private func loadIdentity(_ root: URL) throws -> ExecutionCatalogIdentity {
    try ExecutionCatalogIdentity.load(
      repositoryRoot: root,
      plannerContract: PlannerContractVersion.identity()
    )
  }

  private func loadCanonicalObject(_ relativePath: String) throws -> RepositoryJSONObject {
    let data = try Data(
      contentsOf: repositoryRoot().appendingPathComponent(relativePath)
    )
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

  private func copiedContractRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for directory in ["Registries", "Schemas"] {
      try FileManager.default.copyItem(
        at: repositoryRoot().appendingPathComponent(directory),
        to: root.appendingPathComponent(directory)
      )
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  private func replace(
    in root: URL,
    relativePath: String,
    target: String,
    replacement: String
  ) throws {
    let url = root.appendingPathComponent(relativePath)
    let original = try String(contentsOf: url, encoding: .utf8)
    let range = try XCTUnwrap(original.range(of: target), relativePath)
    let changed = original.replacingCharacters(in: range, with: replacement)
    XCTAssertNotEqual(changed, original, relativePath)
    try Data(changed.utf8).write(to: url)
  }
}
