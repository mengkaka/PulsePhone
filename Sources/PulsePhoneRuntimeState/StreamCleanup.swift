import PulsePhoneSharedDefinitions

public enum StreamCloseMode: String, Equatable, Sendable {
    case cancel
    case close
}

public enum StreamClosedDisposition: String, Equatable, Sendable {
    case alreadyClosed
    case alreadyClosing
    case cancelled
    case closed
    case notFound
}

public struct StreamCleanupCommand: Equatable, Sendable {
    public let closingCause: OperationTerminalCause
    public let droppedFrameCount: Int
    public let lastAcceptedSequence: UInt64?
    public let mode: StreamCloseMode
}

public struct StreamSessionTerminalSnapshot: Equatable, Sendable {
    public let cleanupDisposition: OperationCleanupDisposition
    public let closingCause: OperationTerminalCause
    public let lastAcceptedSequence: UInt64?
    public let terminalBundle: AtomicTerminalBundle
}

public struct StreamClosedResponse: Equatable, Sendable {
    public let disposition: StreamClosedDisposition
    public let terminal: StreamSessionTerminalSnapshot
}

public enum StreamCleanupStartDisposition: Equatable, Sendable {
    case alreadyTerminal(StreamSessionTerminalSnapshot)
    case joined(StreamCleanupCommand)
    case started(StreamCleanupCommand)
}

public enum StreamCleanupError: Error, Equatable, Sendable {
    case barrierIncomplete
}

public struct StreamCleanupCoordinator: Sendable {
    private var command: StreamCleanupCommand?
    private var firstRequestID: CanonicalUUID?
    private var joinedRequestIDs = Set<CanonicalUUID>()
    private var terminal: StreamSessionTerminalSnapshot?

    public init() {}

    public var activeCommand: StreamCleanupCommand? { command }
    public var cleanupStartCount: Int { command == nil ? 0 : 1 }
    public var terminalSnapshot: StreamSessionTerminalSnapshot? { terminal }

    public mutating func begin(
        requestID: CanonicalUUID?,
        mode: StreamCloseMode,
        cause: OperationTerminalCause,
        lastAcceptedSequence: UInt64?,
        droppedFrameCount: Int
    ) -> StreamCleanupStartDisposition {
        if let terminal {
            return .alreadyTerminal(terminal)
        }
        if let command {
            if let requestID, requestID != firstRequestID {
                joinedRequestIDs.insert(requestID)
            }
            return .joined(command)
        }
        let command = StreamCleanupCommand(
            closingCause: cause,
            droppedFrameCount: droppedFrameCount,
            lastAcceptedSequence: lastAcceptedSequence,
            mode: mode
        )
        self.command = command
        firstRequestID = requestID
        return .started(command)
    }

    public mutating func complete(
        terminalBundle: AtomicTerminalBundle
    ) throws -> StreamSessionTerminalSnapshot {
        if let terminal {
            return terminal
        }
        guard let command else {
            throw StreamCleanupError.barrierIncomplete
        }
        let snapshot = StreamSessionTerminalSnapshot(
            cleanupDisposition: terminalBundle.cleanupDisposition,
            closingCause: command.closingCause,
            lastAcceptedSequence: command.lastAcceptedSequence,
            terminalBundle: terminalBundle
        )
        terminal = snapshot
        return snapshot
    }

    public func response(
        for requestID: CanonicalUUID
    ) throws -> StreamClosedResponse {
        guard let terminal else {
            throw StreamCleanupError.barrierIncomplete
        }
        let disposition: StreamClosedDisposition
        if requestID == firstRequestID {
            disposition = command?.mode == .close ? .closed : .cancelled
        } else if joinedRequestIDs.contains(requestID) {
            disposition = .alreadyClosing
        } else {
            disposition = .alreadyClosed
        }
        return StreamClosedResponse(
            disposition: disposition,
            terminal: terminal
        )
    }
}
