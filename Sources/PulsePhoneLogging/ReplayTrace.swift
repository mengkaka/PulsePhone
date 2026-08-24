import PulsePhoneSharedDefinitions

public enum ReplayTraceCompleteness: String, Equatable, Sendable {
    case complete
    case incomplete
    case noFooter
}

public enum ReplayTraceFinalizeReason: String, Equatable, Sendable {
    case explicitStop
    case runtimeCrash
    case sizeCap
    case writeFailure
}

public enum ReplayTraceSemanticEventKind: String, Equatable, Sendable {
    case invocation
    case result
    case summary
}

public enum ReplayTraceError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidPath
    case invalidSemanticEvent
    case writerClosed
}

public struct ReplayTraceSemanticEvent: Equatable, Sendable {
    public let actionID: CanonicalUUID
    public let commandID: String
    public let eventKind: ReplayTraceSemanticEventKind
    public let outcome: ActionLogTerminalOutcome?
    public let payloadByteCount: UInt64?

    public init(
        actionID: CanonicalUUID,
        commandID: String,
        eventKind: ReplayTraceSemanticEventKind,
        outcome: ActionLogTerminalOutcome? = nil,
        payloadByteCount: UInt64? = nil
    ) throws {
        let bytes = Array(commandID.utf8)
        guard (1...128).contains(bytes.count),
              bytes.allSatisfy({ (0x21...0x7e).contains($0) }),
              (eventKind == .result) == (outcome != nil)
        else {
            throw ReplayTraceError.invalidSemanticEvent
        }
        self.actionID = actionID
        self.commandID = commandID
        self.eventKind = eventKind
        self.outcome = outcome
        self.payloadByteCount = payloadByteCount
    }

    fileprivate func canonicalLineBytes() throws -> [UInt8] {
        var members: [RepositoryJSONMember] = [
            .init(key: "actionID", value: .string(actionID.description)),
            .init(key: "commandID", value: .string(commandID)),
            .init(key: "eventKind", value: .string(eventKind.rawValue)),
            .init(key: "kind", value: .string("trace.semantic")),
            .init(key: "redacted", value: .bool(true)),
            .init(key: "schemaVersion", value: .number(.uint64(1))),
        ]
        if let outcome {
            members.append(.init(
                key: "outcome",
                value: .string(outcome.rawValue)
            ))
        }
        if let payloadByteCount {
            members.append(.init(
                key: "payloadByteCount",
                value: .number(.uint64(payloadByteCount))
            ))
        }
        return try Self.line(members)
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

public struct ReplayTraceFinalization: Equatable, Sendable {
    public let absolutePath: String
    public let byteCount: Int
    public let completeness: ReplayTraceCompleteness
    public let reason: ReplayTraceFinalizeReason
    public let traceID: CanonicalUUID
}

public enum ReplayTraceAppendDisposition: Equatable, Sendable {
    case appended(byteCount: Int)
    case autoFinalized(ReplayTraceFinalization)
}

public struct ReplayTraceWriter: Sendable {
    public static let maximumFileBytes = 5 * 1_024 * 1_024
    public static let footerReserveBytes = 512

    public let absolutePath: String
    public let footerReserveBytes: Int
    public let maximumFileBytes: Int
    public let traceID: CanonicalUUID
    public private(set) var bytes: [UInt8]
    public private(set) var finalization: ReplayTraceFinalization?

    public init(
        traceID: CanonicalUUID,
        absolutePath: String,
        maximumFileBytes: Int = Self.maximumFileBytes,
        footerReserveBytes: Int = Self.footerReserveBytes
    ) throws {
        guard absolutePath.utf8.first == 0x2f,
              absolutePath.utf8.count <= 4_096,
              !absolutePath.utf8.contains(0)
        else {
            throw ReplayTraceError.invalidPath
        }
        let header = try ReplayTraceSemanticEvent.line([
            .init(key: "kind", value: .string("trace.header")),
            .init(key: "schemaVersion", value: .number(.uint64(1))),
            .init(key: "traceID", value: .string(traceID.description)),
        ])
        let footerSizes = try ReplayTraceCompleteness.allFooterValues.flatMap {
            completeness in
            try ReplayTraceFinalizeReason.allCasesForFooter.map { reason in
                try Self.footerLine(
                    traceID: traceID,
                    completeness: completeness,
                    reason: reason
                ).count
            }
        }
        guard maximumFileBytes > footerReserveBytes,
              footerReserveBytes >= (footerSizes.max() ?? 0),
              header.count <= maximumFileBytes - footerReserveBytes
        else {
            throw ReplayTraceError.invalidConfiguration
        }
        self.traceID = traceID
        self.absolutePath = absolutePath
        self.maximumFileBytes = maximumFileBytes
        self.footerReserveBytes = footerReserveBytes
        self.bytes = header
        self.finalization = nil
    }

    public mutating func append(
        _ event: ReplayTraceSemanticEvent,
        semanticWriteAvailable: Bool = true,
        incompleteFooterWriteAvailable: Bool = true
    ) throws -> ReplayTraceAppendDisposition {
        guard finalization == nil else { throw ReplayTraceError.writerClosed }
        guard semanticWriteAvailable else {
            return .autoFinalized(finalize(
                completeness: .incomplete,
                reason: .writeFailure,
                footerWriteAvailable: incompleteFooterWriteAvailable
            ))
        }
        let line = try event.canonicalLineBytes()
        let payloadLimit = maximumFileBytes - footerReserveBytes
        let projected = bytes.count.addingReportingOverflow(line.count)
        guard !projected.overflow, projected.partialValue <= payloadLimit else {
            return .autoFinalized(finalize(
                completeness: .incomplete,
                reason: .sizeCap,
                footerWriteAvailable: incompleteFooterWriteAvailable
            ))
        }
        bytes.append(contentsOf: line)
        return .appended(byteCount: bytes.count)
    }

    public mutating func stop(
        completeFooterWriteAvailable: Bool = true,
        incompleteFooterWriteAvailable: Bool = true
    ) throws -> ReplayTraceFinalization {
        guard finalization == nil else { throw ReplayTraceError.writerClosed }
        if completeFooterWriteAvailable {
            return finalize(
                completeness: .complete,
                reason: .explicitStop,
                footerWriteAvailable: true
            )
        }
        return finalize(
            completeness: .incomplete,
            reason: .writeFailure,
            footerWriteAvailable: incompleteFooterWriteAvailable
        )
    }

    public mutating func hardCrash() throws -> ReplayTraceFinalization {
        guard finalization == nil else { throw ReplayTraceError.writerClosed }
        return finalize(
            completeness: .noFooter,
            reason: .runtimeCrash,
            footerWriteAvailable: false
        )
    }

    private mutating func finalize(
        completeness requestedCompleteness: ReplayTraceCompleteness,
        reason: ReplayTraceFinalizeReason,
        footerWriteAvailable: Bool
    ) -> ReplayTraceFinalization {
        var completeness = requestedCompleteness
        if footerWriteAvailable,
           let footer = try? Self.footerLine(
               traceID: traceID,
               completeness: requestedCompleteness,
               reason: reason
           )
        {
            let projected = bytes.count.addingReportingOverflow(footer.count)
            if !projected.overflow, projected.partialValue <= maximumFileBytes {
                bytes.append(contentsOf: footer)
            } else {
                completeness = .noFooter
            }
        } else {
            completeness = .noFooter
        }
        let result = ReplayTraceFinalization(
            absolutePath: absolutePath,
            byteCount: bytes.count,
            completeness: completeness,
            reason: reason,
            traceID: traceID
        )
        finalization = result
        return result
    }

    private static func footerLine(
        traceID: CanonicalUUID,
        completeness: ReplayTraceCompleteness,
        reason: ReplayTraceFinalizeReason
    ) throws -> [UInt8] {
        try ReplayTraceSemanticEvent.line([
            .init(key: "completeness", value: .string(completeness.rawValue)),
            .init(key: "kind", value: .string("trace.footer")),
            .init(key: "reason", value: .string(reason.rawValue)),
            .init(key: "schemaVersion", value: .number(.uint64(1))),
            .init(key: "traceID", value: .string(traceID.description)),
        ])
    }
}

private extension ReplayTraceCompleteness {
    static let allFooterValues: [ReplayTraceCompleteness] = [
        .complete,
        .incomplete,
    ]
}

private extension ReplayTraceFinalizeReason {
    static let allCasesForFooter: [ReplayTraceFinalizeReason] = [
        .explicitStop,
        .runtimeCrash,
        .sizeCap,
        .writeFailure,
    ]
}
