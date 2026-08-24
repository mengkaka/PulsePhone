import Foundation
import PulsePhoneSharedDefinitions
import PulsePhoneWire

public struct RuntimeRequestEnvelope: Sendable {
    public let requestID: CanonicalUUID
    public let operation: RuntimeOperationID
    public let body: RepositoryJSONObject

    public init(
        requestID: CanonicalUUID,
        operation: RuntimeOperationID,
        body: RepositoryJSONObject
    ) {
        self.requestID = requestID
        self.operation = operation
        self.body = body
    }
}

public struct RuntimeStreamFrameEnvelope: Sendable {
    public let sessionID: CanonicalUUID
    public let interactionID: CanonicalUUID
    public let sequence: UInt64
    public let frameKind: String
    public let payload: RepositoryJSONObject
    public let clientSubmittedMonotonicNanoseconds: UInt64?
}

public struct RuntimeResponseAssociation: Equatable, Sendable {
    public let requestID: CanonicalUUID
    public let operation: RuntimeOperationID
}

public enum RuntimeInboundMessage: Sendable {
    case bootstrap(BootstrapRequest)
    case request(RuntimeRequestEnvelope)
    case streamFrame(RuntimeStreamFrameEnvelope)
}

public enum ControlDispatcherError: Error, Equatable, Sendable {
    case connectionClosed
    case protocolViolation
    case invalidPayload
    case targetMismatch
    case bootstrapResponseMismatch
    case requestTracking(RuntimeRequestTrackingError)
    case bootstrap(BootstrapControlSessionError)
}

public enum RuntimeControlCodec {
    public static func decodeResponseAssociation(
        _ frame: RuntimeWireFrame
    ) throws -> RuntimeResponseAssociation {
        guard frame.messageType == .response, frame.flags == 0 else {
            throw ControlDispatcherError.protocolViolation
        }
        let object: RepositoryJSONObject
        do {
            object = try RepositoryCanonicalJSON.parseDocument(
                frame.payload,
                maximumByteCount: 256 * 1_024
            )
        } catch {
            throw ControlDispatcherError.invalidPayload
        }
        guard exactKeys(object) == ["payload", "requestID", "schemaVersion"],
              try uint(object, "schemaVersion") == 1,
              let requestValue = object["requestID"]?.stringValue,
              let requestID = try? CanonicalUUID(requestValue),
              let payload = object["payload"]?.objectValue,
              let operationValue = payload["operation"]?.stringValue,
              let operation = RuntimeOperationID(rawValue: operationValue),
              payload["result"]?.objectValue != nil
        else {
            throw ControlDispatcherError.invalidPayload
        }
        let keys = Set(payload.members.map(\.key))
        let allowedKeys: Set<String> = [
            "actionID", "operation", "parentActionID", "result",
        ]
        guard keys.isSubset(of: allowedKeys),
              keys.contains("operation"),
              keys.contains("result")
        else {
            throw ControlDispatcherError.invalidPayload
        }
        let actionID = try optionalUUID(payload, "actionID")
        let parentActionID = try optionalUUID(payload, "parentActionID")
        guard parentActionID == nil || actionID != nil else {
            throw ControlDispatcherError.invalidPayload
        }
        return RuntimeResponseAssociation(
            requestID: requestID,
            operation: operation
        )
    }

    private static func exactKeys(_ object: RepositoryJSONObject) -> [String] {
        object.members.map(\.key).sorted()
    }

    private static func uint(
        _ object: RepositoryJSONObject,
        _ key: String
    ) throws -> UInt64 {
        guard let number = object[key]?.numberValue,
              let value = try? number.requireUInt64()
        else {
            throw ControlDispatcherError.invalidPayload
        }
        return value
    }

    private static func optionalUUID(
        _ object: RepositoryJSONObject,
        _ key: String
    ) throws -> CanonicalUUID? {
        guard let value = object[key] else {
            return nil
        }
        guard let string = value.stringValue,
              let identifier = try? CanonicalUUID(string)
        else {
            throw ControlDispatcherError.invalidPayload
        }
        return identifier
    }
}

public final class ControlDispatcher: @unchecked Sendable {
    private let lock = NSLock()
    private let canonicalUDID: CanonicalUDID
    private let requests: RuntimeConnectionRequests
    private let bootstrapSession: BootstrapControlSession?
    private var acceptedBootstrapRequest: BootstrapRequest?
    private var state: RuntimeHandshakeConnectionState

    public init(
        state: RuntimeHandshakeConnectionState,
        canonicalUDID: CanonicalUDID,
        requests: RuntimeConnectionRequests,
        bootstrapStartedAt: MonotonicInstant? = nil
    ) throws {
        guard state == .normal || state == .bootstrapOnly else {
            throw ControlDispatcherError.protocolViolation
        }
        if state == .bootstrapOnly {
            guard let bootstrapStartedAt else {
                throw ControlDispatcherError.protocolViolation
            }
            self.bootstrapSession = try BootstrapControlSession(
                startedAt: bootstrapStartedAt
            )
        } else {
            self.bootstrapSession = nil
        }
        self.state = state
        self.canonicalUDID = canonicalUDID
        self.requests = requests
    }

    public var connectionState: RuntimeHandshakeConnectionState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public func completeBootstrapResponse(
        _ response: BootstrapResponse
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard state == .bootstrapOnly,
              let request = acceptedBootstrapRequest,
              response.requestID == request.requestID,
              response.operation == request.operation
        else {
            state = .closed
            throw ControlDispatcherError.bootstrapResponseMismatch
        }
        state = .closed
    }

    public func dispatch(
        _ frame: RuntimeWireFrame,
        now: MonotonicInstant
    ) throws -> RuntimeInboundMessage {
        lock.lock()
        defer { lock.unlock() }
        guard state != .closed else {
            throw ControlDispatcherError.connectionClosed
        }
        guard frame.flags == 0 else {
            state = .closed
            throw ControlDispatcherError.protocolViolation
        }

        do {
            switch state {
            case .bootstrapOnly:
                guard frame.messageType == .bootstrapRequestV1,
                      let bootstrapSession
                else {
                    throw ControlDispatcherError.protocolViolation
                }
                let bytes = try RuntimeWireFrameCodec.encode(frame)
                let request = try bootstrapSession.accept(bytes, now: now)
                acceptedBootstrapRequest = request
                return .bootstrap(request)
            case .normal:
                switch frame.messageType {
                case .request:
                    let request = try decodeRequest(frame.payload)
                    try validateTarget(for: request)
                    do {
                        try requests.accept(
                            requestID: request.requestID,
                            operation: request.operation,
                            now: now
                        )
                    } catch let error as RuntimeRequestTrackingError {
                        throw ControlDispatcherError.requestTracking(error)
                    }
                    return .request(request)
                case .streamFrame:
                    return .streamFrame(try decodeStreamFrame(frame.payload))
                default:
                    throw ControlDispatcherError.protocolViolation
                }
            case .awaitingHello, .closed:
                throw ControlDispatcherError.protocolViolation
            }
        } catch let error as ControlDispatcherError {
            if shouldClose(for: error) {
                state = .closed
            }
            throw error
        } catch let error as BootstrapControlSessionError {
            state = .closed
            throw ControlDispatcherError.bootstrap(error)
        } catch {
            state = .closed
            throw ControlDispatcherError.invalidPayload
        }
    }

    private func shouldClose(for error: ControlDispatcherError) -> Bool {
        switch error {
        case .protocolViolation, .invalidPayload, .targetMismatch,
             .bootstrapResponseMismatch, .bootstrap:
            return true
        case .requestTracking(.duplicateRequestID),
             .requestTracking(.requestNotActive),
             .requestTracking(.operationMismatch),
             .requestTracking(.associatedMessageAfterTerminal):
            return true
        case .connectionClosed,
             .requestTracking(.connectionCapacityExceeded),
             .requestTracking(.runtimeCapacityExceeded):
            return false
        }
    }

    private func decodeRequest(_ payload: [UInt8]) throws -> RuntimeRequestEnvelope {
        let object = try parseObject(payload, maximumBytes: 1 * 1_024 * 1_024)
        guard exactKeys(object) == ["payload", "requestID", "schemaVersion"],
              try uint(object, "schemaVersion") == 1,
              let requestValue = object["requestID"]?.stringValue,
              let requestID = try? CanonicalUUID(requestValue),
              let payloadObject = object["payload"]?.objectValue,
              exactKeys(payloadObject) == ["body", "operation"],
              let operationValue = payloadObject["operation"]?.stringValue,
              let operation = RuntimeOperationID(rawValue: operationValue),
              let body = payloadObject["body"]?.objectValue
        else {
            throw ControlDispatcherError.invalidPayload
        }
        return RuntimeRequestEnvelope(
            requestID: requestID,
            operation: operation,
            body: body
        )
    }

    private func decodeStreamFrame(
        _ payload: [UInt8]
    ) throws -> RuntimeStreamFrameEnvelope {
        let object = try parseObject(payload, maximumBytes: 8 * 1_024)
        let keys = exactKeys(object)
        let required = [
            "frameKind", "interactionID", "payload", "schemaVersion", "seq",
            "sessionID",
        ]
        guard keys == required
                || keys == (required + ["clientSubmittedMonotonicNs"]).sorted(),
              try uint(object, "schemaVersion") == 1,
              let sessionValue = object["sessionID"]?.stringValue,
              let sessionID = try? CanonicalUUID(sessionValue),
              let interactionValue = object["interactionID"]?.stringValue,
              let interactionID = try? CanonicalUUID(interactionValue),
              let frameKind = object["frameKind"]?.stringValue,
              !frameKind.isEmpty,
              frameKind.utf8.count <= 128,
              let framePayload = object["payload"]?.objectValue
        else {
            throw ControlDispatcherError.invalidPayload
        }
        let submitted: UInt64?
        if object["clientSubmittedMonotonicNs"] != nil {
            submitted = try uint(object, "clientSubmittedMonotonicNs")
        } else {
            submitted = nil
        }
        return RuntimeStreamFrameEnvelope(
            sessionID: sessionID,
            interactionID: interactionID,
            sequence: try uint(object, "seq"),
            frameKind: frameKind,
            payload: framePayload,
            clientSubmittedMonotonicNanoseconds: submitted
        )
    }

    private func validateTarget(for request: RuntimeRequestEnvelope) throws {
        let targetValue: RepositoryJSONValue?
        if request.operation == .streamOpen {
            targetValue = request.body["intent"]?.objectValue?["canonicalUDID"]
        } else {
            targetValue = request.body["canonicalUDID"]
        }
        if request.operation == .streamClose || request.operation == .streamCancel {
            guard targetValue == nil else {
                throw ControlDispatcherError.protocolViolation
            }
            return
        }
        guard let value = targetValue?.stringValue else {
            throw ControlDispatcherError.invalidPayload
        }
        guard value == canonicalUDID.rawValue else {
            throw ControlDispatcherError.targetMismatch
        }
    }

    private func parseObject(
        _ payload: [UInt8],
        maximumBytes: Int
    ) throws -> RepositoryJSONObject {
        do {
            return try RepositoryCanonicalJSON.parseDocument(
                payload,
                maximumByteCount: maximumBytes
            )
        } catch {
            throw ControlDispatcherError.invalidPayload
        }
    }

    private func exactKeys(_ object: RepositoryJSONObject) -> [String] {
        object.members.map(\.key).sorted()
    }

    private func uint(
        _ object: RepositoryJSONObject,
        _ key: String
    ) throws -> UInt64 {
        guard let number = object[key]?.numberValue,
              let value = try? number.requireUInt64()
        else {
            throw ControlDispatcherError.invalidPayload
        }
        return value
    }
}
