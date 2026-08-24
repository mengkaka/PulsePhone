import Foundation
import PulsePhoneSharedDefinitions

public enum LiveObservationTopic: String, CaseIterable, Codable, Sendable {
    case pointerProjection
    case preparationStatus
}

public enum LiveAttachError: Error, Equatable, Sendable {
    case duplicateObservationTopic
    case invalidConnectionEpoch
    case invalidStateRevision
}

public struct LiveAttachRequest: Equatable, Sendable {
    public let canonicalUDID: CanonicalUDID
    public let observationTopics: [LiveObservationTopic]

    public init(
        canonicalUDID: CanonicalUDID,
        observationTopics: [LiveObservationTopic]
    ) throws {
        guard Set(observationTopics.map(\.rawValue)).count
            == observationTopics.count
        else {
            throw LiveAttachError.duplicateObservationTopic
        }
        self.canonicalUDID = canonicalUDID
        self.observationTopics = observationTopics.sorted {
            $0.rawValue < $1.rawValue
        }
    }
}

public struct LiveAttachment: Equatable, Sendable {
    public let canonicalUDID: CanonicalUDID
    public let connectionEpoch: UInt64
    public let liveOwnerID: CanonicalUUID
    public let stateRevision: UInt64
    public let subscriptionID: CanonicalUUID

    public init(
        canonicalUDID: CanonicalUDID,
        liveOwnerID: CanonicalUUID,
        subscriptionID: CanonicalUUID,
        connectionEpoch: UInt64,
        stateRevision: UInt64
    ) throws {
        guard connectionEpoch > 0 else {
            throw LiveAttachError.invalidConnectionEpoch
        }
        guard stateRevision > 0 else {
            throw LiveAttachError.invalidStateRevision
        }
        self.canonicalUDID = canonicalUDID
        self.liveOwnerID = liveOwnerID
        self.subscriptionID = subscriptionID
        self.connectionEpoch = connectionEpoch
        self.stateRevision = stateRevision
    }
}
