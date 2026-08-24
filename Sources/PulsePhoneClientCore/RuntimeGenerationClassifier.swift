import Darwin
import PulsePhoneHostPaths
import PulsePhoneSharedDefinitions

public enum RuntimeSocketObservation: Equatable, Sendable {
    case absent
    case trusted
    case untrusted
}

public enum RuntimeLockObservation: Equatable, Sendable {
    case free
    case busy
}

public enum VerifiedRuntimeProcessObservation: Equatable, Sendable {
    case alive
    case gone
    case identityUnknown
}

public enum VerifiedHelperProcessObservation: Equatable, Sendable {
    case none
    case alive
    case identityUnknown
}

public struct RuntimeGenerationSnapshot: Equatable, Sendable {
    public let socket: RuntimeSocketObservation
    public let runtimeLock: RuntimeLockObservation
    public let runtimeProcess: VerifiedRuntimeProcessObservation
    public let helperProcesses: VerifiedHelperProcessObservation

    public init(
        socket: RuntimeSocketObservation,
        runtimeLock: RuntimeLockObservation,
        runtimeProcess: VerifiedRuntimeProcessObservation,
        helperProcesses: VerifiedHelperProcessObservation
    ) {
        self.socket = socket
        self.runtimeLock = runtimeLock
        self.runtimeProcess = runtimeProcess
        self.helperProcesses = helperProcesses
    }
}

public enum RuntimeGenerationClassification: String, Equatable, Sendable {
    case absent
    case alive
    case exiting
    case orphanHelpers
    case identityUnknown
}

public protocol RuntimeGenerationObserving: Sendable {
    func classification(
        for canonicalUDID: CanonicalUDID,
        whileHolding bootstrapLock: BootstrapLock
    ) throws -> RuntimeGenerationClassification
}

public struct RuntimeGenerationClassifier: RuntimeGenerationObserving, Sendable {
    public init() {}

    public static func classify(
        _ snapshot: RuntimeGenerationSnapshot
    ) -> RuntimeGenerationClassification {
        if snapshot.socket == .untrusted {
            return .identityUnknown
        }
        if snapshot.socket == .trusted {
            return snapshot.runtimeLock == .busy ? .alive : .identityUnknown
        }
        if snapshot.runtimeLock == .free {
            return .absent
        }

        switch (snapshot.runtimeProcess, snapshot.helperProcesses) {
        case (.alive, _):
            return .exiting
        case (.gone, .alive):
            return .orphanHelpers
        case (.gone, .none),
             (.gone, .identityUnknown),
             (.identityUnknown, _):
            return .identityUnknown
        }
    }

    public func classification(
        for canonicalUDID: CanonicalUDID,
        whileHolding bootstrapLock: BootstrapLock
    ) throws -> RuntimeGenerationClassification {
        let socket = observeSocket(for: canonicalUDID)
        let runtimeLock: RuntimeLockObservation
        do {
            _ = try RuntimeLock.probe(whileHolding: bootstrapLock)
            runtimeLock = .free
        } catch PerUDIDHostLockError.busy(lock: .runtime) {
            runtimeLock = .busy
        }
        return Self.classify(
            RuntimeGenerationSnapshot(
                socket: socket,
                runtimeLock: runtimeLock,
                runtimeProcess: .identityUnknown,
                helperProcesses: .identityUnknown
            )
        )
    }

    private func observeSocket(
        for canonicalUDID: CanonicalUDID
    ) -> RuntimeSocketObservation {
        let path: String
        do {
            path = try RuntimeSocketPath.current(for: canonicalUDID).path
        } catch {
            return .untrusted
        }
        var status = stat()
        guard lstat(path, &status) == 0 else {
            return errno == ENOENT ? .absent : .untrusted
        }
        guard status.st_uid == geteuid(),
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              status.st_mode & mode_t(0o7777) == mode_t(0o600)
        else {
            return .untrusted
        }
        return .trusted
    }
}
