import Darwin
import Dispatch
import Foundation
import PulsePhoneRuntimeKernel
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions
import PulsePhoneWire

struct ProductionRuntimeScheduledPointerProjection: Equatable, Sendable {
    let delayMilliseconds: UInt64
    let projection: RuntimePointerProjection
}

struct ProductionRuntimePointerObservationPlan: Equatable, Sendable {
    let connectionEpoch: UInt64
    let frames: [ProductionRuntimeScheduledPointerProjection]
}

final class ProductionRuntimePointerObservationSink: @unchecked Sendable {
    typealias Handler = @Sendable (
        CanonicalUUID,
        CanonicalUUID,
        ProductionRuntimePointerObservationPlan
    ) -> Void

    private var handler: Handler?
    private let lock = NSLock()

    func install(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    func publishAccepted(
        clientInstanceID: CanonicalUUID,
        interactionID: CanonicalUUID,
        plan: ProductionRuntimePointerObservationPlan
    ) {
        let current = lock.withLock { handler }
        current?(clientInstanceID, interactionID, plan)
    }
}

final class ProductionRuntimeObservationBroker: @unchecked Sendable {
    private struct Subscriber {
        let context: ProductionRuntimePeerContext
        var deliveryGeneration: UInt64 = 0
        var deliveryScheduled = false
    }

    private let deliveryQueue = DispatchQueue(
        label: "com.pulsephone.runtime-observation.delivery",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let lock = NSLock()
    private var minimumConnectionEpoch: UInt64 = 0
    private var projectionGeneration: UInt64 = 0
    private var publisher: RuntimeObservationPublisher
    private var subscribers = [CanonicalUUID: Subscriber]()

    init(
        maximumFrames: Int = RuntimeObservationPublisher.hardMaximumFrames,
        maximumBytes: Int = RuntimeObservationPublisher.hardMaximumBytes
    ) throws {
        publisher = try RuntimeObservationPublisher(
            maximumFrames: maximumFrames,
            maximumBytes: maximumBytes
        )
    }

    var subscriberCount: Int {
        lock.withLock { subscribers.count }
    }

    func attach(
        clientInstanceID: CanonicalUUID,
        subscriptionID: CanonicalUUID,
        context: ProductionRuntimePeerContext
    ) throws {
        try lock.withLock {
            try publisher.attach(
                clientInstanceID: clientInstanceID,
                subscriptionID: subscriptionID
            )
            subscribers[subscriptionID] = Subscriber(context: context)
        }
    }

    func stop(subscriptionID: CanonicalUUID) {
        lock.withLock {
            _ = try? publisher.stop(subscriptionID: subscriptionID)
            subscribers.removeValue(forKey: subscriptionID)
        }
    }

    func invalidateProjections(connectionEpoch: UInt64) {
        lock.withLock {
            if connectionEpoch < UInt64.max {
                minimumConnectionEpoch = max(
                    minimumConnectionEpoch,
                    connectionEpoch + 1
                )
            }
            projectionGeneration &+= 1
        }
    }

    func resetForControl(
        subscriptionID: CanonicalUUID,
        reason: String
    ) -> ObservationStreamReset? {
        lock.withLock {
            guard var subscriber = subscribers[subscriptionID],
                  let reset = try? publisher.reset(
                      subscriptionID: subscriptionID,
                      reason: reason
                  ),
                  (try? publisher.drain(subscriptionID: subscriptionID)) != nil
            else { return nil }
            subscriber.deliveryGeneration &+= 1
            subscriber.deliveryScheduled = false
            subscribers[subscriptionID] = subscriber
            return reset
        }
    }

    func publishAccepted(
        clientInstanceID: CanonicalUUID,
        interactionID: CanonicalUUID,
        plan: ProductionRuntimePointerObservationPlan
    ) {
        let generation: UInt64? = lock.withLock {
            guard !subscribers.isEmpty,
                  plan.connectionEpoch >= minimumConnectionEpoch
            else { return nil }
            return projectionGeneration
        }
        guard let generation else { return }
        for frame in plan.frames {
            let deadline = DispatchTime.now() + .milliseconds(
                Int(clamping: frame.delayMilliseconds)
            )
            deliveryQueue.asyncAfter(deadline: deadline) { [weak self] in
                self?.publish(
                    clientInstanceID: clientInstanceID,
                    interactionID: interactionID,
                    connectionEpoch: plan.connectionEpoch,
                    projectionGeneration: generation,
                    projection: frame.projection
                )
            }
        }
    }

    private func publish(
        clientInstanceID: CanonicalUUID,
        interactionID: CanonicalUUID,
        connectionEpoch: UInt64,
        projectionGeneration: UInt64,
        projection: RuntimePointerProjection
    ) {
        var disconnectedContexts = [ProductionRuntimePeerContext]()
        lock.lock()
        guard projectionGeneration == self.projectionGeneration,
              connectionEpoch >= minimumConnectionEpoch
        else {
            lock.unlock()
            return
        }
        do {
            _ = try publisher.publishPointerProjection(
                deliveryBoundary: .acceptedForDelivery,
                clientInstanceID: clientInstanceID,
                interactionID: interactionID,
                projection: projection
            )
            let activeIDs = Set(publisher.subscriptionIDs)
            for subscriptionID in subscribers.keys where
                !activeIDs.contains(subscriptionID)
            {
                if let removed = subscribers.removeValue(
                    forKey: subscriptionID
                ) {
                    disconnectedContexts.append(removed.context)
                }
            }
            for subscriptionID in activeIDs {
                scheduleDeliveryLocked(subscriptionID: subscriptionID)
            }
        } catch {
            lock.unlock()
            return
        }
        lock.unlock()
        for context in disconnectedContexts {
            _ = Darwin.shutdown(context.descriptor, SHUT_RDWR)
        }
    }

    private func scheduleDeliveryLocked(subscriptionID: CanonicalUUID) {
        guard var subscriber = subscribers[subscriptionID],
              !subscriber.deliveryScheduled
        else { return }
        subscriber.deliveryScheduled = true
        subscribers[subscriptionID] = subscriber
        let generation = subscriber.deliveryGeneration
        deliveryQueue.async { [weak self] in
            self?.deliver(
                subscriptionID: subscriptionID,
                generation: generation
            )
        }
    }

    private func deliver(
        subscriptionID: CanonicalUUID,
        generation: UInt64
    ) {
        while true {
            let pending: (
                context: ProductionRuntimePeerContext,
                batch: RuntimeObservationBatch
            )? = lock.withLock {
                guard var subscriber = subscribers[subscriptionID],
                      subscriber.deliveryGeneration == generation,
                      let batch = try? publisher.drain(
                          subscriptionID: subscriptionID
                      )
                else { return nil }
                if batch.observations.isEmpty, batch.reset == nil {
                    subscriber.deliveryScheduled = false
                    subscribers[subscriptionID] = subscriber
                    return nil
                }
                return (subscriber.context, batch)
            }
            guard let pending else { return }
            do {
                try pending.context.withOutbound { connection, descriptor in
                    guard self.isCurrent(
                        subscriptionID: subscriptionID,
                        generation: generation
                    ) else { return }
                    let frames = try Self.frames(for: pending.batch)
                    for frame in frames {
                        guard try connection.enqueueUnassociatedReliable(frame)
                            == .enqueued
                        else {
                            throw ProductionRuntimeServerError.invalidFrame
                        }
                    }
                    try Self.drain(connection: connection, to: descriptor)
                }
            } catch {
                stop(subscriptionID: subscriptionID)
                _ = Darwin.shutdown(pending.context.descriptor, SHUT_RDWR)
                return
            }
        }
    }

    private func isCurrent(
        subscriptionID: CanonicalUUID,
        generation: UInt64
    ) -> Bool {
        lock.withLock {
            subscribers[subscriptionID]?.deliveryGeneration == generation
        }
    }

    private static func frames(
        for batch: RuntimeObservationBatch
    ) throws -> [RuntimeWireFrame] {
        if let reset = batch.reset {
            return [try resetFrame(reset)]
        }
        return try batch.observations.map(observationFrame)
    }

    static func observationFrame(
        _ observation: RuntimeObservation
    ) throws -> RuntimeWireFrame {
        RuntimeWireFrame(
            messageType: .runtimeObservation,
            payload: RepositoryCanonicalJSON.encodeDocument(try object([
                (
                    "clientInstanceID",
                    .string(observation.clientInstanceID.canonicalString)
                ),
                (
                    "interactionID",
                    .string(observation.interactionID.canonicalString)
                ),
                (
                    "observationSequence",
                    .number(.uint64(observation.observationSequence))
                ),
                (
                    "presentationPayload",
                    .object(try object([
                        ("edge", .string(
                            observation.presentationPayload.edge
                        )),
                        ("frameKind", .string(
                            observation.presentationPayload.frameKind.rawValue
                        )),
                        ("x", .string(observation.presentationPayload.x)),
                        ("y", .string(observation.presentationPayload.y)),
                    ]))
                ),
                ("schemaVersion", .number(.uint64(1))),
                (
                    "subscriptionID",
                    .string(observation.subscriptionID.canonicalString)
                ),
            ]))
        )
    }

    static func resetFrame(
        _ reset: ObservationStreamReset
    ) throws -> RuntimeWireFrame {
        RuntimeWireFrame(
            messageType: .observationStreamReset,
            payload: RepositoryCanonicalJSON.encodeDocument(try object([
                ("nextSequence", .number(.uint64(reset.nextSequence))),
                ("reason", .string(reset.reason)),
                ("schemaVersion", .number(.uint64(1))),
                (
                    "subscriptionID",
                    .string(reset.subscriptionID.canonicalString)
                ),
            ]))
        )
    }

    private static func drain(
        connection: RuntimeConnection,
        to descriptor: Int32
    ) throws {
        while connection.writer.queuedFrameCount > 0 {
            _ = try connection.writer.drainNext(
                now: SystemMonotonicClock().now()
            ) { remaining in
                let result = remaining.withUnsafeBytes { buffer in
                    Darwin.write(descriptor, buffer.baseAddress, remaining.count)
                }
                if result > 0 { return result }
                if result == -1, errno == EINTR { return 0 }
                throw ProductionRuntimeServerError.transportFailure(errno: errno)
            }
        }
    }

    private static func object(
        _ members: [(String, RepositoryJSONValue)]
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: members.map {
            RepositoryJSONMember(key: $0.0, value: $0.1)
        })
    }
}
