import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions

public enum InputOverlaySource: String, Equatable, Sendable {
    case optimistic
    case runtimeEcho
}

public struct InputObservationOverlayEntry: Equatable, Sendable {
    public let clientInstanceID: CanonicalUUID
    public let interactionID: CanonicalUUID
    public let projection: RuntimePointerProjection
    public let source: InputOverlaySource
}

public enum InputObservationDisposition: Equatable, Sendable {
    case deduplicatedEcho
    case insertedRuntimeEcho
    case ignoredStale
    case resetForSequenceGap
}

public struct InputObservationOverlay: Sendable {
    private struct Key: Hashable, Sendable {
        let clientInstanceID: CanonicalUUID
        let interactionID: CanonicalUUID
    }

    private var entries = [Key: InputObservationOverlayEntry]()
    private var nextSequenceBySubscription = [CanonicalUUID: UInt64]()

    public init() {}

    public var entryCount: Int { entries.count }

    public mutating func showOptimistic(
        clientInstanceID: CanonicalUUID,
        interactionID: CanonicalUUID,
        projection: RuntimePointerProjection
    ) {
        let key = Key(
            clientInstanceID: clientInstanceID,
            interactionID: interactionID
        )
        entries[key] = InputObservationOverlayEntry(
            clientInstanceID: clientInstanceID,
            interactionID: interactionID,
            projection: projection,
            source: .optimistic
        )
    }

    public mutating func receive(
        observation: RuntimeObservation
    ) -> InputObservationDisposition {
        let expected = nextSequenceBySubscription[
            observation.subscriptionID,
            default: 0
        ]
        if observation.observationSequence < expected {
            return .ignoredStale
        }
        let gap = observation.observationSequence > expected
        if gap {
            entries.removeAll(keepingCapacity: false)
        }
        nextSequenceBySubscription[observation.subscriptionID]
            = observation.observationSequence + 1
        let key = Key(
            clientInstanceID: observation.clientInstanceID,
            interactionID: observation.interactionID
        )
        let deduplicated = entries[key]?.source == .optimistic
        if deduplicated {
            return gap ? .resetForSequenceGap : .deduplicatedEcho
        }
        entries[key] = InputObservationOverlayEntry(
            clientInstanceID: observation.clientInstanceID,
            interactionID: observation.interactionID,
            projection: observation.presentationPayload,
            source: .runtimeEcho
        )
        if gap { return .resetForSequenceGap }
        return .insertedRuntimeEcho
    }

    public mutating func applyReset(_ reset: ObservationStreamReset) {
        entries.removeAll(keepingCapacity: false)
        nextSequenceBySubscription[reset.subscriptionID] = reset.nextSequence
    }

    public mutating func stop(subscriptionID: CanonicalUUID) {
        entries.removeAll(keepingCapacity: false)
        nextSequenceBySubscription.removeValue(forKey: subscriptionID)
    }

    public mutating func remove(
        clientInstanceID: CanonicalUUID,
        interactionID: CanonicalUUID
    ) {
        entries.removeValue(forKey: Key(
            clientInstanceID: clientInstanceID,
            interactionID: interactionID
        ))
    }

    public func entry(
        clientInstanceID: CanonicalUUID,
        interactionID: CanonicalUUID
    ) -> InputObservationOverlayEntry? {
        entries[Key(
            clientInstanceID: clientInstanceID,
            interactionID: interactionID
        )]
    }
}
