import Foundation
import PulsePhoneSharedDefinitions
import XCTest

@testable import PulsePhoneCommandCatalog
@testable import PulsePhoneCommandPlanner

struct PlannerCoreFixture: Decodable {
  struct FixtureCase: Decodable {
    let arguments: [String: String]
    let availableGroupIDs: [String]
    let caseID: String
    let commandID: String
    let connected: Bool
    let expectedCandidateIDs: [String]
    let expectedGroupIDs: [String]
    let expectedOutcome: String
    let expectedReason: String
    let geometryAvailable: Bool
    let liveAttached: Bool
    let locked: Bool
    let osMajor: UInt64
    let preparingGroupIDs: [String]
    let quiescing: Bool
    let runtimeConnectionState: String
    let trusted: Bool
  }

  let cases: [FixtureCase]
  let schemaVersion: UInt64
}

final class PlannerCoreTests: XCTestCase {
  func testDeterministicPlannerFixture() throws {
    let catalog = try loadExpandedCatalog()
    let planner = CommandPlanner(catalog: catalog)
    let fixture: PlannerCoreFixture = try loadPlannerFixture("planner-core.v1.json")
    XCTAssertEqual(fixture.schemaVersion, 1)
    for fixtureCase in fixture.cases {
      let result = try planner.plan(
        commandID: fixtureCase.commandID,
        rawArguments: fixtureCase.arguments,
        context: makeContext(fixtureCase, catalog: catalog, revision: 1)
      )
      assert(result, matches: fixtureCase)
    }
  }

  func testResumePlanningUsesRefreshedFactsCapabilitiesAndRevisions() throws {
    let catalog = try loadExpandedCatalog()
    let planner = CommandPlanner(catalog: catalog)
    let fixture: PlannerCoreFixture = try loadPlannerFixture("planner-core.v1.json")
    let preparing = try XCTUnwrap(
      fixture.cases.first { $0.caseID == "modern-touch-preparable" }
    )
    let initial = try planner.plan(
      commandID: preparing.commandID,
      rawArguments: preparing.arguments,
      context: makeContext(preparing, catalog: catalog, revision: 1)
    )
    guard case .awaitingPreparation = initial else {
      return XCTFail("expected preparation waiter")
    }
    var ready = preparing
    ready = PlannerCoreFixture.FixtureCase(
      arguments: ready.arguments,
      availableGroupIDs: ["prep.coredevice.v2"],
      caseID: ready.caseID,
      commandID: ready.commandID,
      connected: ready.connected,
      expectedCandidateIDs: ["coredevice.normalTouch"],
      expectedGroupIDs: [],
      expectedOutcome: "planned",
      expectedReason: "",
      geometryAvailable: ready.geometryAvailable,
      liveAttached: ready.liveAttached,
      locked: ready.locked,
      osMajor: ready.osMajor,
      preparingGroupIDs: [],
      quiescing: ready.quiescing,
      runtimeConnectionState: ready.runtimeConnectionState,
      trusted: ready.trusted
    )
    let resumed = try planner.resumePlanning(
      commandID: ready.commandID,
      rawArguments: ready.arguments,
      refreshedContext: makeContext(ready, catalog: catalog, revision: 2)
    )
    guard case .planned(let plan) = resumed else {
      return XCTFail("expected resumed plan")
    }
    XCTAssertEqual(plan.sourceRevisions.capability, 2)
    XCTAssertEqual(plan.candidates.map(\.routeID), ["coredevice.normalTouch"])
  }

  func testFallbackRequiresAllPrecommitConditions() {
    let first = CandidatePlan(
      backendPayload: NormalizedArgumentsV1(values: [:]),
      candidateClaims: [],
      executorOperationID: "route.first",
      fallbackDisposition: .safe,
      preparationGroupID: nil,
      requiredCapabilityIDs: [],
      routeID: "route.first"
    )
    let second = CandidatePlan(
      backendPayload: NormalizedArgumentsV1(values: [:]),
      candidateClaims: [],
      executorOperationID: "route.second",
      fallbackDisposition: .terminal,
      preparationGroupID: nil,
      requiredCapabilityIDs: [],
      routeID: "route.second"
    )
    let revisions = PlanningRevisions(
      capability: 1,
      condition: 1,
      connection: 1,
      geometry: 1,
      preparation: 1,
      quiescing: 1
    )
    let plan = ExecutionPlan(
      candidates: [first, second],
      cleanupPolicyID: "cleanup.test.v1",
      commandID: "test.command",
      commonClaims: [],
      deadlinePolicyID: "deadline.test.v1",
      kind: .oneShot,
      ownerDisconnectPolicyID: "owner.test.v1",
      queuePolicyID: "queue.test.v1",
      sourceRevisions: revisions
    )
    XCTAssertEqual(
      FallbackSelection.nextCandidate(
        in: plan,
        after: "route.first",
        commitState: .notCommitted,
        observedDisposition: .safe,
        nextClaimsImmediatelyAvailable: true
      ),
      second
    )
    XCTAssertNil(
      FallbackSelection.nextCandidate(
        in: plan,
        after: "route.first",
        commitState: .committed,
        observedDisposition: .safe,
        nextClaimsImmediatelyAvailable: true
      )
    )
    XCTAssertNil(
      FallbackSelection.nextCandidate(
        in: plan,
        after: "route.first",
        commitState: .notCommitted,
        observedDisposition: .terminal,
        nextClaimsImmediatelyAvailable: true
      )
    )
    XCTAssertNil(
      FallbackSelection.nextCandidate(
        in: plan,
        after: "route.first",
        commitState: .notCommitted,
        observedDisposition: .safe,
        nextClaimsImmediatelyAvailable: false
      )
    )
    let terminalPlan = ExecutionPlan(
      candidates: [
        CandidatePlan(
          backendPayload: first.backendPayload,
          candidateClaims: first.candidateClaims,
          executorOperationID: first.executorOperationID,
          fallbackDisposition: .terminal,
          preparationGroupID: first.preparationGroupID,
          requiredCapabilityIDs: first.requiredCapabilityIDs,
          routeID: first.routeID
        ),
        second,
      ],
      cleanupPolicyID: plan.cleanupPolicyID,
      commandID: plan.commandID,
      commonClaims: plan.commonClaims,
      deadlinePolicyID: plan.deadlinePolicyID,
      kind: plan.kind,
      ownerDisconnectPolicyID: plan.ownerDisconnectPolicyID,
      queuePolicyID: plan.queuePolicyID,
      sourceRevisions: plan.sourceRevisions
    )
    XCTAssertNil(
      FallbackSelection.nextCandidate(
        in: terminalPlan,
        after: "route.first",
        commitState: .notCommitted,
        observedDisposition: .safe,
        nextClaimsImmediatelyAvailable: true
      )
    )
  }

  func testUnknownCommandAndLocalShapeDoNotCreateRuntimePlans() throws {
    let catalog = try loadExpandedCatalog()
    let planner = CommandPlanner(catalog: catalog)
    let context = defaultContext(osMajor: 26)
    XCTAssertThrowsError(
      try planner.plan(commandID: "unknown.command", rawArguments: [:], context: context)
    )
    XCTAssertEqual(
      try planner.plan(commandID: "catalog.commands", rawArguments: [:], context: context),
      .notRuntimePlannable(.local)
    )
  }

  private func assert(
    _ result: PlanningResult,
    matches fixtureCase: PlannerCoreFixture.FixtureCase
  ) {
    switch result {
    case .planned(let plan):
      XCTAssertEqual(fixtureCase.expectedOutcome, "planned", fixtureCase.caseID)
      XCTAssertEqual(plan.candidates.map(\.routeID), fixtureCase.expectedCandidateIDs)
    case .awaitingPreparation(let waiting):
      XCTAssertEqual(fixtureCase.expectedOutcome, "awaitingPreparation", fixtureCase.caseID)
      XCTAssertEqual(waiting.completionMode, "resumePlanning")
      XCTAssertEqual(waiting.preparationGroupIDs, fixtureCase.expectedGroupIDs)
    case .unavailable(let reason):
      XCTAssertEqual(fixtureCase.expectedOutcome, "unavailable", fixtureCase.caseID)
      XCTAssertEqual(reason, fixtureCase.expectedReason, fixtureCase.caseID)
    case .unknown(let reason):
      XCTAssertEqual(fixtureCase.expectedOutcome, "unknown", fixtureCase.caseID)
      XCTAssertEqual(reason, fixtureCase.expectedReason, fixtureCase.caseID)
    case .notRuntimePlannable:
      XCTFail("unexpected non-runtime shape: \(fixtureCase.caseID)")
    }
  }
}

func loadExpandedCatalog() throws -> ExecutionProfileCatalogV1 {
  try ExecutionProfileCatalog.load(repositoryRoot: plannerRepositoryRoot())
}

func loadPlannerFixture<T: Decodable>(_ name: String) throws -> T {
  let url = plannerRepositoryRoot().appendingPathComponent("Fixtures/planner/\(name)")
  let data = try Data(contentsOf: url)
  _ = try RepositoryCanonicalJSON.validateCanonicalDocument(
    [UInt8](data),
    maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
  )
  XCTAssertNotEqual(data.last, 0x0a, name)
  return try JSONDecoder().decode(T.self, from: data)
}

func plannerRepositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}

func makeContext(
  _ fixtureCase: PlannerCoreFixture.FixtureCase,
  catalog: ExecutionProfileCatalogV1,
  revision: UInt64
) -> RuntimePlanningContext {
  let groups = Dictionary(
    uniqueKeysWithValues: catalog.preparationGroups.map { ($0.preparationGroupID, $0) }
  )
  var capabilities: [String: CapabilityAvailability] = [:]
  for groupID in fixtureCase.availableGroupIDs {
    for capabilityID in groups[groupID]?.requiredCapabilityIDs ?? [] {
      capabilities[capabilityID] = .available
    }
  }
  for groupID in fixtureCase.preparingGroupIDs {
    for capabilityID in groups[groupID]?.requiredCapabilityIDs ?? [] {
      capabilities[capabilityID] = .preparing
    }
  }
  let connection =
    RuntimeConnectionState(rawValue: fixtureCase.runtimeConnectionState)
    ?? .absent
  return RuntimePlanningContext(
    capabilities: capabilities,
    condition: DeviceConditionSnapshot(
      connected: fixtureCase.connected,
      liveAttached: fixtureCase.liveAttached,
      locked: fixtureCase.locked,
      runtimeConnectionState: connection,
      trusted: fixtureCase.trusted
    ),
    facts: DeviceFactsSnapshot(
      deviceClass: "iPhone",
      osMajor: fixtureCase.osMajor,
      transportIDs: fixtureCase.osMajor >= 17 ? ["rsd", "usb"] : ["usb"]
    ),
    geometry: fixtureCase.geometryAvailable
      ? DisplayGeometrySnapshot(
        geometryRevision: revision,
        logicalHeight: 2_532,
        logicalWidth: 1_170
      ) : nil,
    quiescing: fixtureCase.quiescing,
    revisions: PlanningRevisions(
      capability: revision,
      condition: revision,
      connection: revision,
      geometry: revision,
      preparation: revision,
      quiescing: revision
    )
  )
}

func defaultContext(osMajor: UInt64) -> RuntimePlanningContext {
  RuntimePlanningContext(
    capabilities: [:],
    condition: DeviceConditionSnapshot(
      connected: true,
      liveAttached: true,
      locked: false,
      runtimeConnectionState: .compatible,
      trusted: true
    ),
    facts: DeviceFactsSnapshot(
      deviceClass: "iPhone",
      osMajor: osMajor,
      transportIDs: osMajor >= 17 ? ["rsd", "usb"] : ["usb"]
    ),
    geometry: DisplayGeometrySnapshot(
      geometryRevision: 1,
      logicalHeight: 2_532,
      logicalWidth: 1_170
    ),
    quiescing: false,
    revisions: PlanningRevisions(
      capability: 1,
      condition: 1,
      connection: 1,
      geometry: 1,
      preparation: 1,
      quiescing: 1
    )
  )
}
