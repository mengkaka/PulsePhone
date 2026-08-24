import Foundation
import XCTest
@testable import PulsePhoneRuntimeState
import PulsePhoneCommandCatalog
import PulsePhoneCommandPlanner

final class CapabilityGateTests: XCTestCase {
    func testResumePlanningUsesRefreshedAuthoritativeContext() throws {
        let catalog = try ExecutionProfileCatalog.load(
            repositoryRoot: repositoryRoot()
        )
        let planner = CommandPlanner(catalog: catalog)
        let group = try XCTUnwrap(
            catalog.preparationGroups.first {
                $0.preparationGroupID == "prep.coredevice.v2"
            }
        )
        let initialContext = context(
            capabilities: Dictionary(
                uniqueKeysWithValues: group.requiredCapabilityIDs.map {
                    ($0, CapabilityAvailability.preparing)
                }
            ),
            revision: 1
        )
        let waiter = CapabilityGateWaiter(
            commandID: "touch.tap",
            rawArguments: ["point": "0.5,0.25"],
            sourceRevisions: initialContext.revisions
        )
        guard case .awaitingPreparation = try planner.plan(
            commandID: waiter.commandID,
            rawArguments: waiter.rawArguments,
            context: initialContext
        ) else {
            return XCTFail("expected preparation gate")
        }
        let refreshed = context(
            capabilities: Dictionary(
                uniqueKeysWithValues: group.requiredCapabilityIDs.map {
                    ($0, CapabilityAvailability.available)
                }
            ),
            revision: 2
        )
        guard case .planned(let plan) = try CapabilityGate.resumePlanning(
            waiter: waiter,
            planner: planner,
            refreshedContext: refreshed
        ) else {
            return XCTFail("expected authoritative re-plan")
        }
        XCTAssertEqual(plan.sourceRevisions.capability, 2)
        XCTAssertEqual(plan.candidates.map(\.routeID), ["coredevice.normalTouch"])
    }

    private func context(
        capabilities: [String: CapabilityAvailability],
        revision: UInt64
    ) -> RuntimePlanningContext {
        RuntimePlanningContext(
            capabilities: capabilities,
            condition: DeviceConditionSnapshot(
                connected: true,
                liveAttached: false,
                locked: false,
                runtimeConnectionState: .compatible,
                trusted: true
            ),
            facts: DeviceFactsSnapshot(
                deviceClass: "iPhone",
                osMajor: 26,
                transportIDs: ["rsd", "usb"]
            ),
            geometry: DisplayGeometrySnapshot(
                geometryRevision: revision,
                logicalHeight: 2_532,
                logicalWidth: 1_170
            ),
            quiescing: false,
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

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
