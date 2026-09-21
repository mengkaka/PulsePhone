import Foundation
import XCTest
@testable import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions

final class ShutdownInhibitorTests: XCTestCase {
    func testRegistryProjectsOnlyStableSafeTokenMetadata() throws {
        var registry = ShutdownInhibitorRegistry()
        let preparing = try registry.acquire(
            tokenID: uuid(2),
            metadata: ShutdownInhibitorMetadata(
                kind: .preparingCapability,
                retryWhen: .capabilityResolved,
                state: "mounting"
            )
        )
        _ = try registry.acquire(
            tokenID: uuid(1),
            metadata: ShutdownInhibitorMetadata(
                kind: .assetAcquisition,
                retryWhen: .acquisitionFinished,
                state: "downloading"
            )
        )
        _ = try registry.acquire(
            tokenID: uuid(3),
            metadata: preparing.metadata
        )

        let snapshot = registry.snapshot
        XCTAssertEqual(snapshot.inhibitorRevision, 3)
        XCTAssertEqual(snapshot.tokenCount, 3)
        XCTAssertEqual(
            snapshot.blockers.map(\.kind),
            [.assetAcquisition, .preparingCapability]
        )
        XCTAssertEqual(snapshot.blockers.map(\.count), [1, 2])
        XCTAssertThrowsError(
            try ShutdownInhibitorMetadata(
                kind: .cleanup,
                retryWhen: .cleanupFinished,
                state: "/private/device/path"
            )
        )
        XCTAssertThrowsError(
            try ShutdownInhibitorMetadata(
                kind: .assetAcquisition,
                retryWhen: .jobTerminal
            )
        )
    }

    func testHandoffAndReleaseRequireExactCurrentToken() throws {
        var registry = ShutdownInhibitorRegistry()
        let cleanup = try registry.acquire(
            tokenID: uuid(10),
            metadata: ShutdownInhibitorMetadata(
                kind: .cleanup,
                retryWhen: .cleanupFinished,
                jobID: "job.10"
            )
        )
        let fencing = try registry.handoff(
            cleanup,
            to: ShutdownInhibitorMetadata(
                kind: .fencing,
                retryWhen: .stateChanged,
                jobID: "job.10"
            )
        )
        XCTAssertThrowsError(try registry.release(cleanup)) { error in
            XCTAssertEqual(
                error as? ShutdownInhibitorRegistryError,
                .staleToken
            )
        }
        let release = try registry.release(fencing)
        XCTAssertTrue(release.becameEmpty)
        XCTAssertEqual(release.snapshot.inhibitorRevision, 3)
        XCTAssertThrowsError(try registry.release(fencing)) { error in
            XCTAssertEqual(
                error as? ShutdownInhibitorRegistryError,
                .unknownToken
            )
        }
    }

    func testIdleInhibitorsBlockAndLastReleaseReevaluates() throws {
        let expected = try loadExpected("T-020/idle-inhibitor-l3")
        var registry = ShutdownInhibitorRegistry()
        var coordinator = try RuntimeIdleCoordinator(
            runtimeReadyAt: instant(minutes: 0)
        )
        var lifecycleState = RuntimeLifecycleState.ready

        XCTAssertEqual(
            try coordinator.recordActivity(
                .acceptedPrepareCapabilities,
                at: instant(minutes: 1)
            ),
            .refreshed(instant(minutes: 1))
        )
        XCTAssertEqual(
            try coordinator.recordActivity(
                .prepareProgress,
                at: instant(minutes: 8)
            ),
            .ignored
        )
        let acquisition = try registry.acquire(
            tokenID: uuid(20),
            metadata: ShutdownInhibitorMetadata(
                kind: .assetAcquisition,
                retryWhen: .acquisitionFinished
            )
        )
        let preparation = try registry.acquire(
            tokenID: uuid(21),
            metadata: ShutdownInhibitorMetadata(
                kind: .preparingCapability,
                retryWhen: .capabilityResolved
            )
        )
        let blocked = try coordinator.attemptQuiesce(
            trigger: .automaticIdle,
            at: instant(minutes: 11),
            lifecycleState: &lifecycleState,
            inhibitors: &registry
        )
        guard case .blocked(let blockers) = blocked else {
            return XCTFail("expected idle blockers")
        }
        XCTAssertEqual(
            blockers.map(\.kind),
            [.assetAcquisition, .preparingCapability]
        )
        let firstRelease = try coordinator.releaseInhibitorAndReevaluateIdle(
            acquisition,
            at: instant(minutes: 11),
            lifecycleState: &lifecycleState,
            inhibitors: &registry
        )
        XCTAssertNil(firstRelease.idleReevaluation)
        let finalRelease = try coordinator.releaseInhibitorAndReevaluateIdle(
            preparation,
            at: instant(minutes: 11),
            lifecycleState: &lifecycleState,
            inhibitors: &registry
        )
        XCTAssertEqual(
            finalRelease.idleReevaluation,
            .notIdle(until: instant(minutes: 21))
        )
        XCTAssertEqual(lifecycleState, .ready)
        XCTAssertTrue(registry.snapshot.acceptingNewTokens)
        XCTAssertEqual(uint(expected["validatedPrepareRefreshCount"]), 1)
        XCTAssertEqual(uint(expected["progressRefreshCount"]), 0)
        XCTAssertEqual(bool(expected["lastReleaseStartsIdleGrace"]), true)
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

    private func uint(_ value: RepositoryJSONValue?) -> UInt64? {
        guard let number = value?.numberValue else { return nil }
        return try? number.requireUInt64()
    }
}
