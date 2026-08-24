import Dispatch
import Foundation
import PulsePhoneHostPaths
import PulsePhoneSharedDefinitions

enum ProductionVideoSourceMappingMutationResult: Equatable, Sendable {
    case failed(VideoSourceMappingStoreFailure)
    case saved(VideoSourceMappingRecordV2)
}

enum ProductionVideoSourceMappingClearResult: Equatable, Sendable {
    case cleared(Bool)
    case failed(VideoSourceMappingStoreFailure)
}

enum ProductionVideoSourceReassignmentResult: Equatable, Sendable {
    case conflictChanged
    case failed(VideoSourceMappingStoreFailure)
    case saved(VideoSourceMappingRecordV2)
}

struct ProductionVideoSourceMappingAttempt: Equatable, Sendable {
    let connectionEpoch: UInt64
    let sourceEpoch: UInt64
    let sourceID: String
}

struct ProductionVideoStallRecoveryGate: Equatable, Sendable {
    private(set) var consumedAttempt: ProductionVideoSourceMappingAttempt?

    mutating func beginCleanReacquire(
        for attempt: ProductionVideoSourceMappingAttempt
    ) -> Bool {
        guard consumedAttempt != attempt else { return false }
        consumedAttempt = attempt
        return true
    }

    mutating func reset() {
        consumedAttempt = nil
    }
}

final class ProductionVideoSourceMappingCoordinator: @unchecked Sendable {
    typealias ClearCompletion = @MainActor @Sendable (
        ProductionVideoSourceMappingClearResult
    ) -> Void
    typealias LoadCompletion = @MainActor @Sendable (
        VideoSourceMappingLoadResult
    ) -> Void
    typealias LoadManyCompletion = @MainActor @Sendable (
        [CanonicalUDID: VideoSourceMappingLoadResult]
    ) -> Void
    typealias ReplaceCompletion = @MainActor @Sendable (
        ProductionVideoSourceMappingMutationResult
    ) -> Void
    typealias ReassignCompletion = @MainActor @Sendable (
        ProductionVideoSourceReassignmentResult
    ) -> Void

    private let queue: DispatchQueue
    private let store: any VideoSourceMappingStoring

    convenience init() {
        let store: any VideoSourceMappingStoring
        if let hostPaths = try? POSIXHostPathSystem().makeHostPathLayout() {
            store = ProductionVideoSourceMappingStore(hostPaths: hostPaths)
        } else {
            store = UnavailableVideoSourceMappingStore()
        }
        self.init(store: store)
    }

    init(
        store: any VideoSourceMappingStoring,
        queue: DispatchQueue = DispatchQueue(
            label: "com.pulsephone.gui.video-source-mapping",
            qos: .utility
        )
    ) {
        self.store = store
        self.queue = queue
    }

    func load(target: CanonicalUDID, completion: @escaping LoadCompletion) {
        queue.async { [store] in
            let result = store.load(target: target)
            DispatchQueue.main.async { completion(result) }
        }
    }

    func load(
        targets: [CanonicalUDID],
        completion: @escaping LoadManyCompletion
    ) {
        let uniqueTargets = Array(Set(targets)).sorted()
        queue.async { [store] in
            let records = Dictionary(uniqueKeysWithValues: uniqueTargets.map {
                ($0, store.load(target: $0))
            })
            DispatchQueue.main.async { completion(records) }
        }
    }

    func replace(
        target: CanonicalUDID,
        sourceID: String,
        proofKind: VideoSourceMappingProofKind = .operatorConfirmedPreview,
        initialCanvasWidth: UInt64? = nil,
        initialCanvasHeight: UInt64? = nil,
        completion: @escaping ReplaceCompletion
    ) {
        queue.async { [store] in
            let result: ProductionVideoSourceMappingMutationResult
            do {
                result = .saved(try store.replace(
                    target: target,
                    sourceID: sourceID,
                    proofKind: proofKind,
                    initialCanvasWidth: initialCanvasWidth,
                    initialCanvasHeight: initialCanvasHeight
                ))
            } catch let error as VideoSourceMappingStoreFailure {
                result = .failed(error)
            } catch {
                result = .failed(.ioFailure)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func clear(target: CanonicalUDID, completion: @escaping ClearCompletion) {
        queue.async { [store] in
            let result: ProductionVideoSourceMappingClearResult
            do {
                result = .cleared(try store.clear(target: target))
            } catch let error as VideoSourceMappingStoreFailure {
                result = .failed(error)
            } catch {
                result = .failed(.ioFailure)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }


    func reassign(
        target: CanonicalUDID,
        sourceID: String,
        proofKind: VideoSourceMappingProofKind,
        initialCanvasWidth: UInt64? = nil,
        initialCanvasHeight: UInt64? = nil,
        connectedTargets: [CanonicalUDID],
        expectedConflictingTargets: Set<CanonicalUDID>,
        fence: @escaping @MainActor @Sendable ([CanonicalUDID]) -> Void,
        completion: @escaping ReassignCompletion
    ) {
        let otherTargets = Array(Set(connectedTargets))
            .filter { $0 != target }
            .sorted()
        queue.async { [weak self, store] in
            guard let self else { return }
            let conflicts = Self.conflictingTargets(
                sourceID: sourceID,
                targets: otherTargets,
                store: store
            )
            guard conflicts == expectedConflictingTargets else {
                DispatchQueue.main.async { completion(.conflictChanged) }
                return
            }
            let orderedConflicts = conflicts.sorted()
            DispatchQueue.main.async {
                fence(orderedConflicts)
                self.queue.async { [store] in
                    let current = Self.conflictingTargets(
                        sourceID: sourceID,
                        targets: otherTargets,
                        store: store
                    )
                    guard current == expectedConflictingTargets else {
                        DispatchQueue.main.async {
                            completion(.conflictChanged)
                        }
                        return
                    }
                    let result: ProductionVideoSourceReassignmentResult
                    do {
                        for conflict in orderedConflicts {
                            _ = try store.clear(target: conflict)
                        }
                        result = .saved(try store.replace(
                            target: target,
                            sourceID: sourceID,
                            proofKind: proofKind,
                            initialCanvasWidth: initialCanvasWidth,
                            initialCanvasHeight: initialCanvasHeight
                        ))
                    } catch let error as VideoSourceMappingStoreFailure {
                        result = .failed(error)
                    } catch {
                        result = .failed(.ioFailure)
                    }
                    DispatchQueue.main.async { completion(result) }
                }
            }
        }
    }

    private static func conflictingTargets(
        sourceID: String,
        targets: [CanonicalUDID],
        store: any VideoSourceMappingStoring
    ) -> Set<CanonicalUDID> {
        Set(targets.compactMap { target in
            guard case .mapped(let record) = store.load(target: target),
                  record.sourceID == sourceID
            else { return nil }
            return target
        })
    }
}

private final class UnavailableVideoSourceMappingStore:
    VideoSourceMappingStoring,
    @unchecked Sendable
{
    func load(target: CanonicalUDID) -> VideoSourceMappingLoadResult {
        .unavailable(.ioFailure)
    }

    func replace(
        target: CanonicalUDID,
        sourceID: String,
        proofKind: VideoSourceMappingProofKind,
        initialCanvasWidth: UInt64?,
        initialCanvasHeight: UInt64?
    ) throws -> VideoSourceMappingRecordV2 {
        throw VideoSourceMappingStoreFailure.ioFailure
    }

    func clear(target: CanonicalUDID) throws -> Bool {
        throw VideoSourceMappingStoreFailure.ioFailure
    }
}
