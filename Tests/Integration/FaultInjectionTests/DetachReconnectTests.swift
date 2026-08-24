import PulsePhoneBackendAdapters
import PulsePhoneMedia
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions
import XCTest

final class DetachReconnectTests: XCTestCase {
    func testReconnectEpochTargetBindingFixture() throws {
        let fixture = try faultFixture(
            "T-001/reconnect-epoch-target-binding-l4"
        )
        let input = try fixture.decodeInput(ReconnectBindingInput.self)
        let expected = try fixture.decodeExpected(
            ReconnectBindingExpected.self
        )
        let target = try CanonicalUDID(
            canonicalString: input.targetCanonicalUDID
        )
        var coordinator = VideoReconnectCoordinator(canonicalUDID: target)
        try coordinator.runtimeReconnected(
            connectionEpoch: input.oldConnectionEpoch
        )
        try coordinator.updateGeometry(try geometry(
            connectionEpoch: input.oldConnectionEpoch,
            revision: input.oldGeometryRevision
        ))
        try coordinator.sourceChanged(try faultVideoResolution(
            target: target,
            sourceID: input.sourceID,
            sourceEpoch: input.sourceEpoch
        ))
        let oldBinding = try XCTUnwrap(coordinator.bindIfReady())

        XCTAssertTrue(coordinator.runtimeDetached(
            connectionEpoch: input.oldConnectionEpoch
        ))
        try coordinator.runtimeReconnected(
            connectionEpoch: input.newConnectionEpoch
        )
        try coordinator.updateGeometry(try geometry(
            connectionEpoch: input.newConnectionEpoch,
            revision: input.newGeometryRevision
        ))
        let rebound = try XCTUnwrap(coordinator.bindIfReady())

        XCTAssertEqual(
            rebound.canonicalUDID.rawValue,
            expected.boundCanonicalUDID
        )
        XCTAssertEqual(rebound.connectionEpoch, expected.boundConnectionEpoch)
        XCTAssertEqual(
            coordinator.receive(VideoFrameIdentity(
                binding: oldBinding,
                frameSequence: 1
            )),
            .discarded(.connectionEpochMismatch)
        )
        let wrongTarget = VideoBindingIdentity(
            canonicalUDID: try CanonicalUDID(
                canonicalString: input.wrongCanonicalUDID
            ),
            connectionEpoch: rebound.connectionEpoch,
            sourceID: rebound.sourceID,
            sourceEpoch: rebound.sourceEpoch,
            geometryRevision: rebound.geometryRevision
        )
        XCTAssertEqual(
            coordinator.receive(VideoFrameIdentity(
                binding: wrongTarget,
                frameSequence: 2
            )),
            .discarded(.targetMismatch)
        )
        XCTAssertThrowsError(try coordinator.runtimeReconnected(
            connectionEpoch: input.oldConnectionEpoch
        )) { error in
            XCTAssertEqual(
                error as? VideoReconnectError,
                .staleConnectionEpoch
            )
        }
        XCTAssertTrue(expected.staleEpochRejected)
        XCTAssertTrue(expected.crossTargetRejected)
    }

    func testRuntimeHelperGenerationReconnectFixture() throws {
        let fixture = try faultFixture(
            "T-007/runtime-helper-generation-reconnect-l3"
        )
        let input = try fixture.decodeInput(RuntimeHelperReconnectInput.self)
        let expected = try fixture.decodeExpected(
            RuntimeHelperReconnectExpected.self
        )
        var coordinator = try CoreDeviceGenerationCoordinator(
            runtimeEpoch: input.runtimeEpoch
        )
        _ = coordinator.observeAttach(
            connectionEpoch: input.oldConnectionEpoch
        )
        guard case .start(let firstCommand, _) = try coordinator.admitDemand(
            demandID: "demand.initial",
            descriptor: faultCoreDemand(.explicitPrepare),
            connectionEpoch: input.oldConnectionEpoch,
            preparationAttemptID: "attempt.initial"
        ) else {
            return XCTFail("expected initial generation")
        }
        let oldIdentity = firstCommand.identity
        try makeReady(identity: oldIdentity, coordinator: &coordinator)

        guard case .started(let retirement, _) = coordinator.observeDetach(
            connectionEpoch: input.oldConnectionEpoch
        ) else {
            return XCTFail("expected retirement")
        }
        XCTAssertEqual(
            retirement.commands.map(\.action.rawValue),
            expected.retirementActions
        )
        _ = coordinator.observeAttach(
            connectionEpoch: input.newConnectionEpoch
        )
        guard case .staleIgnored = try coordinator.tunnelReady(
            identity: oldIdentity
        ) else {
            return XCTFail("expected old callback fence")
        }
        _ = coordinator.completeRetirement(identity: oldIdentity)

        guard case .start(let newCommand, _) = try coordinator.admitDemand(
            demandID: "demand.reconnect",
            descriptor: faultCoreDemand(.livePrewarm),
            connectionEpoch: input.newConnectionEpoch,
            preparationAttemptID: "attempt.reconnect"
        ) else {
            return XCTFail("expected replacement generation")
        }
        XCTAssertEqual(
            oldIdentity.executorGeneration,
            expected.oldExecutorGeneration
        )
        XCTAssertEqual(
            newCommand.identity.executorGeneration,
            expected.newExecutorGeneration
        )
        XCTAssertEqual(
            newCommand.identity.connectionEpoch,
            input.newConnectionEpoch
        )
        XCTAssertNotEqual(newCommand.identity, oldIdentity)
        XCTAssertTrue(expected.staleCallbackRejected)
    }

    func testDetachAcquisitionContinuityFixture() throws {
        let fixture = try faultFixture(
            "T-020/detach-acquisition-continuity-l3"
        )
        let input = try fixture.decodeInput(DetachAcquisitionInput.self)
        let expected = try fixture.decodeExpected(
            DetachAcquisitionExpected.self
        )
        let catalog = try faultCatalog()
        var coordinator = PreparationCoordinator(
            runtimeEpoch: input.runtimeEpoch,
            connectionEpoch: input.oldConnectionEpoch,
            executionCatalog: catalog
        )
        guard case .started(let oldIdentity, _) = try coordinator.register(
            faultExplicitSpec(catalog: catalog, value: 1),
            at: faultInstant(0),
            newAttempt: faultSeed(101),
            observerContext: faultObserverContext(1)
        ) else {
            return XCTFail("expected explicit attempt")
        }
        _ = try coordinator.register(
            faultLiveSpec(catalog: catalog, value: 2),
            at: faultInstant(1)
        )
        try coordinator.transitionAttempt(
            oldIdentity.key,
            to: .queryingMountedImage,
            at: faultInstant(2)
        )
        try coordinator.transitionAttempt(
            oldIdentity.key,
            to: .resolvingDeveloperSupport,
            at: faultInstant(3)
        )
        try coordinator.beginAssetAcquisition(
            for: oldIdentity.key,
            acquisitionAttemptID: input.acquisitionAttemptID,
            at: faultInstant(4)
        )

        let detached = try coordinator.detach(at: faultInstant(5))
        XCTAssertEqual(
            detached.waitCompletions.count,
            expected.epochBoundTerminalCount
        )
        XCTAssertEqual(
            detached.continuingAcquisitionAttemptIDs,
            [input.acquisitionAttemptID]
        )
        XCTAssertTrue(coordinator.snapshot.scheduler.activeLeases.isEmpty)
        XCTAssertEqual(
            coordinator.snapshot.activeAcquisitionAttemptIDs,
            [input.acquisitionAttemptID]
        )
        guard case .started(let reboundIdentity) = try coordinator.reconnect(
            connectionEpoch: input.newConnectionEpoch,
            at: faultInstant(6),
            newAttempt: faultSeed(102)
        ) else {
            return XCTFail("expected live prewarm rebound")
        }
        XCTAssertEqual(
            reboundIdentity.connectionEpoch,
            input.newConnectionEpoch
        )
        XCTAssertNotEqual(
            reboundIdentity.preparationAttemptID,
            oldIdentity.preparationAttemptID
        )
        XCTAssertTrue(expected.hostAcquisitionContinues)
        XCTAssertTrue(expected.livePrewarmRebound)
        XCTAssertFalse(expected.epochBoundReplayed)
        XCTAssertFalse(expected.deviceLeaseHeldDuringDownload)
    }

    func testDetachRebootRemountFixture() throws {
        let fixture = try faultFixture(
            "T-021/detach-reboot-remount-l4"
        )
        let input = try fixture.decodeInput(DetachRebootInput.self)
        let expected = try fixture.decodeExpected(DetachRebootExpected.self)
        var coordinator = try CoreDeviceGenerationCoordinator(
            runtimeEpoch: input.runtimeEpoch
        )
        _ = coordinator.observeAttach(
            connectionEpoch: input.oldConnectionEpoch
        )
        XCTAssertNil(coordinator.snapshot.activeGeneration)
        guard case .start(let oldCommand, _) = try coordinator.admitDemand(
            demandID: "demand.before-reboot",
            descriptor: faultCoreDemand(.explicitPrepare),
            connectionEpoch: input.oldConnectionEpoch,
            preparationAttemptID: "attempt.before-reboot"
        ) else {
            return XCTFail("expected old generation")
        }
        try makeReady(identity: oldCommand.identity, coordinator: &coordinator)
        guard case .started(let retirement, _) = coordinator.observeDetach(
            connectionEpoch: input.oldConnectionEpoch
        ) else {
            return XCTFail("expected old generation retirement")
        }
        XCTAssertFalse(retirement.commands.isEmpty)
        _ = coordinator.completeRetirement(identity: oldCommand.identity)
        _ = coordinator.observeAttach(
            connectionEpoch: input.newConnectionEpoch
        )
        XCTAssertNil(coordinator.snapshot.activeGeneration)

        guard case .start(let remount, _) = try coordinator.admitDemand(
            demandID: "demand.after-reboot",
            descriptor: faultCoreDemand(.livePrewarm),
            connectionEpoch: input.newConnectionEpoch,
            preparationAttemptID: "attempt.after-reboot"
        ) else {
            return XCTFail("expected remount generation")
        }
        XCTAssertNotEqual(remount.identity, oldCommand.identity)
        XCTAssertEqual(
            remount.identity.executorGeneration,
            expected.newExecutorGeneration
        )
        XCTAssertFalse(expected.oldGenerationReused)
        XCTAssertFalse(expected.plainAttachMounts)
        XCTAssertTrue(expected.remountRequired)
    }

    private func geometry(
        connectionEpoch: UInt64,
        revision: UInt64
    ) throws -> DisplayGeometryDTO {
        try DisplayGeometryDTO(
            connectionEpoch: connectionEpoch,
            geometryRevision: revision,
            logicalHeight: 2_556,
            logicalWidth: 1_179,
            orientation: .portrait
        )
    }

    private func makeReady(
        identity: CoreDeviceGenerationIdentity,
        coordinator: inout CoreDeviceGenerationCoordinator
    ) throws {
        _ = try coordinator.helperAccepted(identity: identity)
        _ = try coordinator.tunnelReady(identity: identity)
        _ = try coordinator.servicesReady(
            identity: identity,
            serviceSet: faultCoreServiceSet("fault.ready")
        )
        _ = try coordinator.commitReady(identity: identity)
    }
}

private struct ReconnectBindingInput: Decodable {
    let newConnectionEpoch: UInt64
    let newGeometryRevision: UInt64
    let oldConnectionEpoch: UInt64
    let oldGeometryRevision: UInt64
    let sourceEpoch: UInt64
    let sourceID: String
    let targetCanonicalUDID: String
    let wrongCanonicalUDID: String
}

private struct ReconnectBindingExpected: Decodable {
    let boundCanonicalUDID: String
    let boundConnectionEpoch: UInt64
    let crossTargetRejected: Bool
    let staleEpochRejected: Bool
}

private struct RuntimeHelperReconnectInput: Decodable {
    let newConnectionEpoch: UInt64
    let oldConnectionEpoch: UInt64
    let runtimeEpoch: UInt64
}

private struct RuntimeHelperReconnectExpected: Decodable {
    let newExecutorGeneration: UInt64
    let oldExecutorGeneration: UInt64
    let retirementActions: [String]
    let staleCallbackRejected: Bool
}

private struct DetachAcquisitionInput: Decodable {
    let acquisitionAttemptID: String
    let newConnectionEpoch: UInt64
    let oldConnectionEpoch: UInt64
    let runtimeEpoch: UInt64
}

private struct DetachAcquisitionExpected: Decodable {
    let deviceLeaseHeldDuringDownload: Bool
    let epochBoundReplayed: Bool
    let epochBoundTerminalCount: Int
    let hostAcquisitionContinues: Bool
    let livePrewarmRebound: Bool
}

private struct DetachRebootInput: Decodable {
    let newConnectionEpoch: UInt64
    let oldConnectionEpoch: UInt64
    let runtimeEpoch: UInt64
}

private struct DetachRebootExpected: Decodable {
    let newExecutorGeneration: UInt64
    let oldGenerationReused: Bool
    let plainAttachMounts: Bool
    let remountRequired: Bool
}
