import Darwin
import Foundation
import PulsePhoneClientCore
import PulsePhoneHostPaths
import PulsePhoneRuntimeKernel
import PulsePhoneSharedDefinitions

public enum ProductionRuntimeStopBackendError: Error, Equatable, Sendable {
    case invalidState
    case runtimeRequestFailed(code: String)
}

public final class ProductionRuntimeStopBackend: RuntimeStopBackend,
    @unchecked Sendable
{
    private static let shutdownTimeout = MonotonicDuration(
        nanoseconds: 10_000_000_000
    )

    private let runtimeClient: RuntimeClient
    private let runtimeExecutablePath: String
    private let processSystem: any VerifiedRecoveryProcessSystem
    private let poller: any RecoveryPolling
    private let clock = SystemMonotonicClock()
    private let stateLock = NSLock()
    private var bootstrapLock: BootstrapLock?
    private var eofReceipt: RuntimeSocketEOFReceipt?
    private var recoveryManifest: HelperStateManifest?
    private var shutdownDeadline: MonotonicInstant?

    public init(
        runtimeClient: RuntimeClient,
        runtimeExecutablePath: String,
        processSystem: any VerifiedRecoveryProcessSystem =
            POSIXVerifiedRecoveryProcessSystem(),
        poller: any RecoveryPolling = SystemRecoveryPoller()
    ) {
        self.runtimeClient = runtimeClient
        self.runtimeExecutablePath = runtimeExecutablePath
        self.processSystem = processSystem
        self.poller = poller
    }

    public static func bundled() throws -> ProductionRuntimeStopBackend {
        let appPath = try CanonicalAppPath.resolveCurrentExecutable()
        return ProductionRuntimeStopBackend(
            runtimeClient: try RuntimeClient.bundled(role: .cli),
            runtimeExecutablePath: appPath.bundlePath
                + "/Contents/Helpers/PulsePhoneRuntime"
        )
    }

    public func acquireBootstrapLock(
        canonicalUDID: CanonicalUDID
    ) throws {
        let acquired = try BootstrapLock.acquire(for: canonicalUDID)
        let deadline = try clock.now().advanced(by: Self.shutdownTimeout)
        try stateLock.withLock {
            guard bootstrapLock == nil else {
                throw ProductionRuntimeStopBackendError.invalidState
            }
            bootstrapLock = acquired
            eofReceipt = nil
            recoveryManifest = nil
            shutdownDeadline = deadline
        }
    }

    public func releaseBootstrapLock() {
        stateLock.withLock {
            eofReceipt = nil
            recoveryManifest = nil
            shutdownDeadline = nil
            bootstrapLock = nil
        }
    }

    public func recheck(
        canonicalUDID: CanonicalUDID
    ) throws -> RuntimeStopGenerationState {
        let lock = try requiredBootstrapLock(for: canonicalUDID)
        let classification = try RuntimeGenerationClassifier().classification(
            for: canonicalUDID,
            whileHolding: lock
        )
        switch classification {
        case .absent:
            return .absent
        case .exiting:
            return .exiting
        case .orphanHelpers:
            return .orphanHelpers
        case .identityUnknown:
            if try DeadRuntimeGenerationRecovery(
                processSystem: processSystem
            ).recover(
                canonicalUDID: canonicalUDID,
                runtimeExecutablePath: runtimeExecutablePath,
                whileHolding: lock
            ) == .recovered {
                return .absent
            }
            return try inspectSocketAbsentBusyGeneration(
                canonicalUDID: canonicalUDID
            )
        case .alive:
            do {
                let response = try runtimeClient.health(
                    canonicalUDID: canonicalUDID,
                    activation: .existingOnly
                )
                guard response.result["outcome"]?.stringValue == "succeeded" else {
                    let code = response.result["error"]?.objectValue?["code"]?
                        .stringValue ?? "runtimeFailed"
                    throw ProductionRuntimeStopBackendError.runtimeRequestFailed(
                        code: code
                    )
                }
                return .compatible
            } catch RuntimeClientError.incompatibleRuntime {
                try runtimeClient.probeIncompatibleRuntime(
                    canonicalUDID: canonicalUDID
                )
                return .incompatible
            } catch RuntimeClientError.runtimeStopping {
                return .exiting
            } catch RuntimeClientError.socketUnavailable {
                return .exiting
            }
        }
    }

    public func waitOrRecover(
        canonicalUDID: CanonicalUDID,
        state: RuntimeStopGenerationState
    ) throws -> Bool {
        guard state == .exiting || state == .orphanHelpers else {
            throw ProductionRuntimeStopBackendError.invalidState
        }
        let lock = try requiredBootstrapLock(for: canonicalUDID)
        let manifest: HelperStateManifest
        do {
            manifest = try stateLock.withLock { () throws -> HelperStateManifest in
                if let recoveryManifest { return recoveryManifest }
                return try HelperManifestStore.loadCurrent(
                    canonicalUDID: canonicalUDID
                )
            }
        } catch {
            let classification = try RuntimeGenerationClassifier().classification(
                for: canonicalUDID,
                whileHolding: lock
            )
            return classification == .absent
        }
        let identity = RuntimeRecoveryIdentity(
            executablePath: runtimeExecutablePath,
            pid: manifest.runtimePID,
            processStartIdentity: manifest.runtimeProcessStartIdentity
        )
        do {
            _ = try OrphanRecovery(
                processSystem: processSystem,
                poller: poller
            ).recover(
                runtimeIdentity: identity,
                manifest: manifest,
                runtimeLockIsFree: {
                    do {
                        _ = try RuntimeLock.probe(whileHolding: lock)
                        return true
                    } catch PerUDIDHostLockError.busy(lock: .runtime) {
                        return false
                    }
                }
            )
            return true
        } catch is OrphanRecoveryError {
            return false
        }
    }

    public func requestStop(
        canonicalUDID: CanonicalUDID,
        kind: RuntimeStopRequestKind
    ) throws -> Bool {
        let response: RuntimeStopTransportResponse
        do {
            switch kind {
            case .stopIfIdle:
                response = try runtimeClient.requestStopIfIdle(
                    canonicalUDID: canonicalUDID
                )
            case .retireIfIdle:
                response = try runtimeClient.retireIncompatibleRuntimeIfIdle(
                    canonicalUDID: canonicalUDID
                )
            }
        } catch RuntimeClientError.socketUnavailable,
                RuntimeClientError.runtimeStopping {
            stateLock.withLock { eofReceipt = nil }
            return true
        }
        stateLock.withLock { eofReceipt = response.eofReceipt }
        return response.accepted
    }

    public func waitForSocketEOF(
        canonicalUDID: CanonicalUDID
    ) throws -> Bool {
        let receipt = stateLock.withLock { () -> RuntimeSocketEOFReceipt? in
            defer { eofReceipt = nil }
            return eofReceipt
        }
        guard let eofTimeout = try remainingShutdownTime() else { return false }
        if let receipt, try !receipt.waitForEOF(timeout: eofTimeout) {
            return false
        }
        guard let socketTimeout = try remainingShutdownTime() else { return false }
        return try poller.waitUntil(timeout: socketTimeout) {
            try self.socketIsAbsent(canonicalUDID: canonicalUDID)
        }
    }

    public func probeRuntimeLockReleased(
        canonicalUDID: CanonicalUDID
    ) throws -> Bool {
        let lock = try requiredBootstrapLock(for: canonicalUDID)
        guard let timeout = try remainingShutdownTime() else { return false }
        return try poller.waitUntil(timeout: timeout) {
            do {
                _ = try RuntimeLock.probe(whileHolding: lock)
                return true
            } catch PerUDIDHostLockError.busy(lock: .runtime) {
                return false
            }
        }
    }

    private func inspectSocketAbsentBusyGeneration(
        canonicalUDID: CanonicalUDID
    ) throws -> RuntimeStopGenerationState {
        guard try socketIsAbsent(canonicalUDID: canonicalUDID) else {
            return .identityUnknown
        }
        let manifest: HelperStateManifest
        do {
            manifest = try HelperManifestStore.loadCurrent(
                canonicalUDID: canonicalUDID
            )
        } catch {
            return .identityUnknown
        }
        let identity = RuntimeRecoveryIdentity(
            executablePath: runtimeExecutablePath,
            pid: manifest.runtimePID,
            processStartIdentity: manifest.runtimeProcessStartIdentity
        )
        switch processSystem.observeRuntime(identity) {
        case .verified:
            stateLock.withLock { recoveryManifest = manifest }
            return .exiting
        case .identityMismatch:
            return .identityUnknown
        case .gone:
            var hasLiveHelper = false
            for helper in manifest.helpers {
                let identity = HelperProcessIdentity(
                    pid: helper.pid,
                    processGroupID: helper.processGroupID,
                    processStartIdentity: helper.processStartIdentity,
                    executablePath: helper.executablePath
                )
                switch processSystem.observeHelper(identity) {
                case .verified:
                    hasLiveHelper = true
                case .identityMismatch:
                    return .identityUnknown
                case .gone:
                    continue
                }
            }
            guard hasLiveHelper else { return .identityUnknown }
            stateLock.withLock { recoveryManifest = manifest }
            return .orphanHelpers
        }
    }

    private func requiredBootstrapLock(
        for canonicalUDID: CanonicalUDID
    ) throws -> BootstrapLock {
        try stateLock.withLock {
            guard let bootstrapLock,
                  bootstrapLock.canonicalUDID == canonicalUDID
            else {
                throw ProductionRuntimeStopBackendError.invalidState
            }
            return bootstrapLock
        }
    }

    private func remainingShutdownTime() throws -> MonotonicDuration? {
        let deadline = try stateLock.withLock { () throws -> MonotonicInstant in
            guard let shutdownDeadline else {
                throw ProductionRuntimeStopBackendError.invalidState
            }
            return shutdownDeadline
        }
        let now = clock.now()
        guard now < deadline else { return nil }
        return try deadline.duration(since: now)
    }

    private func socketIsAbsent(
        canonicalUDID: CanonicalUDID
    ) throws -> Bool {
        let path = try RuntimeSocketPath.current(for: canonicalUDID).path
        var metadata = stat()
        if lstat(path, &metadata) == 0 { return false }
        if errno == ENOENT { return true }
        throw ProductionRuntimeStopBackendError.invalidState
    }
}
