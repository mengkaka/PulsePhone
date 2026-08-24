import Foundation
import XCTest
@testable import PulsePhoneRuntimeState
import PulsePhoneCommandPlanner
import PulsePhoneSharedDefinitions

final class RuntimeCoordinationTests: XCTestCase {
    func testLifecycleAndTypedRevisionsAdvanceOnlyOnProjectionChange() async throws {
        let actor = makeActor()
        let initial = await actor.snapshot()
        XCTAssertEqual(initial.lifecycleState, .starting)
        XCTAssertEqual(initial.revisions.state.rawValue, 0)

        _ = try await actor.markReady()
        let facts = DeviceFactsSnapshot(
            deviceClass: "iPhone",
            osMajor: 26,
            transportIDs: ["usb"]
        )
        let connected = try await actor.updateConnection(
            connected: true,
            connectionEpoch: 1,
            facts: facts
        )
        XCTAssertEqual(connected.revisions.state.rawValue, 2)
        XCTAssertEqual(connected.revisions.connection.rawValue, 1)
        XCTAssertEqual(connected.revisions.facts.rawValue, 1)

        let noChange = try await actor.updateConnection(
            connected: true,
            connectionEpoch: 1,
            facts: facts
        )
        XCTAssertEqual(noChange.revisions, connected.revisions)

        _ = try await actor.updateCondition(
            locked: true,
            trusted: true,
            liveAttached: false
        )
        _ = try await actor.updateCapabilities([
            "coredevice.input": .available,
            "coredevice.screenshot": .preparing,
        ])
        _ = try await actor.updatePreparations([
            "prep.coredevice.v2": .preparingDevice,
        ])
        let geometry = DisplayGeometrySnapshot(
            geometryRevision: 9,
            logicalHeight: 2_532,
            logicalWidth: 1_170
        )
        let projected = try await actor.updateGeometry(geometry)
        XCTAssertEqual(projected.revisions.state.rawValue, 6)
        XCTAssertEqual(projected.revisions.condition.rawValue, 1)
        XCTAssertEqual(projected.revisions.capability.rawValue, 1)
        XCTAssertEqual(projected.revisions.preparation.rawValue, 1)
        XCTAssertEqual(projected.revisions.geometry.rawValue, 1)
        XCTAssertEqual(
            projected.capabilities.map(\.capabilityID),
            ["coredevice.input", "coredevice.screenshot"]
        )
        XCTAssertEqual(
            projected.planningContext.revisions,
            projected.revisions.planning
        )

        let quiescing = try await actor.beginQuiescing()
        XCTAssertEqual(quiescing.lifecycleState, .quiescing)
        XCTAssertEqual(quiescing.revisions.quiescing.rawValue, 1)
        let stopped = try await actor.markStopped(cause: .expected)
        XCTAssertEqual(stopped.lifecycleState, .stopped)
        XCTAssertEqual(stopped.terminationCause, .expected)
        await XCTAssertThrowsErrorAsync(
            try await actor.markReady(),
            expected: RuntimeCoordinationError.invalidLifecycleTransition
        )
    }

    func testDetachInvalidatesConnectionBoundProjectionAtomically() async throws {
        let actor = makeActor()
        _ = try await actor.markReady()
        _ = try await actor.updateConnection(
            connected: true,
            connectionEpoch: 1,
            facts: DeviceFactsSnapshot(
                deviceClass: "iPhone",
                osMajor: 14,
                transportIDs: ["usb"]
            )
        )
        _ = try await actor.updateCapabilities(["legacy.screenshot": .available])
        _ = try await actor.updatePreparations([
            "prep.legacy.developer.v2": .ready,
        ])
        _ = try await actor.updateGeometry(
            DisplayGeometrySnapshot(
                geometryRevision: 1,
                logicalHeight: 2_436,
                logicalWidth: 1_125
            )
        )
        let before = await actor.snapshot()

        let detached = try await actor.updateConnection(
            connected: false,
            connectionEpoch: 2,
            facts: nil
        )
        XCTAssertFalse(detached.connected)
        XCTAssertEqual(detached.connectionEpoch, 2)
        XCTAssertNil(detached.facts)
        XCTAssertNil(detached.geometry)
        XCTAssertTrue(detached.capabilities.isEmpty)
        XCTAssertTrue(detached.preparations.isEmpty)
        XCTAssertEqual(
            detached.revisions.connection.rawValue,
            before.revisions.connection.rawValue + 1
        )
        XCTAssertEqual(
            detached.revisions.facts.rawValue,
            before.revisions.facts.rawValue + 1
        )
        XCTAssertEqual(
            detached.revisions.capability.rawValue,
            before.revisions.capability.rawValue + 1
        )
        XCTAssertEqual(
            detached.revisions.preparation.rawValue,
            before.revisions.preparation.rawValue + 1
        )
        XCTAssertEqual(
            detached.revisions.geometry.rawValue,
            before.revisions.geometry.rawValue + 1
        )
        XCTAssertEqual(
            detached.revisions.state.rawValue,
            before.revisions.state.rawValue + 1
        )
    }

    func testExternalBoundaryCommitsAfterAwaitAndRejectsStaleCallback() async throws {
        let actor = makeActor()
        _ = try await actor.markReady()
        _ = try await actor.updateConnection(
            connected: true,
            connectionEpoch: 1,
            facts: DeviceFactsSnapshot(
                deviceClass: "iPhone",
                osMajor: 26,
                transportIDs: ["usb"]
            )
        )
        let availabilityBefore = await actor.snapshot().revisions.planning
        let token = try await actor.beginExternalBoundary(
            kind: .deviceIO,
            identity: RuntimeCallbackIdentity(
                runtimeEpoch: 7,
                connectionEpoch: 1,
                executorGeneration: 3,
                attemptID: "attempt-1"
            )
        )
        let opened = await actor.snapshot()
        XCTAssertEqual(opened.activeExternalBoundaryCount, 1)
        XCTAssertEqual(opened.revisions.planning, availabilityBefore)

        await Task.yield()
        let disposition = try await actor.commitExternalBoundary(
            token,
            commit: .condition(
                locked: true,
                trusted: true,
                liveAttached: false
            )
        )
        guard case .committed(let committed) = disposition else {
            return XCTFail("expected committed callback")
        }
        XCTAssertEqual(committed.activeExternalBoundaryCount, 0)
        XCTAssertTrue(committed.condition.locked)
        XCTAssertEqual(committed.revisions.condition.rawValue, 1)

        let repeated = try await actor.commitExternalBoundary(
            token,
            commit: .condition(
                locked: false,
                trusted: false,
                liveAttached: false
            )
        )
        guard case .stale(let unchanged) = repeated else {
            return XCTFail("expected stale repeated callback")
        }
        XCTAssertTrue(unchanged.condition.locked)

        let oldConnectionToken = try await actor.beginExternalBoundary(
            kind: .helperIO,
            identity: RuntimeCallbackIdentity(
                runtimeEpoch: 7,
                connectionEpoch: 1,
                executorGeneration: 3
            )
        )
        _ = try await actor.updateConnection(
            connected: false,
            connectionEpoch: 2,
            facts: nil
        )
        let stale = try await actor.commitExternalBoundary(
            oldConnectionToken,
            commit: .capabilities(["coredevice.input": .available])
        )
        guard case .stale(let staleSnapshot) = stale else {
            return XCTFail("expected old epoch callback to be stale")
        }
        XCTAssertTrue(staleSnapshot.capabilities.isEmpty)
        XCTAssertEqual(staleSnapshot.activeExternalBoundaryCount, 0)
    }

    func testActorSerializesConcurrentMutableTruth() async throws {
        let actor = makeActor()
        _ = try await actor.markReady()
        _ = try await actor.updateConnection(
            connected: true,
            connectionEpoch: 1,
            facts: DeviceFactsSnapshot(
                deviceClass: "iPhone",
                osMajor: 26,
                transportIDs: ["usb"]
            )
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<64 {
                group.addTask {
                    _ = try await actor.updateCapabilities([
                        String(format: "capability.%03d", index): .available,
                    ])
                }
            }
            try await group.waitForAll()
        }
        let snapshot = await actor.snapshot()
        XCTAssertEqual(snapshot.capabilities.count, 1)
        XCTAssertEqual(snapshot.revisions.capability.rawValue, 64)
        XCTAssertEqual(snapshot.revisions.state.rawValue, 66)

        let oldSnapshot = snapshot
        _ = try await actor.updateCondition(
            locked: true,
            trusted: true,
            liveAttached: true
        )
        XCTAssertFalse(oldSnapshot.condition.locked)
    }

    func testBoundaryIdentityMustMatchCurrentGeneration() async throws {
        let actor = makeActor()
        _ = try await actor.markReady()
        await XCTAssertThrowsErrorAsync(
            try await actor.beginExternalBoundary(
                kind: .fileIO,
                identity: RuntimeCallbackIdentity(runtimeEpoch: 8)
            ),
            expected: RuntimeCoordinationError.staleBoundary
        )
    }

    func testEpochAndSnapshotCapsFailClosed() async throws {
        let actor = makeActor()
        _ = try await actor.markReady()
        _ = try await actor.updateConnection(
            connected: true,
            connectionEpoch: 1,
            facts: DeviceFactsSnapshot(
                deviceClass: "iPhone",
                osMajor: 26,
                transportIDs: ["usb"]
            )
        )
        await XCTAssertThrowsErrorAsync(
            try await actor.updateConnection(
                connected: false,
                connectionEpoch: 1,
                facts: nil
            ),
            expected: RuntimeCoordinationError.invalidConnectionState
        )

        let tooManyCapabilities = Dictionary(
            uniqueKeysWithValues: (0...256).map {
                (String(format: "capability.%03d", $0), CapabilityAvailability.available)
            }
        )
        await XCTAssertThrowsErrorAsync(
            try await actor.updateCapabilities(tooManyCapabilities),
            expected: RuntimeCoordinationError.capacityExceeded
        )
        let tooManyPreparations = Dictionary(
            uniqueKeysWithValues: (0...8).map {
                (String(format: "preparation.%03d", $0), RuntimePreparationState.ready)
            }
        )
        await XCTAssertThrowsErrorAsync(
            try await actor.updatePreparations(tooManyPreparations),
            expected: RuntimeCoordinationError.capacityExceeded
        )
    }

    private func makeActor() -> RuntimeCoordinationActor {
        RuntimeCoordinationActor(
            canonicalUDID: try! CanonicalUDID(
                canonicalString: "00008030-001C2D"
            ),
            runtimeEpoch: 7,
            processID: 42,
            boundaryIDFactory: LockedUUIDFactory().next
        )
    }
}

private final class LockedUUIDFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> CanonicalUUID {
        lock.lock()
        value += 1
        let nextValue = value
        lock.unlock()
        return try! CanonicalUUID(
            String(format: "00000000-0000-0000-0000-%012x", nextValue)
        )
    }
}

private func XCTAssertThrowsErrorAsync<T: Sendable>(
    _ expression: @autoclosure () async throws -> T,
    expected: Error,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {
        XCTAssertEqual(
            String(describing: error),
            String(describing: expected),
            file: file,
            line: line
        )
    }
}
