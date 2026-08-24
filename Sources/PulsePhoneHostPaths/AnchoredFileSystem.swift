import Darwin

public enum HostNodeKind: String, Equatable, Sendable {
    case directory
    case regularFile
    case socket
    case symbolicLink
    case other
}

public struct HostNodeIdentity: Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public struct HostNodeMetadata: Equatable, Sendable {
    public let byteCount: UInt64
    public let identity: HostNodeIdentity
    public let linkCount: UInt64
    public let owner: uid_t
    public let kind: HostNodeKind
    public let mode: mode_t

    public init(
        identity: HostNodeIdentity,
        owner: uid_t,
        kind: HostNodeKind,
        mode: mode_t,
        linkCount: UInt64 = 1,
        byteCount: UInt64 = 0
    ) {
        self.byteCount = byteCount
        self.identity = identity
        self.linkCount = linkCount
        self.owner = owner
        self.kind = kind
        self.mode = mode
    }
}

public struct HostNodeExpectation: Equatable, Sendable {
    public let owner: uid_t
    public let kind: HostNodeKind
    public let mode: mode_t?

    public init(owner: uid_t, kind: HostNodeKind, mode: mode_t? = nil) {
        self.owner = owner
        self.kind = kind
        self.mode = mode
    }
}

public enum UnsafeHostNodeReason: Equatable, Sendable {
    case invalidPathComponent
    case symbolicLink
    case wrongOwner(expected: uid_t, actual: uid_t)
    case wrongKind(expected: HostNodeKind, actual: HostNodeKind)
    case wrongMode(expected: mode_t, actual: mode_t)
    case identityMismatch
}

public enum AnchoredFileSystemError: Error, Equatable, Sendable {
    case systemCall(operation: String, errno: Int32)
    case unsafeNode(reason: UnsafeHostNodeReason)
}

public final class AnchoredDirectory: @unchecked Sendable {
    public let logicalPath: String
    public let identity: HostNodeIdentity
    let fileDescriptor: Int32

    init(logicalPath: String, identity: HostNodeIdentity, fileDescriptor: Int32) {
        self.logicalPath = logicalPath
        self.identity = identity
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        Darwin.close(fileDescriptor)
    }
}

public enum AnchoredFileAccess: Sendable {
    case readOnly
    case writeOnly
    case readWrite
}

public final class AnchoredRegularFile: @unchecked Sendable {
    public let logicalPath: String
    public let identity: HostNodeIdentity
    private let fileDescriptor: Int32

    init(logicalPath: String, identity: HostNodeIdentity, fileDescriptor: Int32) {
        self.logicalPath = logicalPath
        self.identity = identity
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        Darwin.close(fileDescriptor)
    }

    public func withUnsafeFileDescriptor<Result>(
        _ body: (Int32) throws -> Result
    ) rethrows -> Result {
        try body(fileDescriptor)
    }
}

public struct AnchoredFileSystem: Sendable {
    private let system: POSIXHostPathSystem

    public init(system: POSIXHostPathSystem = POSIXHostPathSystem()) {
        self.system = system
    }

    public func openDirectory(
        atPath path: String,
        expecting expectation: HostNodeExpectation
    ) throws -> AnchoredDirectory {
        let before = try system.metadataNoFollow(
            atPath: path,
            error: {
                AnchoredFileSystemError.systemCall(
                    operation: "lstat",
                    errno: $0
                )
            }
        )
        try validate(before, expecting: expectation)

        let descriptor = try system.openDirectoryNoFollow(path)
        do {
            let opened = try system.metadata(
                forFileDescriptor: descriptor,
                error: {
                    AnchoredFileSystemError.systemCall(
                        operation: "fstat",
                        errno: $0
                    )
                }
            )
            try validate(opened, expecting: expectation)
            let after = try system.metadataNoFollow(
                atPath: path,
                error: {
                    AnchoredFileSystemError.systemCall(
                        operation: "lstat",
                        errno: $0
                    )
                }
            )
            try validate(after, expecting: expectation)
            guard before.identity == opened.identity,
                  opened.identity == after.identity
            else {
                throw AnchoredFileSystemError.unsafeNode(
                    reason: .identityMismatch
                )
            }
            return AnchoredDirectory(
                logicalPath: path,
                identity: opened.identity,
                fileDescriptor: descriptor
            )
        } catch {
            system.closeFileDescriptor(descriptor)
            throw error
        }
    }

    public func openDirectory(
        named component: String,
        relativeTo parent: AnchoredDirectory,
        expecting expectation: HostNodeExpectation
    ) throws -> AnchoredDirectory {
        try validatePathComponent(component)
        let before = try system.metadataNoFollow(
            named: component,
            relativeTo: parent.fileDescriptor
        )
        try validate(before, expecting: expectation)

        let descriptor = try system.openDirectoryNoFollow(
            named: component,
            relativeTo: parent.fileDescriptor
        )
        do {
            let opened = try system.metadata(
                forFileDescriptor: descriptor,
                error: {
                    AnchoredFileSystemError.systemCall(
                        operation: "fstat",
                        errno: $0
                    )
                }
            )
            try validate(opened, expecting: expectation)
            let after = try system.metadataNoFollow(
                named: component,
                relativeTo: parent.fileDescriptor
            )
            try validate(after, expecting: expectation)
            guard before.identity == opened.identity,
                  opened.identity == after.identity
            else {
                throw AnchoredFileSystemError.unsafeNode(
                    reason: .identityMismatch
                )
            }
            return AnchoredDirectory(
                logicalPath: parent.logicalPath + "/" + component,
                identity: opened.identity,
                fileDescriptor: descriptor
            )
        } catch {
            system.closeFileDescriptor(descriptor)
            throw error
        }
    }

    public func ensureDirectory(
        named component: String,
        relativeTo parent: AnchoredDirectory,
        owner: uid_t,
        mode: mode_t = 0o700
    ) throws -> AnchoredDirectory {
        try validatePathComponent(component)
        try system.createDirectoryIfMissing(
            named: component,
            relativeTo: parent.fileDescriptor,
            mode: mode
        )
        return try openDirectory(
            named: component,
            relativeTo: parent,
            expecting: HostNodeExpectation(
                owner: owner,
                kind: .directory,
                mode: mode
            )
        )
    }

    public func validateNode(
        named component: String,
        relativeTo parent: AnchoredDirectory,
        expecting expectation: HostNodeExpectation,
        identity: HostNodeIdentity? = nil
    ) throws -> HostNodeMetadata {
        try validatePathComponent(component)
        let metadata = try system.metadataNoFollow(
            named: component,
            relativeTo: parent.fileDescriptor
        )
        try validate(metadata, expecting: expectation)
        if let identity, identity != metadata.identity {
            throw AnchoredFileSystemError.unsafeNode(
                reason: .identityMismatch
            )
        }
        return metadata
    }

    public func validateNodeIfPresent(
        named component: String,
        relativeTo parent: AnchoredDirectory,
        expecting expectation: HostNodeExpectation
    ) throws -> HostNodeMetadata? {
        do {
            return try validateNode(
                named: component,
                relativeTo: parent,
                expecting: expectation
            )
        } catch AnchoredFileSystemError.systemCall(
            operation: "fstatat",
            errno: ENOENT
        ) {
            return nil
        }
    }

    public func openRegularFile(
        named component: String,
        relativeTo parent: AnchoredDirectory,
        owner: uid_t,
        mode: mode_t = 0o600,
        access: AnchoredFileAccess = .readOnly
    ) throws -> AnchoredRegularFile {
        try validatePathComponent(component)
        let expectation = HostNodeExpectation(
            owner: owner,
            kind: .regularFile,
            mode: mode
        )
        let before = try system.metadataNoFollow(
            named: component,
            relativeTo: parent.fileDescriptor
        )
        try validate(before, expecting: expectation)

        let descriptor = try system.openRegularFileNoFollow(
            named: component,
            relativeTo: parent.fileDescriptor,
            access: access
        )
        do {
            let opened = try system.metadata(
                forFileDescriptor: descriptor,
                error: {
                    AnchoredFileSystemError.systemCall(
                        operation: "fstat",
                        errno: $0
                    )
                }
            )
            try validate(opened, expecting: expectation)
            let after = try system.metadataNoFollow(
                named: component,
                relativeTo: parent.fileDescriptor
            )
            try validate(after, expecting: expectation)
            guard before.identity == opened.identity,
                  opened.identity == after.identity
            else {
                throw AnchoredFileSystemError.unsafeNode(
                    reason: .identityMismatch
                )
            }
            return AnchoredRegularFile(
                logicalPath: parent.logicalPath + "/" + component,
                identity: opened.identity,
                fileDescriptor: descriptor
            )
        } catch {
            system.closeFileDescriptor(descriptor)
            throw error
        }
    }

    public func createExclusiveRegularFile(
        named component: String,
        relativeTo parent: AnchoredDirectory,
        owner: uid_t,
        mode: mode_t = 0o600
    ) throws -> AnchoredRegularFile {
        try validatePathComponent(component)
        let descriptor = try system.createExclusiveRegularFileNoFollow(
            named: component,
            relativeTo: parent.fileDescriptor,
            mode: mode
        )
        do {
            let expectation = HostNodeExpectation(
                owner: owner,
                kind: .regularFile,
                mode: mode
            )
            let opened = try system.metadata(
                forFileDescriptor: descriptor,
                error: {
                    AnchoredFileSystemError.systemCall(
                        operation: "fstat",
                        errno: $0
                    )
                }
            )
            try validate(opened, expecting: expectation)
            let pathNode = try system.metadataNoFollow(
                named: component,
                relativeTo: parent.fileDescriptor
            )
            try validate(pathNode, expecting: expectation)
            guard opened.identity == pathNode.identity else {
                throw AnchoredFileSystemError.unsafeNode(
                    reason: .identityMismatch
                )
            }
            return AnchoredRegularFile(
                logicalPath: parent.logicalPath + "/" + component,
                identity: opened.identity,
                fileDescriptor: descriptor
            )
        } catch {
            system.closeFileDescriptor(descriptor)
            throw error
        }
    }

    private func validate(
        _ metadata: HostNodeMetadata,
        expecting expectation: HostNodeExpectation
    ) throws {
        guard metadata.kind != .symbolicLink else {
            throw AnchoredFileSystemError.unsafeNode(reason: .symbolicLink)
        }
        guard metadata.owner == expectation.owner else {
            throw AnchoredFileSystemError.unsafeNode(
                reason: .wrongOwner(
                    expected: expectation.owner,
                    actual: metadata.owner
                )
            )
        }
        guard metadata.kind == expectation.kind else {
            throw AnchoredFileSystemError.unsafeNode(
                reason: .wrongKind(
                    expected: expectation.kind,
                    actual: metadata.kind
                )
            )
        }
        if let expectedMode = expectation.mode,
           metadata.mode != expectedMode
        {
            throw AnchoredFileSystemError.unsafeNode(
                reason: .wrongMode(
                    expected: expectedMode,
                    actual: metadata.mode
                )
            )
        }
    }

    private func validatePathComponent(_ component: String) throws {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              !component.contains("/"),
              !component.utf8.contains(0)
        else {
            throw AnchoredFileSystemError.unsafeNode(
                reason: .invalidPathComponent
            )
        }
    }
}
