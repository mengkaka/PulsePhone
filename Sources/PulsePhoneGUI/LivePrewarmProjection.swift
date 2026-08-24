public enum LivePrewarmProjectionState: Equatable, Sendable {
    case absent
    case loading(
        connectionEpoch: UInt64,
        preparationGroupID: String,
        reason: String,
        revision: UInt64
    )
    case ready(
        connectionEpoch: UInt64,
        preparationGroupID: String,
        revision: UInt64
    )
    case reconnecting(
        previousConnectionEpoch: UInt64,
        preparationGroupID: String,
        revision: UInt64
    )
}

public enum LivePrewarmProjectionError: Error, Equatable, Sendable {
    case alreadyAttached
    case connectionEpochRegression
    case groupMismatch
    case invalidConnectionEpoch
    case invalidGroupID
    case invalidState
    case revisionRegression
}

public struct LivePrewarmProjection: Equatable, Sendable {
    public static let persistence = "persistentAcrossReconnect"

    public private(set) var state: LivePrewarmProjectionState = .absent

    public init() {}

    public mutating func attach(
        preparationGroupID: String,
        connectionEpoch: UInt64,
        revision: UInt64
    ) throws {
        guard state == .absent else {
            throw LivePrewarmProjectionError.alreadyAttached
        }
        guard connectionEpoch > 0 else {
            throw LivePrewarmProjectionError.invalidConnectionEpoch
        }
        guard !preparationGroupID.isEmpty else {
            throw LivePrewarmProjectionError.invalidGroupID
        }
        state = .loading(
            connectionEpoch: connectionEpoch,
            preparationGroupID: preparationGroupID,
            reason: "capabilityPreparing",
            revision: revision
        )
    }

    public mutating func updateProgress(
        preparationGroupID: String,
        reason: String,
        revision: UInt64
    ) throws {
        let current = try activeIdentity()
        guard preparationGroupID == current.groupID else {
            throw LivePrewarmProjectionError.groupMismatch
        }
        guard revision >= current.revision else {
            throw LivePrewarmProjectionError.revisionRegression
        }
        guard let connectionEpoch = current.connectionEpoch else {
            throw LivePrewarmProjectionError.invalidState
        }
        state = .loading(
            connectionEpoch: connectionEpoch,
            preparationGroupID: preparationGroupID,
            reason: reason,
            revision: revision
        )
    }

    public mutating func markReady(
        preparationGroupID: String,
        revision: UInt64
    ) throws {
        let current = try activeIdentity()
        guard preparationGroupID == current.groupID else {
            throw LivePrewarmProjectionError.groupMismatch
        }
        guard revision >= current.revision else {
            throw LivePrewarmProjectionError.revisionRegression
        }
        guard let connectionEpoch = current.connectionEpoch else {
            throw LivePrewarmProjectionError.invalidState
        }
        state = .ready(
            connectionEpoch: connectionEpoch,
            preparationGroupID: preparationGroupID,
            revision: revision
        )
    }

    public mutating func usbDetached(
        connectionEpoch: UInt64,
        revision: UInt64
    ) throws {
        let current = try activeIdentity()
        guard current.connectionEpoch == connectionEpoch else {
            throw LivePrewarmProjectionError.connectionEpochRegression
        }
        guard revision >= current.revision else {
            throw LivePrewarmProjectionError.revisionRegression
        }
        state = .reconnecting(
            previousConnectionEpoch: connectionEpoch,
            preparationGroupID: current.groupID,
            revision: revision
        )
    }

    public mutating func rebind(
        connectionEpoch: UInt64,
        revision: UInt64
    ) throws {
        guard case .reconnecting(
            let previousConnectionEpoch,
            let preparationGroupID,
            let currentRevision
        ) = state else {
            throw LivePrewarmProjectionError.invalidState
        }
        guard connectionEpoch > previousConnectionEpoch else {
            throw LivePrewarmProjectionError.connectionEpochRegression
        }
        guard revision >= currentRevision else {
            throw LivePrewarmProjectionError.revisionRegression
        }
        state = .loading(
            connectionEpoch: connectionEpoch,
            preparationGroupID: preparationGroupID,
            reason: "capabilityPreparing",
            revision: revision
        )
    }

    public mutating func detachLive() {
        state = .absent
    }

    public func presentation(
        forRequiredPreparationGroupIDs requiredGroupIDs: [String]
    ) -> LiveToolbarPresentationState {
        guard let groupID = activeGroupID,
              requiredGroupIDs.contains(groupID)
        else {
            return .enabled
        }
        switch state {
        case .absent:
            return .enabled
        case .loading(_, _, let reason, _):
            return .loading(reason: reason)
        case .ready:
            return .enabled
        case .reconnecting:
            return .loading(reason: "deviceReconnecting")
        }
    }

    private var activeGroupID: String? {
        switch state {
        case .absent:
            nil
        case .loading(_, let groupID, _, _),
             .ready(_, let groupID, _),
             .reconnecting(_, let groupID, _):
            groupID
        }
    }

    private func activeIdentity() throws -> (
        groupID: String,
        connectionEpoch: UInt64?,
        revision: UInt64
    ) {
        switch state {
        case .absent:
            throw LivePrewarmProjectionError.invalidState
        case .loading(let epoch, let groupID, _, let revision),
             .ready(let epoch, let groupID, let revision):
            return (groupID, epoch, revision)
        case .reconnecting(_, let groupID, let revision):
            return (groupID, nil, revision)
        }
    }
}
