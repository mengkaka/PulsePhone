import Foundation
import PulsePhoneSharedDefinitions

public enum ObservationDeliveryBoundary: String, Equatable, Sendable {
    case acceptedForDelivery
    case submitted
}

public enum RuntimePointerFrameKind: String, Codable, Equatable, Sendable {
    case begin
    case cancel
    case end
    case move
}

public struct RuntimePointerProjection: Codable, Equatable, Sendable {
    public let edge: String
    public let frameKind: RuntimePointerFrameKind
    public let x: String
    public let y: String

    public init(
        edge: String,
        frameKind: RuntimePointerFrameKind,
        x: String,
        y: String
    ) {
        self.edge = edge
        self.frameKind = frameKind
        self.x = x
        self.y = y
    }
}

public struct RuntimeObservation: Codable, Equatable, Sendable {
    public let clientInstanceID: CanonicalUUID
    public let interactionID: CanonicalUUID
    public let observationSequence: UInt64
    public let presentationPayload: RuntimePointerProjection
    public let subscriptionID: CanonicalUUID

    public init(
        subscriptionID: CanonicalUUID,
        clientInstanceID: CanonicalUUID,
        interactionID: CanonicalUUID,
        observationSequence: UInt64,
        presentationPayload: RuntimePointerProjection
    ) {
        self.subscriptionID = subscriptionID
        self.clientInstanceID = clientInstanceID
        self.interactionID = interactionID
        self.observationSequence = observationSequence
        self.presentationPayload = presentationPayload
    }
}

public struct ObservationStreamReset: Codable, Equatable, Sendable {
    public let nextSequence: UInt64
    public let reason: String
    public let subscriptionID: CanonicalUUID

    public init(
        subscriptionID: CanonicalUUID,
        nextSequence: UInt64,
        reason: String
    ) {
        self.subscriptionID = subscriptionID
        self.nextSequence = nextSequence
        self.reason = reason
    }
}

public struct RuntimeObservationBatch: Equatable, Sendable {
    public let observations: [RuntimeObservation]
    public let reset: ObservationStreamReset?
}

public struct RuntimeObservationPublishReport: Equatable, Sendable {
    public let coalescedSubscriberCount: Int
    public let disconnectedSubscriberCount: Int
    public let eligible: Bool
    public let enqueuedSubscriberCount: Int
    public let resetSubscriberCount: Int
}

public struct RuntimeObservationStopReceipt: Equatable, Sendable {
    public let nextSequence: UInt64
    public let subscriptionID: CanonicalUUID
}

public enum RuntimeObservationError: Error, Equatable, Sendable {
    case duplicateSubscription
    case invalidCapacity
    case invalidProjection
    case sequenceExhausted
    case subscriptionNotFound
}

public struct RuntimeAcceptedPointerDeliveryTelemetry: Equatable, Sendable {
    public let acceptedMonotonicNanoseconds: UInt64?
    public let clientSubmittedMonotonicNanoseconds: UInt64?
    public let connectionEpoch: UInt64
    public let frameKind: RuntimePointerFrameKind
    public let geometryRevision: UInt64
    public let interactionID: CanonicalUUID
    public let sequence: UInt64
    public let sessionID: CanonicalUUID

    public init(
        sessionID: CanonicalUUID,
        interactionID: CanonicalUUID,
        sequence: UInt64,
        frameKind: RuntimePointerFrameKind,
        connectionEpoch: UInt64,
        geometryRevision: UInt64,
        clientSubmittedMonotonicNanoseconds: UInt64?,
        acceptedMonotonicNanoseconds: UInt64?
    ) {
        self.sessionID = sessionID
        self.interactionID = interactionID
        self.sequence = sequence
        self.frameKind = frameKind
        self.connectionEpoch = connectionEpoch
        self.geometryRevision = geometryRevision
        self.clientSubmittedMonotonicNanoseconds =
            clientSubmittedMonotonicNanoseconds
        self.acceptedMonotonicNanoseconds = acceptedMonotonicNanoseconds
    }
}

public struct RuntimePointerDeliveryTelemetryBatch: Equatable, Sendable {
    public let droppedObservationCount: UInt64
    public let observations: [RuntimeAcceptedPointerDeliveryTelemetry]
}

public final class RuntimePointerDeliveryTelemetryBuffer:
    @unchecked Sendable
{
    public static let hardMaximumObservations =
        RuntimeObservationPublisher.hardMaximumFrames

    private var droppedObservationCount: UInt64 = 0
    private let lock = NSLock()
    private let maximumObservations: Int
    private var observations = [RuntimeAcceptedPointerDeliveryTelemetry]()

    public init(
        maximumObservations: Int =
            RuntimePointerDeliveryTelemetryBuffer.hardMaximumObservations
    ) throws {
        guard (1...Self.hardMaximumObservations).contains(
            maximumObservations
        ) else {
            throw RuntimeObservationError.invalidCapacity
        }
        self.maximumObservations = maximumObservations
    }

    public var queuedObservationCount: Int {
        lock.withLock { observations.count }
    }

    public func record(
        _ observation: RuntimeAcceptedPointerDeliveryTelemetry
    ) {
        lock.withLock {
            guard observations.count < maximumObservations else {
                if droppedObservationCount < UInt64.max {
                    droppedObservationCount += 1
                }
                return
            }
            observations.append(observation)
        }
    }

    public func drain() -> RuntimePointerDeliveryTelemetryBatch {
        lock.withLock {
            let batch = RuntimePointerDeliveryTelemetryBatch(
                droppedObservationCount: droppedObservationCount,
                observations: observations
            )
            droppedObservationCount = 0
            observations.removeAll(keepingCapacity: true)
            return batch
        }
    }
}

public struct RuntimeObservationPublisher: Sendable {
    public static let hardMaximumBytes = 256 * 1_024
    public static let hardMaximumFrames = 64
    public static let maximumObservationBytes = 8 * 1_024

    private struct Subscriber: Sendable {
        let clientInstanceID: CanonicalUUID
        var nextSequence: UInt64 = 0
        var queuedBytes = 0
        var queuedObservations = [RuntimeObservation]()
        var reset: ObservationStreamReset?
    }

    private let maximumBytes: Int
    private let maximumFrames: Int
    private var subscribers = [CanonicalUUID: Subscriber]()

    public init(
        maximumFrames: Int = Self.hardMaximumFrames,
        maximumBytes: Int = Self.hardMaximumBytes
    ) throws {
        guard (1...Self.hardMaximumFrames).contains(maximumFrames),
              (1...Self.hardMaximumBytes).contains(maximumBytes)
        else {
            throw RuntimeObservationError.invalidCapacity
        }
        self.maximumFrames = maximumFrames
        self.maximumBytes = maximumBytes
    }

    public var subscriberCount: Int { subscribers.count }

    public var subscriptionIDs: [CanonicalUUID] {
        subscribers.keys.sorted {
            $0.canonicalString < $1.canonicalString
        }
    }

    public mutating func attach(
        clientInstanceID: CanonicalUUID,
        subscriptionID: CanonicalUUID
    ) throws {
        guard subscribers[subscriptionID] == nil else {
            throw RuntimeObservationError.duplicateSubscription
        }
        subscribers[subscriptionID] = Subscriber(
            clientInstanceID: clientInstanceID
        )
    }

    public mutating func publishPointerProjection(
        deliveryBoundary: ObservationDeliveryBoundary,
        clientInstanceID: CanonicalUUID,
        interactionID: CanonicalUUID,
        projection: RuntimePointerProjection
    ) throws -> RuntimeObservationPublishReport {
        guard deliveryBoundary == .acceptedForDelivery else {
            return RuntimeObservationPublishReport(
                coalescedSubscriberCount: 0,
                disconnectedSubscriberCount: 0,
                eligible: false,
                enqueuedSubscriberCount: 0,
                resetSubscriberCount: 0
            )
        }
        guard Self.valid(projection) else {
            throw RuntimeObservationError.invalidProjection
        }
        var disconnected = 0
        var coalesced = 0
        var enqueued = 0
        var reset = 0
        for subscriptionID in subscribers.keys.sorted(by: {
            $0.canonicalString < $1.canonicalString
        }) {
            guard var subscriber = subscribers[subscriptionID] else {
                continue
            }
            if subscriber.reset != nil {
                subscribers.removeValue(forKey: subscriptionID)
                disconnected += 1
                continue
            }
            let sequence = subscriber.nextSequence
            guard sequence < UInt64.max else {
                throw RuntimeObservationError.sequenceExhausted
            }
            if projection.frameKind == .move,
               let last = subscriber.queuedObservations.last,
               last.clientInstanceID == clientInstanceID,
               last.interactionID == interactionID,
               last.presentationPayload.frameKind == .move
            {
                let replacement = RuntimeObservation(
                    subscriptionID: subscriptionID,
                    clientInstanceID: clientInstanceID,
                    interactionID: interactionID,
                    observationSequence: last.observationSequence,
                    presentationPayload: projection
                )
                let replacementBytes = try Self.encodedByteCount(replacement)
                guard replacementBytes <= Self.maximumObservationBytes else {
                    throw RuntimeObservationError.invalidProjection
                }
                let previousBytes = try Self.encodedByteCount(last)
                let nextBytes = subscriber.queuedBytes - previousBytes
                    + replacementBytes
                if nextBytes <= maximumBytes {
                    subscriber.queuedObservations[
                        subscriber.queuedObservations.index(before:
                            subscriber.queuedObservations.endIndex)
                    ] = replacement
                    subscriber.queuedBytes = nextBytes
                    subscribers[subscriptionID] = subscriber
                    coalesced += 1
                    continue
                }
            }
            let observation = RuntimeObservation(
                subscriptionID: subscriptionID,
                clientInstanceID: clientInstanceID,
                interactionID: interactionID,
                observationSequence: sequence,
                presentationPayload: projection
            )
            let encodedBytes = try Self.encodedByteCount(observation)
            guard encodedBytes <= Self.maximumObservationBytes else {
                throw RuntimeObservationError.invalidProjection
            }
            subscriber.nextSequence += 1
            if subscriber.queuedObservations.count + 1 > maximumFrames
                || subscriber.queuedBytes + encodedBytes > maximumBytes
            {
                subscriber.queuedObservations.removeAll(keepingCapacity: false)
                subscriber.queuedBytes = 0
                subscriber.reset = ObservationStreamReset(
                    subscriptionID: subscriptionID,
                    nextSequence: subscriber.nextSequence,
                    reason: "queueSaturated"
                )
                reset += 1
            } else {
                subscriber.queuedObservations.append(observation)
                subscriber.queuedBytes += encodedBytes
                enqueued += 1
            }
            subscribers[subscriptionID] = subscriber
        }
        return RuntimeObservationPublishReport(
            coalescedSubscriberCount: coalesced,
            disconnectedSubscriberCount: disconnected,
            eligible: true,
            enqueuedSubscriberCount: enqueued,
            resetSubscriberCount: reset
        )
    }

    public mutating func reset(
        subscriptionID: CanonicalUUID,
        reason: String
    ) throws -> ObservationStreamReset {
        guard var subscriber = subscribers[subscriptionID] else {
            throw RuntimeObservationError.subscriptionNotFound
        }
        subscriber.queuedObservations.removeAll(keepingCapacity: false)
        subscriber.queuedBytes = 0
        let reset = ObservationStreamReset(
            subscriptionID: subscriptionID,
            nextSequence: subscriber.nextSequence,
            reason: reason
        )
        subscriber.reset = reset
        subscribers[subscriptionID] = subscriber
        return reset
    }

    public mutating func drain(
        subscriptionID: CanonicalUUID
    ) throws -> RuntimeObservationBatch {
        guard var subscriber = subscribers[subscriptionID] else {
            throw RuntimeObservationError.subscriptionNotFound
        }
        if let reset = subscriber.reset {
            subscriber.reset = nil
            subscribers[subscriptionID] = subscriber
            return RuntimeObservationBatch(observations: [], reset: reset)
        }
        let observations = subscriber.queuedObservations
        subscriber.queuedObservations.removeAll(keepingCapacity: false)
        subscriber.queuedBytes = 0
        subscribers[subscriptionID] = subscriber
        return RuntimeObservationBatch(observations: observations, reset: nil)
    }

    public mutating func stop(
        subscriptionID: CanonicalUUID
    ) throws -> RuntimeObservationStopReceipt {
        guard let subscriber = subscribers.removeValue(
            forKey: subscriptionID
        ) else {
            throw RuntimeObservationError.subscriptionNotFound
        }
        return RuntimeObservationStopReceipt(
            nextSequence: subscriber.nextSequence,
            subscriptionID: subscriptionID
        )
    }

    private static func valid(_ projection: RuntimePointerProjection) -> Bool {
        let values = [projection.edge, projection.x, projection.y]
        return values.allSatisfy {
            let bytes = Array($0.utf8)
            return (1...128).contains(bytes.count)
                && bytes.allSatisfy { (0x20...0x7e).contains($0) }
        }
    }

    private static func encodedByteCount<T: Encodable>(_ value: T) throws -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value).count
    }
}
