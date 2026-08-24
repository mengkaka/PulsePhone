import Foundation
import XCTest
@testable import PulsePhoneRuntimeState
import PulsePhoneCommandPlanner
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneSharedDefinitions

final class PreparationWaitRegistryTests: XCTestCase {
    func testWaitRegistryCapacityFixture() throws {
        let expected = try loadExpected(
            "T-020/wait-registry-capacity-l1"
        )
        var registry = PreparationWaitRegistry()
        let key = try attemptKey(connectionEpoch: 1)
        for index in 0..<32 {
            _ = try registry.register(
                commandEntry(id: "command.\(index)", key: key)
            )
            _ = try registry.register(
                observerEntry(id: "observer.\(index)", key: key)
            )
        }
        _ = try registry.register(liveEntry(id: "live.1", key: key))
        XCTAssertEqual(registry.snapshot.externalEntryCount, 64)
        XCTAssertEqual(registry.snapshot.entries.count, 65)
        XCTAssertThrowsError(
            try registry.register(
                observerEntry(id: "observer.overflow", key: key)
            )
        ) { error in
            XCTAssertEqual(
                error as? PreparationWaitRegistryError,
                .capacityExceeded(PreparationWaitCapacityDetails())
            )
        }
        XCTAssertEqual(uint(expected["externalLimit"]), 64)
        XCTAssertEqual(bool(expected["livePrewarmCountsTowardLimit"]), false)
        XCTAssertEqual(string(expected["capacityClass"]), "preparationWaitRegistry")
        XCTAssertEqual(bool(expected["truncated"]), false)
    }

    func testSharedAttemptJoinRemovalAndExactlyOnceTerminal() throws {
        var registry = PreparationWaitRegistry()
        let key = try attemptKey(connectionEpoch: 2)
        XCTAssertEqual(
            try registry.register(commandEntry(id: "command.1", key: key)),
            .startSharedAttempt(key, referenceCount: 1)
        )
        XCTAssertEqual(
            try registry.register(observerEntry(id: "observer.1", key: key)),
            .joinedSharedAttempt(key, referenceCount: 2)
        )
        let removed = try registry.remove(waitID: "observer.1")
        XCTAssertTrue(removed.sharedAttemptContinues)
        XCTAssertEqual(removed.remainingReferenceCount, 1)

        let completion = try registry.completeAttempt(
            key: key,
            resolution: .ready
        )
        XCTAssertEqual(completion.completions.count, 1)
        guard case .resumePlanning(let waitID, _, .ready) =
                completion.completions[0]
        else {
            return XCTFail("expected command resume")
        }
        XCTAssertEqual(waitID, "command.1")
        XCTAssertThrowsError(
            try registry.completeAttempt(key: key, resolution: .ready)
        ) { error in
            XCTAssertEqual(
                error as? PreparationWaitRegistryError,
                .attemptNotActive
            )
        }
    }

    func testDetachTerminatesEpochBoundAndRebindsPersistentLive() throws {
        var registry = PreparationWaitRegistry()
        let oldKey = try attemptKey(connectionEpoch: 3)
        _ = try registry.register(commandEntry(id: "command.detach", key: oldKey))
        _ = try registry.register(observerEntry(id: "observer.detach", key: oldKey))
        _ = try registry.register(liveEntry(id: "live.detach", key: oldKey))

        let completions = registry.detach(runtimeEpoch: 7, connectionEpoch: 3)
        XCTAssertEqual(completions.count, 2)
        XCTAssertEqual(registry.snapshot.externalEntryCount, 0)
        XCTAssertTrue(registry.snapshot.livePrewarmRegistered)
        let newKey = try attemptKey(connectionEpoch: 4)
        XCTAssertEqual(
            try registry.rebindLivePrewarm(connectionEpoch: 4),
            .startSharedAttempt(newKey, referenceCount: 1)
        )
        XCTAssertEqual(registry.snapshot.entries.map(\.key), [newKey])
    }

    func testLastReferenceRemovalDoesNotCancelSharedAttempt() throws {
        var registry = PreparationWaitRegistry()
        let key = try attemptKey(connectionEpoch: 5)
        _ = try registry.register(observerEntry(id: "observer.only", key: key))
        let removal = try registry.remove(waitID: "observer.only")
        XCTAssertTrue(removal.sharedAttemptContinues)
        XCTAssertEqual(removal.remainingReferenceCount, 0)
        let completion = try registry.completeAttempt(
            key: key,
            resolution: .unavailable(reason: "mountFailed")
        )
        XCTAssertTrue(completion.completions.isEmpty)
    }

    private func attemptKey(
        connectionEpoch: UInt64
    ) throws -> PreparationAttemptKey {
        try PreparationAttemptKey(
            runtimeEpoch: 7,
            connectionEpoch: connectionEpoch,
            preparationGroupID: "prep.coredevice.v2"
        )
    }

    private func commandEntry(
        id: String,
        key: PreparationAttemptKey
    ) throws -> PreparationWaitEntry {
        try PreparationWaitEntry(
            waitID: id,
            ownerClientInstanceID: uuid(1),
            key: key,
            demand: PreparationDemandDescriptor(
                origin: .finiteCommand,
                persistence: .epochBound,
                preparationGroupID: key.preparationGroupID
            ),
            kind: .commandWaiter,
            capabilityWaiter: CapabilityGateWaiter(
                commandID: "touch.tap",
                rawArguments: ["point": "0.5,0.25"],
                sourceRevisions: revisions(1)
            )
        )
    }

    private func observerEntry(
        id: String,
        key: PreparationAttemptKey
    ) throws -> PreparationWaitEntry {
        try PreparationWaitEntry(
            waitID: id,
            ownerClientInstanceID: uuid(2),
            key: key,
            demand: PreparationDemandDescriptor(
                origin: .explicitPrepare,
                persistence: .epochBound,
                preparationGroupID: key.preparationGroupID
            ),
            kind: .explicitObserver
        )
    }

    private func liveEntry(
        id: String,
        key: PreparationAttemptKey
    ) throws -> PreparationWaitEntry {
        try PreparationWaitEntry(
            waitID: id,
            ownerClientInstanceID: uuid(3),
            key: key,
            demand: PreparationDemandDescriptor(
                origin: .livePrewarm,
                persistence: .persistentAcrossReconnect,
                preparationGroupID: key.preparationGroupID
            ),
            kind: .livePrewarm
        )
    }

    private func uuid(_ value: Int) throws -> CanonicalUUID {
        try CanonicalUUID(
            String(format: "00000000-0000-0000-0000-%012x", value)
        )
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

    private func string(_ value: RepositoryJSONValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        return value
    }
}
