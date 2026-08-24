import Foundation

public struct VideoSourceInventorySelection: Equatable, Sendable {
    public let captureEligible: [VideoSourceDescriptor]
    public let manualCandidates: [VideoSourceDescriptor]
    public let qualifiedPhoneScreens: [VideoSourceDescriptor]
    public let residual: [VideoSourceDescriptor]

    public init(inventory: VideoSourceInventory) {
        captureEligible = inventory.sources
        qualifiedPhoneScreens = inventory.sources.filter {
            $0.classification == .qualifiedPhoneScreen
        }
        residual = inventory.sources.filter { $0.classification == .residual }
        manualCandidates = inventory.sources.filter {
            $0.classification != .knownNonPhone
        }
    }
}

public enum VideoSourceStableInventoryOutcome: Equatable, Sendable {
    case pending
    case stable(qualifiedSourceIDs: [String])
    case unstable
}

public struct VideoSourceStableInventoryAccumulator: Equatable, Sendable {
    public static let observationWindowNanoseconds: UInt64 = 1_500_000_000
    public static let snapshotIntervalNanoseconds: UInt64 = 100_000_000
    public static let finalQuietSnapshotCount = 4
    public static let finalQuietSpanNanoseconds: UInt64 = 300_000_000

    private struct Observation: Equatable, Sendable {
        let monotonicNanoseconds: UInt64
        let qualifiedSourceIDs: [String]
    }

    private let deadlineNanoseconds: UInt64?
    private var observations: [Observation] = []

    public init(startedAtMonotonicNanoseconds: UInt64) {
        let (deadline, overflow) = startedAtMonotonicNanoseconds
            .addingReportingOverflow(Self.observationWindowNanoseconds)
        deadlineNanoseconds = overflow ? nil : deadline
    }

    public mutating func observe(
        inventory: VideoSourceInventory?,
        atMonotonicNanoseconds now: UInt64
    ) {
        let sourceIDs = inventory.map {
            VideoSourceInventorySelection(inventory: $0)
                .qualifiedPhoneScreens
                .map(\.sourceID)
                .sorted(by: Self.asciiLess)
        } ?? []
        observations.append(Observation(
            monotonicNanoseconds: now,
            qualifiedSourceIDs: sourceIDs
        ))
        if observations.count > 32 {
            observations.removeFirst(observations.count - 32)
        }
    }

    public func outcome(
        atMonotonicNanoseconds now: UInt64
    ) -> VideoSourceStableInventoryOutcome {
        guard let deadlineNanoseconds else { return .unstable }
        guard now >= deadlineNanoseconds else { return .pending }
        guard observations.count >= Self.finalQuietSnapshotCount else {
            return .unstable
        }
        let final = observations.suffix(Self.finalQuietSnapshotCount)
        guard let first = final.first,
              let last = final.last,
              last.monotonicNanoseconds >= deadlineNanoseconds,
              last.monotonicNanoseconds >= first.monotonicNanoseconds,
              last.monotonicNanoseconds - first.monotonicNanoseconds
                >= Self.finalQuietSpanNanoseconds,
              !last.qualifiedSourceIDs.isEmpty,
              final.allSatisfy({
                  $0.qualifiedSourceIDs == last.qualifiedSourceIDs
              })
        else {
            return .unstable
        }
        return .stable(qualifiedSourceIDs: last.qualifiedSourceIDs)
    }

    private static func asciiLess(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}

public enum VideoSourceNameGuard {
    public static func canonicalEquivalentExactMatch(
        sourceName: String,
        targetName: String
    ) -> Bool {
        sourceName.precomposedStringWithCanonicalMapping
            == targetName.precomposedStringWithCanonicalMapping
    }
}
