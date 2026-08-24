import Darwin
import Foundation
import PulsePhoneSharedDefinitions

public enum AssetAcquisitionTakeoverError: Error, Equatable, Sendable {
  case acquisitionBusy
  case invalidAssetKey
  case systemCall(operation: String, errno: Int32)
  case unsafeNode(String)
}

public final class AssetAcquisitionTakeoverLease: @unchecked Sendable {
  public let assetKey: String
  private var assetDescriptor: Int32
  private var storeDescriptor: Int32

  init(assetKey: String, assetDescriptor: Int32, storeDescriptor: Int32) {
    self.assetKey = assetKey
    self.assetDescriptor = assetDescriptor
    self.storeDescriptor = storeDescriptor
  }

  deinit {
    if assetDescriptor >= 0 {
      _ = flock(assetDescriptor, LOCK_UN)
      Darwin.close(assetDescriptor)
    }
    if storeDescriptor >= 0 {
      _ = flock(storeDescriptor, LOCK_UN)
      Darwin.close(storeDescriptor)
    }
  }
}

public protocol AssetAcquisitionTakeoverLocking: Sendable {
  func tryAcquire(assetKey: String) throws -> AssetAcquisitionTakeoverLease?
}

public struct POSIXAssetAcquisitionTakeoverLockSource: AssetAcquisitionTakeoverLocking, Sendable {
  public let storeRootPath: String
  private let ownerUID: uid_t

  public init(storeRootPath: String, ownerUID: uid_t = geteuid()) {
    self.storeRootPath = storeRootPath
    self.ownerUID = ownerUID
  }

  public func tryAcquire(assetKey: String) throws -> AssetAcquisitionTakeoverLease? {
    guard StableBytes.isLowercaseHex(assetKey, byteCount: 32) else {
      throw AssetAcquisitionTakeoverError.invalidAssetKey
    }
    let root = try openDirectory(storeRootPath, expectedMode: 0o700)
    defer { Darwin.close(root) }
    let locks = try openDirectory(named: "locks", relativeTo: root, expectedMode: 0o700)
    defer { Darwin.close(locks) }
    let store = try openLock(named: "asset-store.lock", relativeTo: locks)
    guard flock(store, LOCK_EX | LOCK_NB) == 0 else {
      let code = errno
      Darwin.close(store)
      if code == EWOULDBLOCK || code == EAGAIN { return nil }
      throw systemCall("flock-asset-store", code)
    }
    do {
      try validateLockPath(
        descriptor: store,
        named: "asset-store.lock",
        relativeTo: locks
      )
      let asset = try openLock(named: assetKey + ".lock", relativeTo: locks)
      guard flock(asset, LOCK_EX | LOCK_NB) == 0 else {
        let code = errno
        Darwin.close(asset)
        if code == EWOULDBLOCK || code == EAGAIN {
          _ = flock(store, LOCK_UN)
          Darwin.close(store)
          return nil
        }
        throw systemCall("flock-asset", code)
      }
      do {
        try validateLockPath(
          descriptor: asset,
          named: assetKey + ".lock",
          relativeTo: locks
        )
      } catch {
        _ = flock(asset, LOCK_UN)
        Darwin.close(asset)
        throw error
      }
      return AssetAcquisitionTakeoverLease(
        assetKey: assetKey,
        assetDescriptor: asset,
        storeDescriptor: store
      )
    } catch {
      _ = flock(store, LOCK_UN)
      Darwin.close(store)
      throw error
    }
  }

  private func openDirectory(_ path: String, expectedMode: mode_t) throws -> Int32 {
    let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
    guard descriptor >= 0 else { throw systemCall("open-store-root", errno) }
    do {
      try validate(descriptor, kind: mode_t(S_IFDIR), mode: expectedMode, path: path)
      return descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  private func openDirectory(
    named component: String,
    relativeTo parent: Int32,
    expectedMode: mode_t
  ) throws -> Int32 {
    let descriptor = Darwin.openat(
      parent,
      component,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
    )
    guard descriptor >= 0 else { throw systemCall("open-locks-directory", errno) }
    do {
      try validate(descriptor, kind: mode_t(S_IFDIR), mode: expectedMode, path: component)
      return descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  private func openLock(named component: String, relativeTo parent: Int32) throws -> Int32 {
    let descriptor = Darwin.openat(
      parent,
      component,
      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
      mode_t(0o600)
    )
    guard descriptor >= 0 else { throw systemCall("open-acquisition-lock", errno) }
    do {
      try validate(descriptor, kind: mode_t(S_IFREG), mode: 0o600, path: component)
      return descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  private func validate(
    _ descriptor: Int32,
    kind: mode_t,
    mode: mode_t,
    path: String
  ) throws {
    var status = stat()
    guard fstat(descriptor, &status) == 0 else { throw systemCall("fstat", errno) }
    guard status.st_uid == ownerUID,
      status.st_mode & mode_t(S_IFMT) == kind,
      status.st_mode & mode_t(0o7777) == mode,
      kind != mode_t(S_IFREG) || status.st_nlink == 1
    else {
      throw AssetAcquisitionTakeoverError.unsafeNode(path)
    }
  }

  private func validateLockPath(
    descriptor: Int32,
    named component: String,
    relativeTo parent: Int32
  ) throws {
    var opened = stat()
    var pathNode = stat()
    guard fstat(descriptor, &opened) == 0 else { throw systemCall("fstat-lock", errno) }
    guard fstatat(parent, component, &pathNode, AT_SYMLINK_NOFOLLOW) == 0 else {
      throw systemCall("fstatat-lock", errno)
    }
    guard opened.st_dev == pathNode.st_dev,
      opened.st_ino == pathNode.st_ino,
      pathNode.st_uid == ownerUID,
      pathNode.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      pathNode.st_mode & mode_t(0o7777) == mode_t(0o600),
      pathNode.st_nlink == 1
    else {
      throw AssetAcquisitionTakeoverError.unsafeNode(component)
    }
  }

  private func systemCall(_ operation: String, _ code: Int32) -> AssetAcquisitionTakeoverError {
    .systemCall(operation: operation, errno: code)
  }
}

public struct AssetAcquisitionTakeover: Sendable {
  public static let acquisitionSlotWait = MonotonicDuration(nanoseconds: 900_000_000_000)

  private let lockSource: any AssetAcquisitionTakeoverLocking
  private let poller: any RecoveryPolling
  private let timeout: MonotonicDuration

  public init(
    lockSource: any AssetAcquisitionTakeoverLocking,
    poller: any RecoveryPolling = SystemRecoveryPoller()
  ) {
    self.lockSource = lockSource
    self.poller = poller
    self.timeout = Self.acquisitionSlotWait
  }

  init(
    lockSource: any AssetAcquisitionTakeoverLocking,
    poller: any RecoveryPolling,
    timeout: MonotonicDuration
  ) {
    self.lockSource = lockSource
    self.poller = poller
    self.timeout = timeout
  }

  public func acquire(assetKey: String) throws -> AssetAcquisitionTakeoverLease {
    var lease: AssetAcquisitionTakeoverLease?
    let acquired = try poller.waitUntil(timeout: timeout) {
      lease = try lockSource.tryAcquire(assetKey: assetKey)
      return lease != nil
    }
    guard acquired, let lease else {
      throw AssetAcquisitionTakeoverError.acquisitionBusy
    }
    return lease
  }
}
