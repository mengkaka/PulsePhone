import Darwin
import PulsePhoneHostPaths
import PulsePhoneSharedDefinitions

public enum DeadRuntimeGenerationRecoveryResult: Equatable, Sendable {
    case notRecoverable
    case recovered
}

public struct DeadRuntimeGenerationRecovery: Sendable {
    private let processSystem: any VerifiedRecoveryProcessSystem

    public init(
        processSystem: any VerifiedRecoveryProcessSystem =
            POSIXVerifiedRecoveryProcessSystem()
    ) {
        self.processSystem = processSystem
    }

    public func recover(
        canonicalUDID: CanonicalUDID,
        runtimeExecutablePath: String,
        whileHolding bootstrapLock: BootstrapLock
    ) throws -> DeadRuntimeGenerationRecoveryResult {
        guard bootstrapLock.canonicalUDID == canonicalUDID else {
            return .notRecoverable
        }
        try bootstrapLock.validateStablePathIdentity()

        let runtimeLock: RuntimeLock
        do {
            runtimeLock = try RuntimeLock.probe(whileHolding: bootstrapLock)
        } catch PerUDIDHostLockError.busy(lock: .runtime) {
            return .notRecoverable
        }
        try runtimeLock.validateStablePathIdentity()

        let manifest: HelperStateManifest
        do {
            manifest = try HelperManifestStore.loadCurrent(
                canonicalUDID: canonicalUDID
            )
        } catch {
            return .notRecoverable
        }
        let runtimeIdentity = RuntimeRecoveryIdentity(
            executablePath: runtimeExecutablePath,
            pid: manifest.runtimePID,
            processStartIdentity: manifest.runtimeProcessStartIdentity
        )
        guard processSystem.observeRuntime(runtimeIdentity) == .gone,
              allHelpersAreGone(manifest.helpers)
        else {
            return .notRecoverable
        }

        let socketPath = try RuntimeSocketPath.current(for: canonicalUDID)
        let socketIdentity: RuntimeSocketIdentity?
        do {
            socketIdentity = try RuntimeSocketIdentity.capture(
                path: socketPath.path,
                expectedOwner: geteuid()
            )
        } catch RuntimeListenerError.systemCall(_, let code) where code == ENOENT {
            socketIdentity = nil
        } catch {
            return .notRecoverable
        }

        guard (try? HelperManifestStore.loadCurrent(
            canonicalUDID: canonicalUDID
        )) == manifest,
              processSystem.observeRuntime(runtimeIdentity) == .gone,
              allHelpersAreGone(manifest.helpers)
        else {
            return .notRecoverable
        }
        try runtimeLock.validateStablePathIdentity()

        if let socketIdentity {
            try RuntimeListener.retireStaleSocket(
                for: canonicalUDID,
                expectedIdentity: socketIdentity,
                whileHolding: bootstrapLock
            )
        }
        try HelperManifestStore.removeCurrent(
            canonicalUDID: canonicalUDID,
            matching: manifest
        )
        return .recovered
    }

    private func allHelpersAreGone(_ helpers: [HelperStateRecord]) -> Bool {
        helpers.allSatisfy { helper in
            processSystem.observeHelper(HelperProcessIdentity(
                pid: helper.pid,
                processGroupID: helper.processGroupID,
                processStartIdentity: helper.processStartIdentity,
                executablePath: helper.executablePath
            )) == .gone
        }
    }
}
