import Foundation
import XCTest

@testable import PulsePhoneAvailability
@testable import PulsePhoneCommandCatalog
@testable import PulsePhoneCommandPlanner

private struct AvailabilityFixture: Decodable {
  struct FixtureCase: Decodable {
    let availableGroupIDs: [String]
    let caseID: String
    let expected: [String: String]
    let factsPresent: Bool
    let geometryAvailable: Bool
    let osMajor: UInt64
    let preparingGroupIDs: [String]
    let quiescing: Bool
  }

  let cases: [FixtureCase]
  let schemaVersion: UInt64
}

final class AvailabilityTests: XCTestCase {
  func testCatalogCompatibleAndEffectiveLayers() throws {
    let catalog = try loadExpandedCatalog()
    let planner = CommandPlanner(catalog: catalog)
    let catalogList = CatalogCommandList(catalog: catalog)
    XCTAssertEqual(catalogList.commandIDs.count, 52)
    XCTAssertEqual(
      catalogList.commandIDs,
      catalogList.commandIDs.sorted(by: CommandCatalog.asciiLessThan)
    )

    let fixture: AvailabilityFixture = try loadPlannerFixture("availability.v1.json")
    XCTAssertEqual(fixture.schemaVersion, 1)
    for fixtureCase in fixture.cases {
      let context = makeAvailabilityContext(fixtureCase, catalog: catalog, revision: 1)
      let compatible = CompatibleCommandList(catalog: catalog, facts: context.facts)
      XCTAssertEqual(compatible.entries.count, 52)
      if fixtureCase.caseID == "no-device-facts" {
        let dispositions = Dictionary(
          uniqueKeysWithValues: compatible.entries.map { ($0.commandID, $0.disposition) }
        )
        XCTAssertEqual(dispositions["catalog.commands"], .compatible)
        XCTAssertEqual(
          dispositions["touch.tap"],
          .unknown(reason: "deviceFactsUnavailable")
        )
        XCTAssertEqual(
          dispositions["gui.keyboardCapture.toggle"],
          .unknown(reason: "deviceFactsUnavailable")
        )
        XCTAssertEqual(
          dispositions["gui.softwareKeyboard.toggle"],
          .unknown(reason: "deviceFactsUnavailable")
        )
      }
      let effective = try EffectiveCommandAvailability(
        catalog: catalog,
        planner: planner,
        context: context
      )
      let states = Dictionary(
        uniqueKeysWithValues: effective.entries.map { ($0.commandID, describe($0.state)) }
      )
      for (commandID, expected) in fixtureCase.expected {
        XCTAssertEqual(states[commandID], expected, "\(fixtureCase.caseID): \(commandID)")
      }
      if fixtureCase.caseID == "legacy-ready" {
        XCTAssertEqual(
          states["gui.keyboardCapture.toggle"],
          "unavailable:unsupportedOSVersion"
        )
        XCTAssertEqual(
          states["gui.keyboard.interaction"],
          "unavailable:unsupportedOSVersion"
        )
        XCTAssertEqual(
          states["gui.softwareKeyboard.toggle"],
          "unavailable:unsupportedOSVersion"
        )
      }
    }
  }

  func testAvailabilityOnlyChangesWithDeclaredRevisionsAndSnapshots() throws {
    let catalog = try loadExpandedCatalog()
    let planner = CommandPlanner(catalog: catalog)
    let fixture: AvailabilityFixture = try loadPlannerFixture("availability.v1.json")
    let ready = try XCTUnwrap(fixture.cases.first { $0.caseID == "modern-ready" })
    let first = try EffectiveCommandAvailability(
      catalog: catalog,
      planner: planner,
      context: makeAvailabilityContext(ready, catalog: catalog, revision: 1)
    )
    let second = try EffectiveCommandAvailability(
      catalog: catalog,
      planner: planner,
      context: makeAvailabilityContext(ready, catalog: catalog, revision: 2)
    )
    XCTAssertEqual(first.entries, second.entries)
    XCTAssertNotEqual(first.revisions, second.revisions)
  }

  private func describe(_ state: PlanningAvailability) -> String {
    switch state {
    case .available:
      return "available"
    case .preparable(let groupIDs):
      return "preparable:\(groupIDs.joined(separator: ","))"
    case .unavailable(let reason):
      return "unavailable:\(reason)"
    case .unknown(let reason):
      return "unknown:\(reason)"
    }
  }

  private func makeAvailabilityContext(
    _ fixtureCase: AvailabilityFixture.FixtureCase,
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
    return RuntimePlanningContext(
      capabilities: capabilities,
      condition: DeviceConditionSnapshot(
        connected: fixtureCase.factsPresent,
        liveAttached: true,
        locked: false,
        runtimeConnectionState: .compatible,
        trusted: true
      ),
      facts: fixtureCase.factsPresent
        ? DeviceFactsSnapshot(
          deviceClass: "iPhone",
          osMajor: fixtureCase.osMajor,
          transportIDs: fixtureCase.osMajor >= 17 ? ["rsd", "usb"] : ["usb"]
        ) : nil,
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
}
