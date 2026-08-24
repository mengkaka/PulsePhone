import PulsePhoneCommandCatalog

public struct ResourceLease: Equatable, Sendable {
    public let requestID: String
    public let claimantKind: SchedulerClaimantKind
    public let phase: ResourceClaimPhase
    public let enqueueSequence: UInt64
    public let claims: [ResourceClaim]

    init(request: SchedulerRequest, enqueueSequence: UInt64) {
        self.requestID = request.requestID
        self.claimantKind = request.claimantKind
        self.phase = request.phase
        self.enqueueSequence = enqueueSequence
        self.claims = request.claims
    }

    public var productAccepted: Bool {
        claimantKind != .preparation
    }
}

public struct PendingSchedulerRequest: Equatable, Sendable {
    public let requestID: String
    public let claimantKind: SchedulerClaimantKind
    public let phase: ResourceClaimPhase
    public let enqueueSequence: UInt64
    public let claims: [ResourceClaim]
    public let productAccepted: Bool

    init(request: SchedulerRequest, enqueueSequence: UInt64) {
        self.requestID = request.requestID
        self.claimantKind = request.claimantKind
        self.phase = request.phase
        self.enqueueSequence = enqueueSequence
        self.claims = request.claims
        self.productAccepted = request.productAcceptedWhenQueued
    }
}
