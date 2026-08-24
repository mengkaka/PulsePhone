import Darwin
@testable import PulsePhoneRuntimeKernel
import PulsePhoneSharedDefinitions
import XCTest

final class VerifiedProcessRecoveryTests: XCTestCase {
  func testSignalsOnlyFullyVerifiedSetThenKillsVerifiedSurvivors() throws {
    let system = ScriptedRecoveryProcessSystem()
    let first = helperRecord(id: "a", pid: 101)
    let second = helperRecord(id: "b", pid: 102)
    let gone = helperRecord(id: "c", pid: 103)
    system.helperObservations[101] = [.verified, .gone]
    system.helperObservations[102] = [.verified, .verified, .verified, .gone]
    system.helperObservations[103] = [.gone]
    let poller = ScriptedRecoveryPoller(results: [false, true])
    let recovery = VerifiedProcessRecovery(
      processSystem: system,
      poller: poller,
      gracefulExitTimeout: MonotonicDuration(nanoseconds: 1),
      forcedExitTimeout: MonotonicDuration(nanoseconds: 1)
    )

    let result = try recovery.recover(helpers: [second, gone, first])

    XCTAssertEqual(system.signals, [
      SignalRecord(pid: 101, signal: SIGTERM),
      SignalRecord(pid: 102, signal: SIGTERM),
      SignalRecord(pid: 102, signal: SIGKILL),
    ])
    XCTAssertEqual(
      result,
      VerifiedProcessRecoveryResult(killedCount: 1, terminatedCount: 1, verifiedCount: 2)
    )
  }

  func testIdentityMismatchPreventsEverySignal() throws {
    let system = ScriptedRecoveryProcessSystem()
    system.helperObservations[201] = [.verified]
    system.helperObservations[202] = [.identityMismatch]
    let recovery = VerifiedProcessRecovery(
      processSystem: system,
      poller: ScriptedRecoveryPoller(results: [])
    )

    XCTAssertThrowsError(try recovery.recover(helpers: [
      helperRecord(id: "a", pid: 201),
      helperRecord(id: "b", pid: 202),
    ])) { error in
      XCTAssertEqual(error as? VerifiedProcessRecoveryError, .identityMismatch)
    }
    XCTAssertTrue(system.signals.isEmpty)
  }

  func testSignalFailureStopsRecoveryWithoutWideningTargetSet() throws {
    let system = ScriptedRecoveryProcessSystem()
    system.helperObservations[301] = [.verified]
    system.helperObservations[302] = [.verified]
    system.signalFailurePID = 301
    let recovery = VerifiedProcessRecovery(
      processSystem: system,
      poller: ScriptedRecoveryPoller(results: [])
    )

    XCTAssertThrowsError(try recovery.recover(helpers: [
      helperRecord(id: "a", pid: 301),
      helperRecord(id: "b", pid: 302),
    ])) { error in
      XCTAssertEqual(error as? VerifiedProcessRecoveryError, .signalFailed)
    }
    XCTAssertEqual(system.signals, [SignalRecord(pid: 301, signal: SIGTERM)])
  }

  func testPOSIXObservationRejectsStaleIdentityBeforeSignal() throws {
    let pid = try spawnIndependentSleep()
    var reaped = false
    defer {
      if !reaped {
        _ = Darwin.killpg(pid, SIGKILL)
        var status: Int32 = 0
        while Darwin.waitpid(pid, &status, 0) == -1, errno == EINTR {}
      }
    }
    let identity = try HelperProcessIdentity.capture(
      pid: pid,
      expectedExecutablePath: "/bin/sleep"
    )
    let system = POSIXVerifiedRecoveryProcessSystem()
    XCTAssertEqual(system.observeHelper(identity), .verified)
    let stale = HelperProcessIdentity(
      pid: identity.pid,
      processGroupID: identity.processGroupID,
      processStartIdentity: HelperProcessStartIdentity(
        seconds: identity.processStartIdentity.seconds,
        microseconds: (identity.processStartIdentity.microseconds + 1) % 1_000_000
      ),
      executablePath: identity.executablePath
    )
    XCTAssertEqual(system.observeHelper(stale), .identityMismatch)

    try system.signalHelperProcessGroup(identity, signal: SIGTERM)
    var status: Int32 = 0
    while Darwin.waitpid(pid, &status, 0) == -1, errno == EINTR {}
    reaped = true
    XCTAssertEqual(system.observeHelper(identity), .gone)
  }

  private func helperRecord(id: String, pid: pid_t) -> HelperStateRecord {
    HelperStateRecord(
      helperID: id,
      role: "direct",
      executorID: "executor.direct",
      executorGeneration: 1,
      processIdentity: HelperProcessIdentity(
        pid: pid,
        processGroupID: pid,
        processStartIdentity: HelperProcessStartIdentity(
          seconds: UInt64(pid),
          microseconds: 1
        ),
        executablePath: "/helpers/\(id)"
      )
    )
  }

  private func spawnIndependentSleep() throws -> pid_t {
    var attributes: posix_spawnattr_t?
    XCTAssertEqual(posix_spawnattr_init(&attributes), 0)
    defer { posix_spawnattr_destroy(&attributes) }
    XCTAssertEqual(
      posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)),
      0
    )
    XCTAssertEqual(posix_spawnattr_setpgroup(&attributes, 0), 0)
    var arguments = [strdup("/bin/sleep"), strdup("30"), nil]
    defer { arguments.compactMap { $0 }.forEach { free($0) } }
    var pid: pid_t = 0
    let result = arguments.withUnsafeMutableBufferPointer { buffer in
      posix_spawn(&pid, "/bin/sleep", nil, &attributes, buffer.baseAddress!, environ)
    }
    guard result == 0, pid > 0 else { throw POSIXError(.EIO) }
    return pid
  }
}

struct SignalRecord: Equatable {
  let pid: pid_t
  let signal: Int32
}

final class ScriptedRecoveryProcessSystem: VerifiedRecoveryProcessSystem, @unchecked Sendable {
  var runtimeObservations: [RecoveryProcessObservation] = [.gone]
  var helperObservations: [pid_t: [RecoveryProcessObservation]] = [:]
  var signalFailurePID: pid_t?
  private(set) var signals: [SignalRecord] = []

  func observeRuntime(_ identity: RuntimeRecoveryIdentity) -> RecoveryProcessObservation {
    next(&runtimeObservations)
  }

  func observeHelper(_ identity: HelperProcessIdentity) -> RecoveryProcessObservation {
    guard var values = helperObservations[identity.pid] else { return .identityMismatch }
    let value = next(&values)
    helperObservations[identity.pid] = values
    return value
  }

  func signalHelperProcessGroup(_ identity: HelperProcessIdentity, signal: Int32) throws {
    signals.append(SignalRecord(pid: identity.pid, signal: signal))
    if signalFailurePID == identity.pid {
      throw VerifiedProcessRecoveryError.signalFailed
    }
  }

  private func next(_ values: inout [RecoveryProcessObservation]) -> RecoveryProcessObservation {
    guard let first = values.first else { return .identityMismatch }
    if values.count > 1 { values.removeFirst() }
    return first
  }
}

final class ScriptedRecoveryPoller: RecoveryPolling, @unchecked Sendable {
  private var results: [Bool]

  init(results: [Bool]) {
    self.results = results
  }

  func waitUntil(
    timeout: MonotonicDuration,
    condition: () throws -> Bool
  ) throws -> Bool {
    guard !results.isEmpty else { return false }
    let result = results.removeFirst()
    if !result {
      _ = try condition()
      return false
    }
    for _ in 0..<8 {
      if try condition() { return true }
    }
    return false
  }
}
