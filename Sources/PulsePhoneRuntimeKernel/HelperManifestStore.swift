import Darwin
import Foundation
import PulsePhoneHostPaths
import PulsePhoneSharedDefinitions

public struct HelperStateRecord: Codable, Equatable, Sendable {
    public let helperID: String
    public let role: String
    public let executorID: String
    public let executorGeneration: UInt64
    public let pid: pid_t
    public let processGroupID: pid_t
    public let processStartIdentity: HelperProcessStartIdentity
    public let executablePath: String

    public init(
        helperID: String,
        role: String,
        executorID: String,
        executorGeneration: UInt64,
        processIdentity: HelperProcessIdentity
    ) {
        self.helperID = helperID
        self.role = role
        self.executorID = executorID
        self.executorGeneration = executorGeneration
        self.pid = processIdentity.pid
        self.processGroupID = processIdentity.processGroupID
        self.processStartIdentity = processIdentity.processStartIdentity
        self.executablePath = processIdentity.executablePath
    }
}

public struct HelperStateManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let runtimeEpoch: UInt64
    public let canonicalUDIDHash: String
    public let ownerUID: UInt32
    public let runtimePID: pid_t
    public let runtimeProcessStartIdentity: HelperProcessStartIdentity
    public let helpers: [HelperStateRecord]

    public init(
        runtimeEpoch: UInt64,
        canonicalUDIDHash: String,
        ownerUID: uid_t,
        runtimePID: pid_t,
        runtimeProcessStartIdentity: HelperProcessStartIdentity,
        helpers: [HelperStateRecord]
    ) {
        self.schemaVersion = 1
        self.runtimeEpoch = runtimeEpoch
        self.canonicalUDIDHash = canonicalUDIDHash
        self.ownerUID = ownerUID
        self.runtimePID = runtimePID
        self.runtimeProcessStartIdentity = runtimeProcessStartIdentity
        self.helpers = helpers
    }
}

public enum HelperManifestStoreError: Error, Equatable, Sendable {
    case invalidManifest
    case unsafePath
    case tooLarge
    case systemCall(operation: String, errno: Int32)
}

public struct HelperManifestStore: Sendable {
    public static let maximumBytes = 256 * 1_024
    public static let maximumHelpers = 64

    public let path: String

    private let directoryPath: String
    private let component: String
    private let runtimeEpoch: UInt64
    private let canonicalUDIDHash: String
    private let ownerUID: uid_t
    private let runtimePID: pid_t
    private let runtimeProcessStartIdentity: HelperProcessStartIdentity

    public init(
        canonicalUDID: CanonicalUDID,
        runtimeEpoch: UInt64,
        runtimePID: pid_t,
        runtimeProcessStartIdentity: HelperProcessStartIdentity,
        baseDirectoryPath: String? = nil,
        ownerUID: uid_t = geteuid()
    ) throws {
        let basePath: String
        if let baseDirectoryPath {
            basePath = baseDirectoryPath
        } else {
            let system = POSIXHostPathSystem()
            _ = try system.openTemporaryBaseAnchor()
            basePath = "/tmp/pulsephone-\(ownerUID)"
        }
        guard basePath.hasPrefix("/"), !basePath.utf8.contains(0) else {
            throw HelperManifestStoreError.unsafePath
        }
        self.directoryPath = basePath
        self.component = canonicalUDID.domainSeparatedHash + ".helpers.v1.json"
        self.path = basePath + "/" + component
        self.runtimeEpoch = runtimeEpoch
        self.canonicalUDIDHash = canonicalUDID.domainSeparatedHash
        self.ownerUID = ownerUID
        self.runtimePID = runtimePID
        self.runtimeProcessStartIdentity = runtimeProcessStartIdentity
    }

    public static func loadCurrent(
        canonicalUDID: CanonicalUDID,
        baseDirectoryPath: String? = nil,
        ownerUID: uid_t = geteuid()
    ) throws -> HelperStateManifest {
        let reader = try HelperManifestStore(
            canonicalUDID: canonicalUDID,
            runtimeEpoch: 0,
            runtimePID: 1,
            runtimeProcessStartIdentity: HelperProcessStartIdentity(
                seconds: 0,
                microseconds: 0
            ),
            baseDirectoryPath: baseDirectoryPath,
            ownerUID: ownerUID
        )
        let manifest = try reader.loadUnbound()
        try reader.validateCommon(manifest)
        return manifest
    }

    public func publish(_ helpers: [HelperStateRecord]) throws {
        let manifest = try makeManifest(helpers)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(manifest)
        guard bytes.count <= Self.maximumBytes else {
            throw HelperManifestStoreError.tooLarge
        }

        let directory = try openValidatedDirectory()
        defer { _ = Darwin.close(directory) }
        try validateExistingFinalNode(directory: directory)

        let temporary = ".\(component).tmp.\(UUID().uuidString.lowercased())"
        let descriptor = Darwin.openat(
            directory,
            temporary,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw systemCall("openat-helper-manifest-temp")
        }
        var shouldRemoveTemporary = true
        defer {
            _ = Darwin.close(descriptor)
            if shouldRemoveTemporary {
                _ = unlinkat(directory, temporary, 0)
            }
        }
        try writeAll(bytes, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw systemCall("fsync-helper-manifest")
        }
        guard renameat(directory, temporary, directory, component) == 0 else {
            throw systemCall("renameat-helper-manifest")
        }
        shouldRemoveTemporary = false
        guard fsync(directory) == 0 else {
            throw systemCall("fsync-helper-manifest-directory")
        }
        _ = try load()
    }

    public func load() throws -> HelperStateManifest {
        let manifest = try loadUnbound()
        try validate(manifest)
        return manifest
    }

    public static func removeCurrent(
        canonicalUDID: CanonicalUDID,
        matching expected: HelperStateManifest,
        baseDirectoryPath: String? = nil,
        ownerUID: uid_t = geteuid()
    ) throws {
        let store = try HelperManifestStore(
            canonicalUDID: canonicalUDID,
            runtimeEpoch: expected.runtimeEpoch,
            runtimePID: expected.runtimePID,
            runtimeProcessStartIdentity: expected.runtimeProcessStartIdentity,
            baseDirectoryPath: baseDirectoryPath,
            ownerUID: ownerUID
        )
        try store.remove(matching: expected)
    }

    private func remove(matching expected: HelperStateManifest) throws {
        guard try load() == expected else {
            throw HelperManifestStoreError.invalidManifest
        }
        let directory = try openValidatedDirectory()
        defer { _ = Darwin.close(directory) }
        var before = stat()
        guard fstatat(
            directory,
            component,
            &before,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw systemCall("fstatat-helper-manifest-remove")
        }
        guard before.st_uid == ownerUID,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_mode & mode_t(0o7777) == mode_t(0o600),
              before.st_nlink == 1,
              try load() == expected
        else {
            throw HelperManifestStoreError.unsafePath
        }
        var after = stat()
        guard fstatat(
            directory,
            component,
            &after,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino
        else {
            throw HelperManifestStoreError.unsafePath
        }
        guard unlinkat(directory, component, 0) == 0 else {
            throw systemCall("unlinkat-helper-manifest")
        }
    }

    private func loadUnbound() throws -> HelperStateManifest {
        let directory = try openValidatedDirectory()
        defer { _ = Darwin.close(directory) }
        let descriptor = Darwin.openat(
            directory,
            component,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw HelperManifestStoreError.unsafePath
            }
            throw systemCall("openat-helper-manifest")
        }
        defer { _ = Darwin.close(descriptor) }

        let before = try validatedRegularFile(descriptor)
        let bytes = try readBounded(from: descriptor)
        let after = try validatedRegularFile(descriptor)
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino else {
            throw HelperManifestStoreError.unsafePath
        }
        var pathStatus = stat()
        guard fstatat(
            directory,
            component,
            &pathStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              pathStatus.st_dev == after.st_dev,
              pathStatus.st_ino == after.st_ino
        else {
            throw HelperManifestStoreError.unsafePath
        }
        try validateExactJSONShape(bytes)
        let manifest: HelperStateManifest
        do {
            manifest = try JSONDecoder().decode(
                HelperStateManifest.self,
                from: bytes
            )
        } catch {
            throw HelperManifestStoreError.invalidManifest
        }
        return manifest
    }

    private func makeManifest(
        _ helpers: [HelperStateRecord]
    ) throws -> HelperStateManifest {
        guard helpers.count <= Self.maximumHelpers else {
            throw HelperManifestStoreError.invalidManifest
        }
        let sorted = helpers.sorted { $0.helperID.utf8.lexicographicallyPrecedes($1.helperID.utf8) }
        let manifest = HelperStateManifest(
            runtimeEpoch: runtimeEpoch,
            canonicalUDIDHash: canonicalUDIDHash,
            ownerUID: ownerUID,
            runtimePID: runtimePID,
            runtimeProcessStartIdentity: runtimeProcessStartIdentity,
            helpers: sorted
        )
        try validate(manifest)
        return manifest
    }

    private func validate(_ manifest: HelperStateManifest) throws {
        try validateCommon(manifest)
        guard manifest.runtimeEpoch == runtimeEpoch,
              manifest.runtimePID == runtimePID,
              manifest.runtimeProcessStartIdentity == runtimeProcessStartIdentity
        else {
            throw HelperManifestStoreError.invalidManifest
        }
    }

    private func validateCommon(_ manifest: HelperStateManifest) throws {
        guard manifest.schemaVersion == 1,
              manifest.runtimeEpoch > 0,
              manifest.canonicalUDIDHash == canonicalUDIDHash,
              manifest.ownerUID == ownerUID,
              manifest.runtimePID > 0,
              manifest.runtimeProcessStartIdentity.microseconds < 1_000_000,
              manifest.helpers.count <= Self.maximumHelpers,
              manifest.helpers.map(\.helperID) == manifest.helpers.map(\.helperID).sorted(),
              Set(manifest.helpers.map(\.helperID)).count == manifest.helpers.count
        else {
            throw HelperManifestStoreError.invalidManifest
        }
        for helper in manifest.helpers {
            guard Self.validASCII(helper.helperID, maximumBytes: 128),
                  Self.validASCII(helper.role, maximumBytes: 128),
                  Self.validASCII(helper.executorID, maximumBytes: 128),
                  helper.pid > 0,
                  helper.processGroupID == helper.pid,
                  helper.processStartIdentity.microseconds < 1_000_000,
                  helper.executablePath.hasPrefix("/"),
                  helper.executablePath.utf8.count <= 4_096,
                  !helper.executablePath.utf8.contains(0)
            else {
                throw HelperManifestStoreError.invalidManifest
            }
        }
    }

    private func validateExactJSONShape(_ bytes: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: bytes)
        } catch {
            throw HelperManifestStoreError.invalidManifest
        }
        guard let root = object as? [String: Any],
              Set(root.keys) == [
                "canonicalUDIDHash", "helpers", "ownerUID", "runtimeEpoch",
                "runtimePID", "runtimeProcessStartIdentity", "schemaVersion",
              ],
              let start = root["runtimeProcessStartIdentity"] as? [String: Any],
              Set(start.keys) == ["microseconds", "seconds"],
              let helpers = root["helpers"] as? [Any]
        else {
            throw HelperManifestStoreError.invalidManifest
        }
        for value in helpers {
            guard let helper = value as? [String: Any],
                  Set(helper.keys) == [
                    "executablePath", "executorGeneration", "executorID",
                    "helperID", "pid", "processGroupID", "processStartIdentity",
                    "role",
                  ],
                  let identity = helper["processStartIdentity"] as? [String: Any],
                  Set(identity.keys) == ["microseconds", "seconds"]
            else {
                throw HelperManifestStoreError.invalidManifest
            }
        }
    }

    private func openValidatedDirectory() throws -> Int32 {
        let descriptor = Darwin.open(
            directoryPath,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        guard descriptor >= 0 else {
            throw systemCall("open-helper-manifest-directory")
        }
        do {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw systemCall("fstat-helper-manifest-directory")
            }
            guard status.st_uid == ownerUID,
                  status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            else {
                throw HelperManifestStoreError.unsafePath
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func validateExistingFinalNode(directory: Int32) throws {
        var status = stat()
        guard fstatat(directory, component, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw systemCall("fstatat-helper-manifest-existing")
        }
        guard status.st_uid == ownerUID,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_mode & mode_t(0o7777) == mode_t(0o600),
              status.st_nlink == 1
        else {
            throw HelperManifestStoreError.unsafePath
        }
    }

    private func validatedRegularFile(_ descriptor: Int32) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw systemCall("fstat-helper-manifest")
        }
        guard status.st_uid == ownerUID,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_mode & mode_t(0o7777) == mode_t(0o600),
              status.st_nlink == 1
        else {
            throw HelperManifestStoreError.unsafePath
        }
        return status
    }

    private func writeAll(_ bytes: Data, to descriptor: Int32) throws {
        try bytes.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if result > 0 {
                    offset += result
                } else if result == -1, errno == EINTR {
                    continue
                } else {
                    throw systemCall("write-helper-manifest")
                }
            }
        }
    }

    private func readBounded(from descriptor: Int32) throws -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                output.append(buffer, count: count)
                guard output.count <= Self.maximumBytes else {
                    throw HelperManifestStoreError.tooLarge
                }
            } else if count == 0 {
                return output
            } else if errno != EINTR {
                throw systemCall("read-helper-manifest")
            }
        }
    }

    private static func validASCII(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        let bytes = Array(value.utf8)
        return (1...maximumBytes).contains(bytes.count)
            && bytes.allSatisfy { (0x21...0x7e).contains($0) }
    }

    private func systemCall(_ operation: String) -> HelperManifestStoreError {
        .systemCall(operation: operation, errno: errno)
    }
}
