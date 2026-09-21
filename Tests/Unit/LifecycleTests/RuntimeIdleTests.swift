import Foundation
import XCTest
@testable import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions

final class RuntimeIdleTests: XCTestCase {
    func testOnlyValidatedCLIAdmissionRefreshesIdleReference() throws {
        var coordinator = try RuntimeIdleCoordinator(
            runtimeReadyAt: instant(minutes: 2)
        )
        for event in [
            RuntimeActivityEvent.runtimeHealth,
            .runtimeStatus,
            .prepareProgress,
            .prepareCompletion,
            .liveAttach,
            .liveActivity,
            .streamFrame,
            .guiAction,
            .commandCompletion,
        ] {
            XCTAssertEqual(
                try coordinator.recordActivity(event, at: instant(minutes: 3)),
                .ignored
            )
        }
        XCTAssertNil(coordinator.snapshot.lastCLIActivityAt)
        XCTAssertEqual(
            try coordinator.recordActivity(
                .validatedCLICommandIntent,
                at: instant(minutes: 4)
            ),
            .refreshed(instant(minutes: 4))
        )
        XCTAssertEqual(coordinator.snapshot.idleReferenceAt, instant(minutes: 4))
        XCTAssertEqual(
            coordinator.snapshot.automaticIdleDeadline,
            instant(minutes: 14)
        )
        XCTAssertThrowsError(
            try coordinator.recordActivity(
                .acceptedPrepareCapabilities,
                at: instant(minutes: 3)
            )
        )
    }

    func testManualAndAutomaticQuiesceAreAtomicWithAdmissionClose() throws {
        var registry = ShutdownInhibitorRegistry()
        var coordinator = try RuntimeIdleCoordinator(
            runtimeReadyAt: instant(minutes: 0)
        )
        var lifecycleState = RuntimeLifecycleState.ready
        XCTAssertEqual(
            try coordinator.attemptQuiesce(
                trigger: .automaticIdle,
                at: instant(minutes: 9),
                lifecycleState: &lifecycleState,
                inhibitors: &registry
            ),
            .notIdle(until: instant(minutes: 10))
        )
        XCTAssertEqual(lifecycleState, .ready)
        XCTAssertEqual(
            try coordinator.attemptQuiesce(
                trigger: .manualStop,
                at: instant(minutes: 9),
                lifecycleState: &lifecycleState,
                inhibitors: &registry
            ),
            .quiescing(.manualStop)
        )
        XCTAssertEqual(lifecycleState, .quiescing)
        XCTAssertThrowsError(
            try registry.acquire(
                tokenID: uuid(30),
                metadata: ShutdownInhibitorMetadata(
                    kind: .live,
                    retryWhen: .liveDetached
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ShutdownInhibitorRegistryError,
                .admissionClosed
            )
        }
    }

    func testFatalQuiesceClosesAdmissionBeforeTokenCleanup() throws {
        var registry = ShutdownInhibitorRegistry()
        let token = try registry.acquire(
            tokenID: uuid(35),
            metadata: ShutdownInhibitorMetadata(
                kind: .cleanup,
                retryWhen: .cleanupFinished
            )
        )
        var coordinator = try RuntimeIdleCoordinator(
            runtimeReadyAt: instant(minutes: 0)
        )
        var lifecycleState = RuntimeLifecycleState.ready
        XCTAssertEqual(
            try coordinator.attemptQuiesce(
                trigger: .fatal,
                at: instant(minutes: 1),
                lifecycleState: &lifecycleState,
                inhibitors: &registry
            ),
            .quiescing(.fatal)
        )
        XCTAssertEqual(lifecycleState, .quiescing)
        XCTAssertFalse(registry.snapshot.acceptingNewTokens)
        XCTAssertEqual(registry.snapshot.tokenCount, 1)
        XCTAssertTrue(try registry.release(token).becameEmpty)
    }

    func testAssetOwnerReleaseFixtureKeepsIdleOwnershipAuthoritative() throws {
        let expected = try loadExpected("T-007/idle-download-owner-release-l3")
        var registry = ShutdownInhibitorRegistry()
        var coordinator = try RuntimeIdleCoordinator(
            runtimeReadyAt: instant(minutes: 0)
        )
        var lifecycleState = RuntimeLifecycleState.ready
        let token = try registry.acquire(
            tokenID: uuid(40),
            metadata: ShutdownInhibitorMetadata(
                kind: .assetAcquisition,
                retryWhen: .acquisitionFinished,
                state: "ownerLocked"
            )
        )
        let blocked = try coordinator.attemptQuiesce(
            trigger: .automaticIdle,
            at: instant(minutes: 10),
            lifecycleState: &lifecycleState,
            inhibitors: &registry
        )
        guard case .blocked(let blockers) = blocked else {
            return XCTFail("expected acquisition blocker")
        }
        XCTAssertEqual(blockers.map(\.kind), [.assetAcquisition])
        let released = try coordinator.releaseInhibitorAndReevaluateIdle(
            token,
            at: instant(minutes: 10),
            lifecycleState: &lifecycleState,
            inhibitors: &registry
        )
        XCTAssertEqual(
            released.idleReevaluation,
            .notIdle(until: instant(minutes: 20))
        )
        XCTAssertEqual(bool(expected["assetAcquisitionUsesInhibitor"]), true)
        XCTAssertEqual(bool(expected["deviceLeaseHeldDuringDownload"]), false)
        XCTAssertEqual(bool(expected["ownerReleaseTriggersIdleReevaluation"]), true)
        XCTAssertEqual(bool(expected["staleProgressGrantsOwnership"]), false)
    }

    private func uuid(_ value: Int) throws -> CanonicalUUID {
        try CanonicalUUID(
            String(format: "00000000-0000-0000-0000-%012x", value)
        )
    }

    private func instant(minutes: UInt64) -> MonotonicInstant {
        MonotonicInstant(nanoseconds: minutes * 60 * 1_000_000_000)
    }

    private func loadExpected(_ requirement: String) throws -> RepositoryJSONObject {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: root.appendingPathComponent(
                "Fixtures/requirements/\(requirement)/expected.v1.json"
            )
        )
        return try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](data),
            maximumByteCount: 16 * 1_024
        ).root
    }

    private func bool(_ value: RepositoryJSONValue?) -> Bool? {
        guard case .bool(let value)? = value else { return nil }
        return value
    }
}
