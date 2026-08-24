import CryptoKit
import Darwin
import Foundation
import PulsePhoneSharedDefinitions

struct AssetStorePOSIX {
  let owner: uid_t

  init(owner: uid_t = geteuid()) {
    self.owner = owner
  }

  func ensureDirectory(_ path: String) throws {
    if mkdir(path, 0o700) != 0, errno != EEXIST {
      throw systemCall("mkdir", errno)
    }
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else {
      throw systemCall("lstat-directory", errno)
    }
    guard metadata.st_uid == owner,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_mode & 0o7777 == 0o700
    else {
      throw DeveloperImageAssetStoreError.unsafeNode(path)
    }
  }

  func validateDirectory(_ path: String) throws {
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else {
      throw systemCall("lstat-directory", errno)
    }
    guard metadata.st_uid == owner,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_mode & 0o7777 == 0o700
    else {
      throw DeveloperImageAssetStoreError.unsafeNode(path)
    }
  }

  func openLock(_ path: String, operation: Int32, nonblocking: Bool = false) throws -> Int32 {
    let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw systemCall("open-lock", errno)
    }
    do {
      _ = try validateRegularDescriptor(descriptor, path: path, mode: 0o600)
      let flags = operation | (nonblocking ? LOCK_NB : 0)
      guard flock(descriptor, flags) == 0 else {
        let code = errno
        if nonblocking && (code == EWOULDBLOCK || code == EAGAIN) {
          Darwin.close(descriptor)
          throw DeveloperImageAssetStoreError.lockUnavailable(path)
        }
        throw systemCall("flock", code)
      }
      return descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  /// Publication owns an exclusive content lock until the immutable directory
  /// has been fsynced and validated. Consumers, including external helpers,
  /// must receive a shared lease so they can safely open the same asset.
  func downgradeToSharedLock(_ descriptor: Int32) throws {
    guard flock(descriptor, LOCK_SH) == 0 else {
      throw systemCall("flock-downgrade", errno)
    }
  }

  func readRegularFile(_ path: String, maximumBytes: UInt64) throws -> Data {
    let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else {
      throw systemCall("open-read", errno)
    }
    defer { Darwin.close(descriptor) }
    let size = try validateRegularDescriptor(descriptor, path: path, mode: 0o600)
    guard size <= maximumBytes, size <= UInt64(Int.max) else {
      throw DeveloperImageAssetStoreError.integrityMismatch(path)
    }
    var data = Data(count: Int(size))
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeMutableBytes { buffer in
        Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
      }
      guard count >= 0 else {
        if errno == EINTR { continue }
        throw systemCall("read", errno)
      }
      guard count > 0 else {
        throw DeveloperImageAssetStoreError.integrityMismatch(path)
      }
      offset += count
    }
    return data
  }

  func readExternalRegularFile(_ path: String, maximumBytes: UInt64) throws -> Data {
    let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else {
      throw systemCall("open-external-read", errno)
    }
    defer { Darwin.close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0 else {
      throw systemCall("fstat-external-read", errno)
    }
    guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      before.st_nlink == 1,
      before.st_size >= 0,
      UInt64(before.st_size) <= maximumBytes,
      UInt64(before.st_size) <= UInt64(Int.max)
    else {
      throw DeveloperImageAssetStoreError.unsafeNode(path)
    }
    var data = Data(count: Int(before.st_size))
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeMutableBytes { buffer in
        Darwin.read(
          descriptor,
          buffer.baseAddress!.advanced(by: offset),
          buffer.count - offset
        )
      }
      guard count >= 0 else {
        if errno == EINTR { continue }
        throw systemCall("read-external", errno)
      }
      guard count > 0 else {
        throw DeveloperImageAssetStoreError.integrityMismatch(path)
      }
      offset += count
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0 else {
      throw systemCall("fstat-external-read", errno)
    }
    guard after.st_dev == before.st_dev,
      after.st_ino == before.st_ino,
      after.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      after.st_nlink == 1,
      after.st_size == before.st_size
    else {
      throw DeveloperImageAssetStoreError.integrityMismatch(path)
    }
    return data
  }

  func atomicWrite(_ data: Data, to path: String) throws {
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    try validateDirectory(parent)
    var destination = stat()
    if lstat(path, &destination) == 0 {
      guard destination.st_uid == owner,
        destination.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
        destination.st_mode & 0o7777 == 0o600,
        destination.st_nlink == 1
      else {
        throw DeveloperImageAssetStoreError.unsafeNode(path)
      }
    } else if errno != ENOENT {
      throw systemCall("lstat-atomic-destination", errno)
    }
    let temporary = parent + "/.pulsephone-" + UUID().uuidString.lowercased() + ".tmp"
    let descriptor = Darwin.open(
      temporary,
      O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
      0o600
    )
    guard descriptor >= 0 else {
      throw systemCall("open-atomic-temp", errno)
    }
    var shouldUnlink = true
    defer {
      Darwin.close(descriptor)
      if shouldUnlink { _ = unlink(temporary) }
    }
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeBytes { buffer in
        Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
      }
      guard count >= 0 else {
        if errno == EINTR { continue }
        throw systemCall("write", errno)
      }
      offset += count
    }
    guard fsync(descriptor) == 0 else {
      throw systemCall("fsync-file", errno)
    }
    guard rename(temporary, path) == 0 else {
      throw systemCall("rename", errno)
    }
    shouldUnlink = false
    try fsyncDirectory(parent)
  }

  func createRoleFile(_ data: Data, at path: String) throws {
    let descriptor = Darwin.open(
      path,
      O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
      0o600
    )
    guard descriptor >= 0 else {
      throw systemCall("open-role", errno)
    }
    defer { Darwin.close(descriptor) }
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeBytes { buffer in
        Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
      }
      guard count >= 0 else {
        if errno == EINTR { continue }
        throw systemCall("write-role", errno)
      }
      offset += count
    }
    guard fsync(descriptor) == 0 else {
      throw systemCall("fsync-role", errno)
    }
  }

  func openValidatedRoleFile(
    _ path: String,
    fileRole: String,
    expectedSize: UInt64,
    expectedSHA256: String
  ) throws -> DeveloperImageRoleFile {
    let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else {
      throw systemCall("open-role-read", errno)
    }
    do {
      let size = try validateRegularDescriptor(descriptor, path: path, mode: 0o600)
      guard size == expectedSize else {
        throw DeveloperImageAssetStoreError.integrityMismatch(fileRole)
      }
      guard try sha256Hex(descriptor: descriptor, size: size) == expectedSHA256 else {
        throw DeveloperImageAssetStoreError.integrityMismatch(fileRole)
      }
      guard lseek(descriptor, 0, SEEK_SET) == 0 else {
        throw systemCall("lseek-role", errno)
      }
      return DeveloperImageRoleFile(fileRole: fileRole, size: size, descriptor: descriptor)
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  func regularFileSize(_ path: String) throws -> UInt64 {
    let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else {
      throw systemCall("open-size", errno)
    }
    defer { Darwin.close(descriptor) }
    return try validateRegularDescriptor(descriptor, path: path, mode: 0o600)
  }

  func fsyncDirectory(_ path: String) throws {
    let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
    guard descriptor >= 0 else {
      throw systemCall("open-directory-fsync", errno)
    }
    defer { Darwin.close(descriptor) }
    guard fsync(descriptor) == 0 else {
      throw systemCall("fsync-directory", errno)
    }
  }

  func validateSafeComponent(_ component: String) throws {
    guard !component.isEmpty,
      component != ".",
      component != "..",
      !component.contains("/"),
      !component.contains("\\"),
      !component.utf8.contains(0)
    else {
      throw DeveloperImageAssetStoreError.unsafeNode(component)
    }
  }

  func validateArchivePath(_ path: String) throws {
    guard !path.isEmpty,
      !path.hasPrefix("/"),
      !path.contains("\\"),
      path.utf8.count <= 4_096
    else {
      throw DeveloperImageAssetStoreError.invalidArchive(path)
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      throw DeveloperImageAssetStoreError.invalidArchive(path)
    }
  }

  private func validateRegularDescriptor(
    _ descriptor: Int32,
    path: String,
    mode: mode_t
  ) throws -> UInt64 {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
      throw systemCall("fstat", errno)
    }
    guard metadata.st_uid == owner,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_mode & 0o7777 == mode,
      metadata.st_nlink == 1,
      metadata.st_size >= 0
    else {
      throw DeveloperImageAssetStoreError.unsafeNode(path)
    }
    return UInt64(metadata.st_size)
  }

  private func sha256Hex(descriptor: Int32, size: UInt64) throws -> String {
    var hasher = SHA256()
    var remaining = size
    var buffer = [UInt8](repeating: 0, count: 1_048_576)
    while remaining > 0 {
      let requested = min(buffer.count, Int(remaining))
      let count = Darwin.read(descriptor, &buffer, requested)
      guard count >= 0 else {
        if errno == EINTR { continue }
        throw systemCall("read-hash", errno)
      }
      guard count > 0 else {
        throw DeveloperImageAssetStoreError.integrityMismatch("short read")
      }
      hasher.update(data: Data(buffer.prefix(count)))
      remaining -= UInt64(count)
    }
    return StableBytes.lowercaseHex(Array(hasher.finalize()))
  }

  private func systemCall(_ operation: String, _ code: Int32) -> DeveloperImageAssetStoreError {
    .systemCall(operation: operation, errno: code)
  }
}
