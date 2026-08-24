import Foundation
import XCTest
@testable import PulsePhoneCommandCatalog
import PulsePhoneSharedDefinitions

final class CommandMatrixCoverageTests: XCTestCase {
  func testScreenshotErrorProjectionCoversArtifactAndPreparationFailures() throws {
    let catalog = try ExecutionProfileCatalog.load(
      repositoryRoot: CommandMatrixCoverageSupport.repositoryRoot()
    )
    let required = Set([
      "artifactTooLarge",
      "artifactValidationFailed",
      "capabilityPreparing",
      "capabilityUnavailable",
      "developerImageCatalogMismatch",
      "developerImageIntegrityFailed",
      "developerImageMountFailed",
      "developerModeRequired",
      "developerServicesUnavailable",
      "developerSupportUnavailable",
      "deviceLocked",
      "deviceNotTrusted",
      "executionTimeout",
      "personalizationServiceUnavailable",
      "preparationFailed",
      "preparationTimeout",
      "unsupportedPreparationGroup",
      "unsupportedScreenshotFormat",
    ])
    for commandID in ["screenshot.cli", "screenshot.gui"] {
      let row = try XCTUnwrap(
        catalog.expandedProductActions.first {
          $0.command.commandID == commandID
        }
      )
      XCTAssertTrue(
        required.isSubset(of: Set(row.policyBindings.allowedErrorCodes)),
        commandID
      )
    }
    let supporting = try XCTUnwrap(
      catalog.expandedSupportingActions.first {
        $0.action.supportingActionID == "device.screenshot"
      }
    )
    XCTAssertTrue(
      required.isSubset(of: Set(supporting.policyBindings.allowedErrorCodes))
    )
  }

  func testExactCountsProfilesScopesAndNoDefaults() throws {
    let expected = try CommandMatrixCoverageSupport.loadCoverage()
    let root = CommandMatrixCoverageSupport.repositoryRoot()
    let catalog = try ExecutionProfileCatalog.load(repositoryRoot: root)
    XCTAssertEqual(expected.schemaVersion, 1)
    XCTAssertEqual(catalog.commandCatalog.matrixRevision, CommandCatalog.matrixRevision)
    XCTAssertEqual(catalog.expandedProductActions.count, expected.counts.productActions)
    XCTAssertEqual(catalog.expandedSupportingActions.count, expected.counts.supportingActions)
    XCTAssertEqual(catalog.commandCatalog.features.count, expected.counts.features)

    let productProfiles = catalog.expandedProductActions.map { row in
      CommandMatrixCoverageFixture.ProductProfile(
        commandID: row.command.commandID,
        executionProfileID: row.command.executionProfileID,
        loggingProfileID: row.command.loggingProfileID
      )
    }
    XCTAssertEqual(productProfiles, expected.productProfiles)
    XCTAssertEqual(Set(productProfiles.map(\.commandID)).count, expected.counts.productActions)
    XCTAssertEqual(catalog.expandedProductActions.map(\.command.policyBindings).count, 52)
    XCTAssertTrue(catalog.commandCatalog.productActions.allSatisfy { $0.policyBindings != nil })
    XCTAssertTrue(catalog.commandCatalog.supportingActions.allSatisfy { $0.policyBindings != nil })
    for row in catalog.expandedProductActions {
      XCTAssertEqual(row.executionProfile.executionProfileID, row.command.executionProfileID)
      XCTAssertEqual(row.executionProfile.executionShape, row.command.category)
      XCTAssertEqual(row.loggingProfile.loggingProfileID, row.command.loggingProfileID)
      XCTAssertEqual(
        row.compatibilityRule.ruleID,
        row.policyBindings.compatibilityRuleID
      )
      XCTAssertEqual(
        row.resourceClaimTemplate.resourceClaimTemplateID,
        row.policyBindings.resourceClaimTemplateID
      )
    }

    let productScopes = catalog.commandCatalog.productActions
      .filter { $0.releaseScope == .productGate }
      .map(\.commandID)
    XCTAssertEqual(productScopes, expected.productScopeCommandIDs)
    let featureScopes = catalog.commandCatalog.features.map {
      CommandMatrixCoverageFixture.ScopeRow(
        id: $0.featureID,
        scope: $0.releaseScope.rawValue
      )
    }
    XCTAssertEqual(featureScopes, expected.featureScopes)
    let supportingScopes = catalog.commandCatalog.supportingActions.map {
      CommandMatrixCoverageFixture.ScopeRow(
        id: $0.supportingActionID,
        scope: $0.releaseInheritance.rawValue
      )
    }
    XCTAssertEqual(supportingScopes, expected.supportingScopes)

    let registryData = try Data(
      contentsOf: root.appendingPathComponent(CommandCatalog.registryRelativePath)
    )
    let registry = try RepositoryCanonicalJSON.validateCanonicalDocument(
      [UInt8](registryData),
      maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
    ).root
    guard let products = registry["productActions"]?.arrayValue else {
      return XCTFail("missing productActions")
    }
    for value in products {
      let row = try XCTUnwrap(value.objectValue)
      XCTAssertNotNil(row["executionProfileID"])
      XCTAssertNotNil(row["loggingProfileID"])
      XCTAssertNotNil(row["policyBindings"])
    }
    XCTAssertFalse(String(decoding: registryData, as: UTF8.self).contains("\"defaultProfile"))

    let requirementExpected = try CommandMatrixCoverageSupport.loadCanonicalObject(
      "Fixtures/requirements/T-009/command-catalog-count-profile-coverage-l0/expected.v1.json"
    )
    XCTAssertEqual(requirementExpected["outcome"]?.stringValue, "passed")
    XCTAssertEqual(
      try requirementExpected["productActions"]?.numberValue?.requireUInt64(),
      UInt64(expected.counts.productActions)
    )
    XCTAssertEqual(
      try requirementExpected["supportingActions"]?.numberValue?.requireUInt64(),
      UInt64(expected.counts.supportingActions)
    )
  }
}
