import Darwin
import Foundation
import PulsePhoneHostPaths
import PulsePhoneSharedDefinitions

public enum ProductionActionLogMaintenanceError: Error, Equatable, Sendable {
    case maintenanceBusy
    case systemCall(operation: String, errno: Int32)
    case unsafeHostPath
}

public struct ProductionActionLogMaintenance: Sendable {
    private enum Operation {
        case clearAll
        case clearDevice(CanonicalUDID)
        case prune(nowEpochSeconds: UInt64)
    }

    private struct ScannedFile {
        let byteCount: UInt64
        let closedAtEpochSeconds: UInt64
        let device: UInt64
        let inode: UInt64
        let name: String
    }

    private final class ScannedTarget {
        let canonicalUDID: CanonicalUDID?
        let directoryDescriptor: Int32
        let directoryName: String
        let files: [ScannedFile]
        let identityValid: Bool
        let writerLockDescriptor: Int32

        init(
            canonicalUDID: CanonicalUDID?,
            directoryDescriptor: Int32,
            directoryName: String,
            files: [ScannedFile],
            identityValid: Bool,
            writerLockDescriptor: Int32
        ) {
            self.canonicalUDID = canonicalUDID
            self.directoryDescriptor = directoryDescriptor
            self.directoryName = directoryName
            self.files = files
            self.identityValid = identityValid
            self.writerLockDescriptor = writerLockDescriptor
        }

        deinit {
            if writerLockDescriptor >= 0 {
                _ = flock(writerLockDescriptor, LOCK_UN)
                _ = Darwin.close(writerLockDescriptor)
            }
            _ = Darwin.close(directoryDescriptor)
        }
    }

    private let rootPath: String

    public init(rootPath: String) {
        self.rootPath = rootPath
    }

    public static func bundled() throws -> Self {
        Self(
            rootPath: try POSIXHostPathSystem()
                .makeHostPathLayout()
                .persistentHistoryDirectory
        )
    }

    public func prune(
        nowEpochSeconds: UInt64 = UInt64(Date().timeIntervalSince1970)
    ) throws -> ActionLogMaintenanceResult {
        try perform(.prune(nowEpochSeconds: nowEpochSeconds))
    }

    public func clearAll() throws -> ActionLogMaintenanceResult {
        try perform(.clearAll)
    }

    public func clear(
        canonicalUDID: CanonicalUDID
    ) throws -> ActionLogMaintenanceResult {
        try perform(.clearDevice(canonicalUDID))
    }

    private func perform(
        _ operation: Operation
    ) throws -> ActionLogMaintenanceResult {
        guard let root = try openRootIfPresent() else {
            return Self.result()
        }
        defer { _ = Darwin.close(root) }
        let maintenance = try acquireMaintenanceLock(root: root)
        defer {
            _ = flock(maintenance, LOCK_UN)
            _ = Darwin.close(maintenance)
        }
        let targets = try scanTargets(root: root)
        let desired = desiredFiles(targets: targets, operation: operation)
        return delete(
            targets: targets,
            desired: desired,
            startedAtNanoseconds: monotonicNanoseconds()
        )
    }

    private func openRootIfPresent() throws -> Int32? {
        var metadata = stat()
        guard lstat(rootPath, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw systemCall("lstat-root")
        }
        guard Self.isOwnedDirectory(metadata, mode: 0o700) else {
            throw ProductionActionLogMaintenanceError.unsafeHostPath
        }
        let descriptor = Darwin.open(
            rootPath,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw ProductionActionLogMaintenanceError.unsafeHostPath
            }
            throw systemCall("open-root")
        }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else {
            let error = systemCall("fstat-root")
            _ = Darwin.close(descriptor)
            throw error
        }
        guard Self.sameIdentity(metadata, opened),
              Self.isOwnedDirectory(opened, mode: 0o700)
        else {
            _ = Darwin.close(descriptor)
            throw ProductionActionLogMaintenanceError.unsafeHostPath
        }
        return descriptor
    }

    private func acquireMaintenanceLock(root: Int32) throws -> Int32 {
        let descriptor = openat(
            root,
            "actionlog-maintenance.lock",
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw systemCall("open-maintenance-lock") }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              Self.isOwnedRegularFile(metadata, mode: 0o600)
        else {
            _ = Darwin.close(descriptor)
            throw ProductionActionLogMaintenanceError.unsafeHostPath
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            if code == EWOULDBLOCK {
                throw ProductionActionLogMaintenanceError.maintenanceBusy
            }
            throw ProductionActionLogMaintenanceError.systemCall(
                operation: "flock-maintenance",
                errno: code
            )
        }
        return descriptor
    }

    private func scanTargets(root: Int32) throws -> [ScannedTarget] {
        var result = [ScannedTarget]()
        for name in try directoryEntries(root).sorted(by: Self.asciiLessThan) {
            guard StableBytes.isLowercaseHex(name, byteCount: 32) else { continue }
            let descriptor = openat(
                root,
                name,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
            )
            guard descriptor >= 0 else {
                result.append(ScannedTarget(
                    canonicalUDID: nil,
                    directoryDescriptor: try openNullDirectory(),
                    directoryName: name,
                    files: [],
                    identityValid: false,
                    writerLockDescriptor: -1
                ))
                continue
            }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  Self.isOwnedDirectory(metadata, mode: 0o700)
            else {
                _ = Darwin.close(descriptor)
                result.append(ScannedTarget(
                    canonicalUDID: nil,
                    directoryDescriptor: try openNullDirectory(),
                    directoryName: name,
                    files: [],
                    identityValid: false,
                    writerLockDescriptor: -1
                ))
                continue
            }
            let identity = try? readIdentity(target: descriptor, directoryName: name)
            let writer = try acquireWriterLockIfAvailable(target: descriptor)
            let files = try scanActionFiles(target: descriptor)
            result.append(ScannedTarget(
                canonicalUDID: identity,
                directoryDescriptor: descriptor,
                directoryName: name,
                files: files,
                identityValid: identity != nil,
                writerLockDescriptor: writer
            ))
        }
        return result
    }

    private func readIdentity(
        target: Int32,
        directoryName: String
    ) throws -> CanonicalUDID {
        let descriptor = openat(target, "identity.v1.json", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw systemCall("open-identity") }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              Self.isOwnedRegularFile(metadata, mode: 0o600),
              metadata.st_size >= 0,
              metadata.st_size <= 16 * 1_024
        else {
            throw ProductionActionLogMaintenanceError.unsafeHostPath
        }
        let bytes = try readAll(descriptor, count: Int(metadata.st_size))
        let document = try RepositoryCanonicalJSON.validateCanonicalDocument(
            bytes,
            maximumByteCount: 16 * 1_024
        )
        let object = document.root
        guard object["schemaVersion"]?.numberValue.flatMap({ try? $0.requireUInt64() }) == 1,
              let raw = object["canonicalUDID"]?.stringValue,
              let hash = object["canonicalUDIDHash"]?.stringValue,
              object["createdAtUTC"]?.stringValue != nil
        else {
            throw ProductionActionLogMaintenanceError.unsafeHostPath
        }
        let target = try CanonicalUDID(canonicalString: raw)
        guard target.domainSeparatedHash == hash, hash == directoryName else {
            throw ProductionActionLogMaintenanceError.unsafeHostPath
        }
        return target
    }

    private func acquireWriterLockIfAvailable(target: Int32) throws -> Int32 {
        let descriptor = openat(target, "writer.lock", O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return -1 }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              Self.isOwnedRegularFile(metadata, mode: 0o600)
        else {
            _ = Darwin.close(descriptor)
            return -1
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = Darwin.close(descriptor)
            return -1
        }
        return descriptor
    }

    private func scanActionFiles(target: Int32) throws -> [ScannedFile] {
        var result = [ScannedFile]()
        for name in try directoryEntries(target).sorted(by: Self.asciiLessThan) {
            guard Self.isActionFileName(name) else { continue }
            var metadata = stat()
            guard fstatat(target, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.isOwnedRegularFile(metadata, mode: 0o600),
                  metadata.st_size >= 0
            else { continue }
            result.append(ScannedFile(
                byteCount: UInt64(metadata.st_size),
                closedAtEpochSeconds: metadata.st_mtimespec.tv_sec > 0
                    ? UInt64(metadata.st_mtimespec.tv_sec)
                    : 0,
                device: UInt64(metadata.st_dev),
                inode: UInt64(metadata.st_ino),
                name: name
            ))
        }
        return result
    }

    private func desiredFiles(
        targets: [ScannedTarget],
        operation: Operation
    ) -> Set<String> {
        switch operation {
        case .clearAll:
            return Set(targets.flatMap { target in
                target.files.map { Self.key(target.directoryName, $0.name) }
            })
        case .clearDevice(let target):
            return Set(targets.filter { $0.canonicalUDID == target }.flatMap { item in
                item.files.map { Self.key(item.directoryName, $0.name) }
            })
        case .prune(let now):
            return Self.pruneSelection(targets: targets, nowEpochSeconds: now)
        }
    }

    private static func pruneSelection(
        targets: [ScannedTarget],
        nowEpochSeconds: UInt64
    ) -> Set<String> {
        var desired = Set<String>()
        var all = [(String, ScannedFile)]()
        for target in targets where target.identityValid {
            var remaining = target.files.sorted(by: fileOrder)
            all.append(contentsOf: remaining.map { (target.directoryName, $0) })
            for file in remaining where nowEpochSeconds >= file.closedAtEpochSeconds
                && nowEpochSeconds - file.closedAtEpochSeconds > ActionLogMaintenance.closedAgeSeconds
            {
                desired.insert(key(target.directoryName, file.name))
            }
            remaining.removeAll { desired.contains(key(target.directoryName, $0.name)) }
            while remaining.count > ActionLogMaintenance.maximumClosedFilesPerTarget {
                desired.insert(key(target.directoryName, remaining.removeFirst().name))
            }
            var bytes = remaining.reduce(UInt64(0)) { saturatingAdd($0, $1.byteCount) }
            while bytes > ActionLogMaintenance.maximumBytesPerTarget, !remaining.isEmpty {
                let removed = remaining.removeFirst()
                desired.insert(key(target.directoryName, removed.name))
                bytes = bytes >= removed.byteCount ? bytes - removed.byteCount : 0
            }
        }
        var remaining = all.filter { !desired.contains(key($0.0, $0.1.name)) }
            .sorted {
                if $0.1.closedAtEpochSeconds != $1.1.closedAtEpochSeconds {
                    return $0.1.closedAtEpochSeconds < $1.1.closedAtEpochSeconds
                }
                return key($0.0, $0.1.name) < key($1.0, $1.1.name)
            }
        var bytes = remaining.reduce(UInt64(0)) { saturatingAdd($0, $1.1.byteCount) }
        while bytes > ActionLogMaintenance.maximumGlobalBytes, !remaining.isEmpty {
            let removed = remaining.removeFirst()
            desired.insert(key(removed.0, removed.1.name))
            bytes = bytes >= removed.1.byteCount ? bytes - removed.1.byteCount : 0
        }
        return desired
    }

    private func delete(
        targets: [ScannedTarget],
        desired: Set<String>,
        startedAtNanoseconds: UInt64
    ) -> ActionLogMaintenanceResult {
        var deletedBytes: UInt64 = 0
        var deletedFiles = 0
        var failed = 0
        var failedSample = [String]()
        var skipped = 0
        var skippedSample = [String]()
        var scanComplete = true
        let deadline = startedAtNanoseconds.addingReportingOverflow(
            ActionLogMaintenance.absoluteDeadlineNanoseconds
        )
        for target in targets.sorted(by: { Self.asciiLessThan($0.directoryName, $1.directoryName) }) {
            guard !deadline.overflow, monotonicNanoseconds() < deadline.partialValue else {
                scanComplete = false
                break
            }
            guard target.identityValid, let canonicalUDID = target.canonicalUDID else {
                failed += 1
                appendSample("\(target.directoryName):identityInvalid", to: &failedSample)
                continue
            }
            for file in target.files.sorted(by: Self.fileOrder) {
                guard desired.contains(Self.key(target.directoryName, file.name)) else { continue }
                guard target.writerLockDescriptor >= 0 else {
                    skipped += 1
                    appendSample("\(canonicalUDID.rawValue):\(file.name):writerBusy", to: &skippedSample)
                    continue
                }
                var current = stat()
                guard fstatat(
                    target.directoryDescriptor,
                    file.name,
                    &current,
                    AT_SYMLINK_NOFOLLOW
                ) == 0,
                Self.isOwnedRegularFile(current, mode: 0o600),
                UInt64(current.st_dev) == file.device,
                UInt64(current.st_ino) == file.inode,
                unlinkat(target.directoryDescriptor, file.name, 0) == 0
                else {
                    failed += 1
                    appendSample("\(canonicalUDID.rawValue):\(file.name):deleteFailed", to: &failedSample)
                    continue
                }
                deletedFiles += 1
                deletedBytes = Self.saturatingAdd(deletedBytes, file.byteCount)
            }
        }
        let outcome: ActionLogMaintenanceOutcome = scanComplete
            && skipped == 0 && failed == 0 ? .succeeded : .partial
        return ActionLogMaintenanceResult(
            deletedByteCount: deletedBytes,
            deletedFileCount: deletedFiles,
            failedCount: failed,
            failedSample: failedSample,
            outcome: outcome,
            scanComplete: scanComplete,
            skippedCount: skipped,
            skippedSample: skippedSample
        )
    }

    private func directoryEntries(_ descriptor: Int32) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw systemCall("dup-directory") }
        guard let stream = fdopendir(duplicate) else {
            _ = Darwin.close(duplicate)
            throw systemCall("fdopendir")
        }
        defer { closedir(stream) }
        var result = [String]()
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { result.append(name) }
        }
        return result
    }

    private func readAll(_ descriptor: Int32, count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let amount = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset)
            }
            guard amount > 0 else { throw systemCall("read-identity") }
            offset += amount
        }
        return bytes
    }

    private func openNullDirectory() throws -> Int32 {
        let descriptor = Darwin.open("/", O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        guard descriptor >= 0 else { throw systemCall("open-null-directory") }
        return descriptor
    }

    private func monotonicNanoseconds() -> UInt64 {
        var value = timespec()
        guard clock_gettime(CLOCK_MONOTONIC_RAW, &value) == 0 else { return .max }
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }

    private func systemCall(_ operation: String) -> ProductionActionLogMaintenanceError {
        .systemCall(operation: operation, errno: errno)
    }

    private static func isOwnedDirectory(_ value: stat, mode: mode_t) -> Bool {
        value.st_uid == geteuid()
            && value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            && value.st_mode & mode_t(0o7777) == mode
    }

    private static func isOwnedRegularFile(_ value: stat, mode: mode_t) -> Bool {
        value.st_uid == geteuid()
            && value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && value.st_mode & mode_t(0o7777) == mode
            && value.st_nlink == 1
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func isActionFileName(_ value: String) -> Bool {
        value.range(
            of: #"^actions-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$"#,
            options: .regularExpression
        ) != nil
    }

    private static func key(_ directory: String, _ file: String) -> String {
        directory + "\u{0}" + file
    }

    private static func fileOrder(_ lhs: ScannedFile, _ rhs: ScannedFile) -> Bool {
        if lhs.closedAtEpochSeconds != rhs.closedAtEpochSeconds {
            return lhs.closedAtEpochSeconds < rhs.closedAtEpochSeconds
        }
        return asciiLessThan(lhs.name, rhs.name)
    }

    private static func asciiLessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let value = lhs.addingReportingOverflow(rhs)
        return value.overflow ? .max : value.partialValue
    }

    private func appendSample(_ value: String, to samples: inout [String]) {
        guard samples.count < ActionLogMaintenance.maximumSampleCount else { return }
        samples.append(String(decoding:
            Array(value.utf8.prefix(ActionLogMaintenance.maximumSampleBytes)),
            as: UTF8.self
        ))
    }

    private static func result() -> ActionLogMaintenanceResult {
        ActionLogMaintenanceResult(
            deletedByteCount: 0,
            deletedFileCount: 0,
            failedCount: 0,
            failedSample: [],
            outcome: .succeeded,
            scanComplete: true,
            skippedCount: 0,
            skippedSample: []
        )
    }
}
