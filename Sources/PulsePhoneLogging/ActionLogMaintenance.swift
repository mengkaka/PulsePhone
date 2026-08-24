import PulsePhoneSharedDefinitions

public enum ActionLogMaintenanceNodeKind: String, Equatable, Sendable {
    case actionFile
    case identity
    case maintenanceLock
    case writerLock
}

public struct ActionLogMaintenanceFile: Equatable, Sendable {
    public let byteCount: UInt64
    public let closedAtEpochSeconds: UInt64
    public let fileName: String
    public let nodeKind: ActionLogMaintenanceNodeKind
    public let writerLockAvailable: Bool

    public init(
        fileName: String,
        nodeKind: ActionLogMaintenanceNodeKind,
        byteCount: UInt64,
        closedAtEpochSeconds: UInt64,
        writerLockAvailable: Bool
    ) {
        self.fileName = fileName
        self.nodeKind = nodeKind
        self.byteCount = byteCount
        self.closedAtEpochSeconds = closedAtEpochSeconds
        self.writerLockAvailable = writerLockAvailable
    }
}

public struct ActionLogMaintenanceTarget: Equatable, Sendable {
    public let canonicalUDID: CanonicalUDID
    public let identityValid: Bool
    public let files: [ActionLogMaintenanceFile]

    public init(
        canonicalUDID: CanonicalUDID,
        identityValid: Bool,
        files: [ActionLogMaintenanceFile]
    ) {
        self.canonicalUDID = canonicalUDID
        self.identityValid = identityValid
        self.files = files
    }
}

public enum ActionLogMaintenanceOutcome: String, Equatable, Sendable {
    case partial
    case succeeded
}

public struct ActionLogMaintenanceResult: Equatable, Sendable {
    public let deletedByteCount: UInt64
    public let deletedFileCount: Int
    public let failedCount: Int
    public let failedSample: [String]
    public let outcome: ActionLogMaintenanceOutcome
    public let scanComplete: Bool
    public let skippedCount: Int
    public let skippedSample: [String]
}

public enum ActionLogMaintenance {
    public static let absoluteDeadlineNanoseconds: UInt64 = 30_000_000_000
    public static let closedAgeSeconds: UInt64 = 7 * 24 * 60 * 60
    public static let maximumClosedFilesPerTarget = 5
    public static let maximumBytesPerTarget: UInt64 = 50 * 1_024 * 1_024
    public static let maximumGlobalBytes: UInt64 = 250 * 1_024 * 1_024
    public static let maximumSampleCount = 64
    public static let maximumSampleBytes = 1_024

    public static func prune(
        targets: [ActionLogMaintenanceTarget],
        nowEpochSeconds: UInt64,
        startedAtNanoseconds: UInt64 = 0,
        scanCostNanosecondsPerNode: UInt64 = 1
    ) -> ActionLogMaintenanceResult {
        let sortedTargets = targets.sorted {
            $0.canonicalUDID < $1.canonicalUDID
        }
        var desired = Set<String>()
        var allActionFiles = [(target: CanonicalUDID, file: ActionLogMaintenanceFile)]()
        for target in sortedTargets where target.identityValid {
            let files = target.files.filter { $0.nodeKind == .actionFile }
                .sorted(by: fileOrder)
            allActionFiles.append(contentsOf: files.map { (target.canonicalUDID, $0) })
            for file in files where nowEpochSeconds >= file.closedAtEpochSeconds
                && nowEpochSeconds - file.closedAtEpochSeconds > closedAgeSeconds
            {
                desired.insert(key(target.canonicalUDID, file.fileName))
            }
            var remaining = files.filter {
                !desired.contains(key(target.canonicalUDID, $0.fileName))
            }
            while remaining.count > maximumClosedFilesPerTarget {
                desired.insert(key(target.canonicalUDID, remaining.removeFirst().fileName))
            }
            var bytes = remaining.reduce(UInt64(0)) {
                saturatingAdd($0, $1.byteCount)
            }
            while bytes > maximumBytesPerTarget, !remaining.isEmpty {
                let removed = remaining.removeFirst()
                desired.insert(key(target.canonicalUDID, removed.fileName))
                bytes = bytes >= removed.byteCount ? bytes - removed.byteCount : 0
            }
        }

        var globallyRemaining = allActionFiles.filter {
            !desired.contains(key($0.target, $0.file.fileName))
        }.sorted {
            if $0.file.closedAtEpochSeconds != $1.file.closedAtEpochSeconds {
                return $0.file.closedAtEpochSeconds < $1.file.closedAtEpochSeconds
            }
            return key($0.target, $0.file.fileName) < key($1.target, $1.file.fileName)
        }
        var globalBytes = globallyRemaining.reduce(UInt64(0)) {
            saturatingAdd($0, $1.file.byteCount)
        }
        while globalBytes > maximumGlobalBytes, !globallyRemaining.isEmpty {
            let removed = globallyRemaining.removeFirst()
            desired.insert(key(removed.target, removed.file.fileName))
            globalBytes = globalBytes >= removed.file.byteCount
                ? globalBytes - removed.file.byteCount
                : 0
        }

        let deadline = startedAtNanoseconds.addingReportingOverflow(
            absoluteDeadlineNanoseconds
        )
        var cursor = startedAtNanoseconds
        var deletedBytes: UInt64 = 0
        var deletedFiles = 0
        var failed = 0
        var failedSample = [String]()
        var skipped = 0
        var skippedSample = [String]()
        var scanComplete = !deadline.overflow

        scan: for target in sortedTargets {
            guard target.identityValid else {
                failed += 1
                appendSample("\(target.canonicalUDID.rawValue):identityInvalid", to: &failedSample)
                continue
            }
            for file in target.files.sorted(by: fileOrder) {
                let next = cursor.addingReportingOverflow(scanCostNanosecondsPerNode)
                guard !next.overflow, next.partialValue < deadline.partialValue else {
                    scanComplete = false
                    break scan
                }
                cursor = next.partialValue
                guard file.nodeKind == .actionFile,
                      desired.contains(key(target.canonicalUDID, file.fileName))
                else { continue }
                guard file.writerLockAvailable else {
                    skipped += 1
                    appendSample("\(target.canonicalUDID.rawValue):\(file.fileName):writerBusy", to: &skippedSample)
                    continue
                }
                deletedFiles += 1
                deletedBytes = saturatingAdd(deletedBytes, file.byteCount)
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

    private static func fileOrder(
        _ lhs: ActionLogMaintenanceFile,
        _ rhs: ActionLogMaintenanceFile
    ) -> Bool {
        if lhs.closedAtEpochSeconds != rhs.closedAtEpochSeconds {
            return lhs.closedAtEpochSeconds < rhs.closedAtEpochSeconds
        }
        return lhs.fileName.utf8.lexicographicallyPrecedes(rhs.fileName.utf8)
    }

    private static func key(_ target: CanonicalUDID, _ fileName: String) -> String {
        "\(target.rawValue)\u{0}\(fileName)"
    }

    private static func appendSample(
        _ sample: String,
        to samples: inout [String]
    ) {
        guard samples.count < maximumSampleCount else { return }
        let bytes = Array(sample.utf8.prefix(maximumSampleBytes))
        var value = String(decoding: bytes, as: UTF8.self)
        while value.utf8.count > maximumSampleBytes {
            value.removeLast()
        }
        samples.append(value)
    }

    private static func saturatingAdd(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }
}

public enum ActionLogRuntimePresence: Equatable, Sendable {
    case absent
    case compatible
    case incompatible
}

public enum ActionLogClearRoute: Equatable, Sendable {
    case localClosedFiles
    case runtimeRotateCloseReopen
    case unavailable
}

public enum ActionLogClearPlanner {
    public static func route(
        runtimePresence: ActionLogRuntimePresence
    ) -> ActionLogClearRoute {
        switch runtimePresence {
        case .absent: .localClosedFiles
        case .compatible: .runtimeRotateCloseReopen
        case .incompatible: .unavailable
        }
    }
}
