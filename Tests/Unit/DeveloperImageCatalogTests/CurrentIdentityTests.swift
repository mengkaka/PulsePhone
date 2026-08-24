import Foundation
import XCTest
import PulsePhoneCommandCatalog
import PulsePhoneCommandPlanner
@testable import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneSharedDefinitions

final class CurrentIdentityTests: XCTestCase {
  func testOSRouteBoundariesRejectUnsupportedAndNeverGuess() throws {
    let catalog = try ExecutionProfileCatalog.load(repositoryRoot: repositoryRoot())
    let routeFixture = try loadObject(
      "Fixtures/developer-support/routing/os-routes.v1.json"
    )
    XCTAssertEqual(routeFixture["profiles"]?.arrayValue?.count, 2)
    XCTAssertEqual(
      try routeFixture["unsupportedMajors"]?.arrayValue?.map {
        try XCTUnwrap($0.numberValue).requireUInt64()
      },
      [0, 13]
    )
    let legacy14 = try DeveloperSupportOSRouting.resolve(
      osMajor: 14,
      executionCatalog: catalog
    )
    let legacy16 = try DeveloperSupportOSRouting.resolve(
      osMajor: 16,
      executionCatalog: catalog
    )
    let modern17 = try DeveloperSupportOSRouting.resolve(
      osMajor: 17,
      executionCatalog: catalog
    )
    let modern26 = try DeveloperSupportOSRouting.resolve(
      osMajor: 26,
      executionCatalog: catalog
    )

    XCTAssertEqual(legacy14.profileID, .legacyClassic)
    XCTAssertEqual(legacy14.route, .classic)
    XCTAssertEqual(legacy14.preparationGroupID, "prep.legacy.developer.v2")
    XCTAssertEqual(legacy16, legacy14)
    XCTAssertEqual(modern17.profileID, .modernRSD)
    XCTAssertEqual(modern17.route, .personalized)
    XCTAssertEqual(modern17.preparationGroupID, "prep.coredevice.v2")
    XCTAssertEqual(modern26, modern17)
    XCTAssertThrowsError(
      try DeveloperSupportOSRouting.resolve(osMajor: 13, executionCatalog: catalog)
    ) { error in
      XCTAssertEqual(
        error as? DeveloperSupportOSRoutingError,
        .unsupportedOSMajor(13)
      )
    }

    let catalogData = try Data(
      contentsOf: repositoryRoot().appendingPathComponent(
        "Fixtures/catalog/developer-image/catalog.v1.json"
      )
    )
    let imageCatalog = try DeveloperImageCatalog.decodeCanonical([UInt8](catalogData))
    XCTAssertNotNil(
      DeveloperImageCompatibility.exactEntry(
        in: imageCatalog,
        osMajor: 16,
        buildID: "20H350"
      )
    )
    XCTAssertNil(
      DeveloperImageCompatibility.exactEntry(
        in: imageCatalog,
        osMajor: 16,
        buildID: "20H349"
      )
    )
  }

  func testDemandAuthorityRejectsCallerSelectedGroupAndPersistence() throws {
    let catalog = try ExecutionProfileCatalog.load(repositoryRoot: repositoryRoot())
    let policyFixture = try loadObject(
      "Fixtures/developer-support/routing/demand-persistence.v1.json"
    )
    XCTAssertEqual(policyFixture["derived"]?.arrayValue?.count, 3)
    XCTAssertEqual(
      policyFixture["forbiddenCallerFields"]?.arrayValue?.compactMap(\.stringValue),
      ["persistence", "preparationGroupID"]
    )
    let explicit = try PreparationDemandAuthority.derive(
      origin: .explicitPrepare,
      osMajor: 16,
      executionCatalog: catalog
    )
    let finite = try PreparationDemandAuthority.derive(
      origin: .finiteCommand,
      osMajor: 16,
      executionCatalog: catalog,
      candidatePreparationGroupID: "prep.direct.lockdown.v1"
    )
    let live = try PreparationDemandAuthority.derive(
      origin: .livePrewarm,
      osMajor: 26,
      executionCatalog: catalog
    )

    XCTAssertEqual(explicit.persistence, .epochBound)
    XCTAssertEqual(explicit.preparationGroupID, "prep.legacy.developer.v2")
    XCTAssertEqual(finite.persistence, .epochBound)
    XCTAssertEqual(finite.preparationGroupID, "prep.direct.lockdown.v1")
    XCTAssertEqual(live.persistence, .persistentAcrossReconnect)
    XCTAssertEqual(live.preparationGroupID, "prep.coredevice.v2")

    XCTAssertThrowsError(
      try PreparationDemandAuthority.derive(
        origin: .explicitPrepare,
        osMajor: 16,
        executionCatalog: catalog,
        callerSelectedPreparationGroupID: "prep.coredevice.v2"
      )
    ) { error in
      XCTAssertEqual(
        error as? PreparationDemandAuthorityError,
        .callerSelectedPreparationGroup
      )
    }
    XCTAssertThrowsError(
      try PreparationDemandAuthority.derive(
        origin: .finiteCommand,
        osMajor: 16,
        executionCatalog: catalog,
        candidatePreparationGroupID: "prep.legacy.developer.v2",
        callerSelectedPersistence: .persistentAcrossReconnect
      )
    ) { error in
      XCTAssertEqual(
        error as? PreparationDemandAuthorityError,
        .callerSelectedPersistence
      )
    }
    XCTAssertThrowsError(
      try PreparationDemandAuthority.derive(
        origin: .finiteCommand,
        osMajor: 16,
        executionCatalog: catalog
      )
    ) { error in
      XCTAssertEqual(
        error as? PreparationDemandAuthorityError,
        .missingCandidatePreparationGroup
      )
    }
  }

  func testCurrentImplementationIdentityMatchesExecutionAndCatalog() throws {
    let root = repositoryRoot()
    let expected = try loadObject(
      "Fixtures/developer-support/routing/current-contract-identity.v1.json"
    )
    let expectedCatalog = try XCTUnwrap(expected["developerImageCatalog"]?.objectValue)
    let catalog = try DeveloperImageCatalog.load(repositoryRoot: root)
    let catalogIdentity = try DeveloperImageCatalog.identity(catalog: catalog)
    XCTAssertEqual(catalogIdentity.hash, expectedCatalog["hash"]?.stringValue)
    XCTAssertEqual(catalogIdentity.revision, expectedCatalog["revision"]?.stringValue)

    let execution = try ExecutionCatalogIdentity.load(
      repositoryRoot: root,
      plannerContract: PlannerContractVersion.identity()
    )
    XCTAssertEqual(
      execution.executionCatalogHash,
      expected["executionCatalogHash"]?.stringValue
    )
    XCTAssertEqual(
      execution.plannerContractVersion,
      expected["plannerContractVersion"]?.stringValue
    )
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
