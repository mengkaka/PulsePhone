import PulsePhoneSharedDefinitions

public enum HelperWireConnectionState: String, Equatable, Sendable {
    case preAccepted
    case helloReceived
    case accepted
    case ready
    case closed
}

public enum HelperWireFailureScope: String, Equatable, Sendable {
    case preparationFailureRetireGeneration
    case fatalHelperFailure
}

public enum HelperWireViolationReason: String, Equatable, Sendable {
    case wrongGeneration
    case duplicateMessageID
    case wrongState
    case missingAssociation
    case duplicateOperation
    case invalidOrder
    case eventAfterResult
    case committedResultMismatch
    case invalidDeveloperSupportReference
    case forbiddenPathMaterial
    case wrongDeliveryAttempt
    case wrongFrameSequence
    case frameAckMismatch
    case cleanupBarrierIncomplete
}

public struct HelperWireProtocolViolation: Error, Equatable, Sendable {
    public let reason: HelperWireViolationReason
    public let scope: HelperWireFailureScope
}

public struct HelperWireProtocolSnapshot: Equatable, Sendable {
    public let connectionState: HelperWireConnectionState
    public let activeRequestIDs: [String]
    public let terminalRequestIDs: [String]
    public let activeSessionIDs: [String]
}

public struct HelperWireProtocolMachine: Sendable {
    private enum OneShotPhase: Int, Sendable {
        case requested
        case accepted
        case started
        case committed
    }

    private struct OneShot: Sendable {
        var phase: OneShotPhase
    }

    private struct Stream: Sendable {
        let deliveryAttemptID: String
        var nextSequence: UInt64
        var pendingAcknowledgements: Set<UInt64>
        var closing: Bool
    }

    public let runtimeEpoch: UInt64
    public let executorGeneration: UInt64

    private var connectionState: HelperWireConnectionState = .preAccepted
    private var seenMessageIDs = Set<String>()
    private var oneShots = [String: OneShot]()
    private var terminalRequestIDs = Set<String>()
    private var streams = [String: Stream]()
    private var terminalSessionIDs = Set<String>()

    public init(runtimeEpoch: UInt64, executorGeneration: UInt64) {
        self.runtimeEpoch = runtimeEpoch
        self.executorGeneration = executorGeneration
    }

    public var snapshot: HelperWireProtocolSnapshot {
        HelperWireProtocolSnapshot(
            connectionState: connectionState,
            activeRequestIDs: oneShots.keys.sorted(),
            terminalRequestIDs: terminalRequestIDs.sorted(),
            activeSessionIDs: streams.keys.sorted()
        )
    }

    public mutating func receive(
        _ message: HelperWireMessage,
        direction: HelperWireDirection
    ) throws {
        guard message.runtimeEpoch == runtimeEpoch,
              message.executorGeneration == executorGeneration
        else {
            throw violation(.wrongGeneration)
        }
        guard seenMessageIDs.insert(message.messageID.canonicalString).inserted else {
            throw violation(.duplicateMessageID)
        }
        if message.type == .protocolError {
            connectionState = .closed
            return
        }

        switch connectionState {
        case .preAccepted:
            guard direction == .helperToRuntime, message.type == .hello else {
                throw violation(.wrongState)
            }
            connectionState = .helloReceived
        case .helloReceived:
            guard direction == .runtimeToHelper, message.type == .helloAccepted else {
                throw violation(.wrongState)
            }
            connectionState = .accepted
        case .accepted:
            if direction == .helperToRuntime, message.type == .ready {
                connectionState = .ready
            } else if !isAcceptedControl(message, direction: direction) {
                throw violation(.wrongState)
            }
        case .ready:
            try receiveReady(message, direction: direction)
        case .closed:
            throw violation(.wrongState)
        }
    }

    public mutating func completeStreamCleanup(
        sessionID: CanonicalUUID,
        deliveryAttemptID: String
    ) throws {
        let key = sessionID.canonicalString
        guard let stream = streams[key],
              stream.deliveryAttemptID == deliveryAttemptID
        else {
            throw violation(.wrongDeliveryAttempt)
        }
        guard stream.closing, stream.pendingAcknowledgements.isEmpty else {
            throw violation(.cleanupBarrierIncomplete)
        }
        streams.removeValue(forKey: key)
        terminalSessionIDs.insert(key)
    }

    private mutating func receiveReady(
        _ message: HelperWireMessage,
        direction: HelperWireDirection
    ) throws {
        switch (direction, message.type) {
        case (.runtimeToHelper, .request):
            try openOneShot(message)
        case (.helperToRuntime, .accepted):
            try advanceOneShot(message, to: .accepted)
        case (.helperToRuntime, .started):
            try advanceOneShot(message, to: .started)
        case (.helperToRuntime, .committed):
            try advanceOneShot(message, to: .committed)
        case (.helperToRuntime, .progress):
            try receiveProgress(message)
        case (.helperToRuntime, .result):
            try completeOneShot(message)
        case (.runtimeToHelper, .streamOpen):
            try openStream(message)
        case (.runtimeToHelper, .frame):
            try receiveFrame(message)
        case (.helperToRuntime, .frameAccepted):
            try receiveFrameAccepted(message)
        case (.runtimeToHelper, .close), (.runtimeToHelper, .cancel):
            try beginStreamCleanup(message)
        case (.runtimeToHelper, .shutdown),
             (.helperToRuntime, .deviceDisconnected):
            return
        default:
            throw violation(.wrongState)
        }
    }

    private mutating func openOneShot(_ message: HelperWireMessage) throws {
        guard let requestID = message.requestID?.canonicalString,
              !terminalRequestIDs.contains(requestID),
              oneShots[requestID] == nil,
              let payload = message.payload
        else {
            throw violation(.duplicateOperation)
        }
        try validateRequestPayload(payload)
        oneShots[requestID] = OneShot(phase: .requested)
    }

    private mutating func advanceOneShot(
        _ message: HelperWireMessage,
        to next: OneShotPhase
    ) throws {
        guard let requestID = message.requestID?.canonicalString else {
            throw violation(.missingAssociation)
        }
        guard !terminalRequestIDs.contains(requestID) else {
            throw violation(.eventAfterResult)
        }
        guard var state = oneShots[requestID], next.rawValue > state.phase.rawValue else {
            throw violation(.invalidOrder)
        }
        state.phase = next
        oneShots[requestID] = state
    }

    private func receiveProgress(_ message: HelperWireMessage) throws {
        guard let requestID = message.requestID?.canonicalString else {
            throw violation(.missingAssociation)
        }
        guard !terminalRequestIDs.contains(requestID) else {
            throw violation(.eventAfterResult)
        }
        guard let state = oneShots[requestID],
              state.phase.rawValue >= OneShotPhase.started.rawValue
        else {
            throw violation(.invalidOrder)
        }
    }

    private mutating func completeOneShot(_ message: HelperWireMessage) throws {
        guard let requestID = message.requestID?.canonicalString else {
            throw violation(.missingAssociation)
        }
        guard !terminalRequestIDs.contains(requestID) else {
            throw violation(.eventAfterResult)
        }
        guard let state = oneShots[requestID], let payload = message.payload,
              Set(payload.keys) == ["fallbackDisposition", "result"],
              let result = payload["result"]?.objectValue
        else {
            throw violation(.invalidOrder)
        }
        if state.phase == .committed,
           result["commitState"]?.stringValue != "committed"
        {
            throw violation(.committedResultMismatch)
        }
        oneShots.removeValue(forKey: requestID)
        terminalRequestIDs.insert(requestID)
    }

    private mutating func openStream(_ message: HelperWireMessage) throws {
        guard let sessionID = message.sessionID?.canonicalString,
              let deliveryAttemptID = message.deliveryAttemptID,
              !terminalSessionIDs.contains(sessionID),
              streams[sessionID] == nil,
              let payload = message.payload,
              Set(payload.keys) == [
                "actionID", "interactionID", "streamKind", "streamPayload",
              ] || Set(payload.keys) == [
                "actionID", "interactionID", "parentActionID", "streamKind",
                "streamPayload",
              ],
              validUUID(payload["actionID"]),
              validUUID(payload["interactionID"]),
              payload["streamKind"]?.stringValue != nil,
              payload["streamPayload"]?.objectValue != nil
        else {
            throw violation(.duplicateOperation)
        }
        streams[sessionID] = Stream(
            deliveryAttemptID: deliveryAttemptID,
            nextSequence: 0,
            pendingAcknowledgements: [],
            closing: false
        )
    }

    private mutating func receiveFrame(_ message: HelperWireMessage) throws {
        guard let sessionID = message.sessionID?.canonicalString,
              let deliveryAttemptID = message.deliveryAttemptID,
              var stream = streams[sessionID],
              stream.deliveryAttemptID == deliveryAttemptID
        else {
            throw violation(.wrongDeliveryAttempt)
        }
        guard !stream.closing,
              let payload = message.payload,
              Set(payload.keys) == ["framePayload", "interactionID", "seq"],
              validUUID(payload["interactionID"]),
              let sequence = payload["seq"]?.uintValue,
              sequence == stream.nextSequence
        else {
            throw violation(.wrongFrameSequence)
        }
        stream.pendingAcknowledgements.insert(sequence)
        stream.nextSequence += 1
        streams[sessionID] = stream
    }

    private mutating func receiveFrameAccepted(
        _ message: HelperWireMessage
    ) throws {
        guard let sessionID = message.sessionID?.canonicalString,
              let deliveryAttemptID = message.deliveryAttemptID,
              var stream = streams[sessionID],
              stream.deliveryAttemptID == deliveryAttemptID
        else {
            throw violation(.wrongDeliveryAttempt)
        }
        guard let payload = message.payload,
              Set(payload.keys).isSubset(of: [
                "acceptedMonotonicNs", "interactionID", "seq",
              ]),
              Set(payload.keys).isSuperset(of: ["interactionID", "seq"]),
              validUUID(payload["interactionID"]),
              let sequence = payload["seq"]?.uintValue,
              stream.pendingAcknowledgements.remove(sequence) != nil
        else {
            throw violation(.frameAckMismatch)
        }
        streams[sessionID] = stream
    }

    private mutating func beginStreamCleanup(
        _ message: HelperWireMessage
    ) throws {
        guard let sessionID = message.sessionID?.canonicalString,
              let deliveryAttemptID = message.deliveryAttemptID,
              var stream = streams[sessionID],
              stream.deliveryAttemptID == deliveryAttemptID,
              !stream.closing
        else {
            throw violation(.wrongDeliveryAttempt)
        }
        guard let payload = message.payload,
              validUUID(payload["interactionID"]),
              payload["reason"]?.stringValue != nil
        else {
            throw violation(.invalidOrder)
        }
        stream.closing = true
        streams[sessionID] = stream
    }

    private func validateRequestPayload(
        _ payload: [String: HelperWireJSONValue]
    ) throws {
        let allowed = Set([
            "actionID", "backendPayload", "executorOperationID", "parentActionID",
        ])
        guard Set(payload.keys).isSubset(of: allowed),
              Set(payload.keys).isSuperset(of: [
                "actionID", "backendPayload", "executorOperationID",
              ]),
              validUUID(payload["actionID"]),
              payload["executorOperationID"]?.stringValue != nil,
              let backend = payload["backendPayload"]?.objectValue
        else {
            throw violation(.invalidOrder)
        }
        if backend.keys.contains("catalogRevision")
            || backend.keys.contains("catalogCanonicalSHA256")
            || backend.keys.contains("assetContentManifestSHA256")
            || backend.keys.contains("fileRoles")
        {
            try validateDeveloperSupportPayload(backend)
        }
    }

    private func validateDeveloperSupportPayload(
        _ payload: [String: HelperWireJSONValue]
    ) throws {
        let required = Set([
            "assetContentManifestSHA256", "catalogCanonicalSHA256",
            "catalogRevision", "deviceContext", "fileRoles", "operation",
            "preparationAttemptID", "preparationGroupID",
        ])
        let roles = Set([
            "classic.image", "classic.signature", "personalized.buildManifest",
            "personalized.image", "personalized.trustCache",
        ])
        let operations = Set([
            "mount", "probeServices", "queryMounted", "requestTSS",
            "warmGeneration",
        ])
        let groups = Set([
            "prep.coredevice.v2", "prep.direct.lockdown.v1",
            "prep.legacy.developer.v2",
        ])
        guard Set(payload.keys) == required,
              let revision = payload["catalogRevision"]?.stringValue,
              let catalogSHA256 = payload["catalogCanonicalSHA256"]?.stringValue,
              let contentSHA256 = payload["assetContentManifestSHA256"]?.stringValue,
              HelperWireCodec.isBoundedASCII(revision, maximumBytes: 256),
              StableBytes.isLowercaseHex(catalogSHA256, byteCount: 32),
              StableBytes.isLowercaseHex(contentSHA256, byteCount: 32),
              let roleValues = arrayStrings(payload["fileRoles"]),
              roleValues.count <= 5,
              Set(roleValues).count == roleValues.count,
              Set(roleValues).isSubset(of: roles),
              let operation = payload["operation"]?.stringValue,
              operations.contains(operation),
              let group = payload["preparationGroupID"]?.stringValue,
              groups.contains(group),
              payload["preparationAttemptID"]?.stringValue != nil,
              let context = payload["deviceContext"]?.objectValue
        else {
            throw violation(.invalidDeveloperSupportReference)
        }
        guard !containsForbiddenMaterial(.object(context)) else {
            throw violation(.forbiddenPathMaterial)
        }
    }

    private func containsForbiddenMaterial(
        _ value: HelperWireJSONValue
    ) -> Bool {
        let forbiddenKeys = Set([
            "absolutePath", "clientPath", "ecid", "nonce", "path",
            "sourceURL", "ticket", "url",
        ])
        switch value {
        case let .string(string):
            let segments = string.split(separator: "/", omittingEmptySubsequences: false)
            return string.hasPrefix("/") || string.contains("://")
                || string.contains("\\") || segments.contains("..")
        case let .array(values):
            return values.contains(where: containsForbiddenMaterial)
        case let .object(object):
            return !Set(object.keys).isDisjoint(with: forbiddenKeys)
                || object.values.contains(where: containsForbiddenMaterial)
        default:
            return false
        }
    }

    private func validUUID(_ value: HelperWireJSONValue?) -> Bool {
        guard let string = value?.stringValue else { return false }
        return (try? CanonicalUUID(string)) != nil
    }

    private func arrayStrings(_ value: HelperWireJSONValue?) -> [String]? {
        guard case let .array(values)? = value else { return nil }
        var result = [String]()
        for value in values {
            guard let string = value.stringValue else { return nil }
            result.append(string)
        }
        return result
    }

    private func isAcceptedControl(
        _ message: HelperWireMessage,
        direction: HelperWireDirection
    ) -> Bool {
        (direction == .runtimeToHelper && message.type == .shutdown)
            || (direction == .helperToRuntime && message.type == .deviceDisconnected)
    }

    private func violation(
        _ reason: HelperWireViolationReason
    ) -> HelperWireProtocolViolation {
        HelperWireProtocolViolation(
            reason: reason,
            scope: connectionState == .ready
                ? .fatalHelperFailure
                : .preparationFailureRetireGeneration
        )
    }
}
