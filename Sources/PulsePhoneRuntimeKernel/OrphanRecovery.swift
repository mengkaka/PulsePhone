import PulsePhoneSharedDefinitions

public enum OrphanRecoveryError: Error, Equatable, Sendable {
  case orphanHelperGenerationBusy
}

public enum OrphanRecoveryResult: Equatable, Sendable {
  case controlledExit
  case recoveredHelpers(VerifiedProcessRecoveryResult)
}

public struct OrphanRecovery: Sendable {
  public static let controlledExitTimeout = MonotonicDuration(nanoseconds: 10_000_000_000)
  public static let lockReleaseTimeout = MonotonicDuration(nanoseconds: 10_000_000_000)

  private let processSystem: any VerifiedRecoveryProcessSystem
  private let processRecovery: VerifiedProcessRecovery
  private let poller: any RecoveryPolling
  private let controlledExitTimeout: MonotonicDuration
  private let lockReleaseTimeout: MonotonicDuration

  public init(
    processSystem: any VerifiedRecoveryProcessSystem = POSIXVerifiedRecoveryProcessSystem(),
    poller: any RecoveryPolling = SystemRecoveryPoller()
  ) {
    self.processSystem = processSystem
    self.processRecovery = VerifiedProcessRecovery(processSystem: processSystem, poller: poller)
    self.poller = poller
    self.controlledExitTimeout = Self.controlledExitTimeout
    self.lockReleaseTimeout = Self.lockReleaseTimeout
  }

  init(
    processSystem: any VerifiedRecoveryProcessSystem,
    processRecovery: VerifiedProcessRecovery,
    poller: any RecoveryPolling,
    controlledExitTimeout: MonotonicDuration,
    lockReleaseTimeout: MonotonicDuration
  ) {
    self.processSystem = processSystem
    self.processRecovery = processRecovery
    self.poller = poller
    self.controlledExitTimeout = controlledExitTimeout
    self.lockReleaseTimeout = lockReleaseTimeout
  }

  public func recover(
    runtimeIdentity: RuntimeRecoveryIdentity,
    manifest: HelperStateManifest,
    runtimeLockIsFree: () throws -> Bool
  ) throws -> OrphanRecoveryResult {
    guard manifest.runtimePID == runtimeIdentity.pid,
      manifest.runtimeProcessStartIdentity == runtimeIdentity.processStartIdentity
    else {
      throw OrphanRecoveryError.orphanHelperGenerationBusy
    }

    switch processSystem.observeRuntime(runtimeIdentity) {
    case .identityMismatch:
      throw OrphanRecoveryError.orphanHelperGenerationBusy
    case .verified:
      let released: Bool
      do {
        released = try poller.waitUntil(
          timeout: controlledExitTimeout,
          condition: runtimeLockIsFree
        )
      } catch {
        throw OrphanRecoveryError.orphanHelperGenerationBusy
      }
      guard released else {
        throw OrphanRecoveryError.orphanHelperGenerationBusy
      }
      return .controlledExit
    case .gone:
      let result: VerifiedProcessRecoveryResult
      do {
        result = try processRecovery.recover(helpers: manifest.helpers)
      } catch {
        throw OrphanRecoveryError.orphanHelperGenerationBusy
      }
      let released: Bool
      do {
        released = try poller.waitUntil(
          timeout: lockReleaseTimeout,
          condition: runtimeLockIsFree
        )
      } catch {
        throw OrphanRecoveryError.orphanHelperGenerationBusy
      }
      guard released else {
        throw OrphanRecoveryError.orphanHelperGenerationBusy
      }
      return .recoveredHelpers(result)
    }
  }
}
