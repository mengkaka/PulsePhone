import Darwin
import Foundation
import PulsePhoneSharedDefinitions

public struct RuntimeRecoveryIdentity: Equatable, Sendable {
  public let executablePath: String
  public let pid: pid_t
  public let processStartIdentity: HelperProcessStartIdentity

  public init(
    executablePath: String,
    pid: pid_t,
    processStartIdentity: HelperProcessStartIdentity
  ) {
    self.executablePath = executablePath
    self.pid = pid
    self.processStartIdentity = processStartIdentity
  }
}

public enum RecoveryProcessObservation: Equatable, Sendable {
  case gone
  case identityMismatch
  case verified
}

public protocol VerifiedRecoveryProcessSystem: Sendable {
  func observeRuntime(_ identity: RuntimeRecoveryIdentity) -> RecoveryProcessObservation
  func observeHelper(_ identity: HelperProcessIdentity) -> RecoveryProcessObservation
  func signalHelperProcessGroup(_ identity: HelperProcessIdentity, signal: Int32) throws
}

public protocol RecoveryPolling: Sendable {
  func waitUntil(
    timeout: MonotonicDuration,
    condition: () throws -> Bool
  ) throws -> Bool
}

public struct SystemRecoveryPoller: RecoveryPolling, Sendable {
  public let intervalNanoseconds: UInt64
  private let clock: SystemMonotonicClock

  public init(intervalNanoseconds: UInt64 = 10_000_000) {
    self.intervalNanoseconds = intervalNanoseconds
    self.clock = SystemMonotonicClock()
  }

  public func waitUntil(
    timeout: MonotonicDuration,
    condition: () throws -> Bool
  ) throws -> Bool {
    let deadline = try clock.now().advanced(by: timeout)
    repeat {
      if try condition() { return true }
      var request = timespec(
        tv_sec: Int(intervalNanoseconds / 1_000_000_000),
        tv_nsec: Int(intervalNanoseconds % 1_000_000_000)
      )
      var remaining = timespec()
      while nanosleep(&request, &remaining) != 0, errno == EINTR {
        request = remaining
      }
    } while clock.now() < deadline
    return try condition()
  }
}

public struct POSIXVerifiedRecoveryProcessSystem: VerifiedRecoveryProcessSystem, Sendable {
  public init() {}

  public func observeRuntime(
    _ identity: RuntimeRecoveryIdentity
  ) -> RecoveryProcessObservation {
    guard processExists(identity.pid) else { return .gone }
    guard identity.pid > 0,
      let path = currentExecutablePath(pid: identity.pid),
      path == canonicalPath(identity.executablePath),
      processStart(pid: identity.pid) == identity.processStartIdentity
    else {
      return .identityMismatch
    }
    return .verified
  }

  public func observeHelper(
    _ identity: HelperProcessIdentity
  ) -> RecoveryProcessObservation {
    guard processExists(identity.pid) else { return .gone }
    return identity.matchesCurrentProcess() ? .verified : .identityMismatch
  }

  public func signalHelperProcessGroup(
    _ identity: HelperProcessIdentity,
    signal: Int32
  ) throws {
    guard identity.pid > 0,
      identity.processGroupID == identity.pid,
      signal == SIGTERM || signal == SIGKILL,
      Darwin.killpg(identity.processGroupID, signal) == 0
    else {
      throw VerifiedProcessRecoveryError.signalFailed
    }
  }

  private func processExists(_ pid: pid_t) -> Bool {
    guard pid > 0 else { return false }
    if Darwin.kill(pid, 0) == 0 { return true }
    return errno != ESRCH
  }

  private func processStart(pid: pid_t) -> HelperProcessStartIdentity? {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(size))
    }
    guard result == Int32(size),
      info.pbi_pid == UInt32(pid),
      info.pbi_start_tvusec < 1_000_000
    else {
      return nil
    }
    return HelperProcessStartIdentity(
      seconds: info.pbi_start_tvsec,
      microseconds: info.pbi_start_tvusec
    )
  }

  private func currentExecutablePath(pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let count = buffer.withUnsafeMutableBufferPointer { pointer in
      proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
    }
    guard count > 0 else { return nil }
    let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
    return canonicalPath(String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self))
  }

  private func canonicalPath(_ path: String) -> String? {
    guard path.hasPrefix("/"), !path.utf8.contains(0), let resolved = realpath(path, nil) else {
      return nil
    }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}

public enum VerifiedProcessRecoveryError: Error, Equatable, Sendable {
  case identityMismatch
  case signalFailed
  case survivorsRemain
}

public struct VerifiedProcessRecoveryResult: Equatable, Sendable {
  public let killedCount: Int
  public let terminatedCount: Int
  public let verifiedCount: Int

  public init(killedCount: Int, terminatedCount: Int, verifiedCount: Int) {
    self.killedCount = killedCount
    self.terminatedCount = terminatedCount
    self.verifiedCount = verifiedCount
  }
}

public struct VerifiedProcessRecovery: Sendable {
  public static let gracefulExitTimeout = MonotonicDuration(nanoseconds: 5_000_000_000)
  public static let forcedExitTimeout = MonotonicDuration(nanoseconds: 5_000_000_000)

  private let processSystem: any VerifiedRecoveryProcessSystem
  private let poller: any RecoveryPolling
  private let gracefulExitTimeout: MonotonicDuration
  private let forcedExitTimeout: MonotonicDuration

  public init(
    processSystem: any VerifiedRecoveryProcessSystem = POSIXVerifiedRecoveryProcessSystem(),
    poller: any RecoveryPolling = SystemRecoveryPoller()
  ) {
    self.processSystem = processSystem
    self.poller = poller
    self.gracefulExitTimeout = Self.gracefulExitTimeout
    self.forcedExitTimeout = Self.forcedExitTimeout
  }

  init(
    processSystem: any VerifiedRecoveryProcessSystem,
    poller: any RecoveryPolling,
    gracefulExitTimeout: MonotonicDuration,
    forcedExitTimeout: MonotonicDuration
  ) {
    self.processSystem = processSystem
    self.poller = poller
    self.gracefulExitTimeout = gracefulExitTimeout
    self.forcedExitTimeout = forcedExitTimeout
  }

  public func recover(
    helpers: [HelperStateRecord]
  ) throws -> VerifiedProcessRecoveryResult {
    let identities = helpers.sorted { lhs, rhs in
      lhs.helperID.utf8.lexicographicallyPrecedes(rhs.helperID.utf8)
    }.map { record in
      HelperProcessIdentity(
        pid: record.pid,
        processGroupID: record.processGroupID,
        processStartIdentity: record.processStartIdentity,
        executablePath: record.executablePath
      )
    }

    let verified = try identities.filter { identity in
      switch processSystem.observeHelper(identity) {
      case .gone:
        return false
      case .identityMismatch:
        throw VerifiedProcessRecoveryError.identityMismatch
      case .verified:
        return true
      }
    }
    for identity in verified {
      do {
        try processSystem.signalHelperProcessGroup(identity, signal: SIGTERM)
      } catch {
        throw VerifiedProcessRecoveryError.signalFailed
      }
    }

    let graceful = try poller.waitUntil(timeout: gracefulExitTimeout) {
      try allGoneOrVerified(verified).isEmpty
    }
    if graceful {
      return VerifiedProcessRecoveryResult(
        killedCount: 0,
        terminatedCount: verified.count,
        verifiedCount: verified.count
      )
    }

    let survivors = try allGoneOrVerified(verified)
    for identity in survivors {
      do {
        try processSystem.signalHelperProcessGroup(identity, signal: SIGKILL)
      } catch {
        throw VerifiedProcessRecoveryError.signalFailed
      }
    }
    let forced = try poller.waitUntil(timeout: forcedExitTimeout) {
      try allGoneOrVerified(survivors).isEmpty
    }
    guard forced else {
      throw VerifiedProcessRecoveryError.survivorsRemain
    }
    return VerifiedProcessRecoveryResult(
      killedCount: survivors.count,
      terminatedCount: verified.count - survivors.count,
      verifiedCount: verified.count
    )
  }

  private func allGoneOrVerified(
    _ identities: [HelperProcessIdentity]
  ) throws -> [HelperProcessIdentity] {
    try identities.filter { identity in
      switch processSystem.observeHelper(identity) {
      case .gone:
        return false
      case .identityMismatch:
        throw VerifiedProcessRecoveryError.identityMismatch
      case .verified:
        return true
      }
    }
  }
}
