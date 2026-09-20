import Darwin
import Dispatch
import Foundation
import PulsePhoneHostPaths
import PulsePhoneSharedDefinitions

public enum RuntimeListenerError: Error, Equatable, Sendable {
    case targetLockMismatch
    case invalidSocketPath
    case unsafeBaseDirectory
    case unsafeSocketNode
    case socketIdentityMismatch
    case alreadyShutdown
    case systemCall(operation: String, errno: Int32)
}

public final class RuntimeListener: @unchecked Sendable {
    public static let listenBacklog: Int32 = 16

    public let canonicalUDID: CanonicalUDID
    public let socketPath: String
    public let socketIdentity: RuntimeSocketIdentity

    private let component: String
    private let baseDirectory: RuntimeSocketBaseDirectory
    private let runtimeLock: RuntimeLock
    private let watch: RuntimeSocketWatch
    private let stateLock = NSLock()
    private var listenerDescriptor: Int32
    private var shutdown = false

    private init(
        canonicalUDID: CanonicalUDID,
        socketPath: String,
        component: String,
        socketIdentity: RuntimeSocketIdentity,
        baseDirectory: RuntimeSocketBaseDirectory,
        runtimeLock: RuntimeLock,
        watch: RuntimeSocketWatch,
        listenerDescriptor: Int32
    ) {
        self.canonicalUDID = canonicalUDID
        self.socketPath = socketPath
        self.component = component
        self.socketIdentity = socketIdentity
        self.baseDirectory = baseDirectory
        self.runtimeLock = runtimeLock
        self.watch = watch
        self.listenerDescriptor = listenerDescriptor
    }

    deinit {
        try? shutdownExpected()
    }

    public static func bind(
        for canonicalUDID: CanonicalUDID,
        whileHolding runtimeLock: RuntimeLock,
        watchQueue: DispatchQueue = DispatchQueue(
            label: "com.pulsephone.runtime-socket-watch"
        ),
        onWatchFailure: @escaping @Sendable (RuntimeSocketWatchFailure) -> Void
    ) throws -> RuntimeListener {
        let runtimePath = try RuntimeSocketPath.current(for: canonicalUDID)
        let basePath = String(
            runtimePath.path.dropLast(runtimePath.component.utf8.count + 1)
        )
        return try bind(
            for: canonicalUDID,
            whileHolding: runtimeLock,
            socketPath: runtimePath.path,
            component: runtimePath.component,
            baseDirectoryPath: basePath,
            watchQueue: watchQueue,
            onWatchFailure: onWatchFailure
        )
    }

    public func withUnsafeListeningSocket<Result>(
        _ body: (Int32) throws -> Result
    ) throws -> Result {
        stateLock.lock()
        guard !shutdown else {
            stateLock.unlock()
            throw RuntimeListenerError.alreadyShutdown
        }
        let descriptor = listenerDescriptor
        stateLock.unlock()
        return try body(descriptor)
    }

    public func shutdownExpected() throws {
        stateLock.lock()
        guard !shutdown else {
            stateLock.unlock()
            return
        }
        shutdown = true
        let descriptor = listenerDescriptor
        listenerDescriptor = -1
        stateLock.unlock()

        watch.beginExpectedRemoval()
        watch.cancel()
        _ = Darwin.close(descriptor)
        try baseDirectory.removeSocket(
            component: component,
            expectedIdentity: socketIdentity
        )
    }

    public static func retireStaleSocket(
        for canonicalUDID: CanonicalUDID,
        expectedIdentity: RuntimeSocketIdentity,
        whileHolding bootstrapLock: BootstrapLock
    ) throws {
        guard bootstrapLock.canonicalUDID == canonicalUDID else {
            throw RuntimeListenerError.targetLockMismatch
        }
        try bootstrapLock.validateStablePathIdentity()
        let runtimePath = try RuntimeSocketPath.current(for: canonicalUDID)
        let basePath = String(
            runtimePath.path.dropLast(runtimePath.component.utf8.count + 1)
        )
        let baseDirectory = try RuntimeSocketBaseDirectory.open(
            path: basePath,
            expectedOwner: geteuid()
        )
        try baseDirectory.removeSocket(
            component: runtimePath.component,
            expectedIdentity: expectedIdentity
        )
    }

    static func bind(
        for canonicalUDID: CanonicalUDID,
        whileHolding runtimeLock: RuntimeLock,
        socketPath: String,
        component: String,
        baseDirectoryPath: String,
        watchQueue: DispatchQueue,
        onWatchFailure: @escaping @Sendable (RuntimeSocketWatchFailure) -> Void,
        afterStagingBind: () throws -> Void = {}
    ) throws -> RuntimeListener {
        guard runtimeLock.canonicalUDID == canonicalUDID else {
            throw RuntimeListenerError.targetLockMismatch
        }
        try runtimeLock.validateStablePathIdentity()
        guard socketPath == baseDirectoryPath + "/" + component,
              component == canonicalUDID.domainSeparatedHash + ".sock"
        else {
            throw RuntimeListenerError.invalidSocketPath
        }
        try HostPathLayoutV1.validateUnixDomainSocketPath(socketPath)
        let baseDirectory = try RuntimeSocketBaseDirectory.open(
            path: baseDirectoryPath,
            expectedOwner: geteuid()
        )
        try baseDirectory.removeStaleSocketIfPresent(component: component)
        let stagingComponent = canonicalUDID.domainSeparatedHash + ".bind"
        let stagingPath = baseDirectoryPath + "/" + stagingComponent
        // Only the generation lease holder touches this unpublished endpoint.
        do {
            let stale = try RuntimeSocketIdentity.captureBoundNode(
                path: stagingPath, expectedOwner: geteuid()
            )
            try baseDirectory.removeBoundSocket(
                component: stagingComponent, expectedIdentity: stale
            )
        } catch RuntimeListenerError.systemCall(_, let code) where code == ENOENT {
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw RuntimeListenerError.systemCall(
                operation: "socket-runtime-listener",
                errno: errno
            )
        }
        var boundIdentity: RuntimeSocketIdentity?
        var boundComponent = stagingComponent
        do {
            try setCloseOnExec(descriptor)
            var address = try makeAddress(path: stagingPath)
            let addressLength = socklen_t(address.sun_len)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        descriptor,
                        $0,
                        addressLength
                    )
                }
            }
            guard bindResult == 0 else {
                throw RuntimeListenerError.systemCall(
                    operation: "bind-runtime-listener",
                    errno: errno
                )
            }
            boundIdentity = try RuntimeSocketIdentity.captureBoundNode(
                path: stagingPath,
                expectedOwner: geteuid()
            )
            try afterStagingBind()
            guard fchmodat(
                baseDirectory.fileDescriptor,
                stagingComponent,
                0o600,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw RuntimeListenerError.systemCall(
                    operation: "chmod-runtime-socket",
                    errno: errno
                )
            }
            let identity = try RuntimeSocketIdentity.capture(
                path: stagingPath,
                expectedOwner: geteuid()
            )
            guard identity.device == boundIdentity?.device,
                  identity.inode == boundIdentity?.inode
            else {
                throw RuntimeListenerError.socketIdentityMismatch
            }
            guard Darwin.listen(descriptor, listenBacklog) == 0 else {
                throw RuntimeListenerError.systemCall(
                    operation: "listen-runtime-socket",
                    errno: errno
                )
            }
            try runtimeLock.validateStablePathIdentity()
            guard renameatx_np(
                baseDirectory.fileDescriptor, stagingComponent,
                baseDirectory.fileDescriptor, component, UInt32(RENAME_EXCL)
            ) == 0 else {
                throw RuntimeListenerError.systemCall(
                    operation: "publish-runtime-socket", errno: errno
                )
            }
            boundComponent = component
            let watch = try RuntimeSocketWatch(
                baseDirectoryPath: baseDirectoryPath,
                socketPath: socketPath,
                socketIdentity: identity,
                expectedOwner: geteuid(),
                queue: watchQueue,
                onFailure: onWatchFailure
            )
            return RuntimeListener(
                canonicalUDID: canonicalUDID,
                socketPath: socketPath,
                component: component,
                socketIdentity: identity,
                baseDirectory: baseDirectory,
                runtimeLock: runtimeLock,
                watch: watch,
                listenerDescriptor: descriptor
            )
        } catch {
            _ = Darwin.close(descriptor)
            if let boundIdentity {
                try? baseDirectory.removeBoundSocket(
                    component: boundComponent,
                    expectedIdentity: boundIdentity
                )
            }
            throw error
        }
    }

    func simulateWatcherInvalidationForTesting() {
        watch.simulateWatcherInvalidationForTesting()
    }

    private static func makeAddress(path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)!
        let addressLength = pathOffset + bytes.count + 1
        guard addressLength <= MemoryLayout<sockaddr_un>.size,
              addressLength <= Int(UInt8.max)
        else {
            throw RuntimeListenerError.invalidSocketPath
        }
        var address = sockaddr_un()
        address.sun_len = UInt8(addressLength)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    private static func setCloseOnExec(_ descriptor: Int32) throws {
        typealias FileControlFunction = @convention(c) (
            Int32,
            Int32,
            Int32
        ) -> Int32
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "__fcntl")
        else {
            throw RuntimeListenerError.systemCall(
                operation: "resolve-fcntl",
                errno: ENOSYS
            )
        }
        defer { dlclose(handle) }
        let function = unsafeBitCast(symbol, to: FileControlFunction.self)
        guard function(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw RuntimeListenerError.systemCall(
                operation: "fcntl-cloexec-runtime-listener",
                errno: errno
            )
        }
    }
}

private final class RuntimeSocketBaseDirectory: @unchecked Sendable {
    let path: String
    let expectedOwner: uid_t
    let fileDescriptor: Int32
    private let device: UInt64
    private let inode: UInt64

    private init(
        path: String,
        expectedOwner: uid_t,
        fileDescriptor: Int32,
        device: UInt64,
        inode: UInt64
    ) {
        self.path = path
        self.expectedOwner = expectedOwner
        self.fileDescriptor = fileDescriptor
        self.device = device
        self.inode = inode
    }

    deinit {
        _ = Darwin.close(fileDescriptor)
    }

    static func open(
        path: String,
        expectedOwner: uid_t
    ) throws -> RuntimeSocketBaseDirectory {
        var before = stat()
        guard lstat(path, &before) == 0,
              before.st_uid == expectedOwner,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              before.st_mode & mode_t(0o7777) == mode_t(0o700)
        else {
            throw RuntimeListenerError.unsafeBaseDirectory
        }
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw RuntimeListenerError.systemCall(
                operation: "open-runtime-base",
                errno: errno
            )
        }
        do {
            var opened = stat()
            var after = stat()
            guard fstat(descriptor, &opened) == 0,
                  lstat(path, &after) == 0,
                  before.st_dev == opened.st_dev,
                  before.st_ino == opened.st_ino,
                  opened.st_dev == after.st_dev,
                  opened.st_ino == after.st_ino
            else {
                throw RuntimeListenerError.unsafeBaseDirectory
            }
            return RuntimeSocketBaseDirectory(
                path: path,
                expectedOwner: expectedOwner,
                fileDescriptor: descriptor,
                device: UInt64(opened.st_dev),
                inode: UInt64(opened.st_ino)
            )
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    func removeStaleSocketIfPresent(component: String) throws {
        do {
            try removeSocket(component: component)
        } catch RuntimeListenerError.systemCall(_, let code) where code == ENOENT {
            return
        }
    }

    func removeSocket(
        component: String,
        expectedIdentity: RuntimeSocketIdentity? = nil
    ) throws {
        try validateIdentity()
        var status = stat()
        guard fstatat(
            fileDescriptor,
            component,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw RuntimeListenerError.systemCall(
                operation: "fstatat-runtime-socket",
                errno: errno
            )
        }
        guard status.st_uid == expectedOwner,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              status.st_mode & mode_t(0o7777) == mode_t(0o600)
        else {
            throw RuntimeListenerError.unsafeSocketNode
        }
        if let expectedIdentity {
            guard UInt64(status.st_dev) == expectedIdentity.device,
                  UInt64(status.st_ino) == expectedIdentity.inode
            else {
                throw RuntimeListenerError.socketIdentityMismatch
            }
        }
        guard unlinkat(fileDescriptor, component, 0) == 0 else {
            throw RuntimeListenerError.systemCall(
                operation: "unlinkat-runtime-socket",
                errno: errno
            )
        }
    }

    func removeBoundSocket(
        component: String,
        expectedIdentity: RuntimeSocketIdentity
    ) throws {
        try validateIdentity()
        var status = stat()
        guard fstatat(
            fileDescriptor,
            component,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw RuntimeListenerError.systemCall(
                operation: "fstatat-bound-runtime-socket",
                errno: errno
            )
        }
        guard status.st_uid == expectedOwner,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              UInt64(status.st_dev) == expectedIdentity.device,
              UInt64(status.st_ino) == expectedIdentity.inode
        else {
            throw RuntimeListenerError.socketIdentityMismatch
        }
        guard unlinkat(fileDescriptor, component, 0) == 0 else {
            throw RuntimeListenerError.systemCall(
                operation: "unlinkat-bound-runtime-socket",
                errno: errno
            )
        }
    }

    private func validateIdentity() throws {
        var status = stat()
        guard fstat(fileDescriptor, &status) == 0,
              UInt64(status.st_dev) == device,
              UInt64(status.st_ino) == inode,
              status.st_uid == expectedOwner,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              status.st_mode & mode_t(0o7777) == mode_t(0o700)
        else {
            throw RuntimeListenerError.unsafeBaseDirectory
        }
    }
}
