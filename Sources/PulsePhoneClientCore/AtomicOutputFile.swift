import PulsePhoneSharedDefinitions

public enum AtomicOutputNodeState: Equatable, Sendable {
    case absent
    case present
}

public enum AtomicOutputFileError: Error, Equatable, Sendable {
    case invalidArtifact
    case localWriteFailed
    case outputExists
    case timedOut
}

public struct ScreenshotReceivedArtifact: Equatable, Sendable {
    public let bytes: [UInt8]
    public let contentType: String
    public let readOnly: Bool

    public init(
        bytes: [UInt8],
        contentType: String,
        readOnly: Bool
    ) throws {
        guard readOnly,
              contentType == "image/png",
              UInt64(bytes.count) <= 64 * 1_024 * 1_024,
              bytes.starts(with: [
                  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
              ])
        else {
            throw AtomicOutputFileError.invalidArtifact
        }
        self.bytes = bytes
        self.contentType = contentType
        self.readOnly = readOnly
    }
}

public struct AtomicOutputFilePlan: Equatable, Sendable {
    public let absoluteOutputPath: String
    public let replaceExisting: Bool

    public init(absoluteOutputPath: String, replaceExisting: Bool) {
        self.absoluteOutputPath = absoluteOutputPath
        self.replaceExisting = replaceExisting
    }
}

public struct AtomicOutputStageCosts: Equatable, Sendable {
    public let createNanoseconds: UInt64
    public let writeNanoseconds: UInt64
    public let fileSyncNanoseconds: UInt64
    public let renameNanoseconds: UInt64
    public let directorySyncNanoseconds: UInt64

    public init(
        createNanoseconds: UInt64 = 0,
        writeNanoseconds: UInt64 = 0,
        fileSyncNanoseconds: UInt64 = 0,
        renameNanoseconds: UInt64 = 0,
        directorySyncNanoseconds: UInt64 = 0
    ) {
        self.createNanoseconds = createNanoseconds
        self.writeNanoseconds = writeNanoseconds
        self.fileSyncNanoseconds = fileSyncNanoseconds
        self.renameNanoseconds = renameNanoseconds
        self.directorySyncNanoseconds = directorySyncNanoseconds
    }
}

public protocol AtomicOutputFileSystem: AnyObject, Sendable {
    func nodeState(at absolutePath: String) throws -> AtomicOutputNodeState
    func createExclusiveSiblingTemp(
        for absoluteOutputPath: String,
        tempBasename: String,
        mode: UInt16
    ) throws -> String
    func write(_ bytes: [UInt8], toTempPath: String) throws
    func syncFile(atTempPath: String) throws
    func renameTemp(
        _ tempPath: String,
        to absoluteOutputPath: String,
        replaceExisting: Bool
    ) throws
    func syncParentDirectory(of absoluteOutputPath: String) throws
    func removeTempIfPresent(_ tempPath: String)
}

public enum AtomicOutputFile {
    public static let localWriteDeadlineNanoseconds: UInt64 = 5_000_000_000

    public static func preflight(
        absoluteOutputPath: String,
        force: Bool,
        fileSystem: any AtomicOutputFileSystem
    ) throws -> AtomicOutputFilePlan {
        let state: AtomicOutputNodeState
        do {
            state = try fileSystem.nodeState(at: absoluteOutputPath)
        } catch {
            throw AtomicOutputFileError.localWriteFailed
        }
        guard force || state == .absent else {
            throw AtomicOutputFileError.outputExists
        }
        return AtomicOutputFilePlan(
            absoluteOutputPath: absoluteOutputPath,
            replaceExisting: force
        )
    }

    public static func write(
        plan: AtomicOutputFilePlan,
        artifact: ScreenshotReceivedArtifact,
        tempID: CanonicalUUID,
        costs: AtomicOutputStageCosts = AtomicOutputStageCosts(),
        fileSystem: any AtomicOutputFileSystem
    ) throws {
        let tempBasename = ".pulsephone-\(tempID).tmp"
        var tempPath: String?
        var elapsed: UInt64 = 0
        do {
            try advance(&elapsed, by: costs.createNanoseconds)
            let created = try fileSystem.createExclusiveSiblingTemp(
                for: plan.absoluteOutputPath,
                tempBasename: tempBasename,
                mode: 0o600
            )
            tempPath = created
            try advance(&elapsed, by: costs.writeNanoseconds)
            try fileSystem.write(artifact.bytes, toTempPath: created)
            try advance(&elapsed, by: costs.fileSyncNanoseconds)
            try fileSystem.syncFile(atTempPath: created)
            try advance(&elapsed, by: costs.renameNanoseconds)
            try fileSystem.renameTemp(
                created,
                to: plan.absoluteOutputPath,
                replaceExisting: plan.replaceExisting
            )
            tempPath = nil
            try advance(&elapsed, by: costs.directorySyncNanoseconds)
            try fileSystem.syncParentDirectory(of: plan.absoluteOutputPath)
        } catch AtomicOutputFileError.timedOut {
            if let tempPath { fileSystem.removeTempIfPresent(tempPath) }
            throw AtomicOutputFileError.timedOut
        } catch {
            if let tempPath { fileSystem.removeTempIfPresent(tempPath) }
            throw AtomicOutputFileError.localWriteFailed
        }
    }

    private static func advance(
        _ elapsed: inout UInt64,
        by duration: UInt64
    ) throws {
        let next = elapsed.addingReportingOverflow(duration)
        guard !next.overflow,
              next.partialValue <= localWriteDeadlineNanoseconds
        else {
            throw AtomicOutputFileError.timedOut
        }
        elapsed = next.partialValue
    }
}
