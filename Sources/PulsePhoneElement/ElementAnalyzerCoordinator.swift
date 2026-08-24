import Foundation
import PulsePhoneMedia

public struct ElementAnalyzerDeadlinePolicy: Equatable, Sendable {
    public static let maximumAppleRegion: Duration = .seconds(2)
    public static let maximumOmniparser: Duration = .seconds(8)
    public static let maximumVision: Duration = .seconds(3)
    public static let maximumWhole: Duration = .seconds(10)

    public let appleRegion: Duration
    public let omniparser: Duration
    public let vision: Duration
    public let whole: Duration

    public init(
        omniparser: Duration = .seconds(8),
        vision: Duration = .seconds(3),
        appleRegion: Duration = .seconds(2),
        whole: Duration = .seconds(10)
    ) {
        precondition(omniparser > .zero)
        precondition(vision > .zero)
        precondition(appleRegion > .zero)
        precondition(whole > .zero)
        precondition(omniparser <= Self.maximumOmniparser)
        precondition(vision <= Self.maximumVision)
        precondition(appleRegion <= Self.maximumAppleRegion)
        precondition(whole <= Self.maximumWhole)
        precondition(whole >= omniparser)
        precondition(whole >= vision)
        precondition(whole >= appleRegion)
        self.appleRegion = appleRegion
        self.omniparser = omniparser
        self.vision = vision
        self.whole = whole
    }
}

public struct ElementAnalyzerOperations: Sendable {
    public typealias Operation = @Sendable (SnapshotFrame) async -> ElementAnalyzerResult
    public typealias Preparation = @Sendable () async -> ElementAnalyzerResult?

    public let appleRegion: Operation
    public let omniparser: Operation
    public let prepareAppleRegion: Preparation
    public let prepareOmniparser: Preparation
    public let prepareVision: Preparation
    public let vision: Operation

    public init(
        omniparser: @escaping Operation,
        vision: @escaping Operation,
        appleRegion: @escaping Operation,
        prepareOmniparser: @escaping Preparation = { nil },
        prepareVision: @escaping Preparation = { nil },
        prepareAppleRegion: @escaping Preparation = { nil }
    ) {
        self.appleRegion = appleRegion
        self.omniparser = omniparser
        self.prepareAppleRegion = prepareAppleRegion
        self.prepareOmniparser = prepareOmniparser
        self.prepareVision = prepareVision
        self.vision = vision
    }
}

public struct ElementAnalyzerBatch: Equatable, Sendable {
    public let degraded: Bool
    public let elapsedMilliseconds: UInt64
    public let lateResultCount: UInt64
    public let results: [ElementAnalyzerResult]

    public init(
        degraded: Bool,
        elapsedMilliseconds: UInt64,
        lateResultCount: UInt64 = 0,
        results: [ElementAnalyzerResult]
    ) {
        self.degraded = degraded
        self.elapsedMilliseconds = elapsedMilliseconds
        self.lateResultCount = lateResultCount
        self.results = results
    }
}

public enum ElementSnapshotAnalysisError: Error, Equatable, Sendable {
    case allAnalyzersFailed([ElementAnalyzerResult])
}

public struct ElementAnalyzerCoordinator: Sendable {
    private enum BranchRaceEvent: Sendable {
        case cancelled
        case deadline
        case result(ElementAnalyzerResult)
    }

    private struct BranchTerminal: Sendable {
        let lateResultCount: UInt64
        let result: ElementAnalyzerResult
    }

    private struct Branch: Sendable {
        let deadline: Duration
        let operation: ElementAnalyzerOperations.Operation
        let preparedResult: ElementAnalyzerResult?
        let profileID: String
        let source: ElementAnalyzerSource
    }

    private struct PreparationTerminal: Sendable {
        let result: ElementAnalyzerResult?
        let source: ElementAnalyzerSource
    }

    private let deadlines: ElementAnalyzerDeadlinePolicy
    private let operations: ElementAnalyzerOperations

    public init(
        deadlines: ElementAnalyzerDeadlinePolicy = .init(),
        operations: ElementAnalyzerOperations
    ) {
        self.deadlines = deadlines
        self.operations = operations
    }

    public init(
        deadlines: ElementAnalyzerDeadlinePolicy = .init(),
        omniparser: OmniParserAnalyzer,
        vision: VisionTextAnalyzer,
        appleRegion: AppleRegionAnalyzer
    ) {
        self.init(
            deadlines: deadlines,
            operations: ElementAnalyzerOperations(
                omniparser: { await omniparser.analyze($0) },
                vision: { await vision.analyze($0) },
                appleRegion: { await appleRegion.analyze($0) },
                prepareVision: {
                    await vision.prewarm() ? nil : Self.preparationFailure(.vision)
                },
                prepareAppleRegion: {
                    await appleRegion.prewarm()
                        ? nil : Self.preparationFailure(.appleRegion)
                }
            )
        )
    }

    public func analyze(
        _ frame: SnapshotFrame,
        selection: ElementAnalyzerSelection = .all
    ) async throws -> ElementAnalyzerBatch {
        let preparationResults = await prepareAnalyzers(selection: selection)
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let branches = [
            Branch(
                deadline: deadlines.omniparser,
                operation: operations.omniparser,
                preparedResult: selection.sources.contains(.omniparser)
                    ? preparationResults[.omniparser] ?? nil
                    : Self.disabledResult(.omniparser),
                profileID: ElementAnalyzerProfiles.omniparser.profileID,
                source: .omniparser
            ),
            Branch(
                deadline: deadlines.vision,
                operation: operations.vision,
                preparedResult: selection.sources.contains(.vision)
                    ? preparationResults[.vision] ?? nil
                    : Self.disabledResult(.vision),
                profileID: ElementAnalyzerProfiles.visionProfileID,
                source: .vision
            ),
            Branch(
                deadline: deadlines.appleRegion,
                operation: operations.appleRegion,
                preparedResult: selection.sources.contains(.appleRegion)
                    ? preparationResults[.appleRegion] ?? nil
                    : Self.disabledResult(.appleRegion),
                profileID: ElementAnalyzerProfiles.appleRegion.profileID,
                source: .appleRegion
            ),
        ]
        let collected = await withTaskGroup(
            of: BranchTerminal?.self,
            returning: [ElementAnalyzerSource: BranchTerminal].self
        ) { group in
            for branch in branches {
                group.addTask {
                    await Self.run(branch: branch, frame: frame)
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: deadlines.whole)
                } catch {}
                return nil
            }
            var terminal = [ElementAnalyzerSource: BranchTerminal]()
            while let next = await group.next() {
                guard let next else { break }
                if terminal[next.result.source] == nil {
                    terminal[next.result.source] = next
                }
                if terminal.count == branches.count { break }
            }
            group.cancelAll()
            return terminal
        }
        try Task.checkCancellation()

        var terminal = collected
        for branch in branches where terminal[branch.source] == nil {
            terminal[branch.source] = BranchTerminal(
                lateResultCount: 0,
                result: Self.timedOut(branch: branch, started: started)
            )
        }
        let ordered = branches.compactMap { terminal[$0.source] }
        let results = ordered.map(\.result)
        guard results.contains(where: { $0.status == .succeeded }) else {
            throw ElementSnapshotAnalysisError.allAnalyzersFailed(results)
        }
        return ElementAnalyzerBatch(
            degraded: results.contains(where: { $0.status != .succeeded }),
            elapsedMilliseconds: ElementAnalyzerTiming.elapsedMilliseconds(
                since: started
            ),
            lateResultCount: ordered.reduce(0) {
                min(UInt64.max, $0 + $1.lateResultCount)
            },
            results: results
        )
    }

    private func prepareAnalyzers(selection: ElementAnalyzerSelection) async
        -> [ElementAnalyzerSource: ElementAnalyzerResult?]
    {
        await withTaskGroup(
            of: PreparationTerminal.self,
            returning: [ElementAnalyzerSource: ElementAnalyzerResult?].self
        ) { group in
            if selection.sources.contains(.omniparser) {
                group.addTask {
                    PreparationTerminal(
                        result: await operations.prepareOmniparser(),
                        source: .omniparser
                    )
                }
            }
            if selection.sources.contains(.vision) {
                group.addTask {
                    PreparationTerminal(
                        result: await operations.prepareVision(),
                        source: .vision
                    )
                }
            }
            if selection.sources.contains(.appleRegion) {
                group.addTask {
                    PreparationTerminal(
                        result: await operations.prepareAppleRegion(),
                        source: .appleRegion
                    )
                }
            }
            var results = [ElementAnalyzerSource: ElementAnalyzerResult?]()
            for await terminal in group {
                results[terminal.source] = terminal.result
            }
            return results
        }
    }

    private static func run(
        branch: Branch,
        frame: SnapshotFrame
    ) async -> BranchTerminal {
        let started = ContinuousClock.now
        if let preparedResult = branch.preparedResult {
            return BranchTerminal(
                lateResultCount: 0,
                result: preparedResult.source == branch.source
                    && preparedResult.status != .succeeded
                    ? preparedResult
                    : ElementAnalyzerResult(
                        source: branch.source,
                        status: .failed,
                        profileID: branch.profileID,
                        elapsedMilliseconds: 0,
                        queueWaitMilliseconds: 0
                    )
            )
        }
        return await withTaskGroup(
            of: BranchRaceEvent.self,
            returning: BranchTerminal.self
        ) { group in
            group.addTask {
                .result(await branch.operation(frame))
            }
            group.addTask {
                do {
                    try await Task.sleep(for: branch.deadline)
                    return .deadline
                } catch {
                    return .cancelled
                }
            }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            var lateResultCount: UInt64 = 0
            while let event = await group.next() {
                if case .result = event, case .deadline = first {
                    lateResultCount = 1
                }
            }
            let result: ElementAnalyzerResult
            switch first {
            case .result(let value) where value.source == branch.source:
                result = value
            case .result:
                result = ElementAnalyzerResult(
                    source: branch.source,
                    status: .failed,
                    profileID: branch.profileID,
                    elapsedMilliseconds: ElementAnalyzerTiming.elapsedMilliseconds(
                        since: started
                    )
                )
            case .cancelled, .deadline:
                result = timedOut(branch: branch, started: started)
            }
            return BranchTerminal(
                lateResultCount: lateResultCount,
                result: result
            )
        }
    }

    private static func preparationFailure(
        _ source: ElementAnalyzerSource
    ) -> ElementAnalyzerResult {
        let profileID: String
        let backend: String
        let version: String
        switch source {
        case .appleRegion:
            profileID = ElementAnalyzerProfiles.appleRegion.profileID
            backend = AppleRegionWorkerMessage.expectedBackend
            version = AppleRegionWorkerMessage.expectedVersion
        case .vision:
            profileID = ElementAnalyzerProfiles.visionProfileID
            backend = "Vision.framework"
            version = VisionTextRecognitionPolicy.production.version
        case .omniparser, .localGeometry:
            preconditionFailure("unsupported analyzer preparation source")
        }
        return ElementAnalyzerResult(
            source: source,
            status: .unavailable,
            profileID: profileID,
            elapsedMilliseconds: 0,
            queueWaitMilliseconds: 0,
            backend: backend,
            version: version
        )
    }

    private static func disabledResult(
        _ source: ElementAnalyzerSource
    ) -> ElementAnalyzerResult {
        let profileID: String
        switch source {
        case .appleRegion:
            profileID = ElementAnalyzerProfiles.appleRegion.profileID
        case .omniparser:
            profileID = ElementAnalyzerProfiles.omniparser.profileID
        case .vision:
            profileID = ElementAnalyzerProfiles.visionProfileID
        case .localGeometry:
            preconditionFailure("local geometry is not a selectable analyzer")
        }
        return ElementAnalyzerResult(
            source: source,
            status: .unavailable,
            profileID: profileID,
            elapsedMilliseconds: 0,
            queueWaitMilliseconds: 0
        )
    }

    private static func timedOut(
        branch: Branch,
        started: ContinuousClock.Instant
    ) -> ElementAnalyzerResult {
        ElementAnalyzerResult(
            source: branch.source,
            status: .timedOut,
            profileID: branch.profileID,
            elapsedMilliseconds: ElementAnalyzerTiming.elapsedMilliseconds(
                since: started
            )
        )
    }
}
