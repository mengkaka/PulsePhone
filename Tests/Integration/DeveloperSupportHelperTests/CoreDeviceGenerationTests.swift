import PulsePhoneDeveloperSupportDefinitions
@testable import PulsePhoneBackendAdapters
import XCTest

final class CoreDeviceGenerationTests: XCTestCase {
    func testAttachAndNonCoreDemandDoNotCreateTunnel() throws {
        var coordinator = try CoreDeviceGenerationCoordinator(runtimeEpoch: 7)
        guard case .attached(let attached) = coordinator.observeAttach(
            connectionEpoch: 11
        ) else {
            return XCTFail("expected attach")
        }
        XCTAssertNil(attached.activeGeneration)

        let direct = PreparationDemandDescriptor(
            origin: .finiteCommand,
            persistence: .epochBound,
            preparationGroupID: "prep.direct.lockdown.v1"
        )
        guard case .notApplicable(let unchanged) = try coordinator.admitDemand(
            demandID: "demand.install",
            descriptor: direct,
            connectionEpoch: 11,
            preparationAttemptID: "attempt.install"
        ) else {
            return XCTFail("expected non-CoreDevice demand to be ignored")
        }
        XCTAssertNil(unchanged.activeGeneration)
        XCTAssertEqual(unchanged.nextExecutorGeneration, 1)
    }

    func testAllAuthorizedDemandOriginsJoinOneStartingGeneration() throws {
        var coordinator = try CoreDeviceGenerationCoordinator(runtimeEpoch: 7)
        _ = coordinator.observeAttach(connectionEpoch: 12)

        guard case .start(let command, _) = try coordinator.admitDemand(
            demandID: "demand.explicit",
            descriptor: demand(.explicitPrepare),
            connectionEpoch: 12,
            preparationAttemptID: "attempt.shared"
        ) else {
            return XCTFail("expected first demand to start generation")
        }
        XCTAssertEqual(command.action, .spawnHelper)

        for (id, origin) in [
            ("demand.command", PreparationDemandOrigin.finiteCommand),
            ("demand.live", PreparationDemandOrigin.livePrewarm),
        ] {
            guard case .joined(let identity, _) = try coordinator.admitDemand(
                demandID: id,
                descriptor: demand(origin),
                connectionEpoch: 12,
                preparationAttemptID: "attempt.shared"
            ) else {
                return XCTFail("expected demand to join generation")
            }
            XCTAssertEqual(identity, command.identity)
        }
        XCTAssertEqual(
            coordinator.snapshot.activeGeneration?.pendingDemandIDs,
            ["demand.command", "demand.explicit", "demand.live"]
        )
        XCTAssertEqual(coordinator.snapshot.nextExecutorGeneration, 2)
    }

    func testTunnelServicesReadyAndFacetsAreRetained() throws {
        var coordinator = try startedCoordinator(connectionEpoch: 13)
        let identity = try XCTUnwrap(
            coordinator.snapshot.activeGeneration?.identity
        )

        guard case .advance(let tunnel, _) = try coordinator.helperAccepted(
            identity: identity
        ) else {
            return XCTFail("expected tunnel command")
        }
        XCTAssertEqual(tunnel.action, .startTunnel)
        guard case .advance(let services, _) = try coordinator.tunnelReady(
            identity: identity
        ) else {
            return XCTFail("expected services command")
        }
        XCTAssertEqual(services.action, .openServices)
        let serviceSet = try fullServiceSet(revision: "surface.r1")
        guard case .advance(let publish, _) = try coordinator.servicesReady(
            identity: identity,
            serviceSet: serviceSet
        ) else {
            return XCTFail("expected publish command")
        }
        XCTAssertEqual(publish.action, .publishReady)
        guard case .ready(_, let satisfied, let readySet, _) = try coordinator
            .commitReady(identity: identity)
        else {
            return XCTFail("expected ready generation")
        }
        XCTAssertEqual(satisfied, ["demand.initial"])
        XCTAssertEqual(readySet, serviceSet)

        guard case .reusedReady(let reused, let reusedSet, _) = try coordinator
            .admitDemand(
                demandID: "demand.later",
                descriptor: demand(.finiteCommand),
                connectionEpoch: 13,
                preparationAttemptID: "attempt.later"
            )
        else {
            return XCTFail("expected ready generation reuse")
        }
        XCTAssertEqual(reused, identity)
        XCTAssertEqual(reusedSet, serviceSet)
        XCTAssertEqual(coordinator.snapshot.nextExecutorGeneration, 2)
    }

    func testDetachRetiresInOrderAndOldCallbacksCannotMutateReconnect() throws {
        var coordinator = try readyCoordinator(connectionEpoch: 14)
        let oldIdentity = try XCTUnwrap(
            coordinator.snapshot.activeGeneration?.identity
        )
        guard case .started(let retirement, _) = coordinator.observeDetach(
            connectionEpoch: 14
        ) else {
            return XCTFail("expected retirement")
        }
        XCTAssertEqual(
            retirement.commands.map(\.action),
            [.closeServices, .closeTunnel, .terminateHelper]
        )
        XCTAssertNil(coordinator.snapshot.activeConnectionEpoch)

        _ = coordinator.observeAttach(connectionEpoch: 15)
        XCTAssertNil(coordinator.snapshot.activeGeneration)
        guard case .staleIgnored = try coordinator.tunnelReady(
            identity: oldIdentity
        ) else {
            return XCTFail("expected old callback to be fenced")
        }
        guard case .completed(let retired, _) = coordinator.completeRetirement(
            identity: oldIdentity
        ) else {
            return XCTFail("expected retirement completion")
        }
        XCTAssertEqual(retired.state, .retired)

        guard case .start(let command, _) = try coordinator.admitDemand(
            demandID: "demand.reconnect",
            descriptor: demand(.livePrewarm),
            connectionEpoch: 15,
            preparationAttemptID: "attempt.reconnect"
        ) else {
            return XCTFail("expected new generation")
        }
        XCTAssertEqual(command.identity.connectionEpoch, 15)
        XCTAssertEqual(command.identity.executorGeneration, 2)
        XCTAssertNotEqual(command.identity, oldIdentity)
    }

    func testIncompatibleRetirementBlocksReplacementUntilCleanup() throws {
        var coordinator = try readyCoordinator(connectionEpoch: 16)
        guard case .started(let plan, _) = coordinator.retireCurrent(
            reason: .incompatible
        ) else {
            return XCTFail("expected incompatible retirement")
        }
        XCTAssertFalse(plan.fatalFailStopRequired)
        XCTAssertThrowsError(
            try coordinator.admitDemand(
                demandID: "demand.blocked",
                descriptor: demand(.explicitPrepare),
                connectionEpoch: 16,
                preparationAttemptID: "attempt.blocked"
            )
        ) { error in
            XCTAssertEqual(
                error as? CoreDeviceGenerationControllerError,
                .generationRetirementInProgress
            )
        }
        _ = coordinator.completeRetirement(identity: plan.identity)
        guard case .start(let replacement, _) = try coordinator.admitDemand(
            demandID: "demand.replacement",
            descriptor: demand(.explicitPrepare),
            connectionEpoch: 16,
            preparationAttemptID: "attempt.replacement"
        ) else {
            return XCTFail("expected replacement generation")
        }
        XCTAssertEqual(replacement.identity.executorGeneration, 2)

        guard case .started(let fatal, _) = coordinator.retireCurrent(
            reason: .fatal
        ) else {
            return XCTFail("expected fatal retirement")
        }
        XCTAssertTrue(fatal.fatalFailStopRequired)
        _ = coordinator.completeRetirement(identity: fatal.identity)
        XCTAssertThrowsError(
            try coordinator.admitDemand(
                demandID: "demand.after-fatal",
                descriptor: demand(.explicitPrepare),
                connectionEpoch: 16,
                preparationAttemptID: "attempt.after-fatal"
            )
        ) { error in
            XCTAssertEqual(
                error as? CoreDeviceGenerationControllerError,
                .runtimeNotAcceptingDemand
            )
        }
    }

    private func startedCoordinator(
        connectionEpoch: UInt64
    ) throws -> CoreDeviceGenerationCoordinator {
        var coordinator = try CoreDeviceGenerationCoordinator(runtimeEpoch: 7)
        _ = coordinator.observeAttach(connectionEpoch: connectionEpoch)
        _ = try coordinator.admitDemand(
            demandID: "demand.initial",
            descriptor: demand(.explicitPrepare),
            connectionEpoch: connectionEpoch,
            preparationAttemptID: "attempt.initial"
        )
        return coordinator
    }

    private func readyCoordinator(
        connectionEpoch: UInt64
    ) throws -> CoreDeviceGenerationCoordinator {
        var coordinator = try startedCoordinator(connectionEpoch: connectionEpoch)
        let identity = try XCTUnwrap(
            coordinator.snapshot.activeGeneration?.identity
        )
        _ = try coordinator.helperAccepted(identity: identity)
        _ = try coordinator.tunnelReady(identity: identity)
        _ = try coordinator.servicesReady(
            identity: identity,
            serviceSet: fullServiceSet(revision: "surface.ready")
        )
        _ = try coordinator.commitReady(identity: identity)
        return coordinator
    }

    private func demand(
        _ origin: PreparationDemandOrigin
    ) -> PreparationDemandDescriptor {
        PreparationDemandDescriptor(
            origin: origin,
            persistence: origin == .livePrewarm
                ? .persistentAcrossReconnect
                : .epochBound,
            preparationGroupID: CoreDeviceGenerationCoordinator
                .preparationGroupID
        )
    }

    private func fullServiceSet(revision: String) throws -> CoreDeviceServiceSet {
        try CoreDeviceServiceSet(
            surfaceRevision: revision,
            facets: CoreDeviceGenerationFacet.allCases
        )
    }
}
