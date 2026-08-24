import PulsePhoneSharedDefinitions

public struct ActionLogWriterClaim: Equatable, Sendable {
    public let canonicalUDID: CanonicalUDID
    public let runtimeEpoch: UInt64
    public let writerID: CanonicalUUID

    public init(
        canonicalUDID: CanonicalUDID,
        runtimeEpoch: UInt64,
        writerID: CanonicalUUID
    ) {
        self.canonicalUDID = canonicalUDID
        self.runtimeEpoch = runtimeEpoch
        self.writerID = writerID
    }
}

public enum ActionLogWriterClaimDisposition: Equatable, Sendable {
    case acquired
    case alreadyOwned
    case busy(existingWriterID: CanonicalUUID)
}

public enum ActionLogWriterClaimError: Error, Equatable, Sendable {
    case staleRelease
}

public struct ActionLogSingleWriterRegistry: Sendable {
    private var claims = [CanonicalUDID: ActionLogWriterClaim]()

    public init() {}

    public mutating func acquire(
        _ claim: ActionLogWriterClaim
    ) -> ActionLogWriterClaimDisposition {
        if let current = claims[claim.canonicalUDID] {
            return current == claim
                ? .alreadyOwned
                : .busy(existingWriterID: current.writerID)
        }
        claims[claim.canonicalUDID] = claim
        return .acquired
    }

    public mutating func release(
        _ claim: ActionLogWriterClaim
    ) throws {
        guard claims[claim.canonicalUDID] == claim else {
            throw ActionLogWriterClaimError.staleRelease
        }
        claims.removeValue(forKey: claim.canonicalUDID)
    }
}

public struct ActionLogFile: Equatable, Sendable {
    public let fileID: CanonicalUUID
    public private(set) var byteCount: Int
    public private(set) var closed: Bool
    public private(set) var records: [ActionLogRecord]
    public private(set) var trailingTornByteCount: Int

    public init(
        fileID: CanonicalUUID,
        records: [ActionLogRecord] = [],
        closed: Bool = false,
        trailingTornByteCount: Int = 0
    ) throws {
        self.fileID = fileID
        self.records = records
        self.closed = closed
        self.trailingTornByteCount = trailingTornByteCount
        self.byteCount = try records.reduce(0) {
            $0 + (try $1.canonicalLineBytes().count)
        }
    }

    fileprivate mutating func append(
        _ record: ActionLogRecord,
        byteCount: Int
    ) {
        records.append(record)
        self.byteCount += byteCount
    }

    fileprivate mutating func close() { closed = true }
    fileprivate mutating func discardTornTail() { trailingTornByteCount = 0 }
}

public enum ActionLogAppendDisposition: Equatable, Sendable {
    case appended(fileID: CanonicalUUID, recordSequence: UInt64)
    case droppedBestEffort
    case duplicateIgnored
}

public enum ActionLogWriterError: Error, Equatable, Sendable {
    case duplicateFileID
    case invalidRecoveredSequence
    case recordTooLarge
    case writerClosed
}

public struct ActionLogWriter: Sendable {
    public let maximumFileBytes: Int
    public private(set) var files: [ActionLogFile]
    private var appendKeys = Set<ActionLogAppendKey>()
    private var nextFileOrdinal: UInt64

    public init(
        firstFileID: CanonicalUUID,
        maximumFileBytes: Int = ActionLogRotation.maximumFileBytes
    ) throws {
        self.maximumFileBytes = maximumFileBytes
        self.files = [try ActionLogFile(fileID: firstFileID)]
        self.nextFileOrdinal = 1
    }

    public init(
        recovering files: [ActionLogFile],
        nextFileOrdinal: UInt64,
        maximumFileBytes: Int = ActionLogRotation.maximumFileBytes
    ) throws {
        guard Set(files.map(\.fileID)).count == files.count else {
            throw ActionLogWriterError.duplicateFileID
        }
        var keys = Set<ActionLogAppendKey>()
        var recovered = files
        for index in recovered.indices {
            for (recordIndex, record) in recovered[index].records.enumerated() {
                guard record.recordSequence == UInt64(recordIndex) else {
                    throw ActionLogWriterError.invalidRecoveredSequence
                }
                keys.insert(ActionLogAppendKey(event: record.event))
            }
            recovered[index].discardTornTail()
        }
        self.maximumFileBytes = maximumFileBytes
        self.files = recovered
        self.appendKeys = keys
        self.nextFileOrdinal = nextFileOrdinal
    }

    public mutating func append(
        _ event: ActionLogEvent,
        nextFileID: () throws -> CanonicalUUID
    ) throws -> ActionLogAppendDisposition {
        let key = ActionLogAppendKey(event: event)
        guard !appendKeys.contains(key) else { return .duplicateIgnored }
        guard var current = files.popLast() else {
            throw ActionLogWriterError.writerClosed
        }
        guard !current.closed else {
            files.append(current)
            throw ActionLogWriterError.writerClosed
        }
        var record = ActionLogRecord(
            recordSequence: UInt64(current.records.count),
            event: event
        )
        var bytes = try record.canonicalLineBytes()
        switch ActionLogRotation.decide(
            currentByteCount: current.byteCount,
            currentRecordCount: current.records.count,
            nextRecordByteCount: bytes.count,
            maximumFileBytes: maximumFileBytes
        ) {
        case .recordTooLarge:
            files.append(current)
            throw ActionLogWriterError.recordTooLarge
        case .rotateThenAppend:
            current.close()
            files.append(current)
            let fileID = try nextFileID()
            guard !files.contains(where: { $0.fileID == fileID }) else {
                throw ActionLogWriterError.duplicateFileID
            }
            current = try ActionLogFile(fileID: fileID)
            record = ActionLogRecord(recordSequence: 0, event: event)
            bytes = try record.canonicalLineBytes()
            nextFileOrdinal += 1
        case .appendCurrent:
            break
        }
        current.append(record, byteCount: bytes.count)
        files.append(current)
        appendKeys.insert(key)
        return .appended(
            fileID: current.fileID,
            recordSequence: record.recordSequence
        )
    }

    public mutating func appendBestEffort(
        _ event: ActionLogEvent,
        sinkAvailable: Bool,
        nextFileID: () throws -> CanonicalUUID
    ) -> ActionLogAppendDisposition {
        guard sinkAvailable else { return .droppedBestEffort }
        return (try? append(event, nextFileID: nextFileID))
            ?? .droppedBestEffort
    }
}
