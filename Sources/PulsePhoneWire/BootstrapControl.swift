import Foundation
import PulsePhoneSharedDefinitions

public enum BootstrapOperation: String, CaseIterable, Equatable, Sendable {
    case probeRuntimeLite
    case retireIfIdle
    case stopReplayTraceAndFinalize
}

public struct BootstrapRequest: Equatable, Sendable {
    public let requestID: CanonicalUUID
    public let operation: BootstrapOperation

    public init(requestID: CanonicalUUID, operation: BootstrapOperation) {
        self.requestID = requestID
        self.operation = operation
    }
}

public struct BootstrapErrorPayload: Equatable, Sendable {
    public static let allowedCodes: Set<String> = [
        "incompatibleRuntimeBusy",
        "noActiveTrace",
        "runtimeFailed",
        "traceWriteFailed",
        "unsupportedBootstrapOperation",
    ]

    public let code: String
    public let details: RepositoryJSONObject

    public init(code: String, details: RepositoryJSONObject) throws {
        guard Self.allowedCodes.contains(code) else {
            throw RuntimeWireCodecError.invalidPayload
        }
        self.code = code
        self.details = details
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.code == rhs.code
            && RepositoryCanonicalJSON.encodeDocument(lhs.details)
                == RepositoryCanonicalJSON.encodeDocument(rhs.details)
    }
}

public struct BootstrapResponse: Equatable, Sendable {
    public let requestID: CanonicalUUID
    public let operation: BootstrapOperation
    public let ok: Bool
    public let result: RepositoryJSONObject?
    public let error: BootstrapErrorPayload?

    public init(
        requestID: CanonicalUUID,
        operation: BootstrapOperation,
        result: RepositoryJSONObject
    ) {
        self.requestID = requestID
        self.operation = operation
        self.ok = true
        self.result = result
        self.error = nil
    }

    public init(
        requestID: CanonicalUUID,
        operation: BootstrapOperation,
        error: BootstrapErrorPayload
    ) {
        self.requestID = requestID
        self.operation = operation
        self.ok = false
        self.result = nil
        self.error = error
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.requestID == rhs.requestID
            && lhs.operation == rhs.operation
            && lhs.ok == rhs.ok
            && canonicalBytes(lhs.result) == canonicalBytes(rhs.result)
            && lhs.error == rhs.error
    }

    private static func canonicalBytes(
        _ object: RepositoryJSONObject?
    ) -> [UInt8]? {
        object.map(RepositoryCanonicalJSON.encodeDocument)
    }
}

public enum BootstrapControlSessionError: Error, Equatable, Sendable {
    case alreadyConsumed
    case expired
    case invalidRequest
}

public final class BootstrapControlSession: @unchecked Sendable {
    public static let absoluteLifetimeNanoseconds: UInt64 = 15_000_000_000

    private let deadline: MonotonicInstant
    private let stateLock = NSLock()
    private var consumed = false

    public init(startedAt: MonotonicInstant) throws {
        self.deadline = try startedAt.advanced(
            by: MonotonicDuration(
                nanoseconds: Self.absoluteLifetimeNanoseconds
            )
        )
    }

    public func accept(
        _ frameBytes: [UInt8],
        now: MonotonicInstant
    ) throws -> BootstrapRequest {
        stateLock.lock()
        guard !consumed else {
            stateLock.unlock()
            throw BootstrapControlSessionError.alreadyConsumed
        }
        consumed = true
        stateLock.unlock()
        guard now <= deadline else {
            throw BootstrapControlSessionError.expired
        }
        do {
            return try BootstrapControlCodec.decodeRequest(frameBytes)
        } catch {
            throw BootstrapControlSessionError.invalidRequest
        }
    }
}

public enum BootstrapControlCodec {
    public static func encodeRequest(_ request: BootstrapRequest) throws -> [UInt8] {
        try encodeFrame(
            type: .bootstrapRequestV1,
            object: RuntimeHandshakeCodec.object([
                ("operation", .string(request.operation.rawValue)),
                ("payload", .object(try RuntimeHandshakeCodec.object([]))),
                ("requestID", .string(request.requestID.canonicalString)),
                ("schemaVersion", .number(.uint64(1))),
            ])
        )
    }

    public static func decodeRequest(_ bytes: [UInt8]) throws -> BootstrapRequest {
        let object = try RuntimeHandshakeCodec.decodePayloadObject(
            bytes,
            expectedType: .bootstrapRequestV1
        )
        guard RuntimeHandshakeCodec.exactKeys(object) == [
            "operation", "payload", "requestID", "schemaVersion",
        ],
        try RuntimeHandshakeCodec.uint(object, "schemaVersion") == 1,
        let requestValue = object["requestID"]?.stringValue,
        let requestID = try? CanonicalUUID(requestValue),
        let operationValue = object["operation"]?.stringValue,
        let operation = BootstrapOperation(rawValue: operationValue),
        let payload = object["payload"]?.objectValue,
        payload.members.isEmpty
        else {
            throw RuntimeWireCodecError.invalidPayload
        }
        return BootstrapRequest(requestID: requestID, operation: operation)
    }

    public static func encodeResponse(_ response: BootstrapResponse) throws -> [UInt8] {
        var members: [(String, RepositoryJSONValue)] = [
            ("ok", .bool(response.ok)),
            ("operation", .string(response.operation.rawValue)),
            ("requestID", .string(response.requestID.canonicalString)),
            ("schemaVersion", .number(.uint64(1))),
        ]
        if let result = response.result {
            members.append(("result", .object(result)))
        }
        if let error = response.error {
            members.append((
                "error",
                .object(
                    try RuntimeHandshakeCodec.object([
                        ("code", .string(error.code)),
                        ("details", .object(error.details)),
                    ])
                )
            ))
        }
        return try encodeFrame(
            type: .bootstrapResponseV1,
            object: RuntimeHandshakeCodec.object(members)
        )
    }

    public static func decodeResponse(_ bytes: [UInt8]) throws -> BootstrapResponse {
        let object = try RuntimeHandshakeCodec.decodePayloadObject(
            bytes,
            expectedType: .bootstrapResponseV1
        )
        let keys = RuntimeHandshakeCodec.exactKeys(object)
        guard keys == ["ok", "operation", "requestID", "result", "schemaVersion"]
                || keys == ["error", "ok", "operation", "requestID", "schemaVersion"],
              try RuntimeHandshakeCodec.uint(object, "schemaVersion") == 1,
              case .bool(let ok)? = object["ok"],
              let requestValue = object["requestID"]?.stringValue,
              let requestID = try? CanonicalUUID(requestValue),
              let operationValue = object["operation"]?.stringValue,
              let operation = BootstrapOperation(rawValue: operationValue)
        else {
            throw RuntimeWireCodecError.invalidPayload
        }
        if ok {
            guard let result = object["result"]?.objectValue,
                  object["error"] == nil
            else {
                throw RuntimeWireCodecError.invalidPayload
            }
            return BootstrapResponse(
                requestID: requestID,
                operation: operation,
                result: result
            )
        }
        guard let errorObject = object["error"]?.objectValue,
              RuntimeHandshakeCodec.exactKeys(errorObject) == ["code", "details"],
              let code = errorObject["code"]?.stringValue,
              let details = errorObject["details"]?.objectValue,
              object["result"] == nil
        else {
            throw RuntimeWireCodecError.invalidPayload
        }
        return BootstrapResponse(
            requestID: requestID,
            operation: operation,
            error: try BootstrapErrorPayload(code: code, details: details)
        )
    }

    private static func encodeFrame(
        type: RuntimeWireMessageType,
        object: RepositoryJSONObject
    ) throws -> [UInt8] {
        try RuntimeWireFrameCodec.encode(
            RuntimeWireFrame(
                messageType: type,
                payload: RepositoryCanonicalJSON.encodeDocument(object)
            )
        )
    }
}
