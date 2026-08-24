import PulsePhoneCommandCatalog
import PulsePhoneCommandPlanner
import PulsePhoneSharedDefinitions
import XCTest

@testable import PulsePhoneRuntimeState

final class CoordinatorTests: XCTestCase {
    func testAttemptSingleFlightFixture() throws {
        let expected = try loadCoordinatorExpected(
            "T-020/attempt-single-flight-l3"
        )
        let catalog = try loadCoordinatorCatalog()
        var coordinator = PreparationCoordinator(
            runtimeEpoch: 9,
            connectionEpoch: 1,
            executionCatalog: catalog
        )
        let first = try coordinator.register(
            explicitSpec(catalog: catalog, id: 1),
            at: instant(0),
            newAttempt: coordinatorSeed(100),
            observerContext: observerContext(1)
        )
        let second = try coordinator.register(
            finiteSpec(catalog: catalog, id: 2),
            at: instant(1),
            newAttempt: coordinatorSeed(101)
        )
        guard case .started(let firstIdentity, let firstCount) = first,
              case .joined(let secondIdentity, let secondCount) = second
        else {
            return XCTFail("expected one started attempt and one join")
        }
        XCTAssertEqual(firstIdentity, secondIdentity)
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 2)
        XCTAssertEqual(coordinator.snapshot.attempts.count, 1)
        XCTAssertEqual(coordinator.snapshot.inhibitors.tokenCount, 1)
        XCTAssertEqual(expectedUInt(expected, "attemptCount"), 1)
        XCTAssertEqual(expectedUInt(expected, "joinedReferenceCount"), 2)
        XCTAssertEqual(expectedBool(expected, "newRetryUsesNewAttemptID"), true)
    }

    func testPreparationWaiterReplanFixture() throws {
        let expected = try loadCoordinatorExpected(
            "T-015/preparation-waiter-replan-l3"
        )
        let catalog = try loadCoordinatorCatalog()
        var coordinator = PreparationCoordinator(
            runtimeEpoch: 9,
            connectionEpoch: 1,
            executionCatalog: catalog
        )
        let spec = try finiteSpec(catalog: catalog, id: 3)
        guard case .started(let identity, _) = try coordinator.register(
            spec,
            at: instant(0),
            newAttempt: coordinatorSeed(103)
        ) else {
            return XCTFail("expected attempt")
        }
        try coordinator.transitionAttempt(
            identity.key,
            to: .queryingMountedImage,
            at: instant(1)
        )
        let completion = try coordinator.completeAttempt(
            identity.key,
            resolution: .ready,
            at: instant(2)
        )
        XCTAssertEqual(completion.waitCompletions.count, 1)
        guard case .resumePlanning(_, let waiter, .ready) =
                completion.waitCompletions[0]
        else {
            return XCTFail("expected resumePlanning completion")
        }
        XCTAssertEqual(waiter, spec.capabilityWaiter)
        XCTAssertEqual(expectedString(expected, "completionMode"), "resumePlanning")
        XCTAssertEqual(expectedBool(expected, "stalePlanExecuted"), false)
        XCTAssertEqual(expectedBool(expected, "readyRequiresReplan"), true)
    }

    func testImplicitReadyReplanFixture() throws {
        let expected = try loadCoordinatorExpected(
            "T-020/implicit-ready-replan-l3"
        )
        let catalog = try loadCoordinatorCatalog()
        let planner = CommandPlanner(catalog: catalog)
        let initial = try planner.plan(
            commandID: "touch.tap",
            rawArguments: ["point": "0.5,0.25"],
            context: coordinatorContext(
                catalog: catalog,
                readyGroupID: nil,
                revision: 1
            )
        )
        guard case .awaitingPreparation = initial else {
            return XCTFail("expected initial preparation waiter")
        }
        var coordinator = PreparationCoordinator(
            runtimeEpoch: 9,
            connectionEpoch: 1,
            executionCatalog: catalog
        )
        guard case .started(let identity, _) = try coordinator.register(
            finiteSpec(catalog: catalog, id: 4),
            at: instant(0),
            newAttempt: coordinatorSeed(104)
        ) else {
            return XCTFail("expected attempt")
        }
        try coordinator.transitionAttempt(
            identity.key,
            to: .queryingMountedImage,
            at: instant(1)
        )
        let completion = try coordinator.completeAttempt(
            identity.key,
            resolution: .ready,
            at: instant(2)
        )
        guard case .resumePlanning(_, let waiter, .ready) =
                completion.waitCompletions[0]
        else {
            return XCTFail("expected waiter completion")
        }
        let resumed = try CapabilityGate.resumePlanning(
            waiter: waiter,
            planner: planner,
            refreshedContext: coordinatorContext(
                catalog: catalog,
                readyGroupID: "prep.coredevice.v2",
                revision: 2
            )
        )
        guard case .planned(let plan) = resumed else {
            return XCTFail("expected authoritative re-plan")
        }
        XCTAssertEqual(plan.sourceRevisions.capability, 2)
        XCTAssertEqual(plan.candidates.map(\.routeID), ["coredevice.normalTouch"])
        XCTAssertEqual(expectedBool(expected, "authoritativeReplan"), true)
        XCTAssertEqual(expectedUInt(expected, "readyRevision"), 2)
    }

    func testObserverReferenceReleaseFixture() throws {
        let expected = try loadCoordinatorExpected(
            "T-020/observer-reference-release-l3"
        )
        let catalog = try loadCoordinatorCatalog()
        var coordinator = PreparationCoordinator(
            runtimeEpoch: 9,
            connectionEpoch: 1,
            executionCatalog: catalog
        )
        let spec = try explicitSpec(catalog: catalog, id: 5)
        guard case .started(let identity, _) = try coordinator.register(
            spec,
            at: instant(0),
            newAttempt: coordinatorSeed(105),
            observerContext: observerContext(5)
        ) else {
            return XCTFail("expected attempt")
        }
        let released = try coordinator.releaseObserverReference(
            observerID: spec.waitID,
            reason: .clientGone,
            at: instant(1)
        )
        XCTAssertEqual(released.terminal, .released(.clientGone))
        XCTAssertEqual(coordinator.snapshot.waitRegistry.entries.count, 0)
        XCTAssertEqual(coordinator.snapshot.attempts.count, 1)
        let completion = try coordinator.completeAttempt(
            identity.key,
            resolution: .unavailable(reason: "developerSupportUnavailable"),
            at: instant(2)
        )
        XCTAssertTrue(completion.waitCompletions.isEmpty)
        XCTAssertEqual(expectedBool(expected, "attemptContinuesAfterLastReference"), true)
        XCTAssertEqual(expectedBool(expected, "acquisitionRolledBack"), false)
        XCTAssertEqual(expectedBool(expected, "automaticRetryAfterTerminal"), false)
    }

    func testObserverAttemptTimeoutFixture() throws {
        let expected = try loadCoordinatorExpected(
            "T-020/observer-attempt-timeout-l3"
        )
        let catalog = try loadCoordinatorCatalog()
        var coordinator = PreparationCoordinator(
            runtimeEpoch: 9,
            connectionEpoch: 1,
            executionCatalog: catalog
        )
        let spec = try explicitSpec(catalog: catalog, id: 6)
        guard case .started(let identity, _) = try coordinator.register(
            spec,
            at: instant(0),
            newAttempt: coordinatorSeed(106),
            observerContext: observerContext(6)
        ) else {
            return XCTFail("expected attempt")
        }
        let observerDeadline = instant(20)
        let observerCompletion = try XCTUnwrap(
            coordinator.checkObserverDeadline(
                observerID: spec.waitID,
                at: observerDeadline
            )
        )
        XCTAssertEqual(
            observerCompletion.terminal,
            .outcomeUnknown(
                reason: "preparationObserverDeadlineExceeded",
                runtimeMayContinue: true,
                exitCode: 7
            )
        )
        XCTAssertEqual(coordinator.snapshot.attempts.count, 1)
        let attemptCompletion = try XCTUnwrap(
            coordinator.checkAttemptDeadline(identity.key, at: instant(40))
        )
        XCTAssertTrue(attemptCompletion.waitCompletions.isEmpty)
        XCTAssertEqual(expectedUInt(expected, "observerMinutes"), 20)
        XCTAssertEqual(expectedUInt(expected, "attemptMinutes"), 40)
        XCTAssertEqual(expectedString(expected, "observerOutcome"), "outcomeUnknown")
        XCTAssertEqual(expectedBool(expected, "runtimeMayContinue"), true)
    }

    func testDemandPersistenceReconnectFixture() throws {
        let expected = try loadCoordinatorExpected(
            "T-020/demand-persistence-reconnect-l3"
        )
        let catalog = try loadCoordinatorCatalog()
        var coordinator = PreparationCoordinator(
            runtimeEpoch: 9,
            connectionEpoch: 1,
            executionCatalog: catalog
        )
        guard case .started(let oldIdentity, _) = try coordinator.register(
            explicitSpec(catalog: catalog, id: 7),
            at: instant(0),
            newAttempt: coordinatorSeed(107),
            observerContext: observerContext(7)
        ) else {
            return XCTFail("expected explicit attempt")
        }
        _ = try coordinator.register(
            liveSpec(catalog: catalog, id: 8),
            at: instant(1)
        )
        try coordinator.transitionAttempt(
            oldIdentity.key,
            to: .queryingMountedImage,
            at: instant(1)
        )
        try coordinator.transitionAttempt(
            oldIdentity.key,
            to: .resolvingDeveloperSupport,
            at: instant(1)
        )
        try coordinator.beginAssetAcquisition(
            for: oldIdentity.key,
            acquisitionAttemptID: "acquisition.1",
            at: instant(2)
        )
        let detached = try coordinator.detach(at: instant(3))
        XCTAssertEqual(detached.waitCompletions.count, 1)
        XCTAssertEqual(detached.continuingAcquisitionAttemptIDs, ["acquisition.1"])
        XCTAssertTrue(coordinator.snapshot.waitRegistry.livePrewarmRegistered)
        guard case .started(let newIdentity) = try coordinator.reconnect(
            connectionEpoch: 2,
            at: instant(4),
            newAttempt: coordinatorSeed(108)
        ) else {
            return XCTFail("expected persistent live rebind")
        }
        XCTAssertNotEqual(oldIdentity.preparationAttemptID, newIdentity.preparationAttemptID)
        XCTAssertEqual(newIdentity.connectionEpoch, 2)
        XCTAssertEqual(expectedBool(expected, "epochBoundReplayed"), false)
        XCTAssertEqual(expectedBool(expected, "livePrewarmRebound"), true)
        XCTAssertEqual(expectedBool(expected, "hostAcquisitionContinues"), true)
    }

    func testNoDemandNoopFixture() throws {
        let expected = try loadCoordinatorExpected("T-020/no-demand-noop-l3")
        let catalog = try loadCoordinatorCatalog()
        var coordinator = PreparationCoordinator(
            runtimeEpoch: 9,
            connectionEpoch: 1,
            executionCatalog: catalog
        )
        try coordinator.observeCapabilityReady(
            preparationGroupID: "prep.coredevice.v2"
        )
        let disposition = try coordinator.register(
            explicitSpec(catalog: catalog, id: 9),
            at: instant(0),
            newAttempt: coordinatorSeed(109),
            observerContext: observerContext(9)
        )
        XCTAssertEqual(disposition, .alreadyReady(.explicitReady))
        XCTAssertTrue(coordinator.snapshot.attempts.isEmpty)
        XCTAssertTrue(coordinator.snapshot.waitRegistry.entries.isEmpty)
        let noDemand = try coordinator.invalidateCapability(
            preparationGroupID: "prep.legacy.developer.v2",
            at: instant(1),
            newAttempt: coordinatorSeed(110)
        )
        XCTAssertEqual(noDemand, .noDemand)
        XCTAssertEqual(expectedUInt(expected, "attemptCount"), 0)
        XCTAssertEqual(expectedBool(expected, "preparationAttemptIDPresent"), false)
        XCTAssertEqual(expectedBool(expected, "backgroundAcquisitionStarted"), false)
    }

    func testCapabilityInvalidationFixture() throws {
        let expected = try loadCoordinatorExpected(
            "T-020/capability-invalidation-l3"
        )
        let catalog = try loadCoordinatorCatalog()
        var coordinator = PreparationCoordinator(
            runtimeEpoch: 9,
            connectionEpoch: 1,
            executionCatalog: catalog
        )
        try coordinator.observeCapabilityReady(
            preparationGroupID: "prep.coredevice.v2"
        )
        XCTAssertEqual(
            try coordinator.register(
                liveSpec(catalog: catalog, id: 10),
                at: instant(0)
            ),
            .alreadyReady(.liveReady)
        )
        guard case .started(let first) = try coordinator.invalidateCapability(
            preparationGroupID: "prep.coredevice.v2",
            at: instant(1),
            newAttempt: coordinatorSeed(111)
        ) else {
            return XCTFail("expected invalidation attempt")
        }
        try coordinator.transitionAttempt(
            first.key,
            to: .queryingMountedImage,
            at: instant(2)
        )
        _ = try coordinator.completeAttempt(
            first.key,
            resolution: .ready,
            at: instant(3)
        )
        guard case .started(let second) = try coordinator.invalidateCapability(
            preparationGroupID: "prep.coredevice.v2",
            at: instant(4),
            newAttempt: coordinatorSeed(112)
        ) else {
            return XCTFail("expected demand re-evaluation")
        }
        XCTAssertNotEqual(first.preparationAttemptID, second.preparationAttemptID)
        XCTAssertEqual(expectedBool(expected, "readyInvalidated"), true)
        XCTAssertEqual(expectedBool(expected, "existingDemandReevaluated"), true)
        XCTAssertEqual(expectedBool(expected, "noDemandCreatesAttempt"), false)
    }

    func testAssetReadyRevalidationFixture() throws {
        let expected = try loadCoordinatorExpected(
            "T-020/asset-ready-revalidation-l3"
        )
        let catalog = try loadCoordinatorCatalog()
        var coordinator = PreparationCoordinator(
            runtimeEpoch: 9,
            connectionEpoch: 1,
            executionCatalog: catalog
        )
        guard case .started(let identity, _) = try coordinator.register(
            finiteSpec(catalog: catalog, id: 11),
            at: instant(0),
            newAttempt: coordinatorSeed(113)
        ) else {
            return XCTFail("expected attempt")
        }
        try coordinator.transitionAttempt(
            identity.key,
            to: .queryingMountedImage,
            at: instant(1)
        )
        try coordinator.transitionAttempt(
            identity.key,
            to: .resolvingDeveloperSupport,
            at: instant(1)
        )
        try coordinator.beginAssetAcquisition(
            for: identity.key,
            acquisitionAttemptID: "acquisition.asset",
            at: instant(2)
        )
        let stale = try PreparationAttemptIdentity(
            runtimeEpoch: identity.runtimeEpoch,
            connectionEpoch: identity.connectionEpoch + 1,
            preparationGroupID: identity.preparationGroupID,
            preparationAttemptID: identity.preparationAttemptID
        )
        XCTAssertEqual(
            try coordinator.assetBecameReady(
                acquisitionAttemptID: "acquisition.stale",
                callbackIdentity: stale,
                at: instant(3)
            ),
            .staleIgnored
        )
        try coordinator.transitionAttempt(
            identity.key,
            to: .waitingForSharedAcquisition,
            at: instant(3)
        )
        guard case .requeryMountedState = try coordinator.assetBecameReady(
            acquisitionAttemptID: "acquisition.asset",
            callbackIdentity: identity,
            at: instant(4)
        ) else {
            return XCTFail("expected mounted-state requery")
        }
        XCTAssertEqual(
            coordinator.snapshot.attempts[0].phase,
            .queryingMountedImage
        )
        XCTAssertNotNil(
            coordinator.snapshot.attempts[0]
                .activeDeadlines[.mountedStateQuery]
        )
        XCTAssertTrue(coordinator.snapshot.scheduler.activeLeases.isEmpty)
        XCTAssertEqual(expectedBool(expected, "staleAttemptMountAllowed"), false)
        XCTAssertEqual(expectedBool(expected, "mountedStateRequeried"), true)
        XCTAssertEqual(expectedBool(expected, "deviceLeaseHeldDuringAcquisition"), false)
    }

    func testPhaseScopedClaimsAndHostAcquisitionHasNoDeviceLease() throws {
        let catalog = try loadCoordinatorCatalog()
        var coordinator = PreparationCoordinator(
            runtimeEpoch: 9,
            connectionEpoch: 1,
            executionCatalog: catalog
        )
        guard case .started(let identity, _) = try coordinator.register(
            finiteSpec(catalog: catalog, id: 12),
            at: instant(0),
            newAttempt: coordinatorSeed(114)
        ) else {
            return XCTFail("expected attempt")
        }
        guard case .running(let queryLease) = try coordinator.requestClaims(
            for: identity.key,
            phaseID: .queryMountedState,
            at: instant(1)
        ) else {
            return XCTFail("query claims should run")
        }
        XCTAssertEqual(
            queryLease.claims.map(\.resourceID),
            ["executor.direct.process-slot", "service.mobile-image-mounter"]
        )
        try coordinator.releaseClaims(for: identity.key)
        guard case .running(let mountLease) = try coordinator.requestClaims(
            for: identity.key,
            phaseID: .mountGeneration,
            at: instant(2)
        ) else {
            return XCTFail("mount claims should run")
        }
        XCTAssertEqual(mountLease.claims.count, 4)
        try coordinator.releaseClaims(for: identity.key)
        try coordinator.transitionAttempt(
            identity.key,
            to: .queryingMountedImage,
            at: instant(3)
        )
        try coordinator.transitionAttempt(
            identity.key,
            to: .resolvingDeveloperSupport,
            at: instant(3)
        )
        try coordinator.beginAssetAcquisition(
            for: identity.key,
            acquisitionAttemptID: "acquisition.no-lease",
            at: instant(4)
        )
        XCTAssertTrue(coordinator.snapshot.scheduler.activeLeases.isEmpty)
    }

    func testFailedAttemptStartDoesNotPublishActiveRegistryState() throws {
        let catalog = try loadCoordinatorCatalog()
        var coordinator = PreparationCoordinator(
            runtimeEpoch: 9,
            connectionEpoch: 1,
            executionCatalog: catalog
        )
        try coordinator.observeCapabilityReady(
            preparationGroupID: "prep.coredevice.v2"
        )
        _ = try coordinator.register(
            liveSpec(catalog: catalog, id: 13),
            at: instant(0)
        )
        XCTAssertThrowsError(
            try coordinator.invalidateCapability(
                preparationGroupID: "prep.coredevice.v2",
                at: instant(1),
                newAttempt: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? PreparationCoordinatorError,
                .missingAttemptSeed
            )
        }
        XCTAssertTrue(coordinator.snapshot.waitRegistry.activeAttemptKeys.isEmpty)
        XCTAssertTrue(coordinator.snapshot.attempts.isEmpty)

        _ = try coordinator.detach(at: instant(2))
        XCTAssertThrowsError(
            try coordinator.reconnect(
                connectionEpoch: 2,
                at: instant(3),
                newAttempt: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? PreparationCoordinatorError,
                .missingAttemptSeed
            )
        }
        XCTAssertFalse(coordinator.snapshot.connected)
        XCTAssertEqual(coordinator.snapshot.connectionEpoch, 1)
        XCTAssertTrue(coordinator.snapshot.waitRegistry.activeAttemptKeys.isEmpty)
    }

    private func explicitSpec(
        catalog: ExecutionProfileCatalogV1,
        id: Int
    ) throws -> DemandSpec {
        try DemandSpec.explicitPrepare(
            observerID: coordinatorUUID(id),
            ownerClientInstanceID: coordinatorUUID(900 + id),
            osMajor: 26,
            executionCatalog: catalog
        )
    }

    private func finiteSpec(
        catalog: ExecutionProfileCatalogV1,
        id: Int
    ) throws -> DemandSpec {
        try DemandSpec.finiteCommand(
            waiterID: coordinatorUUID(id),
            ownerClientInstanceID: coordinatorUUID(900 + id),
            candidatePreparationGroupID: "prep.coredevice.v2",
            capabilityWaiter: coordinatorWaiter(),
            executionCatalog: catalog
        )
    }

    private func liveSpec(
        catalog: ExecutionProfileCatalogV1,
        id: Int
    ) throws -> DemandSpec {
        try DemandSpec.livePrewarm(
            demandID: coordinatorUUID(id),
            ownerClientInstanceID: coordinatorUUID(900 + id),
            osMajor: 26,
            executionCatalog: catalog
        )
    }

    private func observerContext(_ id: Int) throws -> PrepareObserverContext {
        PrepareObserverContext(
            requestID: try coordinatorUUID(2_000 + id),
            actionID: try coordinatorUUID(3_000 + id)
        )
    }

    private func instant(_ minutes: UInt64) -> MonotonicInstant {
        MonotonicInstant(nanoseconds: minutes * 60 * 1_000_000_000)
    }
}
