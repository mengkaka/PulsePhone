import Foundation
import PulsePhoneSharedDefinitions
import PulsePhoneWire

public enum RuntimeRequestTrackingError: Error, Equatable, Sendable {
    case duplicateRequestID
    case connectionCapacityExceeded
    case runtimeCapacityExceeded
    case requestNotActive
    case operationMismatch
    case associatedMessageAfterTerminal
}

public enum RuntimeConnectionError: Error, Equatable, Sendable {
    case controlDispatcherUnavailable
}

public final class RuntimeOutstandingRegistry: @unchecked Sendable {
    public static let maximumOutstanding = 128

    private let lock = NSLock()
    private var count = 0

    public init() {}

    public var outstandingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func reserve() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard count < Self.maximumOutstanding else {
            return false
        }
        count += 1
        return true
    }

    func release(_ releasedCount: Int = 1) {
        lock.lock()
        count -= releasedCount
        precondition(count >= 0)
        lock.unlock()
    }
}

public final class RuntimeConnectionRequests: @unchecked Sendable {
    public static let maximumOutstanding = 16
    public static let maximumTombstones = 64
    public static let tombstoneLifetimeNanoseconds: UInt64 = 300_000_000_000

    private struct Tombstone {
        let requestID: CanonicalUUID
        let completedAt: MonotonicInstant
    }

    private let runtimeRegistry: RuntimeOutstandingRegistry
    private let lock = NSLock()
    private var active = [CanonicalUUID: RuntimeOperationID]()
    private var tombstones = [Tombstone]()

    public init(runtimeRegistry: RuntimeOutstandingRegistry) {
        self.runtimeRegistry = runtimeRegistry
    }

    deinit {
        disconnect()
    }

    public var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return active.count
    }

    public func accept(
        requestID: CanonicalUUID,
        operation: RuntimeOperationID,
        now: MonotonicInstant
    ) throws {
        guard operation != .runtimeRecordLocalAction else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        pruneTombstones(now: now)
        guard active[requestID] == nil,
              !tombstones.contains(where: { $0.requestID == requestID })
        else {
            throw RuntimeRequestTrackingError.duplicateRequestID
        }
        guard active.count < Self.maximumOutstanding else {
            throw RuntimeRequestTrackingError.connectionCapacityExceeded
        }
        guard runtimeRegistry.reserve() else {
            throw RuntimeRequestTrackingError.runtimeCapacityExceeded
        }
        active[requestID] = operation
    }

    public func validateAssociatedMessage(requestID: CanonicalUUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard active[requestID] != nil else {
            throw RuntimeRequestTrackingError.associatedMessageAfterTerminal
        }
    }

    public func complete(
        requestID: CanonicalUUID,
        operation: RuntimeOperationID,
        now: MonotonicInstant
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let acceptedOperation = active[requestID] else {
            throw RuntimeRequestTrackingError.requestNotActive
        }
        guard acceptedOperation == operation else {
            throw RuntimeRequestTrackingError.operationMismatch
        }
        active.removeValue(forKey: requestID)
        runtimeRegistry.release()
        pruneTombstones(now: now)
        tombstones.append(Tombstone(requestID: requestID, completedAt: now))
        if tombstones.count > Self.maximumTombstones {
            tombstones.removeFirst(tombstones.count - Self.maximumTombstones)
        }
    }

    public func disconnect() {
        lock.lock()
        let releasedCount = active.count
        active.removeAll()
        tombstones.removeAll()
        lock.unlock()
        if releasedCount > 0 {
            runtimeRegistry.release(releasedCount)
        }
    }

    private func pruneTombstones(now: MonotonicInstant) {
        tombstones.removeAll { tombstone in
            guard now >= tombstone.completedAt else {
                return false
            }
            return now.nanoseconds - tombstone.completedAt.nanoseconds
                >= Self.tombstoneLifetimeNanoseconds
        }
    }
}

public enum RuntimeAssociatedMessageKind: Equatable, Sendable {
    case event
    case progress
    case artifactFD
    case terminalResponse(operation: RuntimeOperationID)
}

public final class RuntimeConnection: @unchecked Sendable {
    public let requests: RuntimeConnectionRequests
    public let writer: SerializedWriter
    public let demultiplexer: ConnectionDemultiplexer
    private var controlDispatcher: ControlDispatcher?

    public init(
        runtimeRegistry: RuntimeOutstandingRegistry,
        writer: SerializedWriter = SerializedWriter(),
        demultiplexer: ConnectionDemultiplexer = ConnectionDemultiplexer()
    ) {
        self.requests = RuntimeConnectionRequests(runtimeRegistry: runtimeRegistry)
        self.writer = writer
        self.demultiplexer = demultiplexer
        self.controlDispatcher = nil
    }

    public static func accepted(
        state: RuntimeHandshakeConnectionState,
        canonicalUDID: CanonicalUDID,
        runtimeRegistry: RuntimeOutstandingRegistry,
        bootstrapStartedAt: MonotonicInstant? = nil
    ) throws -> RuntimeConnection {
        let connection = RuntimeConnection(runtimeRegistry: runtimeRegistry)
        connection.controlDispatcher = try ControlDispatcher(
            state: state,
            canonicalUDID: canonicalUDID,
            requests: connection.requests,
            bootstrapStartedAt: bootstrapStartedAt
        )
        return connection
    }

    public func receive(
        _ bytes: [UInt8],
        now: MonotonicInstant
    ) throws -> [RuntimeInboundMessage] {
        guard let controlDispatcher else {
            throw RuntimeConnectionError.controlDispatcherUnavailable
        }
        return try demultiplexer.consume(bytes, now: now).map { frame in
            try controlDispatcher.dispatch(frame, now: now)
        }
    }

    public func enqueueTerminalResponse(
        _ frame: RuntimeWireFrame,
        now: MonotonicInstant
    ) throws -> RuntimeWriterEnqueueResult {
        let association = try RuntimeControlCodec.decodeResponseAssociation(frame)
        return try enqueueAssociated(
            frame,
            requestID: association.requestID,
            kind: .terminalResponse(operation: association.operation),
            now: now
        )
    }

    public func enqueueUnassociatedReliable(
        _ frame: RuntimeWireFrame
    ) throws -> RuntimeWriterEnqueueResult {
        try writer.enqueue(frame, lane: .regularReliable)
    }

    public func enqueueAssociated(
        _ frame: RuntimeWireFrame,
        requestID: CanonicalUUID,
        kind: RuntimeAssociatedMessageKind,
        now: MonotonicInstant
    ) throws -> RuntimeWriterEnqueueResult {
        switch kind {
        case .event, .progress, .artifactFD:
            try requests.validateAssociatedMessage(requestID: requestID)
            return try writer.enqueue(frame, lane: .regularReliable)
        case .terminalResponse(let operation):
            try requests.complete(
                requestID: requestID,
                operation: operation,
                now: now
            )
            return try writer.enqueue(frame, lane: .finalControl)
        }
    }
}
