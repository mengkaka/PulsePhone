import Darwin

@_silgen_name("_NSGetExecutablePath")
private func dyldExecutablePath(
    _ buffer: UnsafeMutablePointer<CChar>?,
    _ bufferSize: UnsafeMutablePointer<UInt32>
) -> Int32

public struct POSIXHostPathSystem: Sendable {
    private typealias FileControlFunction = @convention(c) (
        Int32,
        Int32,
        UnsafeMutableRawPointer
    ) -> Int32

    public init() {}

    public var effectiveUserID: uid_t {
        geteuid()
    }

    public func currentExecutablePath() throws -> String {
        var capacity: UInt32 = 0
        _ = dyldExecutablePath(nil, &capacity)
        guard capacity > 0 else {
            throw CanonicalAppPathError.currentExecutablePathUnavailable
        }

        var buffer = [CChar](repeating: 0, count: Int(capacity))
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            dyldExecutablePath(pointer.baseAddress, &capacity)
        }
        guard result == 0 else {
            throw CanonicalAppPathError.currentExecutablePathUnavailable
        }
        return Self.stringFromNullTerminatedBuffer(buffer)
    }

    public func realPath(_ path: String) throws -> String {
        guard !path.utf8.contains(0) else {
            throw CanonicalAppPathError.invalidSyntax
        }
        return try resolvedPath(path) {
            CanonicalAppPathError.realpathFailed(errno: $0)
        }
    }

    func openReadOnlyNoFollow(_ path: String) throws -> Int32 {
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CanonicalAppPathError.executableOpenFailed(errno: errno)
        }
        return descriptor
    }

    func openDirectoryNoFollow(_ path: String) throws -> Int32 {
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        guard descriptor >= 0 else {
            throw AnchoredFileSystemError.systemCall(
                operation: "open-directory",
                errno: errno
            )
        }
        return descriptor
    }

    func openDirectoryNoFollow(
        named component: String,
        relativeTo parentDescriptor: Int32
    ) throws -> Int32 {
        let descriptor = Darwin.openat(
            parentDescriptor,
            component,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        guard descriptor >= 0 else {
            throw AnchoredFileSystemError.systemCall(
                operation: "openat-directory",
                errno: errno
            )
        }
        return descriptor
    }

    func openRegularFileNoFollow(
        named component: String,
        relativeTo parentDescriptor: Int32,
        access: AnchoredFileAccess
    ) throws -> Int32 {
        let accessFlag: Int32
        switch access {
        case .readOnly:
            accessFlag = O_RDONLY
        case .writeOnly:
            accessFlag = O_WRONLY
        case .readWrite:
            accessFlag = O_RDWR
        }
        let descriptor = Darwin.openat(
            parentDescriptor,
            component,
            accessFlag | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw AnchoredFileSystemError.systemCall(
                operation: "openat-regular-file",
                errno: errno
            )
        }
        return descriptor
    }

    func createExclusiveRegularFileNoFollow(
        named component: String,
        relativeTo parentDescriptor: Int32,
        mode: mode_t
    ) throws -> Int32 {
        let descriptor = Darwin.openat(
            parentDescriptor,
            component,
            O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            mode
        )
        guard descriptor >= 0 else {
            throw AnchoredFileSystemError.systemCall(
                operation: "openat-create-exclusive",
                errno: errno
            )
        }
        return descriptor
    }

    func closeFileDescriptor(_ descriptor: Int32) {
        _ = Darwin.close(descriptor)
    }

    func path(forFileDescriptor descriptor: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            Self.fileControlFunction()(
                descriptor,
                F_GETPATH,
                UnsafeMutableRawPointer(pointer.baseAddress!)
            )
        }
        guard result == 0 else {
            throw CanonicalAppPathError.executablePathLookupFailed(errno: errno)
        }
        return Self.stringFromNullTerminatedBuffer(buffer)
    }

    func metadata(
        forFileDescriptor descriptor: Int32,
        error makeError: (Int32) -> any Error
    ) throws -> HostNodeMetadata {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw makeError(errno)
        }
        return Self.metadata(from: status)
    }

    func metadataNoFollow(
        atPath path: String,
        error makeError: (Int32) -> any Error
    ) throws -> HostNodeMetadata {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            throw makeError(errno)
        }
        return Self.metadata(from: status)
    }

    func metadataNoFollow(
        named component: String,
        relativeTo parentDescriptor: Int32
    ) throws -> HostNodeMetadata {
        var status = stat()
        guard fstatat(
            parentDescriptor,
            component,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw AnchoredFileSystemError.systemCall(
                operation: "fstatat",
                errno: errno
            )
        }
        return Self.metadata(from: status)
    }

    func createDirectoryIfMissing(
        named component: String,
        relativeTo parentDescriptor: Int32,
        mode: mode_t
    ) throws {
        guard mkdirat(parentDescriptor, component, mode) == 0 else {
            if errno == EEXIST {
                return
            }
            throw AnchoredFileSystemError.systemCall(
                operation: "mkdirat",
                errno: errno
            )
        }
    }

    public func trustedHomeDirectory() throws -> String {
        let userID = effectiveUserID
        let suggestedCapacity = max(1024, Int(sysconf(_SC_GETPW_R_SIZE_MAX)))
        var capacity = suggestedCapacity

        while capacity <= 1 << 20 {
            var record = passwd()
            var result: UnsafeMutablePointer<passwd>?
            var buffer = [CChar](repeating: 0, count: capacity)
            let status = buffer.withUnsafeMutableBufferPointer { pointer in
                getpwuid_r(
                    userID,
                    &record,
                    pointer.baseAddress,
                    pointer.count,
                    &result
                )
            }
            if status == ERANGE {
                capacity *= 2
                continue
            }
            guard status == 0,
                  result != nil,
                  record.pw_uid == userID,
                  let directory = record.pw_dir
            else {
                throw AnchoredFileSystemError.systemCall(
                    operation: "getpwuid_r",
                    errno: status == 0 ? ENOENT : status
                )
            }
            let path = String(cString: directory)
            guard CanonicalAppPath.isCanonicalAbsolutePath(path) else {
                throw AnchoredFileSystemError.unsafeNode(
                    reason: .invalidPathComponent
                )
            }
            return path
        }

        throw AnchoredFileSystemError.systemCall(
            operation: "getpwuid_r",
            errno: ERANGE
        )
    }

    public func openHomeAnchor(
        fileSystem: AnchoredFileSystem? = nil
    ) throws -> AnchoredDirectory {
        let path = try trustedHomeDirectory()
        return try (fileSystem ?? AnchoredFileSystem(system: self)).openDirectory(
            atPath: path,
            expecting: HostNodeExpectation(
                owner: effectiveUserID,
                kind: .directory
            )
        )
    }

    public func openDeveloperImageStoreAnchor() throws -> AnchoredDirectory {
        let fileSystem = AnchoredFileSystem(system: self)
        let home = try openHomeAnchor(fileSystem: fileSystem)
        return try Self.ensureDeveloperImageStoreAnchor(
            inHome: home,
            fileSystem: fileSystem,
            system: self
        )
    }

    static func ensureDeveloperImageStoreAnchor(
        inHome home: AnchoredDirectory,
        fileSystem: AnchoredFileSystem,
        system: POSIXHostPathSystem
    ) throws -> AnchoredDirectory {
        let owner = system.effectiveUserID
        let library = try fileSystem.openDirectory(
            named: "Library",
            relativeTo: home,
            expecting: HostNodeExpectation(owner: owner, kind: .directory)
        )
        try system.createDirectoryIfMissing(
            named: "Application Support",
            relativeTo: library.fileDescriptor,
            mode: 0o700
        )
        let applicationSupport = try fileSystem.openDirectory(
            named: "Application Support",
            relativeTo: library,
            expecting: HostNodeExpectation(owner: owner, kind: .directory)
        )
        return try Self.ensureDeveloperImageStoreAnchor(
            in: applicationSupport,
            fileSystem: fileSystem,
            owner: owner
        )
    }

    static func ensureDeveloperImageStoreAnchor(
        in applicationSupport: AnchoredDirectory,
        fileSystem: AnchoredFileSystem,
        owner: uid_t
    ) throws -> AnchoredDirectory {
        let product = try fileSystem.ensureDirectory(
            named: "PulsePhone",
            relativeTo: applicationSupport,
            owner: owner
        )
        return try fileSystem.ensureDirectory(
            named: "DeveloperImages",
            relativeTo: product,
            owner: owner
        )
    }

    public func openTemporaryBaseAnchor(
        fileSystem: AnchoredFileSystem? = nil
    ) throws -> AnchoredDirectory {
        let fileSystem = fileSystem ?? AnchoredFileSystem(system: self)
        try validateSystemTemporaryAlias()
        let privateTemporary = try fileSystem.openDirectory(
            atPath: "/private/tmp",
            expecting: HostNodeExpectation(
                owner: 0,
                kind: .directory,
                mode: 0o1777
            )
        )
        return try fileSystem.ensureDirectory(
            named: "pulsephone-\(effectiveUserID)",
            relativeTo: privateTemporary,
            owner: effectiveUserID,
            mode: 0o700
        )
    }

    public func makeHostPathLayout() throws -> HostPathLayoutV1 {
        try HostPathLayoutV1(
            effectiveUserID: effectiveUserID,
            trustedHomeDirectory: trustedHomeDirectory()
        )
    }

    private func validateSystemTemporaryAlias() throws {
        let metadata = try metadataNoFollow(
            atPath: "/tmp",
            error: {
                AnchoredFileSystemError.systemCall(
                    operation: "lstat-tmp",
                    errno: $0
                )
            }
        )
        guard metadata.owner == 0 else {
            throw AnchoredFileSystemError.unsafeNode(
                reason: .wrongOwner(expected: 0, actual: metadata.owner)
            )
        }
        guard metadata.kind == HostNodeKind.symbolicLink else {
            throw AnchoredFileSystemError.unsafeNode(
                reason: .wrongKind(
                    expected: .symbolicLink,
                    actual: metadata.kind
                )
            )
        }

        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            readlink("/tmp", pointer.baseAddress, pointer.count)
        }
        guard length >= 0 else {
            throw AnchoredFileSystemError.systemCall(
                operation: "readlink-tmp",
                errno: errno
            )
        }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        let target = String(decoding: bytes, as: UTF8.self)
        guard target == "private/tmp" || target == "/private/tmp" else {
            throw AnchoredFileSystemError.unsafeNode(
                reason: .identityMismatch
            )
        }
        let resolvedTemporary = try resolvedPath("/tmp") {
            AnchoredFileSystemError.systemCall(
                operation: "realpath-tmp",
                errno: $0
            )
        }
        guard resolvedTemporary == "/private/tmp" else {
            throw AnchoredFileSystemError.unsafeNode(
                reason: .identityMismatch
            )
        }
    }

    private static func metadata(from status: stat) -> HostNodeMetadata {
        HostNodeMetadata(
            identity: HostNodeIdentity(
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino)
            ),
            owner: status.st_uid,
            kind: kind(from: status.st_mode),
            mode: status.st_mode & mode_t(0o7777),
            linkCount: UInt64(status.st_nlink),
            byteCount: status.st_size < 0 ? 0 : UInt64(status.st_size)
        )
    }

    private static func kind(from mode: mode_t) -> HostNodeKind {
        switch mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR):
            .directory
        case mode_t(S_IFREG):
            .regularFile
        case mode_t(S_IFSOCK):
            .socket
        case mode_t(S_IFLNK):
            .symbolicLink
        default:
            .other
        }
    }

    private static func stringFromNullTerminatedBuffer(
        _ buffer: [CChar]
    ) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func resolvedPath(
        _ path: String,
        error makeError: (Int32) -> any Error
    ) throws -> String {
        errno = 0
        guard let resolved = path.withCString({ Darwin.realpath($0, nil) }) else {
            throw makeError(errno)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func fileControlFunction() -> FileControlFunction {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "__fcntl")
        else {
            preconditionFailure("Darwin __fcntl symbol is unavailable")
        }
        let function = unsafeBitCast(symbol, to: FileControlFunction.self)
        dlclose(handle)
        return function
    }
}
