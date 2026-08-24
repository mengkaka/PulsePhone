import Darwin
import Foundation

public final class ProductionAtomicOutputFileSystem:
    AtomicOutputFileSystem,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var descriptors = [String: Int32]()

    public init() {}

    public func nodeState(at absolutePath: String) throws -> AtomicOutputNodeState {
        var status = stat()
        if lstat(absolutePath, &status) == 0 { return .present }
        guard errno == ENOENT else { throw POSIXError(Self.code()) }
        return .absent
    }

    public func createExclusiveSiblingTemp(
        for absoluteOutputPath: String,
        tempBasename: String,
        mode: UInt16
    ) throws -> String {
        guard absoluteOutputPath.hasPrefix("/"),
              !absoluteOutputPath.utf8.contains(0),
              !tempBasename.isEmpty,
              !tempBasename.contains("/"),
              !tempBasename.utf8.contains(0)
        else {
            throw AtomicOutputFileError.localWriteFailed
        }
        let parent = (absoluteOutputPath as NSString).deletingLastPathComponent
        let path = (parent as NSString).appendingPathComponent(tempBasename)
        let descriptor = open(
            path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(mode)
        )
        guard descriptor >= 0 else { throw POSIXError(Self.code()) }
        lock.withLock { descriptors[path] = descriptor }
        return path
    }

    public func write(_ bytes: [UInt8], toTempPath path: String) throws {
        try lock.withLock {
            guard let descriptor = descriptors[path] else {
                throw AtomicOutputFileError.localWriteFailed
            }
            var offset = 0
            while offset < bytes.count {
                let count = bytes.withUnsafeBytes { buffer in
                    Darwin.write(
                        descriptor,
                        buffer.baseAddress!.advanced(by: offset),
                        bytes.count - offset
                    )
                }
                if count > 0 { offset += count }
                else if count == -1, errno == EINTR { continue }
                else { throw POSIXError(Self.code()) }
            }
        }
    }

    public func syncFile(atTempPath path: String) throws {
        try lock.withLock {
            guard let descriptor = descriptors[path], fsync(descriptor) == 0 else {
                throw POSIXError(Self.code())
            }
        }
    }

    public func renameTemp(
        _ tempPath: String,
        to absoluteOutputPath: String,
        replaceExisting: Bool
    ) throws {
        let descriptor = lock.withLock { descriptors.removeValue(forKey: tempPath) }
        if let descriptor, Darwin.close(descriptor) != 0 {
            throw POSIXError(Self.code())
        }
        let result: Int32
        if replaceExisting {
            result = Darwin.rename(tempPath, absoluteOutputPath)
        } else {
            result = renameatx_np(
                AT_FDCWD,
                tempPath,
                AT_FDCWD,
                absoluteOutputPath,
                UInt32(RENAME_EXCL)
            )
        }
        guard result == 0 else { throw POSIXError(Self.code()) }
    }

    public func syncParentDirectory(of absoluteOutputPath: String) throws {
        let parent = (absoluteOutputPath as NSString).deletingLastPathComponent
        let descriptor = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(Self.code()) }
        defer { _ = Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(Self.code()) }
    }

    public func removeTempIfPresent(_ path: String) {
        if let descriptor = lock.withLock({ descriptors.removeValue(forKey: path) }) {
            _ = Darwin.close(descriptor)
        }
        _ = unlink(path)
    }

    deinit {
        let snapshot: [String: Int32] = lock.withLock {
            let snapshot = descriptors
            descriptors.removeAll()
            return snapshot
        }
        for (path, descriptor) in snapshot {
            _ = Darwin.close(descriptor)
            _ = unlink(path)
        }
    }

    private static func code() -> POSIXErrorCode {
        POSIXErrorCode(rawValue: errno) ?? .EIO
    }
}
