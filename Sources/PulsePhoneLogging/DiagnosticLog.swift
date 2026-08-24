import PulsePhoneSharedDefinitions

public enum DiagnosticLogCompleteness: String, Equatable, Sendable {
    case complete
    case incomplete
}

public enum DiagnosticLogFinalizeReason: String, Equatable, Sendable {
    case explicitStop
    case shutdown
    case shutdownTimeout
    case sizeCap
    case writeFailure
}

public enum DiagnosticLogCategory: String, Equatable, Sendable {
    case backend
    case lifecycle
    case maintenance
    case supervision
}

public enum DiagnosticLogError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidEvent
    case invalidPath
    case writerClosed
}

public struct DiagnosticLogEvent: Equatable, Sendable {
    public let category: DiagnosticLogCategory
    public let code: String
    public let occurrenceCount: UInt64

    public init(
        category: DiagnosticLogCategory,
        code: String,
        occurrenceCount: UInt64 = 1
    ) throws {
        let bytes = Array(code.utf8)
        guard (1...128).contains(bytes.count),
              bytes.allSatisfy({ (0x21...0x7e).contains($0) }),
              occurrenceCount > 0
        else {
            throw DiagnosticLogError.invalidEvent
        }
        self.category = category
        self.code = code
        self.occurrenceCount = occurrenceCount
    }

    fileprivate func canonicalLineBytes() throws -> [UInt8] {
        try Self.line([
            .init(key: "category", value: .string(category.rawValue)),
            .init(key: "code", value: .string(code)),
            .init(key: "kind", value: .string("diagnostic.event")),
            .init(
                key: "occurrenceCount",
                value: .number(.uint64(occurrenceCount))
            ),
            .init(key: "redacted", value: .bool(true)),
            .init(key: "schemaVersion", value: .number(.uint64(1))),
        ])
    }

    fileprivate static func line(
        _ members: [RepositoryJSONMember]
    ) throws -> [UInt8] {
        var bytes = RepositoryCanonicalJSON.encodeDocument(
            try RepositoryJSONObject(members: members)
        )
        bytes.append(0x0a)
        return bytes
    }
}

public struct DiagnosticLogFinalization: Equatable, Sendable {
    public let absolutePath: String
    public let byteCount: Int
    public let completeness: DiagnosticLogCompleteness
    public let footerWritten: Bool
    public let reason: DiagnosticLogFinalizeReason
    public let sessionID: CanonicalUUID
}

public enum DiagnosticLogAppendDisposition: Equatable, Sendable {
    case appended(byteCount: Int)
    case autoFinalized(DiagnosticLogFinalization)
}

public struct DiagnosticLogWriter: Sendable {
    public static let maximumFileBytes = 5 * 1_024 * 1_024
    public static let footerReserveBytes = 384

    public let absolutePath: String
    public let footerReserveBytes: Int
    public let maximumFileBytes: Int
    public let sessionID: CanonicalUUID
    public private(set) var bytes: [UInt8]
    public private(set) var finalization: DiagnosticLogFinalization?

    public init(
        sessionID: CanonicalUUID,
        absolutePath: String,
        maximumFileBytes: Int = Self.maximumFileBytes,
        footerReserveBytes: Int = Self.footerReserveBytes
    ) throws {
        guard absolutePath.utf8.first == 0x2f,
              absolutePath.utf8.count <= 4_096,
              !absolutePath.utf8.contains(0)
        else {
            throw DiagnosticLogError.invalidPath
        }
        let header = try DiagnosticLogEvent.line([
            .init(key: "kind", value: .string("diagnostic.header")),
            .init(key: "schemaVersion", value: .number(.uint64(1))),
            .init(key: "sessionID", value: .string(sessionID.description)),
        ])
        let maximumFooter = try DiagnosticLogFinalizeReason.allCases.map {
            try Self.footerLine(
                sessionID: sessionID,
                completeness: .incomplete,
                reason: $0
            ).count
        }.max() ?? 0
        guard maximumFileBytes > footerReserveBytes,
              footerReserveBytes >= maximumFooter,
              header.count <= maximumFileBytes - footerReserveBytes
        else {
            throw DiagnosticLogError.invalidConfiguration
        }
        self.sessionID = sessionID
        self.absolutePath = absolutePath
        self.maximumFileBytes = maximumFileBytes
        self.footerReserveBytes = footerReserveBytes
        self.bytes = header
        self.finalization = nil
    }

    public mutating func append(
        _ event: DiagnosticLogEvent,
        writeAvailable: Bool = true,
        footerWriteAvailable: Bool = true
    ) throws -> DiagnosticLogAppendDisposition {
        guard finalization == nil else { throw DiagnosticLogError.writerClosed }
        guard writeAvailable else {
            return .autoFinalized(finalize(
                completeness: .incomplete,
                reason: .writeFailure,
                footerWriteAvailable: footerWriteAvailable
            ))
        }
        let line = try event.canonicalLineBytes()
        let payloadLimit = maximumFileBytes - footerReserveBytes
        let projected = bytes.count.addingReportingOverflow(line.count)
        guard !projected.overflow, projected.partialValue <= payloadLimit else {
            return .autoFinalized(finalize(
                completeness: .incomplete,
                reason: .sizeCap,
                footerWriteAvailable: footerWriteAvailable
            ))
        }
        bytes.append(contentsOf: line)
        return .appended(byteCount: bytes.count)
    }

    public mutating func stop(
        reason: DiagnosticLogFinalizeReason = .explicitStop,
        footerWriteAvailable: Bool = true
    ) throws -> DiagnosticLogFinalization {
        guard finalization == nil else { throw DiagnosticLogError.writerClosed }
        let completeness: DiagnosticLogCompleteness = footerWriteAvailable
            ? .complete
            : .incomplete
        return finalize(
            completeness: completeness,
            reason: reason,
            footerWriteAvailable: footerWriteAvailable
        )
    }

    public mutating func forceIncomplete(
        reason: DiagnosticLogFinalizeReason,
        footerWriteAvailable: Bool
    ) throws -> DiagnosticLogFinalization {
        guard finalization == nil else { throw DiagnosticLogError.writerClosed }
        return finalize(
            completeness: .incomplete,
            reason: reason,
            footerWriteAvailable: footerWriteAvailable
        )
    }

    private mutating func finalize(
        completeness: DiagnosticLogCompleteness,
        reason: DiagnosticLogFinalizeReason,
        footerWriteAvailable: Bool
    ) -> DiagnosticLogFinalization {
        var wroteFooter = false
        if footerWriteAvailable,
           let footer = try? Self.footerLine(
               sessionID: sessionID,
               completeness: completeness,
               reason: reason
           )
        {
            let projected = bytes.count.addingReportingOverflow(footer.count)
            if !projected.overflow, projected.partialValue <= maximumFileBytes {
                bytes.append(contentsOf: footer)
                wroteFooter = true
            }
        }
        let result = DiagnosticLogFinalization(
            absolutePath: absolutePath,
            byteCount: bytes.count,
            completeness: wroteFooter ? completeness : .incomplete,
            footerWritten: wroteFooter,
            reason: reason,
            sessionID: sessionID
        )
        finalization = result
        return result
    }

    private static func footerLine(
        sessionID: CanonicalUUID,
        completeness: DiagnosticLogCompleteness,
        reason: DiagnosticLogFinalizeReason
    ) throws -> [UInt8] {
        try DiagnosticLogEvent.line([
            .init(key: "completeness", value: .string(completeness.rawValue)),
            .init(key: "kind", value: .string("diagnostic.footer")),
            .init(key: "reason", value: .string(reason.rawValue)),
            .init(key: "schemaVersion", value: .number(.uint64(1))),
            .init(key: "sessionID", value: .string(sessionID.description)),
        ])
    }
}

private extension DiagnosticLogFinalizeReason {
    static let allCases: [DiagnosticLogFinalizeReason] = [
        .explicitStop,
        .shutdown,
        .shutdownTimeout,
        .sizeCap,
        .writeFailure,
    ]
}
