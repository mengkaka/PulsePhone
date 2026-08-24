import XCTest

@testable import PulsePhoneCommandCatalog
@testable import PulsePhoneCommandPlanner

final class ClaimResolverTests: XCTestCase {
  func testBundlePlaceholderAndCandidateClaimsMaterializeDeterministically() throws {
    let catalog = try loadExpandedCatalog()
    let uninstall = try XCTUnwrap(
      catalog.expandedProductActions.first { $0.command.commandID == "app.uninstall" }
    )
    let arguments = try ArgumentNormalizer.normalize(
      schemaID: "bundleID.v1",
      raw: ["bundleID": "com.example.Pulse"]
    )
    let claims = try ClaimResolver.materialize(
      template: uninstall.resourceClaimTemplate,
      arguments: arguments
    )
    XCTAssertTrue(
      claims.contains {
        $0.resourceID == "device.app-lifecycle.com.example.Pulse"
      })
    XCTAssertEqual(claims, claims.sorted(by: claimLessThan))

    let coreClaims = try ClaimResolver.candidateClaims(
      routeID: "coredevice.normalTouch",
      kind: .oneShot,
      preparationGroupID: "prep.coredevice.v2"
    )
    XCTAssertEqual(
      Set(coreClaims.map(\.resourceID)),
      [
        "device.developer-environment", "executor.coredevice.input-channel",
        "executor.coredevice.oneshot-capacity-slot",
      ])
    let directClaims = try ClaimResolver.candidateClaims(
      routeID: "direct.installationProxy.install",
      kind: .oneShot,
      preparationGroupID: "prep.direct.lockdown.v1"
    )
    XCTAssertEqual(
      Set(directClaims.map(\.resourceID)),
      [
        "executor.direct.oneshot-capacity-slot", "executor.direct.process-slot",
      ])
    let appList = try XCTUnwrap(
      catalog.expandedProductActions.first { $0.command.commandID == "app.list" }
    )
    let appListClaims = try ClaimResolver.materialize(
      template: appList.resourceClaimTemplate,
      arguments: NormalizedArgumentsV1(values: [:])
    )
    XCTAssertEqual(
      Set(appListClaims.map(\.resourceID)),
      ["device.app-state", "service.installation"]
    )
    XCTAssertFalse(appListClaims.contains { $0.resourceID == "device.app-management" })
    let rows = Dictionary(
      uniqueKeysWithValues: catalog.expandedProductActions.map {
        ($0.command.commandID, $0)
      }
    )
    for commandID in ["app.install", "app.launch", "app.uninstall"] {
      let template = try XCTUnwrap(rows[commandID]?.resourceClaimTemplate)
      XCTAssertTrue(
        template.claims.contains {
          $0.accessMode == .exclusive
            && $0.resourceIDTemplate == "device.app-management"
        },
        commandID
      )
    }
  }

  func testMissingPlaceholderAndConflictingClaimsFailClosed() throws {
    let placeholder = ResourceClaimTemplateDescriptor(
      claims: [
        ResourceClaimDescriptor(
          accessMode: .exclusive,
          phase: .running,
          resourceIDTemplate: "device.app-lifecycle.{bundleID}"
        )
      ],
      resourceClaimTemplateID: "claims.test.placeholder.v1"
    )
    XCTAssertThrowsError(
      try ClaimResolver.materialize(
        template: placeholder,
        arguments: NormalizedArgumentsV1(values: [:])
      )
    )

    let conflicting = ResourceClaimTemplateDescriptor(
      claims: [
        ResourceClaimDescriptor(
          accessMode: .exclusive,
          phase: .running,
          resourceIDTemplate: "device.app-state"
        ),
        ResourceClaimDescriptor(
          accessMode: .shared,
          phase: .running,
          resourceIDTemplate: "device.app-state"
        ),
      ],
      resourceClaimTemplateID: "claims.test.conflict.v1"
    )
    XCTAssertThrowsError(
      try ClaimResolver.materialize(
        template: conflicting,
        arguments: NormalizedArgumentsV1(values: [:])
      )
    )
  }

  func testKeyboardMacroUsesExclusiveProductClaimsAndCoreInputChannel() throws {
    let catalog = try loadExpandedCatalog()
    let key = try XCTUnwrap(
      catalog.expandedProductActions.first { $0.command.commandID == "text.key" }
    )
    let productClaims = try ClaimResolver.materialize(
      template: key.resourceClaimTemplate,
      arguments: NormalizedArgumentsV1(values: [:])
    )
    XCTAssertEqual(
      productClaims.map { "\($0.accessMode.rawValue)|\($0.resourceID)" },
      ["exclusive|device.app-state", "exclusive|device.input.keyboard"]
    )

    let candidateClaims = try ClaimResolver.candidateClaims(
      routeID: "coredevice.keyboardMacro",
      kind: .oneShot,
      preparationGroupID: "prep.coredevice.v2"
    )
    XCTAssertEqual(
      Set(candidateClaims.map(\.resourceID)),
      [
        "device.developer-environment", "executor.coredevice.input-channel",
        "executor.coredevice.oneshot-capacity-slot",
      ]
    )
  }

  private func claimLessThan(
    _ lhs: MaterializedResourceClaim,
    _ rhs: MaterializedResourceClaim
  ) -> Bool {
    let left = "\(lhs.phase.rawValue)|\(lhs.accessMode.rawValue)|\(lhs.resourceID)"
    let right = "\(rhs.phase.rawValue)|\(rhs.accessMode.rawValue)|\(rhs.resourceID)"
    return left.utf8.lexicographicallyPrecedes(right.utf8)
  }
}
