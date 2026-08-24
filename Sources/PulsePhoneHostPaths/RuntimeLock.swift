import Darwin
import PulsePhoneSharedDefinitions

public final class RuntimeLock: @unchecked Sendable {
    public let canonicalUDID: CanonicalUDID
    public let path: String
    public var identity: HostNodeIdentity { lockFile.identity }

    private let lockFile: StableLockFile

    private init(
        canonicalUDID: CanonicalUDID,
        path: String,
        lockFile: StableLockFile
    ) {
        self.canonicalUDID = canonicalUDID
        self.path = path
        self.lockFile = lockFile
    }

    public static func acquireForRuntimeStartup(
        for canonicalUDID: CanonicalUDID,
        system: POSIXHostPathSystem = POSIXHostPathSystem()
    ) throws -> RuntimeLock {
        let baseDirectory = try system.openTemporaryBaseAnchor()
        return try acquire(
            for: canonicalUDID,
            path: logicalTemporaryBasePath(system: system) + "/"
                + canonicalUDID.domainSeparatedHash + ".runtime.lock",
            baseDirectory: baseDirectory,
            acquisition: .nonBlocking,
            system: system
        )
    }

    public static func probe(
        whileHolding bootstrapLock: BootstrapLock
    ) throws -> RuntimeLock {
        let bootstrapSuffix = ".bootstrap.lock"
        let pathPrefix = bootstrapLock.path.dropLast(bootstrapSuffix.count)
        return try acquire(
            for: bootstrapLock.canonicalUDID,
            path: String(pathPrefix) + ".runtime.lock",
            baseDirectory: bootstrapLock.baseDirectory,
            acquisition: .nonBlocking,
            system: bootstrapLock.system
        )
    }

    public func validateStablePathIdentity() throws {
        try lockFile.validateStablePathIdentity()
    }

    public func duplicateForChildInheritance() throws -> Int32 {
        try lockFile.duplicateForChildInheritance()
    }

    static func acquire(
        for canonicalUDID: CanonicalUDID,
        path: String? = nil,
        baseDirectory: AnchoredDirectory,
        acquisition: HostLockAcquisition = .nonBlocking,
        system: POSIXHostPathSystem = POSIXHostPathSystem()
    ) throws -> RuntimeLock {
        let component = canonicalUDID.domainSeparatedHash + ".runtime.lock"
        let logicalPath = path ?? baseDirectory.logicalPath + "/" + component
        let file = try StableLockFile.acquire(
            kind: .runtime,
            component: component,
            logicalPath: logicalPath,
            baseDirectory: baseDirectory,
            owner: system.effectiveUserID,
            acquisition: acquisition,
            system: system
        )
        return RuntimeLock(
            canonicalUDID: canonicalUDID,
            path: logicalPath,
            lockFile: file
        )
    }

    private static func logicalTemporaryBasePath(
        system: POSIXHostPathSystem
    ) -> String {
        "/tmp/pulsephone-\(system.effectiveUserID)"
    }
}
