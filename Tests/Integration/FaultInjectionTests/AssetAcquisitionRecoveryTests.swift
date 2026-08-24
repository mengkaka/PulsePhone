import Darwin
import Foundation
import PulsePhoneDeveloperImageAssets
@testable import PulsePhoneRuntimeKernel
import PulsePhoneSharedDefinitions
import XCTest

final class AssetAcquisitionRecoveryTests: XCTestCase {
    func testAcquisitionCrashTakeoverFixture() throws {
        let fixture = try assetAcquisitionFixture(
            "T-019/acquisition-crash-takeover-l2"
        )
        let input = try fixture.decodeInput(CrashTakeoverInput.self)
        let expected = try fixture.decodeExpected(AssetAcquisitionExpected.self)
        let store = try makeAssetAcquisitionStore()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: store.rootURL.deletingLastPathComponent())
        }
        let assetKey = String(repeating: "a", count: 64)
        let source = POSIXAssetAcquisitionTakeoverLockSource(
            storeRootPath: store.rootURL.path
        )
        var first: AssetAcquisitionTakeoverLease? = try XCTUnwrap(
            source.tryAcquire(assetKey: assetKey)
        )
        let stale = store.rootURL.appendingPathComponent(
            "state/\(assetKey).progress.v1.json"
        )
        try Data("stale-owner-pid=999".utf8).write(to: stale)
        chmod(stale.path, 0o600)
        XCTAssertNil(try source.tryAcquire(assetKey: assetKey))

        let bounded = AssetAcquisitionTakeover(
            lockSource: source,
            poller: AssetAcquisitionPoller(
                maximumAttempts: input.pollAttempts,
                shouldSucceed: false
            ),
            timeout: MonotonicDuration(nanoseconds: 1)
        )
        XCTAssertThrowsError(try bounded.acquire(assetKey: assetKey)) { error in
            XCTAssertEqual(
                error as? AssetAcquisitionTakeoverError,
                .acquisitionBusy
            )
        }

        first = nil
        XCTAssertNil(first)
        let takeover = try XCTUnwrap(source.tryAcquire(assetKey: assetKey))
        XCTAssertEqual(takeover.assetKey, assetKey)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertEqual(expected.outcome, "passed")
        XCTAssertEqual(expected.kernelLockAuthoritative, true)
        XCTAssertEqual(expected.staleMetadataIgnored, true)
        XCTAssertEqual(expected.boundedWaitFailsBusy, true)
        XCTAssertEqual(expected.takeoverAfterRelease, true)
    }

    func testStoreLockOrderHandoffFixture() throws {
        let fixture = try assetAcquisitionFixture(
            "T-019/store-lock-order-handoff-l2"
        )
        let input = try fixture.decodeInput(LockHandoffInput.self)
        let expected = try fixture.decodeExpected(AssetAcquisitionExpected.self)
        let store = try makeAssetAcquisitionStore()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: store.rootURL.deletingLastPathComponent())
        }
        let busyKey = input.busyAssetKey
        let freeKey = input.freeAssetKey
        let lockPath = store.rootURL.appendingPathComponent(
            "locks/\(busyKey).lock"
        ).path
        let busyDescriptor = Darwin.open(
            lockPath,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        XCTAssertGreaterThanOrEqual(busyDescriptor, 0)
        XCTAssertEqual(flock(busyDescriptor, LOCK_EX | LOCK_NB), 0)
        defer {
            _ = flock(busyDescriptor, LOCK_UN)
            Darwin.close(busyDescriptor)
        }
        let source = POSIXAssetAcquisitionTakeoverLockSource(
            storeRootPath: store.rootURL.path
        )
        XCTAssertNil(try source.tryAcquire(assetKey: busyKey))
        let freeLease = try XCTUnwrap(source.tryAcquire(assetKey: freeKey))
        XCTAssertEqual(freeLease.assetKey, freeKey)
        XCTAssertEqual(expected.outcome, "passed")
        XCTAssertEqual(expected.storeLockReleasedOnBusyAsset, true)
    }

    func testCacheIndexRebuildFaultFixture() throws {
        let fixture = try assetAcquisitionFixture(
            "T-019/cache-index-rebuild-fault-l2"
        )
        let input = try fixture.decodeInput(IndexRebuildInput.self)
        let expected = try fixture.decodeExpected(AssetAcquisitionExpected.self)
        let model = try assetAcquisitionHTTPModel(input.modelRelativePath)
        XCTAssertEqual(model.corruptions, ["truncatedCanonical", "symlink"])
        let entries = [
            AssetAcquisitionEntrySpec(
                entryID: "classic.index-a",
                image: Data("index-a".utf8),
                signature: Data("sig-a".utf8)
            ),
            AssetAcquisitionEntrySpec(
                entryID: "classic.index-b",
                image: Data("index-b".utf8),
                signature: Data("sig-b".utf8)
            ),
        ]
        let catalog = try makeAssetAcquisitionCatalog(
            revision: "acquisition-index.v1",
            entries: entries
        )
        let store = try makeAssetAcquisitionStore()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: store.rootURL.deletingLastPathComponent())
        }
        var keys = [String]()
        for entry in entries {
            keys.append(try store.publish(
                catalog: catalog,
                entryID: entry.entryID,
                archiveEntries: entry.archiveEntries
            ).assetKey)
        }
        let index = store.rootURL.appendingPathComponent(
            "state/cache-index.v1.json"
        )
        try Data("{".utf8).write(to: index)
        chmod(index.path, 0o600)
        let rebuilt = try store.rebuildIndex()
        XCTAssertEqual(rebuilt.evictionOrder, keys.sorted())

        let external = store.rootURL.deletingLastPathComponent()
            .appendingPathComponent("external-index.json")
        try Data("external".utf8).write(to: external)
        chmod(external.path, 0o600)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createSymbolicLink(
            at: index,
            withDestinationURL: external
        )
        XCTAssertThrowsError(try store.rebuildIndex())
        XCTAssertEqual(try Data(contentsOf: external), Data("external".utf8))
        XCTAssertEqual(expected.outcome, "passed")
        XCTAssertEqual(expected.canonicalCorruptionRebuilt, true)
        XCTAssertEqual(expected.unsafeNodeRejected, true)
        XCTAssertEqual(expected.externalTargetUnchanged, true)
    }
}

private struct CrashTakeoverInput: Decodable {
    let pollAttempts: Int
}

private struct LockHandoffInput: Decodable {
    let busyAssetKey: String
    let freeAssetKey: String
}

private struct IndexRebuildInput: Decodable {
    let modelRelativePath: String
}

private final class AssetAcquisitionPoller: RecoveryPolling, @unchecked Sendable {
    private let maximumAttempts: Int
    private let shouldSucceed: Bool

    init(maximumAttempts: Int, shouldSucceed: Bool) {
        self.maximumAttempts = maximumAttempts
        self.shouldSucceed = shouldSucceed
    }

    func waitUntil(
        timeout: MonotonicDuration,
        condition: () throws -> Bool
    ) throws -> Bool {
        for _ in 0..<maximumAttempts {
            if try condition() { return true }
        }
        return shouldSucceed
    }
}
