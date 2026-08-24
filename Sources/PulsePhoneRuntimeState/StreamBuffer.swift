import PulsePhoneSharedDefinitions

public enum StreamFrameDeliveryClass: Equatable, Sendable {
    case ordered
    case latestWins(slotID: String)
}

public struct StreamFrameRule: Equatable, Sendable {
    public let deliveryClass: StreamFrameDeliveryClass
    public let frameKind: String

    public init(
        frameKind: String,
        deliveryClass: StreamFrameDeliveryClass
    ) {
        self.frameKind = frameKind
        self.deliveryClass = deliveryClass
    }
}

public enum StreamBufferPlanError: Error, Equatable, Sendable {
    case invalidFrameRule
    case duplicateFrameKind
    case invalidCapacity
}

public struct StreamBufferPlan: Equatable, Sendable {
    public static let hardMaximumFrameBytes = 8 * 1_024
    public static let hardMaximumOpeningFrames = 32
    public static let hardMaximumOrderedBytes = 256 * 1_024
    public static let hardMaximumOrderedFrames = 64

    public let frameRules: [StreamFrameRule]
    public let maximumFrameBytes: Int
    public let maximumOpeningFrames: Int
    public let maximumOrderedBytes: Int
    public let maximumOrderedFrames: Int

    public init(
        frameRules: [StreamFrameRule],
        maximumOpeningFrames: Int,
        maximumOrderedFrames: Int = Self.hardMaximumOrderedFrames,
        maximumOrderedBytes: Int = Self.hardMaximumOrderedBytes,
        maximumFrameBytes: Int = Self.hardMaximumFrameBytes
    ) throws {
        guard !frameRules.isEmpty,
              (1...Self.hardMaximumOpeningFrames).contains(maximumOpeningFrames),
              (1...Self.hardMaximumOrderedFrames).contains(maximumOrderedFrames),
              (1...Self.hardMaximumOrderedBytes).contains(maximumOrderedBytes),
              (1...Self.hardMaximumFrameBytes).contains(maximumFrameBytes)
        else {
            throw StreamBufferPlanError.invalidCapacity
        }
        guard Set(frameRules.map(\.frameKind)).count == frameRules.count else {
            throw StreamBufferPlanError.duplicateFrameKind
        }
        for rule in frameRules {
            guard Self.validIdentifier(rule.frameKind, maximumBytes: 128) else {
                throw StreamBufferPlanError.invalidFrameRule
            }
            if case .latestWins(let slotID) = rule.deliveryClass {
                guard Self.validIdentifier(slotID, maximumBytes: 128) else {
                    throw StreamBufferPlanError.invalidFrameRule
                }
            }
        }
        self.frameRules = frameRules.sorted { $0.frameKind < $1.frameKind }
        self.maximumOpeningFrames = maximumOpeningFrames
        self.maximumOrderedFrames = maximumOrderedFrames
        self.maximumOrderedBytes = maximumOrderedBytes
        self.maximumFrameBytes = maximumFrameBytes
    }

    func rule(for frameKind: String) -> StreamFrameRule? {
        frameRules.first { $0.frameKind == frameKind }
    }

    private static func validIdentifier(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        let bytes = Array(value.utf8)
        return (1...maximumBytes).contains(bytes.count)
            && bytes.allSatisfy { (0x21...0x7e).contains($0) }
    }
}

public struct StreamFrameEnvelope: Equatable, Sendable {
    public let encodedBytes: [UInt8]
    public let frameKind: String
    public let interactionID: CanonicalUUID
    public let sequence: UInt64
    public let sessionID: CanonicalUUID

    public init(
        sessionID: CanonicalUUID,
        interactionID: CanonicalUUID,
        sequence: UInt64,
        frameKind: String,
        encodedBytes: [UInt8]
    ) {
        self.sessionID = sessionID
        self.interactionID = interactionID
        self.sequence = sequence
        self.frameKind = frameKind
        self.encodedBytes = encodedBytes
    }
}

public struct StreamFrameDeliveryAttempt: Equatable, Sendable {
    public let deliveredAtMonotonicNanoseconds: UInt64
    public let deliveryAttemptID: String
    public let frame: StreamFrameEnvelope
}

public enum StreamBufferError: Error, Equatable, Sendable {
    case unknownFrameKind
    case frameTooLarge
    case sequenceMismatch(expected: UInt64, actual: UInt64)
    case sequenceExhausted
    case openingCapacityExceeded
    case orderedCapacityExceeded
    case byteCapacityExceeded
    case invalidDeliveryAttemptID
    case duplicateDeliveryAttemptID
    case frameNotInFlight
    case deliveryAttemptMismatch
}

public struct StreamBufferSnapshot: Equatable, Sendable {
    public let bufferedBytes: Int
    public let inFlightFrameCount: Int
    public let lastAcceptedSequence: UInt64?
    public let pendingFrameCount: Int
}

public struct StreamFrameBuffer: Sendable {
    private struct PendingFrame: Equatable, Sendable {
        let deliveryClass: StreamFrameDeliveryClass
        let frame: StreamFrameEnvelope
    }

    private struct InFlightFrame: Equatable, Sendable {
        let attempt: StreamFrameDeliveryAttempt
        let deliveryClass: StreamFrameDeliveryClass
    }

    public let plan: StreamBufferPlan

    private var inFlight = [UInt64: InFlightFrame]()
    private var lastAcceptedSequence: UInt64?
    private var latestPending = [String: PendingFrame]()
    private var nextExpectedSequence: UInt64? = 0
    private var orderedPending = [UInt64: PendingFrame]()

    public init(plan: StreamBufferPlan) {
        self.plan = plan
    }

    public var snapshot: StreamBufferSnapshot {
        StreamBufferSnapshot(
            bufferedBytes: outstandingByteCount,
            inFlightFrameCount: inFlight.count,
            lastAcceptedSequence: lastAcceptedSequence,
            pendingFrameCount: orderedPending.count + latestPending.count
        )
    }

    public mutating func enqueue(
        _ frame: StreamFrameEnvelope,
        whileOpening: Bool
    ) throws {
        guard let expected = nextExpectedSequence else {
            throw StreamBufferError.sequenceExhausted
        }
        guard frame.sequence == expected else {
            throw StreamBufferError.sequenceMismatch(
                expected: expected,
                actual: frame.sequence
            )
        }
        guard frame.encodedBytes.count <= plan.maximumFrameBytes else {
            throw StreamBufferError.frameTooLarge
        }
        guard let rule = plan.rule(for: frame.frameKind) else {
            throw StreamBufferError.unknownFrameKind
        }

        let savedOrdered = orderedPending
        let savedLatest = latestPending
        let pending = PendingFrame(
            deliveryClass: rule.deliveryClass,
            frame: frame
        )
        switch rule.deliveryClass {
        case .ordered:
            orderedPending[frame.sequence] = pending
        case .latestWins(let slotID):
            latestPending[slotID] = pending
        }

        do {
            try validateCapacity(whileOpening: whileOpening)
        } catch {
            orderedPending = savedOrdered
            latestPending = savedLatest
            throw error
        }
        nextExpectedSequence = frame.sequence == UInt64.max
            ? nil
            : frame.sequence + 1
    }

    public mutating func dequeueForDelivery(
        deliveryAttemptID: String,
        atMonotonicNanoseconds now: UInt64
    ) throws -> StreamFrameDeliveryAttempt? {
        guard Self.validDeliveryAttemptID(deliveryAttemptID) else {
            throw StreamBufferError.invalidDeliveryAttemptID
        }
        guard !inFlight.values.contains(where: {
            $0.attempt.deliveryAttemptID == deliveryAttemptID
        }) else {
            throw StreamBufferError.duplicateDeliveryAttemptID
        }
        guard let pending = nextPendingFrame() else {
            return nil
        }
        removePending(pending)
        let attempt = StreamFrameDeliveryAttempt(
            deliveredAtMonotonicNanoseconds: now,
            deliveryAttemptID: deliveryAttemptID,
            frame: pending.frame
        )
        inFlight[pending.frame.sequence] = InFlightFrame(
            attempt: attempt,
            deliveryClass: pending.deliveryClass
        )
        return attempt
    }

    public mutating func acceptFrame(
        sequence: UInt64,
        deliveryAttemptID: String
    ) throws {
        guard let frame = inFlight[sequence] else {
            throw StreamBufferError.frameNotInFlight
        }
        guard frame.attempt.deliveryAttemptID == deliveryAttemptID else {
            throw StreamBufferError.deliveryAttemptMismatch
        }
        inFlight.removeValue(forKey: sequence)
        if lastAcceptedSequence == nil || sequence > lastAcceptedSequence! {
            lastAcceptedSequence = sequence
        }
    }

    public func oldestFrameAcceptedWatchdogExpired(
        atMonotonicNanoseconds now: UInt64,
        timeoutNanoseconds: UInt64
    ) -> Bool {
        guard timeoutNanoseconds > 0,
              let oldest = inFlight.values.map({
                  $0.attempt.deliveredAtMonotonicNanoseconds
              }).min(),
              now >= oldest
        else {
            return false
        }
        return now - oldest >= timeoutNanoseconds
    }

    @discardableResult
    public mutating func removeAllOutstandingFrames() -> Int {
        let count = orderedPending.count + latestPending.count + inFlight.count
        orderedPending.removeAll(keepingCapacity: false)
        latestPending.removeAll(keepingCapacity: false)
        inFlight.removeAll(keepingCapacity: false)
        return count
    }

    private var outstandingByteCount: Int {
        let pendingBytes = orderedPending.values.reduce(0) {
            $0 + $1.frame.encodedBytes.count
        } + latestPending.values.reduce(0) {
            $0 + $1.frame.encodedBytes.count
        }
        return pendingBytes + inFlight.values.reduce(0) {
            $0 + $1.attempt.frame.encodedBytes.count
        }
    }

    private func validateCapacity(whileOpening: Bool) throws {
        let openingCount = orderedPending.count + latestPending.count
        if whileOpening && openingCount > plan.maximumOpeningFrames {
            throw StreamBufferError.openingCapacityExceeded
        }
        let orderedInFlight = inFlight.values.reduce(0) { count, value in
            if case .ordered = value.deliveryClass {
                return count + 1
            }
            return count
        }
        if orderedPending.count + orderedInFlight > plan.maximumOrderedFrames {
            throw StreamBufferError.orderedCapacityExceeded
        }
        if outstandingByteCount > plan.maximumOrderedBytes {
            throw StreamBufferError.byteCapacityExceeded
        }
    }

    private func nextPendingFrame() -> PendingFrame? {
        let inFlightLatestSlots = Set(inFlight.values.compactMap { value in
            if case .latestWins(let slotID) = value.deliveryClass {
                return slotID
            }
            return nil
        })
        let deliverableLatest = latestPending.compactMap { slotID, frame in
            inFlightLatestSlots.contains(slotID) ? nil : frame
        }
        return (Array(orderedPending.values) + deliverableLatest).min {
            $0.frame.sequence < $1.frame.sequence
        }
    }

    private mutating func removePending(_ pending: PendingFrame) {
        switch pending.deliveryClass {
        case .ordered:
            orderedPending.removeValue(forKey: pending.frame.sequence)
        case .latestWins(let slotID):
            latestPending.removeValue(forKey: slotID)
        }
    }

    private static func validDeliveryAttemptID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...256).contains(bytes.count)
            && bytes.allSatisfy { (0x21...0x7e).contains($0) }
    }
}
