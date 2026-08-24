import XCTest

@testable import PulsePhoneRuntimeState

final class DemandSpecTests: XCTestCase {
    func testRuntimeDerivesOriginPersistenceAndPreparationGroup() throws {
        let catalog = try loadCoordinatorCatalog()
        let owner = try coordinatorUUID(1)
        let explicit = try DemandSpec.explicitPrepare(
            observerID: coordinatorUUID(2),
            ownerClientInstanceID: owner,
            osMajor: 16,
            executionCatalog: catalog
        )
        XCTAssertEqual(explicit.descriptor.origin, .explicitPrepare)
        XCTAssertEqual(explicit.descriptor.persistence, .epochBound)
        XCTAssertEqual(
            explicit.descriptor.preparationGroupID,
            "prep.legacy.developer.v2"
        )

        let finite = try DemandSpec.finiteCommand(
            waiterID: coordinatorUUID(3),
            ownerClientInstanceID: owner,
            candidatePreparationGroupID: "prep.coredevice.v2",
            capabilityWaiter: coordinatorWaiter(),
            executionCatalog: catalog
        )
        XCTAssertEqual(finite.descriptor.origin, .finiteCommand)
        XCTAssertEqual(finite.descriptor.persistence, .epochBound)
        XCTAssertEqual(finite.kind, .commandWaiter)

        let live = try DemandSpec.livePrewarm(
            demandID: coordinatorUUID(4),
            ownerClientInstanceID: owner,
            osMajor: 26,
            executionCatalog: catalog
        )
        XCTAssertEqual(live.descriptor.origin, .livePrewarm)
        XCTAssertEqual(live.descriptor.persistence, .persistentAcrossReconnect)
        XCTAssertEqual(live.descriptor.preparationGroupID, "prep.coredevice.v2")
    }

    func testFiniteDemandRejectsUnknownCandidateGroup() throws {
        let catalog = try loadCoordinatorCatalog()
        XCTAssertThrowsError(
            try DemandSpec.finiteCommand(
                waiterID: coordinatorUUID(5),
                ownerClientInstanceID: coordinatorUUID(6),
                candidatePreparationGroupID: "prep.caller.selected",
                capabilityWaiter: coordinatorWaiter(),
                executionCatalog: catalog
            )
        )
    }
}
