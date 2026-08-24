import Foundation
import PulsePhoneSharedDefinitions

public enum ActionLogEventKind: String, Equatable, Hashable, Sendable {
    case begin = "action.begin"
    case terminal = "action.terminal"
}

public enum ActionLogSourceRole: String, Equatable, Sendable {
    case cli
    case gui
    case runtime
}

public enum ActionLogTerminalOutcome: String, Equatable, Sendable {
    case cancelled
    case failed
    case outcomeUnknown
    case partial
    case succeeded
}

public enum ActionLogResultDelivery: String, Equatable, Sendable {
    case clientGone
    case delivered
}

public enum ActionLogError: Error, Equatable, Sendable {
    case identityHashMismatch
    case invalidCommandID
    case invalidDuration
    case invalidRuntimeEpoch
    case invalidTimestamp
}

public struct ActionLogIdentity: Equatable, Sendable {
    public let canonicalUDID: CanonicalUDID
    public let canonicalUDIDHash: String
    public let createdAtUTC: String
    public let schemaVersion: Int

    public init(
        canonicalUDID: CanonicalUDID,
        canonicalUDIDHash: String,
        createdAtUTC: String
    ) throws {
        guard canonicalUDIDHash == canonicalUDID.domainSeparatedHash else {
            throw ActionLogError.identityHashMismatch
        }
        guard ActionLogCommon.validASCII(createdAtUTC, maximum: 64) else {
            throw ActionLogError.invalidTimestamp
        }
        self.schemaVersion = 1
        self.canonicalUDID = canonicalUDID
        self.canonicalUDIDHash = canonicalUDIDHash
        self.createdAtUTC = createdAtUTC
    }
}

public struct ActionLogCommon: Equatable, Sendable {
    public let actionID: CanonicalUUID
    public let canonicalUDID: CanonicalUDID
    public let commandID: String
    public let parentActionID: CanonicalUUID?
    public let runtimeEpoch: UInt64
    public let sourceClientInstanceID: CanonicalUUID?
    public let sourceRole: ActionLogSourceRole
    public let timestampUTC: String

    public init(
        actionID: CanonicalUUID,
        parentActionID: CanonicalUUID? = nil,
        canonicalUDID: CanonicalUDID,
        sourceRole: ActionLogSourceRole,
        sourceClientInstanceID: CanonicalUUID? = nil,
        commandID: String,
        timestampUTC: String,
        runtimeEpoch: UInt64
    ) throws {
        guard runtimeEpoch > 0 else {
            throw ActionLogError.invalidRuntimeEpoch
        }
        guard Self.validASCII(commandID, maximum: 128) else {
            throw ActionLogError.invalidCommandID
        }
        guard Self.validASCII(timestampUTC, maximum: 64) else {
            throw ActionLogError.invalidTimestamp
        }
        self.actionID = actionID
        self.parentActionID = parentActionID
        self.canonicalUDID = canonicalUDID
        self.sourceRole = sourceRole
        self.sourceClientInstanceID = sourceClientInstanceID
        self.commandID = commandID
        self.timestampUTC = timestampUTC
        self.runtimeEpoch = runtimeEpoch
    }

    fileprivate static func validASCII(
        _ value: String,
        maximum: Int
    ) -> Bool {
        let bytes = Array(value.utf8)
        return (1...maximum).contains(bytes.count)
            && bytes.allSatisfy { (0x20...0x7e).contains($0) }
    }
}

public struct ActionLogBegin: Equatable, Sendable {
    public let common: ActionLogCommon
    public let executionShape: String
    public let redactedArguments: [String: String]
    public let routeSummary: String?

    public init(
        common: ActionLogCommon,
        executionShape: String,
        redactedArguments: [String: String],
        routeSummary: String? = nil
    ) throws {
        let validRoute = routeSummary.map {
            ActionLogCommon.validASCII($0, maximum: 256)
        } ?? true
        guard ActionLogCommon.validASCII(executionShape, maximum: 64),
              validRoute
        else {
            throw ActionLogError.invalidCommandID
        }
        self.common = common
        self.executionShape = executionShape
        self.redactedArguments = redactedArguments
        self.routeSummary = routeSummary
    }
}

public struct ActionLogTerminal: Equatable, Sendable {
    public let attemptSummary: String?
    public let commitState: String?
    public let common: ActionLogCommon
    public let durationNanoseconds: UInt64
    public let outcome: ActionLogTerminalOutcome
    public let resultDelivery: ActionLogResultDelivery
    public let resultSummary: String?

    public init(
        common: ActionLogCommon,
        outcome: ActionLogTerminalOutcome,
        commitState: String? = nil,
        durationNanoseconds: UInt64,
        attemptSummary: String? = nil,
        resultSummary: String? = nil,
        resultDelivery: ActionLogResultDelivery
    ) throws {
        guard durationNanoseconds <= 86_400_000_000_000 else {
            throw ActionLogError.invalidDuration
        }
        for value in [commitState, attemptSummary, resultSummary].compactMap({ $0 }) {
            guard ActionLogCommon.validASCII(value, maximum: 512) else {
                throw ActionLogError.invalidCommandID
            }
        }
        self.common = common
        self.outcome = outcome
        self.commitState = commitState
        self.durationNanoseconds = durationNanoseconds
        self.attemptSummary = attemptSummary
        self.resultSummary = resultSummary
        self.resultDelivery = resultDelivery
    }
}

public enum ActionLogEvent: Equatable, Sendable {
    case begin(ActionLogBegin)
    case terminal(ActionLogTerminal)

    public var common: ActionLogCommon {
        switch self {
        case .begin(let value): value.common
        case .terminal(let value): value.common
        }
    }

    public var kind: ActionLogEventKind {
        switch self {
        case .begin: .begin
        case .terminal: .terminal
        }
    }
}

public struct ActionLogAppendKey: Hashable, Sendable {
    public let actionID: CanonicalUUID
    public let eventKind: ActionLogEventKind

    public init(event: ActionLogEvent) {
        self.actionID = event.common.actionID
        self.eventKind = event.kind
    }
}

public struct ActionLogRecord: Equatable, Sendable {
    public let event: ActionLogEvent
    public let recordSequence: UInt64
    public let schemaVersion: Int

    public init(recordSequence: UInt64, event: ActionLogEvent) {
        self.schemaVersion = 1
        self.recordSequence = recordSequence
        self.event = event
    }

    public func canonicalLineBytes() throws -> [UInt8] {
        let common = event.common
        var members: [RepositoryJSONMember] = [
            .init(key: "actionID", value: .string(common.actionID.description)),
            .init(key: "canonicalUDID", value: .string(common.canonicalUDID.rawValue)),
            .init(key: "commandID", value: .string(common.commandID)),
            .init(key: "eventKind", value: .string(event.kind.rawValue)),
            .init(key: "recordSequence", value: .number(.uint64(recordSequence))),
            .init(key: "runtimeEpoch", value: .number(.uint64(common.runtimeEpoch))),
            .init(key: "schemaVersion", value: .number(.uint64(1))),
            .init(key: "sourceRole", value: .string(common.sourceRole.rawValue)),
            .init(key: "timestampUTC", value: .string(common.timestampUTC)),
        ]
        if let parent = common.parentActionID {
            members.append(.init(
                key: "parentActionID",
                value: .string(parent.description)
            ))
        }
        if let client = common.sourceClientInstanceID {
            members.append(.init(
                key: "sourceClientInstanceID",
                value: .string(client.description)
            ))
        }
        switch event {
        case .begin(let begin):
            members.append(.init(
                key: "executionShape",
                value: .string(begin.executionShape)
            ))
            members.append(.init(
                key: "redactedArguments",
                value: .object(try RepositoryJSONObject(members:
                    begin.redactedArguments.map {
                        RepositoryJSONMember(
                            key: $0.key,
                            value: .string($0.value)
                        )
                    }
                ))
            ))
            if let route = begin.routeSummary {
                members.append(.init(key: "routeSummary", value: .string(route)))
            }
        case .terminal(let terminal):
            members.append(.init(
                key: "durationNanoseconds",
                value: .number(.uint64(terminal.durationNanoseconds))
            ))
            members.append(.init(
                key: "outcome",
                value: .string(terminal.outcome.rawValue)
            ))
            members.append(.init(
                key: "resultDelivery",
                value: .string(terminal.resultDelivery.rawValue)
            ))
            for (key, value) in [
                ("attemptSummary", terminal.attemptSummary),
                ("commitState", terminal.commitState),
                ("resultSummary", terminal.resultSummary),
            ] where value != nil {
                members.append(.init(key: key, value: .string(value!)))
            }
        }
        var bytes = RepositoryCanonicalJSON.encodeDocument(
            try RepositoryJSONObject(members: members)
        )
        bytes.append(0x0a)
        return bytes
    }
}
