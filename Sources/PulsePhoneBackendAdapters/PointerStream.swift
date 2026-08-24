import Foundation
import PulsePhoneCommandPlanner
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions

public enum PointerStreamFrameKind: String, Codable, Equatable, Sendable {
    case begin
    case cancel
    case end
    case move
}

public enum PointerStreamEdge: String, Codable, Equatable, Sendable {
    case bottom
    case left
    case none
    case right
    case top
}

public struct PointerStreamInputFrame: Equatable, Sendable {
    public let edge: PointerStreamEdge
    public let expectedGeometry: GeometryAssertionDTO
    public let kind: PointerStreamFrameKind
    public let point: NormalizedPointV1
    public let sequence: UInt64

    public init(
        sequence: UInt64,
        kind: PointerStreamFrameKind,
        point: NormalizedPointV1,
        edge: PointerStreamEdge,
        expectedGeometry: GeometryAssertionDTO
    ) {
        self.sequence = sequence
        self.kind = kind
        self.point = point
        self.edge = edge
        self.expectedGeometry = expectedGeometry
    }
}

public struct PointerDeviceFrame: Codable, Equatable, Sendable {
    public let edge: PointerStreamEdge
    public let expectedConnectionEpoch: UInt64
    public let expectedGeometryRevision: UInt64
    public let kind: PointerStreamFrameKind
    public let sequence: UInt64
    public let x: UInt16
    public let y: UInt16
}

public enum PointerFrameTransportDisposition: Equatable, Sendable {
    case accepted(acceptedMonotonicNanoseconds: UInt64?)
    case unconfirmed
}

public struct PointerAcceptedDeliveryObservation: Equatable, Sendable {
    public let acceptedMonotonicNanoseconds: UInt64?
    public let clientSubmittedMonotonicNanoseconds: UInt64?
    public let expectedConnectionEpoch: UInt64
    public let expectedGeometryRevision: UInt64
    public let frameKind: PointerStreamFrameKind
    public let interactionID: CanonicalUUID
    public let sequence: UInt64
    public let sessionID: CanonicalUUID

    public init(
        sessionID: CanonicalUUID,
        interactionID: CanonicalUUID,
        sequence: UInt64,
        frameKind: PointerStreamFrameKind,
        expectedConnectionEpoch: UInt64,
        expectedGeometryRevision: UInt64,
        clientSubmittedMonotonicNanoseconds: UInt64?,
        acceptedMonotonicNanoseconds: UInt64?
    ) {
        self.sessionID = sessionID
        self.interactionID = interactionID
        self.sequence = sequence
        self.frameKind = frameKind
        self.expectedConnectionEpoch = expectedConnectionEpoch
        self.expectedGeometryRevision = expectedGeometryRevision
        self.clientSubmittedMonotonicNanoseconds =
            clientSubmittedMonotonicNanoseconds
        self.acceptedMonotonicNanoseconds = acceptedMonotonicNanoseconds
    }
}

public protocol PointerAcceptedDeliveryObserver: Sendable {
    func recordAcceptedDelivery(
        _ observation: PointerAcceptedDeliveryObservation
    )
}

public protocol PointerStreamTransport: Sendable {
    func open(
        sessionID: CanonicalUUID,
        interactionID: CanonicalUUID,
        routeID: String
    ) throws
    func send(
        frame: PointerDeviceFrame,
        deliveryAttemptID: String
    ) throws -> PointerFrameTransportDisposition
    func cancelAndClean(
        timeoutMilliseconds: UInt64
    ) throws -> OperationCleanupDisposition
}

public enum PointerStreamError: Error, Equatable, Sendable {
    case invalidCoordinate
    case invalidFrameOrder
    case transportFailure
}

public struct PointerStreamAction: Sendable {
    public static let absoluteMaximumMilliseconds: UInt64 = 30_000
    public static let cleanupMilliseconds: UInt64 = 2_000
    public static let commandID = "gui.pointer.interaction"
    public static let preparationGroupID = "prep.coredevice.v2"
    public static let routeID = "coredevice.pointerStream"

    private enum ProtocolState: Equatable, Sendable {
        case active
        case awaitingBegin
        case ended(StreamCloseMode)
    }

    private struct SubmittedTelemetry: Equatable, Sendable {
        let clientSubmittedMonotonicNanoseconds: UInt64?
        let frameKind: PointerStreamFrameKind
    }

    private let acceptedDeliveryObserver: (any PointerAcceptedDeliveryObserver)?
    private var currentGeometry: DisplayGeometryDTO
    private var deliveryCounter: UInt64 = 0
    private var pendingLatestMoveSequence: UInt64?
    private var protocolState: ProtocolState = .awaitingBegin
    private var session: StreamSession
    private var submittedTelemetryBySequence = [UInt64: SubmittedTelemetry]()
    private let transport: any PointerStreamTransport

    public init(
        openRequestID: CanonicalUUID,
        actionID: CanonicalUUID,
        sessionID: CanonicalUUID,
        interactionID: CanonicalUUID,
        currentGeometry: DisplayGeometryDTO,
        transport: any PointerStreamTransport,
        acceptedDeliveryObserver: (any PointerAcceptedDeliveryObserver)? = nil
    ) throws {
        self.currentGeometry = currentGeometry
        self.transport = transport
        self.acceptedDeliveryObserver = acceptedDeliveryObserver
        self.session = try StreamSession(
            openRequestID: openRequestID,
            actionID: actionID,
            sessionID: sessionID,
            interactionID: interactionID,
            plan: StreamSessionPlan(bufferPlan: Self.bufferPlan())
        )
    }

    public var snapshot: StreamSessionSnapshot { session.snapshot }

    public static func bufferPlan() throws -> StreamBufferPlan {
        try StreamBufferPlan(
            frameRules: [
                StreamFrameRule(frameKind: "begin", deliveryClass: .ordered),
                StreamFrameRule(
                    frameKind: "move",
                    deliveryClass: .latestWins(slotID: "pointer.move")
                ),
                StreamFrameRule(frameKind: "end", deliveryClass: .ordered),
                StreamFrameRule(frameKind: "cancel", deliveryClass: .ordered),
            ],
            maximumOpeningFrames: 3
        )
    }

    public mutating func beginOpening(
        inhibitorTokenID: String,
        bindings: OperationRuntimeBindings
    ) throws {
        try session.beginOpening(
            inhibitorTokenID: inhibitorTokenID,
            bindings: bindings
        )
    }

    public mutating func completeOpen() throws {
        do {
            try transport.open(
                sessionID: session.sessionID,
                interactionID: session.interactionID,
                routeID: Self.routeID
            )
            try session.markBackendOpen()
        } catch {
            abortActiveSession(outcome: .outcomeUnknown)
            throw PointerStreamError.transportFailure
        }
    }

    public mutating func updateGeometry(_ geometry: DisplayGeometryDTO) {
        currentGeometry = geometry
    }

    public mutating func submit(
        _ frame: PointerStreamInputFrame,
        clientSubmittedMonotonicNanoseconds: UInt64? = nil
    ) throws {
        if frame.kind != .cancel {
            do {
                try frame.expectedGeometry.validate(currentGeometry)
            } catch {
                abortActiveSession(outcome: .cancelled)
                throw error
            }
        }
        let deviceFrame: PointerDeviceFrame
        do {
            deviceFrame = try project(frame)
            try validateOrder(frame)
        } catch {
            abortActiveSession(outcome: .cancelled)
            throw error
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            try session.submitFrame(StreamFrameEnvelope(
                sessionID: session.sessionID,
                interactionID: session.interactionID,
                sequence: frame.sequence,
                frameKind: frame.kind.rawValue,
                encodedBytes: [UInt8](try encoder.encode(deviceFrame))
            ))
            if frame.kind == .move,
               let replacedSequence = pendingLatestMoveSequence
            {
                submittedTelemetryBySequence.removeValue(
                    forKey: replacedSequence
                )
            }
            submittedTelemetryBySequence[frame.sequence] = SubmittedTelemetry(
                clientSubmittedMonotonicNanoseconds:
                    clientSubmittedMonotonicNanoseconds,
                frameKind: frame.kind
            )
            if frame.kind == .move {
                pendingLatestMoveSequence = frame.sequence
            }
        } catch {
            protocolState = .ended(.cancel)
            _ = try? finishCleanup(
                outcome: .cancelled,
                resultDelivery: .reliableEnqueued
            )
            throw error
        }
    }

    @discardableResult
    public mutating func drainAvailableFrames(
        atMonotonicNanoseconds now: UInt64
    ) throws -> [PointerDeviceFrame] {
        var sent = [PointerDeviceFrame]()
        let decoder = JSONDecoder()
        deliveryLoop: while true {
            let attemptID = "pointer.delivery.\(deliveryCounter)"
            guard let attempt = try session.dequeueFrameForDelivery(
                deliveryAttemptID: attemptID,
                atMonotonicNanoseconds: now
            ) else {
                break
            }
            deliveryCounter += 1
            let frame: PointerDeviceFrame
            do {
                frame = try decoder.decode(
                    PointerDeviceFrame.self,
                    from: Data(attempt.frame.encodedBytes)
                )
            } catch {
                abortActiveSession(outcome: .outcomeUnknown)
                throw PointerStreamError.transportFailure
            }
            if pendingLatestMoveSequence == frame.sequence {
                pendingLatestMoveSequence = nil
            }
            let disposition: PointerFrameTransportDisposition
            do {
                disposition = try transport.send(
                    frame: frame,
                    deliveryAttemptID: attemptID
                )
            } catch {
                abortActiveSession(outcome: .outcomeUnknown)
                throw PointerStreamError.transportFailure
            }
            sent.append(frame)
            switch disposition {
            case .accepted(let acceptedMonotonicNanoseconds):
                try session.acceptFrame(
                    sequence: frame.sequence,
                    deliveryAttemptID: attemptID
                )
                if let submitted = submittedTelemetryBySequence.removeValue(
                    forKey: frame.sequence
                ) {
                    acceptedDeliveryObserver?.recordAcceptedDelivery(
                        PointerAcceptedDeliveryObservation(
                            sessionID: session.sessionID,
                            interactionID: session.interactionID,
                            sequence: frame.sequence,
                            frameKind: submitted.frameKind,
                            expectedConnectionEpoch:
                                frame.expectedConnectionEpoch,
                            expectedGeometryRevision:
                                frame.expectedGeometryRevision,
                            clientSubmittedMonotonicNanoseconds:
                                submitted.clientSubmittedMonotonicNanoseconds,
                            acceptedMonotonicNanoseconds:
                                acceptedMonotonicNanoseconds
                        )
                    )
                }
            case .unconfirmed:
                break deliveryLoop
            }
        }
        return sent
    }

    public mutating func evaluateFrameAcceptedWatchdog(
        atMonotonicNanoseconds now: UInt64
    ) throws -> StreamSessionTerminalSnapshot? {
        guard try session.evaluateFrameAcceptedWatchdog(
            atMonotonicNanoseconds: now
        ) != nil else {
            return nil
        }
        return try finishCleanup(
            outcome: .cancelled,
            resultDelivery: .reliableEnqueued
        )
    }

    public mutating func finish(
        requestID: CanonicalUUID,
        resultDelivery: OperationResultDelivery = .reliableEnqueued
    ) throws -> StreamClosedResponse {
        guard case .ended(let mode) = protocolState else {
            throw PointerStreamError.invalidFrameOrder
        }
        _ = try session.requestClose(
            requestID: requestID,
            mode: mode,
            cause: mode == .close ? .backendResult : .clientCancelled
        )
        let outcome: StandardOutcome = mode == .close ? .succeeded : .cancelled
        _ = try finishCleanup(
            outcome: outcome,
            resultDelivery: resultDelivery
        )
        return try session.closeResponse(for: requestID)
    }

    private mutating func finishCleanup(
        outcome: StandardOutcome,
        resultDelivery: OperationResultDelivery
    ) throws -> StreamSessionTerminalSnapshot {
        let disposition: OperationCleanupDisposition
        do {
            disposition = try transport.cancelAndClean(
                timeoutMilliseconds: Self.cleanupMilliseconds
            )
        } catch {
            throw PointerStreamError.transportFailure
        }
        pendingLatestMoveSequence = nil
        submittedTelemetryBySequence.removeAll(keepingCapacity: false)
        return try session.completeCleanup(
            outcome: outcome,
            resultDelivery: resultDelivery,
            disposition: disposition
        )
    }

    private mutating func abortActiveSession(outcome: StandardOutcome) {
        guard session.snapshot.lifecycle.phase == .running else { return }
        protocolState = .ended(.cancel)
        _ = try? session.requestClose(
            requestID: session.snapshot.lifecycle.requestID,
            mode: .cancel,
            cause: .runtimeAbort
        )
        _ = try? finishCleanup(
            outcome: outcome,
            resultDelivery: .reliableEnqueued
        )
    }

    private mutating func validateOrder(
        _ frame: PointerStreamInputFrame
    ) throws {
        switch (protocolState, frame.kind, frame.sequence) {
        case (.awaitingBegin, .begin, 0):
            protocolState = .active
        case (.active, .move, _):
            break
        case (.active, .end, _):
            protocolState = .ended(.close)
        case (.active, .cancel, _):
            protocolState = .ended(.cancel)
        default:
            throw PointerStreamError.invalidFrameOrder
        }
    }

    private func project(
        _ frame: PointerStreamInputFrame
    ) throws -> PointerDeviceFrame {
        let normalized: NormalizedPointV1
        do {
            let arguments = try ArgumentNormalizer.normalize(
                schemaID: "normalizedPoint.v1",
                raw: ["point": "\(frame.point.x),\(frame.point.y)"]
            )
            guard case .point(let value)? = arguments.values["point"] else {
                throw PointerStreamError.invalidCoordinate
            }
            normalized = value
        } catch is ArgumentNormalizationError {
            throw PointerStreamError.invalidCoordinate
        }
        return PointerDeviceFrame(
            edge: frame.edge,
            expectedConnectionEpoch: frame.expectedGeometry.expectedConnectionEpoch,
            expectedGeometryRevision: frame.expectedGeometry.expectedGeometryRevision,
            kind: frame.kind,
            sequence: frame.sequence,
            x: try projectAxis(normalized.x),
            y: try projectAxis(normalized.y)
        )
    }

    private func projectAxis(_ value: String) throws -> UInt16 {
        if value == "0" { return 0 }
        if value == "1" { return UInt16.max }
        guard value.hasPrefix("0."),
              let numerator = UInt64(value.dropFirst(2))
        else {
            throw PointerStreamError.invalidCoordinate
        }
        var scale: UInt64 = 1
        for _ in value.dropFirst(2) {
            let result = scale.multipliedReportingOverflow(by: 10)
            guard !result.overflow else {
                throw PointerStreamError.invalidCoordinate
            }
            scale = result.partialValue
        }
        let product = numerator.multipliedFullWidth(by: UInt64(UInt16.max))
        let division = scale.dividingFullWidth(product)
        let rounded = division.quotient
            + (division.remainder >= scale / 2 ? 1 : 0)
        guard let coordinate = UInt16(exactly: rounded) else {
            throw PointerStreamError.invalidCoordinate
        }
        return coordinate
    }
}
