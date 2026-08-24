import PulsePhoneClientCore
import PulsePhoneSharedDefinitions

public struct LiveOwnerLease: Equatable, Sendable {
    public let attachment: LiveAttachment
    public let clientInstanceID: CanonicalUUID
    public let windowID: String

    public init(
        attachment: LiveAttachment,
        clientInstanceID: CanonicalUUID,
        windowID: String
    ) {
        self.attachment = attachment
        self.clientInstanceID = clientInstanceID
        self.windowID = windowID
    }
}

public enum LiveOwnerRegistryAttachDisposition: Equatable, Sendable {
    case alreadyAttached
    case attached
    case conflict(existingLiveOwnerID: CanonicalUUID)
}

public enum LiveOwnerRegistryError: Error, Equatable, Sendable {
    case staleReconnect
    case staleDetach
}

public struct LiveOwnerRegistry: Sendable {
    private var leases = [CanonicalUDID: LiveOwnerLease]()

    public init() {}

    public var ownerCount: Int { leases.count }

    public mutating func attach(
        _ lease: LiveOwnerLease
    ) -> LiveOwnerRegistryAttachDisposition {
        if let current = leases[lease.attachment.canonicalUDID] {
            if current == lease { return .alreadyAttached }
            return .conflict(
                existingLiveOwnerID: current.attachment.liveOwnerID
            )
        }
        leases[lease.attachment.canonicalUDID] = lease
        return .attached
    }

    @discardableResult
    public mutating func detach(
        _ attachment: LiveAttachment
    ) throws -> Bool {
        guard let current = leases[attachment.canonicalUDID] else {
            return false
        }
        guard current.attachment == attachment else {
            throw LiveOwnerRegistryError.staleDetach
        }
        leases.removeValue(forKey: attachment.canonicalUDID)
        return true
    }

    public mutating func replace(
        current: LiveAttachment,
        with replacement: LiveOwnerLease
    ) throws {
        guard let lease = leases[current.canonicalUDID],
              lease.attachment == current,
              replacement.attachment.canonicalUDID == current.canonicalUDID,
              replacement.attachment.liveOwnerID == current.liveOwnerID,
              replacement.attachment.subscriptionID == current.subscriptionID,
              replacement.attachment.connectionEpoch > current.connectionEpoch,
              replacement.clientInstanceID == lease.clientInstanceID,
              replacement.windowID == lease.windowID
        else {
            throw LiveOwnerRegistryError.staleReconnect
        }
        leases[current.canonicalUDID] = replacement
    }
}

public enum LiveOwnerCoordinatorState: Equatable, Sendable {
    case attached(LiveAttachment)
    case closed
    case closing(LiveAttachment)
    case conflicted(existingLiveOwnerID: CanonicalUUID)
    case detached
}

public struct LiveCloseProgress: Equatable, Sendable {
    public let acceptedOneShotCancellationRequested: Bool
    public let mediaStopped: Bool
    public let pendingOwnedStreamCount: Int
    public let readyForDetach: Bool
    public let stage: LiveCloseStage
}

public enum LiveOwnerCoordinatorError: Error, Equatable, Sendable {
    case alreadyClosing
    case detachNotConfirmed
    case invalidState
    case streamAlreadyOwned
    case streamNotOwned
    case streamsNotClean
}

public struct LiveOwnerCoordinator: Sendable {
    public private(set) var mediaActive = false
    public private(set) var state: LiveOwnerCoordinatorState = .detached
    private var deadline: LiveCloseDeadline?
    private var ownedStreams = Set<CanonicalUUID>()

    public init() {}

    public var runtimeBackedControlEnabled: Bool {
        if case .attached = state { return true }
        return false
    }

    public var currentAttachment: LiveAttachment? {
        switch state {
        case .attached(let attachment), .closing(let attachment):
            return attachment
        case .closed, .conflicted, .detached:
            return nil
        }
    }

    public var ownedStreamCount: Int { ownedStreams.count }

    public mutating func attach(
        attachment: LiveAttachment,
        clientInstanceID: CanonicalUUID,
        windowID: String,
        registry: inout LiveOwnerRegistry
    ) -> LiveOwnerRegistryAttachDisposition {
        let disposition = registry.attach(LiveOwnerLease(
            attachment: attachment,
            clientInstanceID: clientInstanceID,
            windowID: windowID
        ))
        switch disposition {
        case .alreadyAttached, .attached:
            state = .attached(attachment)
            mediaActive = true
        case .conflict(let ownerID):
            state = .conflicted(existingLiveOwnerID: ownerID)
            mediaActive = false
        }
        return disposition
    }

    public mutating func registerOwnedStream(
        _ sessionID: CanonicalUUID
    ) throws {
        guard case .attached = state else {
            throw LiveOwnerCoordinatorError.invalidState
        }
        guard ownedStreams.insert(sessionID).inserted else {
            throw LiveOwnerCoordinatorError.streamAlreadyOwned
        }
    }

    public mutating func completeOwnedStream(
        _ sessionID: CanonicalUUID
    ) throws {
        guard case .attached = state else {
            throw LiveOwnerCoordinatorError.invalidState
        }
        guard ownedStreams.remove(sessionID) != nil else {
            throw LiveOwnerCoordinatorError.streamNotOwned
        }
    }

    public mutating func invalidateOwnedStreamsForReconnect() {
        ownedStreams.removeAll()
    }

    public mutating func replaceAttachmentAfterReconnect(
        _ replacement: LiveAttachment,
        clientInstanceID: CanonicalUUID,
        windowID: String,
        registry: inout LiveOwnerRegistry
    ) throws {
        guard case .attached(let current) = state,
              replacement.canonicalUDID == current.canonicalUDID,
              replacement.liveOwnerID == current.liveOwnerID,
              replacement.subscriptionID == current.subscriptionID,
              replacement.connectionEpoch > current.connectionEpoch
        else {
            throw LiveOwnerCoordinatorError.invalidState
        }
        let lease = LiveOwnerLease(
            attachment: replacement,
            clientInstanceID: clientInstanceID,
            windowID: windowID
        )
        try registry.replace(current: current, with: lease)
        state = .attached(replacement)
        mediaActive = true
        ownedStreams.removeAll()
    }

    public mutating func beginClose(
        atNanoseconds now: UInt64
    ) throws -> LiveCloseProgress {
        guard case .attached(let attachment) = state else {
            if case .closing = state {
                throw LiveOwnerCoordinatorError.alreadyClosing
            }
            throw LiveOwnerCoordinatorError.invalidState
        }
        deadline = try LiveCloseDeadline(startedAtNanoseconds: now)
        try deadline?.check(stage: .stopMedia, atNanoseconds: now)
        mediaActive = false
        state = .closing(attachment)
        return progress
    }

    public mutating func completeOwnedStreamCleanup(
        _ sessionID: CanonicalUUID,
        atNanoseconds now: UInt64
    ) throws -> LiveCloseProgress {
        guard case .closing = state else {
            throw LiveOwnerCoordinatorError.invalidState
        }
        try deadline?.check(stage: .streamCleanup, atNanoseconds: now)
        guard ownedStreams.remove(sessionID) != nil else {
            throw LiveOwnerCoordinatorError.streamNotOwned
        }
        return progress
    }

    public func detachRequest(
        atNanoseconds now: UInt64
    ) throws -> LiveDetachRequest {
        guard case .closing(let attachment) = state else {
            throw LiveOwnerCoordinatorError.invalidState
        }
        guard ownedStreams.isEmpty else {
            throw LiveOwnerCoordinatorError.streamsNotClean
        }
        try deadline?.check(stage: .detachLive, atNanoseconds: now)
        return LiveDetachRequest(attachment: attachment)
    }

    public mutating func completeDetach(
        _ result: LiveDetachResult,
        registry: inout LiveOwnerRegistry,
        atNanoseconds now: UInt64
    ) throws -> LiveCloseProgress {
        guard case .closing(let attachment) = state else {
            throw LiveOwnerCoordinatorError.invalidState
        }
        guard ownedStreams.isEmpty else {
            throw LiveOwnerCoordinatorError.streamsNotClean
        }
        try deadline?.check(stage: .detachLive, atNanoseconds: now)
        guard result.detached else {
            throw LiveOwnerCoordinatorError.detachNotConfirmed
        }
        _ = try registry.detach(attachment)
        state = .detached
        return LiveCloseProgress(
            acceptedOneShotCancellationRequested: false,
            mediaStopped: true,
            pendingOwnedStreamCount: 0,
            readyForDetach: false,
            stage: .closeConnection
        )
    }

    public mutating func completeConnectionClose(
        atNanoseconds now: UInt64
    ) throws -> LiveCloseProgress {
        guard state == .detached else {
            throw LiveOwnerCoordinatorError.invalidState
        }
        try deadline?.check(stage: .closeConnection, atNanoseconds: now)
        state = .closed
        deadline = nil
        return LiveCloseProgress(
            acceptedOneShotCancellationRequested: false,
            mediaStopped: true,
            pendingOwnedStreamCount: 0,
            readyForDetach: false,
            stage: .completed
        )
    }

    private var progress: LiveCloseProgress {
        LiveCloseProgress(
            acceptedOneShotCancellationRequested: false,
            mediaStopped: !mediaActive,
            pendingOwnedStreamCount: ownedStreams.count,
            readyForDetach: ownedStreams.isEmpty,
            stage: ownedStreams.isEmpty ? .detachLive : .streamCleanup
        )
    }
}
