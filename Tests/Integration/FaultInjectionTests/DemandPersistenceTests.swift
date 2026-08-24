import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions
import XCTest

final class DemandPersistenceTests: XCTestCase {
    func testDemandPersistenceReconnectFixture() throws {
        let fixture = try faultFixture(
            "T-020/demand-persistence-reconnect-l3"
        )
        let input = try fixture.decodeInput(DemandPersistenceInput.self)
        let expected = try fixture.decodeExpected(
            DemandPersistenceExpected.self
        )
        let catalog = try faultCatalog()
        var coordinator = PreparationCoordinator(
            runtimeEpoch: 9,
            connectionEpoch: input.oldConnectionEpoch,
            executionCatalog: catalog
        )
        guard case .started(let oldIdentity, _) = try coordinator.register(
            faultExplicitSpec(catalog: catalog, value: 10),
            at: faultInstant(0),
            newAttempt: faultSeed(110),
            observerContext: faultObserverContext(10)
        ) else {
            return XCTFail("expected explicit attempt")
        }
        _ = try coordinator.register(
            faultLiveSpec(catalog: catalog, value: 11),
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
            acquisitionAttemptID: "acquisition.1",
            at: faultInstant(4)
        )
        let detached = try coordinator.detach(at: faultInstant(5))
        XCTAssertEqual(detached.waitCompletions.count, 1)
        XCTAssertEqual(
            detached.continuingAcquisitionAttemptIDs,
            ["acquisition.1"]
        )
        guard case .started(let newIdentity) = try coordinator.reconnect(
            connectionEpoch: input.newConnectionEpoch,
            at: faultInstant(6),
            newAttempt: faultSeed(111)
        ) else {
            return XCTFail("expected live rebind")
        }
        XCTAssertNotEqual(
            oldIdentity.preparationAttemptID,
            newIdentity.preparationAttemptID
        )
        XCTAssertFalse(expected.epochBoundReplayed)
        XCTAssertTrue(expected.hostAcquisitionContinues)
        XCTAssertTrue(expected.livePrewarmRebound)
    }

    func testIdleDownloadOwnerReleaseFixture() throws {
        let fixture = try faultFixture(
            "T-007/idle-download-owner-release-l3"
        )
        let input = try fixture.decodeInput(IdleOwnerInput.self)
        let expected = try fixture.decodeExpected(IdleOwnerExpected.self)
        var inhibitors = ShutdownInhibitorRegistry()
        var idle = try RuntimeIdleCoordinator(
            runtimeReadyAt: faultInstant(0)
        )
        var lifecycle = RuntimeLifecycleState.ready
        let token = try inhibitors.acquire(
            tokenID: faultUUID(500),
            metadata: ShutdownInhibitorMetadata(
                kind: .assetAcquisition,
                retryWhen: .acquisitionFinished,
                state: "ownerLocked"
            )
        )
        let threshold = faultInstant(input.idleThresholdSeconds * 1_000_000_000)
        guard case .blocked(let blockers) = try idle.attemptQuiesce(
            trigger: .automaticIdle,
            at: threshold,
            lifecycleState: &lifecycle,
            inhibitors: &inhibitors
        ) else {
            return XCTFail("expected acquisition blocker")
        }
        XCTAssertEqual(blockers.map(\.kind), [.assetAcquisition])
        let release = try idle.releaseInhibitorAndReevaluateIdle(
            token,
            at: threshold,
            lifecycleState: &lifecycle,
            inhibitors: &inhibitors
        )
        XCTAssertEqual(release.idleReevaluation, .quiescing(.automaticIdle))
        XCTAssertEqual(input.ownerKind, ShutdownInhibitorKind.assetAcquisition.rawValue)
        XCTAssertEqual(input.releaseEvent, "assetPublished")
        XCTAssertEqual(input.deviceLeaseHeld, expected.deviceLeaseHeldDuringDownload)
        XCTAssertTrue(expected.assetAcquisitionUsesInhibitor)
        XCTAssertTrue(expected.ownerReleaseTriggersIdleReevaluation)
        XCTAssertFalse(expected.staleProgressGrantsOwnership)
    }
}

private struct DemandPersistenceInput: Decodable {
    let newConnectionEpoch: UInt64
    let oldConnectionEpoch: UInt64
}

private struct DemandPersistenceExpected: Decodable {
    let epochBoundReplayed: Bool
    let hostAcquisitionContinues: Bool
    let livePrewarmRebound: Bool
}

private struct IdleOwnerInput: Decodable {
    let deviceLeaseHeld: Bool
    let idleThresholdSeconds: UInt64
    let ownerKind: String
    let releaseEvent: String
}

private struct IdleOwnerExpected: Decodable {
    let assetAcquisitionUsesInhibitor: Bool
    let deviceLeaseHeldDuringDownload: Bool
    let ownerReleaseTriggersIdleReevaluation: Bool
    let staleProgressGrantsOwnership: Bool
}
