import Darwin
import Foundation
import PulsePhoneSharedDefinitions

public enum ReadinessFDError: Error, Equatable, Sendable {
  case alreadyPublished
  case invalidErrorCode
  case invalidFileDescriptor
  case invalidPID
  case writeFailed(Int32)
}

public final class ReadinessFD: @unchecked Sendable {
  public static let standardFileDescriptor: Int32 = 3
  public static let maximumFrameBytes = 4_096

  private let fileDescriptor: Int32
  private let lock = NSLock()
  private var published = false

  public init(fileDescriptor: Int32) throws {
    guard fileDescriptor >= 0, fcntl(fileDescriptor, F_GETFD) != -1 else {
      throw ReadinessFDError.invalidFileDescriptor
    }
    self.fileDescriptor = fileDescriptor
  }

  deinit {
    lock.lock()
    let shouldClose = !published
    published = true
    lock.unlock()
    if shouldClose {
      _ = Darwin.close(fileDescriptor)
    }
  }

  public func publishReady(runtimeEpoch: CanonicalUUID, pid: Int32) throws {
    guard pid > 0 else {
      throw ReadinessFDError.invalidPID
    }
    try publish(
      object: try RepositoryJSONObject(members: [
        RepositoryJSONMember(key: "pid", value: .number(.uint64(UInt64(pid)))),
        RepositoryJSONMember(
          key: "runtimeEpoch",
          value: .string(runtimeEpoch.canonicalString)
        ),
        RepositoryJSONMember(key: "schemaVersion", value: .number(.uint64(1))),
        RepositoryJSONMember(key: "state", value: .string("ready")),
      ])
    )
  }

  public func publishFailed(code: String) throws {
    let bytes = Array(code.utf8)
    guard !bytes.isEmpty,
      bytes.count <= 128,
      bytes.allSatisfy({ (0x21...0x7e).contains($0) })
    else {
      throw ReadinessFDError.invalidErrorCode
    }
    let error = try RepositoryJSONObject(members: [
      RepositoryJSONMember(key: "code", value: .string(code)),
    ])
    try publish(
      object: try RepositoryJSONObject(members: [
        RepositoryJSONMember(key: "error", value: .object(error)),
        RepositoryJSONMember(key: "schemaVersion", value: .number(.uint64(1))),
        RepositoryJSONMember(key: "state", value: .string("failed")),
      ])
    )
  }

  private func publish(object: RepositoryJSONObject) throws {
    let bytes = RepositoryCanonicalJSON.encodeDocument(object)
    precondition(bytes.count <= Self.maximumFrameBytes)

    lock.lock()
    guard !published else {
      lock.unlock()
      throw ReadinessFDError.alreadyPublished
    }
    published = true
    lock.unlock()

    defer { _ = Darwin.close(fileDescriptor) }
    var written = 0
    while written < bytes.count {
      let result = bytes.withUnsafeBytes { buffer in
        Darwin.write(
          fileDescriptor,
          buffer.baseAddress!.advanced(by: written),
          bytes.count - written
        )
      }
      if result > 0 {
        written += result
      } else if result == -1, errno == EINTR {
        continue
      } else {
        throw ReadinessFDError.writeFailed(errno)
      }
    }
  }
}
