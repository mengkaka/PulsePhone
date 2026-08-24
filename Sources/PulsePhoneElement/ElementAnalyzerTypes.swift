import Foundation
import PulsePhoneMedia

public enum ElementAnalyzerSource: String, Equatable, Hashable, Sendable {
    case appleRegion
    case localGeometry
    case omniparser
    case vision
}

public struct ElementAnalyzerSelection: Equatable, Sendable {
    public static let all = ElementAnalyzerSelection(uncheckedSources: [
        .omniparser,
        .vision,
        .appleRegion,
    ])

    public let sources: Set<ElementAnalyzerSource>

    public init?(canonicalString: String) {
        let tokens = canonicalString.split(
            separator: ",",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !tokens.isEmpty else { return nil }
        var sources = Set<ElementAnalyzerSource>()
        for token in tokens {
            let source: ElementAnalyzerSource
            switch token {
            case "apple": source = .appleRegion
            case "omni": source = .omniparser
            case "vision": source = .vision
            default: return nil
            }
            sources.insert(source)
        }
        guard !sources.isEmpty else { return nil }
        self.sources = sources
    }

    public var canonicalString: String {
        Self.productionOrder.compactMap { source in
            guard sources.contains(source) else { return nil }
            return switch source {
            case .appleRegion: "apple"
            case .omniparser: "omni"
            case .vision: "vision"
            case .localGeometry: nil
            }
        }.joined(separator: ",")
    }

    private static let productionOrder: [ElementAnalyzerSource] = [
        .omniparser,
        .vision,
        .appleRegion,
    ]

    private init(uncheckedSources: Set<ElementAnalyzerSource>) {
        sources = uncheckedSources
    }
}

public enum ElementCandidateType: String, Equatable, Sendable {
    case controlCandidate
    case text
    case unknown
}

public struct ElementAnalyzerCandidate: Equatable, Sendable {
    public let confidence: Double?
    public let frame: SnapshotPixelRect
    public let label: String?
    public let source: ElementAnalyzerSource
    public let type: ElementCandidateType

    public init(
        frame: SnapshotPixelRect,
        source: ElementAnalyzerSource,
        type: ElementCandidateType,
        confidence: Double?,
        label: String?
    ) {
        self.confidence = confidence
        self.frame = frame
        self.label = label
        self.source = source
        self.type = type
    }
}

public enum ElementAnalyzerStatus: String, Equatable, Sendable {
    case circuitOpen
    case failed
    case succeeded
    case timedOut
    case unavailable
}

public struct ElementAnalyzerStageTimings: Equatable, Sendable {
    public let inputEncodeMicroseconds: UInt64?
    public let requestEncodeMicroseconds: UInt64?
    public let resizeAndColorSpaceMicroseconds: UInt64?
    public let responseDecodeMicroseconds: UInt64?
    public let transportOverheadMicroseconds: UInt64?
    public let transportRoundTripMicroseconds: UInt64?

    public init(
        resizeAndColorSpaceMicroseconds: UInt64? = nil,
        inputEncodeMicroseconds: UInt64? = nil,
        requestEncodeMicroseconds: UInt64? = nil,
        transportRoundTripMicroseconds: UInt64? = nil,
        transportOverheadMicroseconds: UInt64? = nil,
        responseDecodeMicroseconds: UInt64? = nil
    ) {
        self.inputEncodeMicroseconds = inputEncodeMicroseconds
        self.requestEncodeMicroseconds = requestEncodeMicroseconds
        self.resizeAndColorSpaceMicroseconds = resizeAndColorSpaceMicroseconds
        self.responseDecodeMicroseconds = responseDecodeMicroseconds
        self.transportOverheadMicroseconds = transportOverheadMicroseconds
        self.transportRoundTripMicroseconds = transportRoundTripMicroseconds
    }

    public static let noDerivedInputOrTransport = ElementAnalyzerStageTimings(
        resizeAndColorSpaceMicroseconds: 0,
        inputEncodeMicroseconds: 0,
        requestEncodeMicroseconds: 0,
        transportRoundTripMicroseconds: 0,
        transportOverheadMicroseconds: 0,
        responseDecodeMicroseconds: 0
    )
}

public struct ElementAnalyzerResult: Equatable, Sendable {
    public let backend: String?
    public let candidates: [ElementAnalyzerCandidate]
    public let elapsedMilliseconds: UInt64?
    public let inferenceMilliseconds: UInt64?
    public let inputDimensions: SnapshotImageDimensions?
    public let profileID: String
    public let queueWaitMilliseconds: UInt64?
    public let source: ElementAnalyzerSource
    public let stageTimings: ElementAnalyzerStageTimings
    public let status: ElementAnalyzerStatus
    public let version: String?

    public init(
        source: ElementAnalyzerSource,
        status: ElementAnalyzerStatus,
        profileID: String,
        candidates: [ElementAnalyzerCandidate] = [],
        elapsedMilliseconds: UInt64? = nil,
        inferenceMilliseconds: UInt64? = nil,
        inputDimensions: SnapshotImageDimensions? = nil,
        queueWaitMilliseconds: UInt64? = nil,
        backend: String? = nil,
        version: String? = nil,
        stageTimings: ElementAnalyzerStageTimings = .init()
    ) {
        self.backend = backend
        self.candidates = candidates
        self.elapsedMilliseconds = elapsedMilliseconds
        self.inferenceMilliseconds = inferenceMilliseconds
        self.inputDimensions = inputDimensions
        self.profileID = profileID
        self.queueWaitMilliseconds = queueWaitMilliseconds
        self.source = source
        self.stageTimings = stageTimings
        self.status = status
        self.version = version
    }
}

public enum ElementAnalyzerError: Error, Equatable, Sendable {
    case imageDecodeFailed
    case imageEncodeFailed
    case invalidEndpoint
    case invalidImageGeometry
    case invalidResponse
    case requestTooLarge
    case responseTooLarge
    case tooManyCandidates
}

enum ElementAnalyzerTiming {
    static func elapsedMilliseconds(since started: ContinuousClock.Instant) -> UInt64 {
        let duration = started.duration(to: .now)
        let seconds = max(0, duration.components.seconds)
        let milliseconds = max(0, duration.components.attoseconds) / 1_000_000_000_000_000
        let (base, overflow) = UInt64(seconds).multipliedReportingOverflow(by: 1_000)
        guard !overflow else { return UInt64.max }
        return base.addingReportingOverflow(UInt64(milliseconds)).overflow
            ? UInt64.max
            : base + UInt64(milliseconds)
    }

    static func adding(_ first: UInt64, _ second: UInt64) -> UInt64 {
        let result = first.addingReportingOverflow(second)
        return result.overflow ? UInt64.max : result.partialValue
    }

    static func elapsedMicroseconds(since started: ContinuousClock.Instant) -> UInt64 {
        let duration = started.duration(to: .now)
        let seconds = max(0, duration.components.seconds)
        let microseconds = max(0, duration.components.attoseconds) / 1_000_000_000_000
        let (base, overflow) = UInt64(seconds).multipliedReportingOverflow(
            by: 1_000_000
        )
        guard !overflow else { return UInt64.max }
        let total = base.addingReportingOverflow(UInt64(microseconds))
        return total.overflow ? UInt64.max : total.partialValue
    }

    static func transportOverheadMicroseconds(
        roundTripMicroseconds: UInt64,
        remoteElapsedMilliseconds: UInt64
    ) -> UInt64 {
        let converted = remoteElapsedMilliseconds.multipliedReportingOverflow(
            by: 1_000
        )
        guard !converted.overflow else { return 0 }
        return roundTripMicroseconds > converted.partialValue
            ? roundTripMicroseconds - converted.partialValue
            : 0
    }
}

actor ElementAnalyzerRequestGate {
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Error>
        let id: UUID
    }

    private var held = false
    private var waiters = [Waiter]()

    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if !held {
                    held = true
                    continuation.resume()
                } else {
                    waiters.append(Waiter(continuation: continuation, id: id))
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    func cancelAll() {
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
