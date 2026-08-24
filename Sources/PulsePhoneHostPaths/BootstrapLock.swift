import Darwin
import PulsePhoneSharedDefinitions

public enum PerUDIDHostLockKind: String, Equatable, Sendable {
    case bootstrap
    case runtime
}

public enum HostLockAcquisition: Equatable, Sendable {
    case blocking
    case nonBlocking
}

public enum PerUDIDHostLockError: Error, Equatable, Sendable {
    case busy(lock: PerUDIDHostLockKind)
    case systemCall(operation: String, errno: Int32)
}

public final class BootstrapLock: @unchecked Sendable {
    public let canonicalUDID: CanonicalUDID
    public let path: String
    public var identity: HostNodeIdentity { lockFile.identity }

    let baseDirectory: AnchoredDirectory
    let system: POSIXHostPathSystem
    private let lockFile: StableLockFile

    private init(
        canonicalUDID: CanonicalUDID,
        path: String,
        baseDirectory: AnchoredDirectory,
        system: POSIXHostPathSystem,
        lockFile: StableLockFile
    ) {
        self.canonicalUDID = canonicalUDID
        self.path = path
        self.baseDirectory = baseDirectory
        self.system = system
        self.lockFile = lockFile
    }

    public static func acquire(
        for canonicalUDID: CanonicalUDID,
        acquisition: HostLockAcquisition = .blocking,
        system: POSIXHostPathSystem = POSIXHostPathSystem()
    ) throws -> BootstrapLock {
        let baseDirectory = try system.openTemporaryBaseAnchor()
        return try acquire(
            for: canonicalUDID,
            path: logicalTemporaryBasePath(system: system) + "/"
                + canonicalUDID.domainSeparatedHash + ".bootstrap.lock",
            baseDirectory: baseDirectory,
            acquisition: acquisition,
            system: system
        )
    }

    public func validateStablePathIdentity() throws {
        try lockFile.validateStablePathIdentity()
    }

    static func acquire(
        for canonicalUDID: CanonicalUDID,
        path: String? = nil,
        baseDirectory: AnchoredDirectory,
        acquisition: HostLockAcquisition = .blocking,
        system: POSIXHostPathSystem = POSIXHostPathSystem()
    ) throws -> BootstrapLock {
        let component = canonicalUDID.domainSeparatedHash + ".bootstrap.lock"
        let logicalPath = path ?? baseDirectory.logicalPath + "/" + component
        let file = try StableLockFile.acquire(
            kind: .bootstrap,
            component: component,
            logicalPath: logicalPath,
            baseDirectory: baseDirectory,
            owner: system.effectiveUserID,
            acquisition: acquisition,
            system: system
        )
        return BootstrapLock(
            canonicalUDID: canonicalUDID,
            path: logicalPath,
            baseDirectory: baseDirectory,
            system: system,
            lockFile: file
        )
    }

    private static func logicalTemporaryBasePath(
        system: POSIXHostPathSystem
    ) -> String {
        "/tmp/pulsephone-\(system.effectiveUserID)"
    }
}

final class StableLockFile: @unchecked Sendable {
    static let mode: mode_t = 0o600

    let kind: PerUDIDHostLockKind
    let component: String
    let logicalPath: String
    let identity: HostNodeIdentity
    let baseDirectory: AnchoredDirectory
    let system: POSIXHostPathSystem
    private let fileDescriptor: Int32

    private init(
        kind: PerUDIDHostLockKind,
        component: String,
        logicalPath: String,
        identity: HostNodeIdentity,
        baseDirectory: AnchoredDirectory,
        system: POSIXHostPathSystem,
        fileDescriptor: Int32
    ) {
        self.kind = kind
        self.component = component
        self.logicalPath = logicalPath
        self.identity = identity
        self.baseDirectory = baseDirectory
        self.system = system
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        // An inherited Helper FD shares this lock; explicit LOCK_UN would release both.
        _ = Darwin.close(fileDescriptor)
    }

    static func acquire(
        kind: PerUDIDHostLockKind,
        component: String,
        logicalPath: String,
        baseDirectory: AnchoredDirectory,
        owner: uid_t,
        acquisition: HostLockAcquisition,
        system: POSIXHostPathSystem
    ) throws -> StableLockFile {
        let descriptor = try openOrCreate(
            component: component,
            baseDirectory: baseDirectory,
            owner: owner,
            system: system
        )
        do {
            try acquireLock(descriptor, kind: kind, acquisition: acquisition)
            let metadata = try validateDescriptorAndPath(
                descriptor,
                component: component,
                baseDirectory: baseDirectory,
                owner: owner,
                system: system
            )
            return StableLockFile(
                kind: kind,
                component: component,
                logicalPath: logicalPath,
                identity: metadata.identity,
                baseDirectory: baseDirectory,
                system: system,
                fileDescriptor: descriptor
            )
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    func validateStablePathIdentity() throws {
        let metadata = try Self.validateDescriptorAndPath(
            fileDescriptor,
            component: component,
            baseDirectory: baseDirectory,
            owner: system.effectiveUserID,
            system: system
        )
        guard metadata.identity == identity else {
            throw AnchoredFileSystemError.unsafeNode(reason: .identityMismatch)
        }
    }

    func duplicateForChildInheritance() throws -> Int32 {
        try validateStablePathIdentity()
        let descriptor = Darwin.dup(fileDescriptor)
        guard descriptor >= 0 else {
            throw PerUDIDHostLockError.systemCall(
                operation: "dup-lock-for-child",
                errno: errno
            )
        }
        return descriptor
    }

    private static func openOrCreate(
        component: String,
        baseDirectory: AnchoredDirectory,
        owner: uid_t,
        system: POSIXHostPathSystem
    ) throws -> Int32 {
        do {
            return try openExisting(
                component: component,
                baseDirectory: baseDirectory,
                owner: owner,
                system: system
            )
        } catch AnchoredFileSystemError.systemCall(_, let code) where code == ENOENT {
            do {
                let descriptor = try system.createExclusiveRegularFileNoFollow(
                    named: component,
                    relativeTo: baseDirectory.fileDescriptor,
                    mode: mode
                )
                do {
                    // Only a node created by this call may be normalized to the frozen mode.
                    guard fchmod(descriptor, mode) == 0 else {
                        throw PerUDIDHostLockError.systemCall(
                            operation: "fchmod-created-lock",
                            errno: errno
                        )
                    }
                    _ = try validateDescriptorAndPath(
                        descriptor,
                        component: component,
                        baseDirectory: baseDirectory,
                        owner: owner,
                        system: system
                    )
                    return descriptor
                } catch {
                    _ = Darwin.close(descriptor)
                    throw error
                }
            } catch AnchoredFileSystemError.systemCall(_, let code) where code == EEXIST {
                return try openExisting(
                    component: component,
                    baseDirectory: baseDirectory,
                    owner: owner,
                    system: system
                )
            }
        }
    }

    private static func openExisting(
        component: String,
        baseDirectory: AnchoredDirectory,
        owner: uid_t,
        system: POSIXHostPathSystem
    ) throws -> Int32 {
        let before = try system.metadataNoFollow(
            named: component,
            relativeTo: baseDirectory.fileDescriptor
        )
        try validate(before, owner: owner)
        let descriptor = try system.openRegularFileNoFollow(
            named: component,
            relativeTo: baseDirectory.fileDescriptor,
            access: .readWrite
        )
        do {
            _ = try validateDescriptorAndPath(
                descriptor,
                component: component,
                baseDirectory: baseDirectory,
                owner: owner,
                expectedIdentity: before.identity,
                system: system
            )
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func validateDescriptorAndPath(
        _ descriptor: Int32,
        component: String,
        baseDirectory: AnchoredDirectory,
        owner: uid_t,
        expectedIdentity: HostNodeIdentity? = nil,
        system: POSIXHostPathSystem
    ) throws -> HostNodeMetadata {
        let opened = try system.metadata(
            forFileDescriptor: descriptor,
            error: {
                PerUDIDHostLockError.systemCall(
                    operation: "fstat-lock",
                    errno: $0
                )
            }
        )
        try validate(opened, owner: owner)
        let pathNode = try system.metadataNoFollow(
            named: component,
            relativeTo: baseDirectory.fileDescriptor
        )
        try validate(pathNode, owner: owner)
        guard opened.identity == pathNode.identity,
              expectedIdentity == nil || expectedIdentity == opened.identity
        else {
            throw AnchoredFileSystemError.unsafeNode(reason: .identityMismatch)
        }
        return opened
    }

    private static func validate(
        _ metadata: HostNodeMetadata,
        owner: uid_t
    ) throws {
        guard metadata.kind != .symbolicLink else {
            throw AnchoredFileSystemError.unsafeNode(reason: .symbolicLink)
        }
        guard metadata.owner == owner else {
            throw AnchoredFileSystemError.unsafeNode(
                reason: .wrongOwner(expected: owner, actual: metadata.owner)
            )
        }
        guard metadata.kind == .regularFile else {
            throw AnchoredFileSystemError.unsafeNode(
                reason: .wrongKind(expected: .regularFile, actual: metadata.kind)
            )
        }
        guard metadata.mode == mode else {
            throw AnchoredFileSystemError.unsafeNode(
                reason: .wrongMode(expected: mode, actual: metadata.mode)
            )
        }
    }

    private static func acquireLock(
        _ descriptor: Int32,
        kind: PerUDIDHostLockKind,
        acquisition: HostLockAcquisition
    ) throws {
        let operation = LOCK_EX | (acquisition == .nonBlocking ? LOCK_NB : 0)
        while flock(descriptor, operation) != 0 {
            let code = errno
            if code == EINTR {
                continue
            }
            if acquisition == .nonBlocking,
               code == EWOULDBLOCK || code == EAGAIN
            {
                throw PerUDIDHostLockError.busy(lock: kind)
            }
            throw PerUDIDHostLockError.systemCall(
                operation: "flock-\(kind.rawValue)",
                errno: code
            )
        }
    }
}
