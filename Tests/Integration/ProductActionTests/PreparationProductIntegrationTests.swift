import Foundation
import PulsePhoneClientCore
import PulsePhoneCommandPlanner
import PulsePhoneGUI
import XCTest

final class PreparationProductIntegrationTests: XCTestCase {
    func testImplicitFiniteCommandReplansWithoutManualPrepare() throws {
        let input = try load(FixtureInput.self, "input.v1.json")
        let expected = try load(FixtureExpected.self, "expected.v1.json")
        var integration = ImplicitPreparationIntegration(
            commandID: input.finiteCommandID,
            shape: .finiteOneShot,
            availability: .preparable(groupIDs: [input.preparationGroupID]),
            revisions: revisions(input.initialRevision)
        )
        XCTAssertFalse(integration.manualPrepareRequired)
        XCTAssertEqual(
            try integration.begin(),
            .awaitingPreparation(
                completionMode: expected.completionMode,
                persistence: expected.finitePersistence,
                preparationGroupIDs: [input.preparationGroupID]
            )
        )
        XCTAssertEqual(
            try integration.preparationReadyAndReplanned(
                preparationGroupID: input.preparationGroupID,
                refreshedAvailability: .available,
                refreshedRevisions: revisions(input.readyRevision)
            ),
            .submitResumed
        )
    }

    func testStreamFailsFastAndDisjointAvailableCommandContinues() throws {
        let input = try load(FixtureInput.self, "input.v1.json")
        let expected = try load(FixtureExpected.self, "expected.v1.json")
        var stream = ImplicitPreparationIntegration(
            commandID: input.streamCommandID,
            shape: .stream,
            availability: .preparable(groupIDs: [input.preparationGroupID]),
            revisions: revisions(input.initialRevision)
        )
        XCTAssertEqual(
            try stream.begin(),
            .failFast(reason: expected.streamReason)
        )

        var disjoint = ImplicitPreparationIntegration(
            commandID: input.disjointCommandID,
            shape: .finiteOneShot,
            availability: .available,
            revisions: revisions(input.initialRevision)
        )
        XCTAssertEqual(
            try disjoint.begin(otherPreparingGroupIDs: [
                input.preparationGroupID,
            ]),
            .submitImmediately
        )
    }

    func testLivePrewarmPersistsAcrossReconnectAndDrivesOnlyMatchingGroup() throws {
        let input = try load(FixtureInput.self, "input.v1.json")
        let expected = try load(FixtureExpected.self, "expected.v1.json")
        var projection = LivePrewarmProjection()
        try projection.attach(
            preparationGroupID: input.preparationGroupID,
            connectionEpoch: 1,
            revision: 1
        )
        XCTAssertEqual(
            LivePrewarmProjection.persistence,
            expected.livePersistence
        )
        try projection.updateProgress(
            preparationGroupID: input.preparationGroupID,
            reason: "downloading",
            revision: 2
        )
        XCTAssertEqual(
            projection.presentation(
                forRequiredPreparationGroupIDs: [input.preparationGroupID]
            ),
            .loading(reason: "downloading")
        )
        XCTAssertEqual(
            projection.presentation(
                forRequiredPreparationGroupIDs: [input.disjointGroupID]
            ),
            .enabled
        )
        try projection.usbDetached(connectionEpoch: 1, revision: 3)
        XCTAssertEqual(
            projection.presentation(
                forRequiredPreparationGroupIDs: [input.preparationGroupID]
            ),
            .loading(reason: "deviceReconnecting")
        )
        try projection.rebind(connectionEpoch: 2, revision: 4)
        try projection.markReady(
            preparationGroupID: input.preparationGroupID,
            revision: 5
        )
        XCTAssertEqual(
            projection.presentation(
                forRequiredPreparationGroupIDs: [input.preparationGroupID]
            ),
            .enabled
        )
        projection.detachLive()
        XCTAssertEqual(projection.state, .absent)
    }

    func testStaleReplanAndPrewarmIdentityFailClosed() throws {
        let input = try load(FixtureInput.self, "input.v1.json")
        var integration = ImplicitPreparationIntegration(
            commandID: input.finiteCommandID,
            shape: .finiteOneShot,
            availability: .preparable(groupIDs: [input.preparationGroupID]),
            revisions: revisions(input.initialRevision)
        )
        _ = try integration.begin()
        XCTAssertThrowsError(try integration.preparationReadyAndReplanned(
            preparationGroupID: input.preparationGroupID,
            refreshedAvailability: .available,
            refreshedRevisions: revisions(input.initialRevision)
        )) { error in
            XCTAssertEqual(
                error as? ImplicitPreparationIntegrationError,
                .nonMonotonicRevisions
            )
        }

        var projection = LivePrewarmProjection()
        try projection.attach(
            preparationGroupID: input.preparationGroupID,
            connectionEpoch: 2,
            revision: 2
        )
        XCTAssertThrowsError(try projection.markReady(
            preparationGroupID: input.disjointGroupID,
            revision: 3
        )) { error in
            XCTAssertEqual(
                error as? LivePrewarmProjectionError,
                .groupMismatch
            )
        }
    }

    private func revisions(_ value: UInt64) -> PlanningRevisions {
        PlanningRevisions(
            capability: value,
            condition: value,
            connection: value,
            geometry: value,
            preparation: value,
            quiescing: value
        )
    }

    private func load<Value: Decodable>(
        _ type: Value.Type,
        _ name: String
    ) throws -> Value {
        try JSONDecoder().decode(
            type,
            from: Data(contentsOf: fixtureRoot().appendingPathComponent(name))
        )
    }

    private func fixtureRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Fixtures/preparation-lifecycle/product-integration"
            )
    }
}

private struct FixtureInput: Decodable {
    let disjointCommandID: String
    let disjointGroupID: String
    let finiteCommandID: String
    let initialRevision: UInt64
    let preparationGroupID: String
    let readyRevision: UInt64
    let streamCommandID: String
}

private struct FixtureExpected: Decodable {
    let completionMode: String
    let finitePersistence: String
    let livePersistence: String
    let streamReason: String
}
