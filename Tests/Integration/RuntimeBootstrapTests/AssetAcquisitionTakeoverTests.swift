import Darwin
import Foundation
@testable import PulsePhoneRuntimeKernel
import PulsePhoneSharedDefinitions
import XCTest

final class AssetAcquisitionTakeoverTests: XCTestCase {
  func testFlockOwnershipControlsTakeoverAndStaleMetadataIsIgnored() throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let assetKey = String(repeating: "a", count: 64)
    let source = POSIXAssetAcquisitionTakeoverLockSource(storeRootPath: root.path)
    var first: AssetAcquisitionTakeoverLease? = try XCTUnwrap(
      source.tryAcquire(assetKey: assetKey)
    )

    try Data("stale-owner-pid=999".utf8).write(
      to: root.appendingPathComponent("state/\(assetKey).progress.v1.json")
    )
    chmod(root.appendingPathComponent("state/\(assetKey).progress.v1.json").path, 0o600)
    XCTAssertNil(try source.tryAcquire(assetKey: assetKey))

    first = nil
    XCTAssertNil(first)
    let takeover = AssetAcquisitionTakeover(
      lockSource: source,
      poller: ScriptedRecoveryPoller(results: [true]),
      timeout: MonotonicDuration(nanoseconds: 1)
    )
    let acquired = try takeover.acquire(assetKey: assetKey)
    XCTAssertEqual(acquired.assetKey, assetKey)
  }

  func testBusyAssetReleasesStoreLockForDisjointTakeover() throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let busyKey = String(repeating: "b", count: 64)
    let freeKey = String(repeating: "c", count: 64)
    let locks = root.appendingPathComponent("locks").path
    let busyDescriptor = Darwin.open(
      locks + "/" + busyKey + ".lock",
      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
      mode_t(0o600)
    )
    XCTAssertGreaterThanOrEqual(busyDescriptor, 0)
    XCTAssertEqual(flock(busyDescriptor, LOCK_EX | LOCK_NB), 0)
    defer {
      _ = flock(busyDescriptor, LOCK_UN)
      Darwin.close(busyDescriptor)
    }
    let source = POSIXAssetAcquisitionTakeoverLockSource(storeRootPath: root.path)

    XCTAssertNil(try source.tryAcquire(assetKey: busyKey))
    XCTAssertNotNil(try source.tryAcquire(assetKey: freeKey))
  }

  func testUnsafeLockNodeAndInvalidAssetKeyFailClosed() throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let assetKey = String(repeating: "d", count: 64)
    let lockPath = root.appendingPathComponent("locks/\(assetKey).lock").path
    XCTAssertEqual(symlink("/dev/null", lockPath), 0)
    let source = POSIXAssetAcquisitionTakeoverLockSource(storeRootPath: root.path)

    XCTAssertThrowsError(try source.tryAcquire(assetKey: "../escape")) { error in
      XCTAssertEqual(error as? AssetAcquisitionTakeoverError, .invalidAssetKey)
    }
    XCTAssertThrowsError(try source.tryAcquire(assetKey: assetKey))
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: lockPath), "/dev/null")
  }

  private func makeStoreRoot() throws -> URL {
    let root = URL(fileURLWithPath: "/private/tmp")
      .appendingPathComponent("pulsephone-acquisition-takeover-\(UUID().uuidString)")
    XCTAssertEqual(mkdir(root.path, 0o700), 0)
    XCTAssertEqual(mkdir(root.appendingPathComponent("locks").path, 0o700), 0)
    XCTAssertEqual(mkdir(root.appendingPathComponent("state").path, 0o700), 0)
    return root
  }
}
