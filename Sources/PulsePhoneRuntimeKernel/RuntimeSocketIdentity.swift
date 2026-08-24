import Darwin

public struct RuntimeSocketIdentity: Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let owner: uid_t
    public let mode: mode_t

    public init(
        device: UInt64,
        inode: UInt64,
        owner: uid_t,
        mode: mode_t
    ) {
        self.device = device
        self.inode = inode
        self.owner = owner
        self.mode = mode
    }

    static func capture(
        path: String,
        expectedOwner: uid_t
    ) throws -> RuntimeSocketIdentity {
        let identity = try captureBoundNode(
            path: path,
            expectedOwner: expectedOwner
        )
        guard identity.mode == mode_t(0o600) else {
            throw RuntimeListenerError.unsafeSocketNode
        }
        return identity
    }

    static func captureBoundNode(
        path: String,
        expectedOwner: uid_t
    ) throws -> RuntimeSocketIdentity {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            throw RuntimeListenerError.systemCall(
                operation: "lstat-runtime-socket",
                errno: errno
            )
        }
        guard status.st_uid == expectedOwner,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK)
        else {
            throw RuntimeListenerError.unsafeSocketNode
        }
        return RuntimeSocketIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            owner: status.st_uid,
            mode: status.st_mode & mode_t(0o7777)
        )
    }

    func validation(
        path: String,
        expectedOwner: uid_t
    ) -> RuntimeSocketIdentityValidation {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            return errno == ENOENT ? .missing : .unsafe
        }
        guard status.st_uid == expectedOwner,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              status.st_mode & mode_t(0o7777) == mode_t(0o600)
        else {
            return .unsafe
        }
        let current = RuntimeSocketIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            owner: status.st_uid,
            mode: status.st_mode & mode_t(0o7777)
        )
        return current == self ? .valid : .replaced
    }
}

enum RuntimeSocketIdentityValidation: Equatable {
    case valid
    case missing
    case replaced
    case unsafe
}
