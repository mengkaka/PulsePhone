import Darwin
import Foundation
import XCTest
@testable import PulsePhoneRuntimeExecutable
import PulsePhoneSharedDefinitions

final class RuntimeReadinessTests: XCTestCase {
  func testRuntimeHelpExitsBeforeReadinessFDIsRequired() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let executable = root.appendingPathComponent(".build/debug/PulsePhoneRuntime").path
    for argument in ["--help", "help"] {
      let process = Process()
      let stdout = Pipe()
      let stderr = Pipe()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = [argument]
      process.standardOutput = stdout
      process.standardError = stderr
      try process.run()
      process.waitUntilExit()
      XCTAssertEqual(process.terminationStatus, 0)
      let output = String(
        decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
      )
      XCTAssertTrue(output.contains("PulsePhoneRuntime --canonical-udid <UDID>"))
      XCTAssertTrue(stderr.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
  }

  func testExecutablePublishesReadyOnFD3WithinStartupDeadline() throws {
    let child = try spawnRuntime(arguments: [
      "--canonical-udid", "00008030-001C2D123456802E",
    ])
    defer {
      _ = Darwin.kill(child.pid, SIGTERM)
      var status: Int32 = 0
      _ = Darwin.waitpid(child.pid, &status, 0)
      _ = Darwin.close(child.reader)
    }
    try waitForReadable(child.reader, timeoutMilliseconds: 5_000)
    let object = try decodeFrame(readToEOF(child.reader))
    XCTAssertEqual(object["state"]?.stringValue, "ready")
    XCTAssertNotNil(object["runtimeEpoch"]?.stringValue)
    XCTAssertEqual(try object["pid"]?.numberValue?.requireUInt64(), UInt64(child.pid))
  }

  func testExecutablePublishesFailureForInvalidArguments() throws {
    let child = try spawnRuntime(arguments: [
      "--canonical-udid", "lowercase",
    ])
    defer { _ = Darwin.close(child.reader) }
    try waitForReadable(child.reader, timeoutMilliseconds: 5_000)
    let object = try decodeFrame(readToEOF(child.reader))
    XCTAssertEqual(object["state"]?.stringValue, "failed")
    let error = try XCTUnwrap(object["error"]?.objectValue)
    XCTAssertEqual(error["code"]?.stringValue, "invalidArgument")
    var status: Int32 = 0
    XCTAssertEqual(Darwin.waitpid(child.pid, &status, 0), child.pid)
  }

  func testLaunchArgumentsRequireOneCanonicalTarget() throws {
    let parsed = try RuntimeLaunchArguments.parse([
      "PulsePhoneRuntime", "--canonical-udid", "00008030-001C2D123456802E",
    ])
    XCTAssertEqual(parsed.canonicalUDID.rawValue, "00008030-001C2D123456802E")
    XCTAssertEqual(RuntimeLaunchArguments.startupDeadlineNanoseconds, 5_000_000_000)

    XCTAssertThrowsError(try RuntimeLaunchArguments.parse(["PulsePhoneRuntime"]))
    XCTAssertThrowsError(
      try RuntimeLaunchArguments.parse([
        "PulsePhoneRuntime", "--canonical-udid", "lowercase",
      ])
    )
    XCTAssertThrowsError(
      try RuntimeLaunchArguments.parse([
        "PulsePhoneRuntime", "--canonical-udid", "A",
        "--canonical-udid", "B",
      ])
    )
    XCTAssertThrowsError(
      try RuntimeLaunchArguments.parse(["PulsePhoneRuntime", "--unknown"])
    )
  }

  func testReadyFrameIsCanonicalExactlyOnceAndCloses() throws {
    let (reader, writer) = try makePipe()
    defer { _ = Darwin.close(reader) }
    let readiness = try ReadinessFD(fileDescriptor: writer)
    let epoch = try CanonicalUUID("01234567-89ab-cdef-0123-456789abcdef")
    try readiness.publishReady(runtimeEpoch: epoch, pid: 42)
    XCTAssertThrowsError(
      try readiness.publishReady(runtimeEpoch: epoch, pid: 43)
    ) { error in
      XCTAssertEqual(error as? ReadinessFDError, .alreadyPublished)
    }

    let bytes = try readToEOF(reader)
    XCTAssertEqual(
      String(decoding: bytes, as: UTF8.self),
      "{\"pid\":42,\"runtimeEpoch\":\"01234567-89ab-cdef-0123-456789abcdef\",\"schemaVersion\":1,\"state\":\"ready\"}"
    )
    _ = try RepositoryCanonicalJSON.validateCanonicalDocument(
      bytes,
      maximumByteCount: ReadinessFD.maximumFrameBytes
    )
  }

  func testFailedFrameIsCanonicalExactlyOnceAndCloses() throws {
    let (reader, writer) = try makePipe()
    defer { _ = Darwin.close(reader) }
    let readiness = try ReadinessFD(fileDescriptor: writer)
    try readiness.publishFailed(code: "runtimeStartupTimeout")
    XCTAssertThrowsError(try readiness.publishFailed(code: "internalFailure"))
    XCTAssertEqual(
      String(decoding: try readToEOF(reader), as: UTF8.self),
      "{\"error\":{\"code\":\"runtimeStartupTimeout\"},\"schemaVersion\":1,\"state\":\"failed\"}"
    )
  }

  func testInvalidDescriptorPIDAndErrorCodeFailClosed() throws {
    XCTAssertThrowsError(try ReadinessFD(fileDescriptor: -1))
    let (reader, writer) = try makePipe()
    defer { _ = Darwin.close(reader) }
    let readiness = try ReadinessFD(fileDescriptor: writer)
    let epoch = try CanonicalUUID("01234567-89ab-cdef-0123-456789abcdef")
    XCTAssertThrowsError(try readiness.publishReady(runtimeEpoch: epoch, pid: 0))
    XCTAssertThrowsError(try readiness.publishFailed(code: "bad code"))
    try readiness.publishFailed(code: "internalFailure")
    XCTAssertFalse(try readToEOF(reader).isEmpty)
  }

  private func makePipe() throws -> (Int32, Int32) {
    var descriptors = [Int32](repeating: -1, count: 2)
    XCTAssertEqual(Darwin.pipe(&descriptors), 0)
    return (descriptors[0], descriptors[1])
  }

  private func spawnRuntime(
    arguments: [String]
  ) throws -> (pid: pid_t, reader: Int32) {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let executable = root.appendingPathComponent(".build/debug/PulsePhoneRuntime").path
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable))
    let (reader, writer) = try makePipe()
    let rawArguments = [executable] + arguments
    var cArguments = rawArguments.map { strdup($0) } + [nil]
    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else {
      _ = Darwin.close(reader)
      _ = Darwin.close(writer)
      throw POSIXError(.EIO)
    }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawn_file_actions_addclose(&actions, reader) == 0,
      posix_spawn_file_actions_adddup2(
        &actions,
        writer,
        ReadinessFD.standardFileDescriptor
      ) == 0,
      writer == ReadinessFD.standardFileDescriptor
        || posix_spawn_file_actions_addclose(&actions, writer) == 0
    else {
      _ = Darwin.close(reader)
      _ = Darwin.close(writer)
      throw POSIXError(.EIO)
    }
    var pid: pid_t = 0
    let spawnResult = executable.withCString { path in
      cArguments.withUnsafeMutableBufferPointer { buffer in
        posix_spawn(
          &pid,
          path,
          &actions,
          nil,
          buffer.baseAddress!,
          environ
        )
      }
    }
    cArguments.compactMap { $0 }.forEach { free($0) }
    _ = Darwin.close(writer)
    guard spawnResult == 0, pid > 0 else {
      _ = Darwin.close(reader)
      throw POSIXError(POSIXErrorCode(rawValue: spawnResult) ?? .EIO)
    }
    return (pid, reader)
  }

  private func waitForReadable(
    _ fileDescriptor: Int32,
    timeoutMilliseconds: Int32
  ) throws {
    var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
    let result = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
    guard result == 1, descriptor.revents & Int16(POLLIN | POLLHUP) != 0 else {
      throw POSIXError(result == 0 ? .ETIMEDOUT : POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private func decodeFrame(_ bytes: [UInt8]) throws -> RepositoryJSONObject {
    try RepositoryCanonicalJSON.validateCanonicalDocument(
      bytes,
      maximumByteCount: ReadinessFD.maximumFrameBytes
    ).root
  }

  private func readToEOF(_ fileDescriptor: Int32) throws -> [UInt8] {
    var output = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 256)
    while true {
      let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
      if count > 0 {
        output.append(contentsOf: buffer.prefix(count))
      } else if count == 0 {
        return output
      } else if errno != EINTR {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    }
  }
}
