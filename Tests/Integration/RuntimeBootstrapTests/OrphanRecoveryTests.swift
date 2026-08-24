@testable import PulsePhoneRuntimeKernel
import PulsePhoneSharedDefinitions
import XCTest

final class OrphanRecoveryTests: XCTestCase {
  func testAliveRuntimeGetsControlledWaitWithoutSignals() throws {
    let system = ScriptedRecoveryProcessSystem()
    system.runtimeObservations = [.verified]
    let poller = ScriptedRecoveryPoller(results: [true])
    let recovery = makeRecovery(system: system, poller: poller)
    var lockStates = [false, true, true]

    let result = try recovery.recover(
      runtimeIdentity: runtimeIdentity(),
      manifest: manifest(helpers: []),
      runtimeLockIsFree: { lockStates.removeFirst() }
    )

    XCTAssertEqual(result, .controlledExit)
    XCTAssertTrue(system.signals.isEmpty)
  }

  func testGoneRuntimeRecoversVerifiedHelpersThenRequiresLockRelease() throws {
    let system = ScriptedRecoveryProcessSystem()
    system.runtimeObservations = [.gone]
    system.helperObservations[401] = [.verified, .gone]
    let poller = ScriptedRecoveryPoller(results: [true, true])
    let recovery = makeRecovery(system: system, poller: poller)

    let result = try recovery.recover(
      runtimeIdentity: runtimeIdentity(),
      manifest: manifest(helpers: [helperRecord(pid: 401)]),
      runtimeLockIsFree: { true }
    )

    XCTAssertEqual(
      result,
      .recoveredHelpers(
        VerifiedProcessRecoveryResult(killedCount: 0, terminatedCount: 1, verifiedCount: 1)
      )
    )
    XCTAssertEqual(system.signals, [SignalRecord(pid: 401, signal: SIGTERM)])
  }

  func testManifestRuntimeMismatchAndUnknownIdentityNeverSignal() throws {
    let system = ScriptedRecoveryProcessSystem()
    system.runtimeObservations = [.identityMismatch]
    let recovery = makeRecovery(
      system: system,
      poller: ScriptedRecoveryPoller(results: [])
    )
    let helper = helperRecord(pid: 501)

    XCTAssertThrowsError(try recovery.recover(
      runtimeIdentity: runtimeIdentity(),
      manifest: HelperStateManifest(
        runtimeEpoch: 7,
        canonicalUDIDHash: String(repeating: "a", count: 64),
        ownerUID: 501,
        runtimePID: 999,
        runtimeProcessStartIdentity: HelperProcessStartIdentity(seconds: 1, microseconds: 2),
        helpers: [helper]
      ),
      runtimeLockIsFree: { false }
    )) { error in
      XCTAssertEqual(error as? OrphanRecoveryError, .orphanHelperGenerationBusy)
    }
    XCTAssertTrue(system.signals.isEmpty)

    XCTAssertThrowsError(try recovery.recover(
      runtimeIdentity: runtimeIdentity(),
      manifest: manifest(helpers: [helper]),
      runtimeLockIsFree: { false }
    )) { error in
      XCTAssertEqual(error as? OrphanRecoveryError, .orphanHelperGenerationBusy)
    }
    XCTAssertTrue(system.signals.isEmpty)
  }

  func testLockReleaseTimeoutFailsAfterVerifiedCleanup() throws {
    let system = ScriptedRecoveryProcessSystem()
    system.runtimeObservations = [.gone]
    system.helperObservations[601] = [.verified, .gone]
    let poller = ScriptedRecoveryPoller(results: [true, false])
    let recovery = makeRecovery(system: system, poller: poller)

    XCTAssertThrowsError(try recovery.recover(
      runtimeIdentity: runtimeIdentity(),
      manifest: manifest(helpers: [helperRecord(pid: 601)]),
      runtimeLockIsFree: { false }
    )) { error in
      XCTAssertEqual(error as? OrphanRecoveryError, .orphanHelperGenerationBusy)
    }
    XCTAssertEqual(system.signals, [SignalRecord(pid: 601, signal: SIGTERM)])
  }

  func testLockProbeFailureMapsToBusy() throws {
    let system = ScriptedRecoveryProcessSystem()
    system.runtimeObservations = [.verified]
    let recovery = makeRecovery(
      system: system,
      poller: ScriptedRecoveryPoller(results: [true])
    )

    XCTAssertThrowsError(try recovery.recover(
      runtimeIdentity: runtimeIdentity(),
      manifest: manifest(helpers: []),
      runtimeLockIsFree: { throw POSIXError(.EIO) }
    )) { error in
      XCTAssertEqual(error as? OrphanRecoveryError, .orphanHelperGenerationBusy)
    }
    XCTAssertTrue(system.signals.isEmpty)
  }

  private func makeRecovery(
    system: ScriptedRecoveryProcessSystem,
    poller: ScriptedRecoveryPoller
  ) -> OrphanRecovery {
    let processRecovery = VerifiedProcessRecovery(
      processSystem: system,
      poller: poller,
      gracefulExitTimeout: MonotonicDuration(nanoseconds: 1),
      forcedExitTimeout: MonotonicDuration(nanoseconds: 1)
    )
    return OrphanRecovery(
      processSystem: system,
      processRecovery: processRecovery,
      poller: poller,
      controlledExitTimeout: MonotonicDuration(nanoseconds: 1),
      lockReleaseTimeout: MonotonicDuration(nanoseconds: 1)
    )
  }

  private func runtimeIdentity() -> RuntimeRecoveryIdentity {
    RuntimeRecoveryIdentity(
      executablePath: "/runtime",
      pid: 700,
      processStartIdentity: HelperProcessStartIdentity(seconds: 11, microseconds: 12)
    )
  }

  private func manifest(helpers: [HelperStateRecord]) -> HelperStateManifest {
    HelperStateManifest(
      runtimeEpoch: 7,
      canonicalUDIDHash: String(repeating: "a", count: 64),
      ownerUID: 501,
      runtimePID: 700,
      runtimeProcessStartIdentity: HelperProcessStartIdentity(seconds: 11, microseconds: 12),
      helpers: helpers
    )
  }

  private func helperRecord(pid: pid_t) -> HelperStateRecord {
    HelperStateRecord(
      helperID: "helper-\(pid)",
      role: "direct",
      executorID: "executor.direct",
      executorGeneration: 1,
      processIdentity: HelperProcessIdentity(
        pid: pid,
        processGroupID: pid,
        processStartIdentity: HelperProcessStartIdentity(seconds: UInt64(pid), microseconds: 1),
        executablePath: "/helper-\(pid)"
      )
    )
  }
}
