public enum DeviceSchedulerError: Error, Equatable, Sendable {
    case duplicateRequestID
    case unknownLease
    case unknownPendingRequest
    case sequenceOverflow
}

public enum SchedulerAdmission: Equatable, Sendable {
    case running(ResourceLease)
    case pending(PendingSchedulerRequest)
    case waiting(PendingSchedulerRequest)
    case resourceBusy([String])
    case queueFull(limit: Int)
}

public struct SchedulerRelease: Equatable, Sendable {
    public let released: ResourceLease
    public let newlyGranted: [ResourceLease]
}

public struct DeviceSchedulerSnapshot: Equatable, Sendable {
    public let activeLeases: [ResourceLease]
    public let pendingRequests: [PendingSchedulerRequest]
    public let pendingOneShotCount: Int
}

public struct DeviceScheduler: Sendable {
    public static let maximumPendingOneShotCount = 64

    private struct QueueEntry: Equatable, Sendable {
        let request: SchedulerRequest
        let enqueueSequence: UInt64

        var projection: PendingSchedulerRequest {
            PendingSchedulerRequest(
                request: request,
                enqueueSequence: enqueueSequence
            )
        }
    }

    private var nextEnqueueSequence: UInt64 = 0
    private var active = [String: ResourceLease]()
    private var pending = [QueueEntry]()

    public init() {}

    public var snapshot: DeviceSchedulerSnapshot {
        DeviceSchedulerSnapshot(
            activeLeases: active.values.sorted {
                $0.enqueueSequence < $1.enqueueSequence
            },
            pendingRequests: pending.map(\.projection),
            pendingOneShotCount: pending.reduce(into: 0) {
                if $1.request.claimantKind == .oneShot {
                    $0 += 1
                }
            }
        )
    }

    public mutating func submit(
        _ request: SchedulerRequest
    ) throws -> SchedulerAdmission {
        guard active[request.requestID] == nil,
              !pending.contains(where: { $0.request.requestID == request.requestID })
        else {
            throw DeviceSchedulerError.duplicateRequestID
        }
        let sequence = try takeEnqueueSequence()
        let entry = QueueEntry(request: request, enqueueSequence: sequence)
        if canGrant(entry, earlierPending: pending) {
            let lease = ResourceLease(
                request: request,
                enqueueSequence: sequence
            )
            active[request.requestID] = lease
            return .running(lease)
        }

        if request.claimantKind == .stream {
            return .resourceBusy(blockingResourceIDs(for: entry))
        }
        if request.claimantKind == .oneShot,
           snapshot.pendingOneShotCount >= Self.maximumPendingOneShotCount
        {
            return .queueFull(limit: Self.maximumPendingOneShotCount)
        }
        pending.append(entry)
        if request.claimantKind == .oneShot {
            return .pending(entry.projection)
        }
        return .waiting(entry.projection)
    }

    public mutating func release(
        requestID: String
    ) throws -> SchedulerRelease {
        guard let lease = active.removeValue(forKey: requestID) else {
            throw DeviceSchedulerError.unknownLease
        }
        return SchedulerRelease(
            released: lease,
            newlyGranted: drainGrantableRequests()
        )
    }

    @discardableResult
    public mutating func cancelPending(
        requestID: String
    ) throws -> [ResourceLease] {
        guard let index = pending.firstIndex(where: {
            $0.request.requestID == requestID
        }) else {
            throw DeviceSchedulerError.unknownPendingRequest
        }
        pending.remove(at: index)
        return drainGrantableRequests()
    }

    private mutating func drainGrantableRequests() -> [ResourceLease] {
        var granted = [ResourceLease]()
        var madeProgress = true
        while madeProgress {
            madeProgress = false
            var index = 0
            while index < pending.count {
                let earlier = Array(pending[..<index])
                let entry = pending[index]
                if canGrant(entry, earlierPending: earlier) {
                    pending.remove(at: index)
                    let lease = ResourceLease(
                        request: entry.request,
                        enqueueSequence: entry.enqueueSequence
                    )
                    active[entry.request.requestID] = lease
                    granted.append(lease)
                    madeProgress = true
                } else {
                    index += 1
                }
            }
        }
        return granted.sorted { $0.enqueueSequence < $1.enqueueSequence }
    }

    private func canGrant(
        _ entry: QueueEntry,
        earlierPending: [QueueEntry]
    ) -> Bool {
        guard entry.request.claims.allSatisfy({ claim in
            active.values.allSatisfy { lease in
                lease.claims.allSatisfy {
                    !ResourceClaim.conflict(claim, $0)
                }
            }
        }) else {
            return false
        }
        return earlierPending.allSatisfy { earlier in
            !requestsConflict(entry.request, earlier.request)
        }
    }

    private func requestsConflict(
        _ lhs: SchedulerRequest,
        _ rhs: SchedulerRequest
    ) -> Bool {
        lhs.claims.contains { lhsClaim in
            rhs.claims.contains { ResourceClaim.conflict(lhsClaim, $0) }
        }
    }

    private func blockingResourceIDs(for entry: QueueEntry) -> [String] {
        let activeClaims = active.values.flatMap(\.claims)
        let earlierClaims = pending.flatMap { $0.request.claims }
        return Array(Set(entry.request.claims.compactMap { claim in
            let blocked = activeClaims.contains {
                ResourceClaim.conflict(claim, $0)
            } || earlierClaims.contains {
                ResourceClaim.conflict(claim, $0)
            }
            return blocked ? claim.resourceID : nil
        })).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    private mutating func takeEnqueueSequence() throws -> UInt64 {
        let current = nextEnqueueSequence
        let (next, overflow) = current.addingReportingOverflow(1)
        guard !overflow else {
            throw DeviceSchedulerError.sequenceOverflow
        }
        nextEnqueueSequence = next
        return current
    }
}
