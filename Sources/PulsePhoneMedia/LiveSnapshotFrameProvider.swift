import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import PulsePhoneSharedDefinitions

enum LiveSnapshotSettlementPolicyError: Error, Equatable, Sendable {
    case invalidPolicy
}

struct LiveSnapshotSettlementPolicy: Equatable, Sendable {
    static let production = try! LiveSnapshotSettlementPolicy(
        actionRetentionNanoseconds: 30_000_000_000,
        changeThresholdMilli: 30,
        maximumRegisteredActions: 64,
        settlementDeadlineNanoseconds: 1_500_000_000,
        stableThresholdMilli: 10,
        stableWindowNanoseconds: 120_000_000
    )

    static let profileID = "live-visual-settlement.v1"

    let actionRetentionNanoseconds: UInt64
    let changeThresholdMilli: UInt64
    let maximumRegisteredActions: Int
    let settlementDeadlineNanoseconds: UInt64
    let stableThresholdMilli: UInt64
    let stableWindowNanoseconds: UInt64

    init(
        actionRetentionNanoseconds: UInt64,
        changeThresholdMilli: UInt64,
        maximumRegisteredActions: Int,
        settlementDeadlineNanoseconds: UInt64,
        stableThresholdMilli: UInt64,
        stableWindowNanoseconds: UInt64
    ) throws {
        guard actionRetentionNanoseconds >= settlementDeadlineNanoseconds,
              changeThresholdMilli > stableThresholdMilli,
              changeThresholdMilli <= 1_000,
              (1...256).contains(maximumRegisteredActions),
              settlementDeadlineNanoseconds > stableWindowNanoseconds,
              stableWindowNanoseconds > 0
        else {
            throw LiveSnapshotSettlementPolicyError.invalidPolicy
        }
        self.actionRetentionNanoseconds = actionRetentionNanoseconds
        self.changeThresholdMilli = changeThresholdMilli
        self.maximumRegisteredActions = maximumRegisteredActions
        self.settlementDeadlineNanoseconds = settlementDeadlineNanoseconds
        self.stableThresholdMilli = stableThresholdMilli
        self.stableWindowNanoseconds = stableWindowNanoseconds
    }
}

public enum LiveSnapshotFrameProviderState: String, Equatable, Sendable {
    case active
    case provisional
    case reconfiguring
    case retired
    case stalled
    case withheld
}

public enum LiveSnapshotFrameProviderError: Error, Equatable, Sendable {
    case authorityChanged
    case authorityMismatch
    case duplicateAction
    case invalidActionTimestamp
    case noTrustedFrameAtDeadline
    case settlementRegistryFull
    case unavailable(LiveSnapshotFrameProviderState)
    case unknownAction
}

public enum LiveSnapshotFramePublishDisposition: Equatable, Sendable {
    case ignored(LiveSnapshotFrameProviderState)
    case published(completedRequestCount: Int)
    case rejected(SnapshotFrameError)
}

public struct LiveSnapshotFrameProviderSnapshot: Equatable, Sendable {
    public let latestAcceptedFrameSequence: UInt64?
    public let pendingRequestCount: Int
    public let state: LiveSnapshotFrameProviderState
}

public final class LiveSnapshotFrameProvider: @unchecked Sendable {
    private enum ActionPhase {
        case deadline
        case stable
        case stabilizing(anchor: [UInt8], sinceNanoseconds: UInt64)
        case waitingForChange
    }

    private struct ActionRecord {
        var baselineFingerprint: [UInt8]?
        let baselineFrameSequence: UInt64
        let binding: VideoBindingIdentity
        let deadlineNanoseconds: UInt64
        let geometry: DisplayGeometryDTO
        var phase: ActionPhase
        let retentionDeadlineNanoseconds: UInt64
        let startedAtNanoseconds: UInt64
    }

    private struct CandidateFrame {
        let capturedAtNanoseconds: UInt64
        let frameSequence: UInt64
        let sourceImage: SnapshotSourceImageLease
    }

    private struct Waiter {
        let afterActionID: CanonicalUUID?
        let authority: SnapshotFrameAuthority
        let baselineFrameSequence: UInt64
        let continuation: CheckedContinuation<SnapshotFrame, Error>
        var deadlineTimer: DispatchSourceTimer?
        var latestCandidate: CandidateFrame?
        let maximumFrameAgeNanoseconds: UInt64
        let queryStartedAtNanoseconds: UInt64
    }

    private struct Completion {
        let continuation: CheckedContinuation<SnapshotFrame, Error>
        let result: Result<SnapshotFrame, Error>
    }

    private let lock = NSLock()
    private let monotonicNow: @Sendable () -> UInt64
    private let settlementPolicy: LiveSnapshotSettlementPolicy
    private var actions = [CanonicalUUID: ActionRecord]()
    private var binding: VideoBindingIdentity
    private var geometry: DisplayGeometryDTO
    private var latestAcceptedFingerprint: [UInt8]?
    private var latestAcceptedFrameSequence: UInt64?
    private var reconfiguring = false
    private var retired = false
    private var stalled = false
    private var waiters = [UUID: Waiter]()
    private var withheld = false

    public convenience init(
        binding: VideoBindingIdentity,
        geometry: DisplayGeometryDTO
    ) throws {
        try self.init(
            binding: binding,
            geometry: geometry,
            monotonicNow: { SystemMonotonicClock().now().nanoseconds },
            settlementPolicy: .production
        )
    }

    init(
        binding: VideoBindingIdentity,
        geometry: DisplayGeometryDTO,
        monotonicNow: @escaping @Sendable () -> UInt64,
        settlementPolicy: LiveSnapshotSettlementPolicy = .production
    ) throws {
        try Self.validate(
            binding: binding,
            geometry: geometry,
            allowsProvisionalGeometry: true
        )
        self.binding = binding
        self.geometry = geometry
        self.monotonicNow = monotonicNow
        self.settlementPolicy = settlementPolicy
    }

    public func frame(
        expectedBinding: VideoBindingIdentity,
        expectedGeometry: DisplayGeometryDTO,
        captureGeneration: UInt64,
        maximumFrameAgeNanoseconds: UInt64,
        afterActionID: CanonicalUUID? = nil
    ) async throws -> SnapshotFrame {
        guard maximumFrameAgeNanoseconds > 0 else {
            throw SnapshotFrameError.invalidMaximumFrameAge
        }
        guard captureGeneration > 0 else {
            throw SnapshotFrameError.invalidCaptureGeneration
        }
        try Self.validate(
            binding: expectedBinding,
            geometry: expectedGeometry,
            allowsProvisionalGeometry: true
        )

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            let frame = try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    waiterID: waiterID,
                    expectedBinding: expectedBinding,
                    expectedGeometry: expectedGeometry,
                    captureGeneration: captureGeneration,
                    maximumFrameAgeNanoseconds: maximumFrameAgeNanoseconds,
                    afterActionID: afterActionID,
                    continuation: continuation
                )
            }
            try Task.checkCancellation()
            return frame
        } onCancel: {
            self.cancel(waiterID: waiterID)
        }
    }

    public func recordAction(
        actionID: CanonicalUUID,
        startedAtNanoseconds: UInt64
    ) throws {
        try lock.withLock {
            let state = currentState
            guard state == .active else {
                throw LiveSnapshotFrameProviderError.unavailable(state)
            }
            let now = monotonicNow()
            guard startedAtNanoseconds <= now,
                  now - startedAtNanoseconds
                    <= settlementPolicy.actionRetentionNanoseconds
            else {
                throw LiveSnapshotFrameProviderError.invalidActionTimestamp
            }
            pruneActions(atNanoseconds: now)
            guard actions[actionID] == nil else {
                throw LiveSnapshotFrameProviderError.duplicateAction
            }
            guard actions.count < settlementPolicy.maximumRegisteredActions else {
                throw LiveSnapshotFrameProviderError.settlementRegistryFull
            }
            let deadline = startedAtNanoseconds.addingReportingOverflow(
                settlementPolicy.settlementDeadlineNanoseconds
            )
            let retentionDeadline = startedAtNanoseconds.addingReportingOverflow(
                settlementPolicy.actionRetentionNanoseconds
            )
            guard !deadline.overflow, !retentionDeadline.overflow else {
                throw LiveSnapshotFrameProviderError.invalidActionTimestamp
            }
            actions[actionID] = ActionRecord(
                baselineFingerprint: latestAcceptedFingerprint,
                baselineFrameSequence: latestAcceptedFrameSequence ?? 0,
                binding: binding,
                deadlineNanoseconds: deadline.partialValue,
                geometry: geometry,
                phase: .waitingForChange,
                retentionDeadlineNanoseconds: retentionDeadline.partialValue,
                startedAtNanoseconds: startedAtNanoseconds
            )
        }
    }

    @discardableResult
    public func publish(
        sampleBuffer: CMSampleBuffer,
        capturedAtNanoseconds: UInt64,
        frameSequence: UInt64,
        binding suppliedBinding: VideoBindingIdentity,
        visualFingerprint: [UInt8]? = nil
    ) -> LiveSnapshotFramePublishDisposition {
        guard CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              CVPixelBufferGetWidth(pixelBuffer) > 0,
              CVPixelBufferGetHeight(pixelBuffer) > 0
        else {
            return .rejected(.invalidEncodedImage)
        }

        var completions = [Completion]()
        let disposition = lock.withLock {
            guard suppliedBinding == binding else {
                return LiveSnapshotFramePublishDisposition.rejected(
                    Self.bindingMismatch(
                        expected: binding,
                        actual: suppliedBinding
                    )
                )
            }
            let state = currentState
            guard state == .active else {
                return .ignored(state)
            }
            guard Self.pixelBuffer(
                pixelBuffer,
                alignsWith: geometry.orientation
            ) else {
                return .rejected(.geometryOrientationMismatch)
            }
            if let latestAcceptedFrameSequence,
               frameSequence <= latestAcceptedFrameSequence
            {
                return .rejected(.frameSequenceNotAdvanced)
            }
            let validatedAtNanoseconds = monotonicNow()
            guard capturedAtNanoseconds <= validatedAtNanoseconds else {
                return .rejected(.frameFromFuture)
            }

            let fingerprint = Self.validFingerprint(visualFingerprint)
            pruneActions(atNanoseconds: validatedAtNanoseconds)
            observeActions(
                fingerprint: fingerprint,
                capturedAtNanoseconds: capturedAtNanoseconds,
                frameSequence: frameSequence
            )
            self.latestAcceptedFingerprint = fingerprint
            self.latestAcceptedFrameSequence = frameSequence
            let eligible = waiters.filter { _, waiter in
                frameSequence > waiter.baselineFrameSequence
                    && capturedAtNanoseconds >= waiter.queryStartedAtNanoseconds
            }
            guard !eligible.isEmpty else {
                return .published(completedRequestCount: 0)
            }

            let sourceImage: SnapshotSourceImageLease
            do {
                sourceImage = try SnapshotSourceImageLease(
                    sampleBuffer: sampleBuffer
                )
            } catch {
                for (id, waiter) in eligible {
                    waiters.removeValue(forKey: id)
                    waiter.deadlineTimer?.cancel()
                    completions.append(Completion(
                        continuation: waiter.continuation,
                        result: .failure(error)
                    ))
                }
                return .rejected(
                    error as? SnapshotFrameError ?? .invalidEncodedImage
                )
            }

            let candidate = CandidateFrame(
                capturedAtNanoseconds: capturedAtNanoseconds,
                frameSequence: frameSequence,
                sourceImage: sourceImage
            )
            var completedRequestCount = 0
            for (id, var waiter) in eligible {
                let reason: SnapshotFrameSettleReason?
                if let actionID = waiter.afterActionID {
                    guard let action = actions[actionID] else {
                        waiters.removeValue(forKey: id)
                        waiter.deadlineTimer?.cancel()
                        completions.append(Completion(
                            continuation: waiter.continuation,
                            result: .failure(
                                LiveSnapshotFrameProviderError.unknownAction
                            )
                        ))
                        completedRequestCount += 1
                        continue
                    }
                    guard action.binding == binding, action.geometry == geometry else {
                        waiters.removeValue(forKey: id)
                        waiter.deadlineTimer?.cancel()
                        completions.append(Completion(
                            continuation: waiter.continuation,
                            result: .failure(
                                LiveSnapshotFrameProviderError.authorityChanged
                            )
                        ))
                        completedRequestCount += 1
                        continue
                    }
                    switch action.phase {
                    case .deadline:
                        reason = .unchangedAtDeadline
                    case .stable:
                        reason = .stableAfterVisualChange
                    case .stabilizing, .waitingForChange:
                        reason = nil
                    }
                } else {
                    reason = .queryFenceSatisfied
                }

                guard let reason else {
                    waiter.latestCandidate = candidate
                    waiters[id] = waiter
                    continue
                }
                waiters.removeValue(forKey: id)
                waiter.deadlineTimer?.cancel()
                completions.append(Completion(
                    continuation: waiter.continuation,
                    result: makeFrame(
                        waiter: waiter,
                        candidate: candidate,
                        validatedAtNanoseconds: validatedAtNanoseconds,
                        settleReason: reason
                    )
                ))
                completedRequestCount += 1
            }
            return .published(completedRequestCount: completedRequestCount)
        }
        resume(completions)
        return disposition
    }

    public func rebind(
        binding newBinding: VideoBindingIdentity,
        geometry newGeometry: DisplayGeometryDTO,
        reconfiguring: Bool
    ) throws {
        try Self.validate(binding: newBinding, geometry: newGeometry)
        let completions = lock.withLock { () -> [Completion] in
            guard !retired else { return [] }
            let authorityChanged = binding != newBinding || geometry != newGeometry
            binding = newBinding
            geometry = newGeometry
            self.reconfiguring = reconfiguring
            guard authorityChanged else {
                return drainIfUnavailable()
            }
            actions.removeAll(keepingCapacity: false)
            latestAcceptedFingerprint = nil
            return drain(with: LiveSnapshotFrameProviderError.authorityChanged)
        }
        resume(completions)
    }

    public func setWithheld(_ value: Bool) {
        transition { withheld = value }
    }

    public func setReconfiguring(_ value: Bool) {
        transition { reconfiguring = value }
    }

    public func markStalled() {
        transition { stalled = true }
    }

    public func retire() {
        transition { retired = true }
    }

    public func snapshot() -> LiveSnapshotFrameProviderSnapshot {
        lock.withLock {
            LiveSnapshotFrameProviderSnapshot(
                latestAcceptedFrameSequence: latestAcceptedFrameSequence,
                pendingRequestCount: waiters.count,
                state: currentState
            )
        }
    }

    private var currentState: LiveSnapshotFrameProviderState {
        if retired { return .retired }
        if stalled { return .stalled }
        if geometry.geometryRevision == 0 { return .provisional }
        if reconfiguring { return .reconfiguring }
        if withheld { return .withheld }
        return .active
    }

    private func enqueue(
        waiterID: UUID,
        expectedBinding: VideoBindingIdentity,
        expectedGeometry: DisplayGeometryDTO,
        captureGeneration: UInt64,
        maximumFrameAgeNanoseconds: UInt64,
        afterActionID: CanonicalUUID?,
        continuation: CheckedContinuation<SnapshotFrame, Error>
    ) {
        let result = lock.withLock { () -> Error? in
            guard !Task.isCancelled else { return CancellationError() }
            guard binding == expectedBinding, geometry == expectedGeometry else {
                return LiveSnapshotFrameProviderError.authorityMismatch
            }
            let state = currentState
            guard state == .active else {
                return LiveSnapshotFrameProviderError.unavailable(state)
            }
            let authority: SnapshotFrameAuthority
            do {
                authority = try SnapshotFrameAuthority(
                    canonicalUDID: binding.canonicalUDID,
                    geometry: geometry,
                    sourceEpoch: binding.sourceEpoch,
                    sourceID: binding.sourceID,
                    captureGeneration: captureGeneration
                )
            } catch {
                return error
            }
            let queryStartedAtNanoseconds = monotonicNow()
            var deadlineTimer: DispatchSourceTimer?
            if let afterActionID {
                pruneActions(atNanoseconds: queryStartedAtNanoseconds)
                guard var action = actions[afterActionID] else {
                    return LiveSnapshotFrameProviderError.unknownAction
                }
                guard action.binding == binding, action.geometry == geometry else {
                    return LiveSnapshotFrameProviderError.authorityChanged
                }
                if queryStartedAtNanoseconds >= action.deadlineNanoseconds {
                    switch action.phase {
                    case .stabilizing, .waitingForChange:
                        action.phase = .deadline
                        actions[afterActionID] = action
                    case .deadline, .stable:
                        break
                    }
                }
                switch action.phase {
                case .stabilizing, .waitingForChange:
                    let timer = DispatchSource.makeTimerSource(
                        queue: .global(qos: .userInitiated)
                    )
                    let delay = action.deadlineNanoseconds
                        - queryStartedAtNanoseconds
                    timer.schedule(
                        deadline: .now() + .nanoseconds(Int(delay)),
                        leeway: .milliseconds(5)
                    )
                    timer.setEventHandler { [weak self] in
                        self?.settlementDeadline(waiterID: waiterID)
                    }
                    deadlineTimer = timer
                case .deadline, .stable:
                    break
                }
            }
            waiters[waiterID] = Waiter(
                afterActionID: afterActionID,
                authority: authority,
                baselineFrameSequence: latestAcceptedFrameSequence ?? 0,
                continuation: continuation,
                deadlineTimer: deadlineTimer,
                latestCandidate: nil,
                maximumFrameAgeNanoseconds: maximumFrameAgeNanoseconds,
                queryStartedAtNanoseconds: queryStartedAtNanoseconds
            )
            deadlineTimer?.activate()
            return nil
        }
        if let result { continuation.resume(throwing: result) }
    }

    private func cancel(waiterID: UUID) {
        let waiter = lock.withLock {
            waiters.removeValue(forKey: waiterID)
        }
        waiter?.deadlineTimer?.cancel()
        waiter?.continuation.resume(throwing: CancellationError())
    }

    private func settlementDeadline(waiterID: UUID) {
        let completion = lock.withLock { () -> Completion? in
            guard let waiter = waiters.removeValue(forKey: waiterID),
                  let actionID = waiter.afterActionID,
                  var action = actions[actionID]
            else { return nil }
            let now = monotonicNow()
            guard now >= action.deadlineNanoseconds else {
                waiter.deadlineTimer?.schedule(
                    deadline: .now() + .nanoseconds(Int(
                        action.deadlineNanoseconds - now
                    )),
                    leeway: .milliseconds(5)
                )
                waiters[waiterID] = waiter
                return nil
            }
            switch action.phase {
            case .stabilizing, .waitingForChange:
                action.phase = .deadline
                actions[actionID] = action
            case .deadline, .stable:
                break
            }
            waiter.deadlineTimer?.cancel()
            guard let candidate = waiter.latestCandidate else {
                return Completion(
                    continuation: waiter.continuation,
                    result: .failure(
                        LiveSnapshotFrameProviderError.noTrustedFrameAtDeadline
                    )
                )
            }
            let reason: SnapshotFrameSettleReason
            switch action.phase {
            case .stable:
                reason = .stableAfterVisualChange
            case .deadline, .stabilizing, .waitingForChange:
                reason = .unchangedAtDeadline
            }
            return Completion(
                continuation: waiter.continuation,
                result: makeFrame(
                    waiter: waiter,
                    candidate: candidate,
                    validatedAtNanoseconds: now,
                    settleReason: reason
                )
            )
        }
        if let completion { resume([completion]) }
    }

    private func observeActions(
        fingerprint: [UInt8]?,
        capturedAtNanoseconds: UInt64,
        frameSequence: UInt64
    ) {
        for actionID in Array(actions.keys) {
            guard var action = actions[actionID],
                  action.binding == binding,
                  action.geometry == geometry,
                  frameSequence > action.baselineFrameSequence,
                  capturedAtNanoseconds >= action.startedAtNanoseconds
            else { continue }
            switch action.phase {
            case .deadline, .stable:
                continue
            case .stabilizing, .waitingForChange:
                break
            }
            guard capturedAtNanoseconds < action.deadlineNanoseconds else {
                action.phase = .deadline
                actions[actionID] = action
                continue
            }
            guard let fingerprint else { continue }
            switch action.phase {
            case .waitingForChange:
                guard let baseline = action.baselineFingerprint else {
                    action.baselineFingerprint = fingerprint
                    actions[actionID] = action
                    continue
                }
                guard let difference = Self.fingerprintDifferenceMilli(
                    baseline,
                    fingerprint
                ), difference >= settlementPolicy.changeThresholdMilli else {
                    continue
                }
                action.phase = .stabilizing(
                    anchor: fingerprint,
                    sinceNanoseconds: capturedAtNanoseconds
                )
                actions[actionID] = action
            case .stabilizing(let anchor, let sinceNanoseconds):
                guard let difference = Self.fingerprintDifferenceMilli(
                    anchor,
                    fingerprint
                ) else { continue }
                guard difference <= settlementPolicy.stableThresholdMilli else {
                    action.phase = .stabilizing(
                        anchor: fingerprint,
                        sinceNanoseconds: capturedAtNanoseconds
                    )
                    actions[actionID] = action
                    continue
                }
                guard capturedAtNanoseconds >= sinceNanoseconds,
                      capturedAtNanoseconds - sinceNanoseconds
                        >= settlementPolicy.stableWindowNanoseconds
                else { continue }
                action.phase = .stable
                actions[actionID] = action
            case .deadline, .stable:
                break
            }
        }
    }

    private func makeFrame(
        waiter: Waiter,
        candidate: CandidateFrame,
        validatedAtNanoseconds: UInt64,
        settleReason: SnapshotFrameSettleReason
    ) -> Result<SnapshotFrame, Error> {
        do {
            let fence = try SnapshotFreshnessFence(
                queryStartedAtNanoseconds: waiter.queryStartedAtNanoseconds,
                baselineFrameSequence: waiter.baselineFrameSequence,
                maximumFrameAgeNanoseconds: waiter.maximumFrameAgeNanoseconds,
                validatedAtNanoseconds: validatedAtNanoseconds,
                afterActionID: waiter.afterActionID
            )
            let metadata = try SnapshotFrameMetadata(
                canonicalUDID: binding.canonicalUDID,
                connectionEpoch: binding.connectionEpoch,
                sourceEpoch: binding.sourceEpoch,
                sourceID: binding.sourceID,
                geometry: geometry,
                captureGeneration: waiter.authority.captureGeneration,
                frameSequence: candidate.frameSequence,
                capturedAtNanoseconds: candidate.capturedAtNanoseconds,
                freshnessFence: fence,
                pixelDimensions: candidate.sourceImage.dimensions,
                provider: .liveVideo,
                settleReason: settleReason
            )
            return .success(try SnapshotFrame(
                authority: waiter.authority,
                metadata: metadata,
                sourceImage: candidate.sourceImage
            ))
        } catch {
            return .failure(error)
        }
    }

    private func pruneActions(atNanoseconds now: UInt64) {
        actions = actions.filter { _, action in
            now <= action.retentionDeadlineNanoseconds
        }
    }

    private func transition(_ update: () -> Void) {
        let completions = lock.withLock { () -> [Completion] in
            let previous = currentState
            update()
            let state = currentState
            if state == .retired || state == .stalled {
                actions.removeAll(keepingCapacity: false)
                latestAcceptedFingerprint = nil
            }
            guard state != previous || state != .active else { return [] }
            return drainIfUnavailable()
        }
        resume(completions)
    }

    private func drainIfUnavailable() -> [Completion] {
        let state = currentState
        guard state != .active else { return [] }
        return drain(with: LiveSnapshotFrameProviderError.unavailable(state))
    }

    private func drain(with error: Error) -> [Completion] {
        let drained = waiters.values.map { waiter in
            waiter.deadlineTimer?.cancel()
            return Completion(
                continuation: waiter.continuation,
                result: .failure(error)
            )
        }
        waiters.removeAll(keepingCapacity: false)
        return drained
    }

    private func resume(_ completions: [Completion]) {
        for completion in completions {
            completion.continuation.resume(with: completion.result)
        }
    }

    private static func validate(
        binding: VideoBindingIdentity,
        geometry: DisplayGeometryDTO,
        allowsProvisionalGeometry: Bool = false
    ) throws {
        guard binding.connectionEpoch > 0,
              geometry.connectionEpoch == binding.connectionEpoch
        else {
            throw SnapshotFrameError.connectionEpochMismatch
        }
        guard geometry.geometryRevision == binding.geometryRevision,
              allowsProvisionalGeometry || geometry.geometryRevision > 0
        else {
            throw SnapshotFrameError.geometryRevisionMismatch
        }
        guard binding.sourceEpoch > 0, !binding.sourceID.isEmpty else {
            throw SnapshotFrameError.invalidSourceIdentity
        }
    }

    private static func bindingMismatch(
        expected: VideoBindingIdentity,
        actual: VideoBindingIdentity
    ) -> SnapshotFrameError {
        if expected.canonicalUDID != actual.canonicalUDID {
            return .targetMismatch
        }
        if expected.connectionEpoch != actual.connectionEpoch {
            return .connectionEpochMismatch
        }
        if expected.sourceEpoch != actual.sourceEpoch {
            return .sourceEpochMismatch
        }
        if expected.sourceID != actual.sourceID {
            return .sourceIDMismatch
        }
        return .geometryRevisionMismatch
    }

    private static func pixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        alignsWith orientation: DisplayOrientationDTO
    ) -> Bool {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        switch orientation {
        case .portrait, .portraitUpsideDown:
            return height > width
        case .landscapeLeft, .landscapeRight:
            return width > height
        }
    }

    private static func validFingerprint(_ fingerprint: [UInt8]?) -> [UInt8]? {
        guard let fingerprint,
              fingerprint.count == 16 * 16 * 4
        else { return nil }
        return fingerprint
    }

    private static func fingerprintDifferenceMilli(
        _ lhs: [UInt8],
        _ rhs: [UInt8]
    ) -> UInt64? {
        guard lhs.count == rhs.count,
              !lhs.isEmpty,
              lhs.count.isMultiple(of: 4)
        else { return nil }
        var difference: UInt64 = 0
        for index in lhs.indices where index % 4 != 3 {
            difference += UInt64(abs(Int(lhs[index]) - Int(rhs[index])))
        }
        let componentCount = UInt64(lhs.count / 4 * 3)
        return difference * 1_000 / (componentCount * 255)
    }
}
