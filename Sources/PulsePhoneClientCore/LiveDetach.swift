import PulsePhoneSharedDefinitions

public struct LiveDetachRequest: Equatable, Sendable {
    public let canonicalUDID: CanonicalUDID
    public let liveOwnerID: CanonicalUUID
    public let subscriptionID: CanonicalUUID

    public init(attachment: LiveAttachment) {
        self.canonicalUDID = attachment.canonicalUDID
        self.liveOwnerID = attachment.liveOwnerID
        self.subscriptionID = attachment.subscriptionID
    }
}

public struct LiveDetachResult: Equatable, Sendable {
    public let detached: Bool

    public init(detached: Bool) {
        self.detached = detached
    }
}
