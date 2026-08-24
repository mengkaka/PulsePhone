import Darwin
import Foundation
import PulsePhoneHostPaths
import PulsePhoneRuntimeKernel
import PulsePhoneSharedDefinitions

struct ProductionScreenshotArtifactReservation: Sendable {
    let artifactID: CanonicalUUID
    let internalPath: String
}

struct ProductionScreenshotArtifactDelivery: Sendable {
    let artifactID: CanonicalUUID
    let byteCount: UInt64
    let descriptor: Int32
}

final class ProductionScreenshotArtifactStore: @unchecked Sendable {
    private struct Record {
        let descriptor: Int32
        let reservation: ScreenshotReservation
    }

    private var baseDescriptor: Int32
    private var closed = false
    private var epochDescriptor: Int32
    private let epochName: String
    private let lock = NSLock()
    private let owner: uid_t
    private var records = [String: Record]()
    private var scratchDescriptor: Int32
    private var screenshotDescriptor: Int32
    private var targetDescriptor: Int32
    private let targetName: String
    private let transferDirectoryPath: String

    static func bundled(
        canonicalUDID: CanonicalUDID,
        runtimeEpoch: UInt64
    ) throws -> ProductionScreenshotArtifactStore {
        let system = POSIXHostPathSystem()
        let anchor = try system.openTemporaryBaseAnchor()
        let transferBasePath = "/tmp/pulsephone-\(system.effectiveUserID)"
        return try ProductionScreenshotArtifactStore(
            openedBasePath: anchor.logicalPath,
            transferBasePath: transferBasePath,
            owner: system.effectiveUserID,
            canonicalUDID: canonicalUDID,
            runtimeEpoch: runtimeEpoch
        )
    }

    static func testing(
        temporaryBasePath: String,
        canonicalUDID: CanonicalUDID,
        runtimeEpoch: UInt64
    ) throws -> ProductionScreenshotArtifactStore {
        try ProductionScreenshotArtifactStore(
            openedBasePath: temporaryBasePath,
            transferBasePath: temporaryBasePath,
            owner: geteuid(),
            canonicalUDID: canonicalUDID,
            runtimeEpoch: runtimeEpoch
        )
    }

    private init(
        openedBasePath: String,
        transferBasePath: String,
        owner: uid_t,
        canonicalUDID: CanonicalUDID,
        runtimeEpoch: UInt64
    ) throws {
        guard runtimeEpoch > 0 else {
            throw ScreenshotArtifactError.unsafeHostPath
        }
        self.owner = owner
        self.targetName = canonicalUDID.domainSeparatedHash
        self.epochName = String(runtimeEpoch)
        let openedBase = try Self.openDirectory(
            at: openedBasePath,
            owner: owner,
            mode: 0o700
        )
        var openedScratch: Int32 = -1
        var openedTarget: Int32 = -1
        var openedEpoch: Int32 = -1
        var openedScreenshots: Int32 = -1
        do {
            openedScratch = try Self.ensureDirectory(
                named: "scratch",
                relativeTo: openedBase,
                owner: owner
            )
            openedTarget = try Self.ensureDirectory(
                named: targetName,
                relativeTo: openedScratch,
                owner: owner
            )
            openedEpoch = try Self.ensureDirectory(
                named: epochName,
                relativeTo: openedTarget,
                owner: owner
            )
            openedScreenshots = try Self.ensureDirectory(
                named: "screenshots",
                relativeTo: openedEpoch,
                owner: owner
            )
        } catch {
            if openedEpoch >= 0 { _ = Darwin.close(openedEpoch) }
            if openedTarget >= 0 { _ = Darwin.close(openedTarget) }
            if openedScratch >= 0 { _ = Darwin.close(openedScratch) }
            _ = Darwin.close(openedBase)
            throw error
        }
        baseDescriptor = openedBase
        scratchDescriptor = openedScratch
        targetDescriptor = openedTarget
        epochDescriptor = openedEpoch
        screenshotDescriptor = openedScreenshots
        transferDirectoryPath = transferBasePath
            + "/scratch/\(targetName)/\(epochName)/screenshots"
    }

    func reserve(
        artifactID: CanonicalUUID
    ) throws -> ProductionScreenshotArtifactReservation {
        try lock.withLock {
            guard !closed else { throw ScreenshotArtifactError.unsafeHostPath }
            let key = artifactID.canonicalString
            guard records[key] == nil else {
                throw ScreenshotArtifactError.protocolViolation
            }
            let basename = "\(key).png"
            let descriptor = openat(
                screenshotDescriptor,
                basename,
                O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                0o600
            )
            guard descriptor >= 0 else { throw Self.posixError() }
            do {
                let node = try Self.node(for: descriptor, owner: owner)
                let reservation = try ScreenshotReservation(
                    artifactID: artifactID,
                    directoryPath: transferDirectoryPath,
                    node: node
                )
                records[key] = Record(
                    descriptor: descriptor,
                    reservation: reservation
                )
                return ProductionScreenshotArtifactReservation(
                    artifactID: artifactID,
                    internalPath: reservation.internalPath
                )
            } catch {
                _ = Darwin.close(descriptor)
                _ = unlinkat(screenshotDescriptor, basename, 0)
                throw error
            }
        }
    }

    func complete(
        _ reservation: ProductionScreenshotArtifactReservation,
        byteCount: UInt64,
        format: ScreenshotBackendFormat
    ) throws -> ProductionScreenshotArtifactDelivery {
        try lock.withLock {
            guard !closed else { throw ScreenshotArtifactError.unsafeHostPath }
            let key = reservation.artifactID.canonicalString
            guard let record = records[key],
                  record.reservation.internalPath == reservation.internalPath
            else {
                throw ScreenshotArtifactError.protocolViolation
            }
            let basename = record.reservation.basename
            let descriptor = openat(
                screenshotDescriptor,
                basename,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
            guard descriptor >= 0 else {
                cleanupOwnedRecord(key: key, record: record)
                throw Self.posixError()
            }
            do {
                let reopened = try Self.node(for: descriptor, owner: owner)
                let bytes = try Self.readArtifact(from: descriptor)
                let validated = try ScreenshotReservationValidator.validate(
                    reservation: record.reservation,
                    completion: ScreenshotHelperCompletion(
                        artifactID: reservation.artifactID,
                        byteCount: byteCount,
                        format: format
                    ),
                    reopenedNode: reopened,
                    bytes: bytes
                )
                guard fcntl(descriptor, F_GETFL) & O_ACCMODE == O_RDONLY,
                      unlinkat(screenshotDescriptor, basename, 0) == 0
                else {
                    throw ScreenshotArtifactError.unsafeHostPath
                }
                records.removeValue(forKey: key)
                _ = Darwin.close(record.descriptor)
                _ = lseek(descriptor, 0, SEEK_SET)
                return ProductionScreenshotArtifactDelivery(
                    artifactID: validated.artifactID,
                    byteCount: validated.byteCount,
                    descriptor: descriptor
                )
            } catch {
                _ = Darwin.close(descriptor)
                if let artifactError = error as? ScreenshotArtifactError,
                   ScreenshotReservationValidator.failureCleanup(for: artifactError)
                    == .preserveNode
                {
                    records.removeValue(forKey: key)
                    _ = Darwin.close(record.descriptor)
                } else {
                    cleanupOwnedRecord(key: key, record: record)
                }
                throw error
            }
        }
    }

    func storeGeneratedPNG(
        artifactID: CanonicalUUID,
        bytes: [UInt8]
    ) throws -> ProductionScreenshotArtifactDelivery {
        guard !bytes.isEmpty,
              UInt64(bytes.count) <= ScreenshotReservationValidator
                .maximumArtifactBytes,
              bytes.starts(with: [
                  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
              ])
        else {
            throw ScreenshotArtifactError.artifactValidationFailed
        }
        let reservation = try reserve(artifactID: artifactID)
        do {
            try lock.withLock {
                let key = artifactID.canonicalString
                guard !closed,
                      let record = records[key],
                      record.reservation.internalPath == reservation.internalPath,
                      lseek(record.descriptor, 0, SEEK_SET) == 0
                else {
                    throw ScreenshotArtifactError.protocolViolation
                }
                try Self.writeAll(bytes, to: record.descriptor)
                guard fsync(record.descriptor) == 0 else {
                    throw Self.posixError()
                }
            }
            return try complete(
                reservation,
                byteCount: UInt64(bytes.count),
                format: .png
            )
        } catch {
            cancel(reservation)
            throw error
        }
    }

    func cancel(_ reservation: ProductionScreenshotArtifactReservation) {
        lock.withLock {
            guard !closed else { return }
            let key = reservation.artifactID.canonicalString
            guard let record = records[key] else { return }
            cleanupOwnedRecord(key: key, record: record)
        }
    }

    private func cleanupOwnedRecord(key: String, record: Record) {
        records.removeValue(forKey: key)
        let basename = record.reservation.basename
        var status = stat()
        if fstatat(
            screenshotDescriptor,
            basename,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
           UInt64(status.st_dev) == record.reservation.node.identity.device,
           UInt64(status.st_ino) == record.reservation.node.identity.inode,
           status.st_uid == owner,
           status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        {
            _ = unlinkat(screenshotDescriptor, basename, 0)
        }
        _ = Darwin.close(record.descriptor)
    }

    private static func readArtifact(from descriptor: Int32) throws -> [UInt8] {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_size >= 0,
              UInt64(status.st_size) <= ScreenshotReservationValidator.maximumArtifactBytes
        else {
            throw ScreenshotArtifactError.artifactTooLarge
        }
        var bytes = [UInt8](repeating: 0, count: Int(status.st_size))
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.pread(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    remaining,
                    off_t(offset)
                )
            }
            if count > 0 { offset += count }
            else if count == -1, errno == EINTR { continue }
            else { throw Self.posixError() }
        }
        return bytes
    }

    private static func writeAll(_ bytes: [UInt8], to descriptor: Int32) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    buffer.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count == -1, errno == EINTR {
                    continue
                } else {
                    throw posixError()
                }
            }
        }
    }

    private static func node(
        for descriptor: Int32,
        owner: uid_t
    ) throws -> ScreenshotReservationNode {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw posixError() }
        guard status.st_uid == owner,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_mode & mode_t(0o7777) == 0o600
        else {
            throw ScreenshotArtifactError.unsafeHostPath
        }
        return ScreenshotReservationNode(
            identity: HostNodeIdentity(
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino)
            ),
            owner: UInt32(status.st_uid),
            kind: .regularFile,
            mode: UInt16(status.st_mode & mode_t(0o7777))
        )
    }

    private static func openDirectory(
        at path: String,
        owner: uid_t,
        mode: mode_t
    ) throws -> Int32 {
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw posixError() }
        do {
            try validateDirectory(descriptor, owner: owner, mode: mode)
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func ensureDirectory(
        named name: String,
        relativeTo parent: Int32,
        owner: uid_t
    ) throws -> Int32 {
        guard mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else {
            throw posixError()
        }
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw posixError() }
        do {
            try validateDirectory(descriptor, owner: owner, mode: 0o700)
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func validateDirectory(
        _ descriptor: Int32,
        owner: uid_t,
        mode: mode_t
    ) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw posixError() }
        guard status.st_uid == owner,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              status.st_mode & mode_t(0o7777) == mode
        else {
            throw ScreenshotArtifactError.unsafeHostPath
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    func shutdown() {
        lock.withLock {
            guard !closed else { return }
            let active = records
            for (key, record) in active {
                cleanupOwnedRecord(key: key, record: record)
            }
            closed = true
            _ = Darwin.close(screenshotDescriptor)
            screenshotDescriptor = -1
            _ = unlinkat(epochDescriptor, "screenshots", AT_REMOVEDIR)
            _ = Darwin.close(epochDescriptor)
            epochDescriptor = -1
            _ = unlinkat(targetDescriptor, epochName, AT_REMOVEDIR)
            _ = Darwin.close(targetDescriptor)
            targetDescriptor = -1
            _ = unlinkat(scratchDescriptor, targetName, AT_REMOVEDIR)
            _ = Darwin.close(scratchDescriptor)
            scratchDescriptor = -1
            _ = unlinkat(baseDescriptor, "scratch", AT_REMOVEDIR)
            _ = Darwin.close(baseDescriptor)
            baseDescriptor = -1
        }
    }

    deinit {
        shutdown()
    }
}
