import AVFoundation
import Foundation
import PulsePhoneMedia
import PulsePhoneSharedDefinitions

enum ProductionSourceCaptureRole: String, Sendable {
    case bound
    case chooserPreview
    case handoff
    case liveProbe
    case resolverProbe
    case thumbnail
}

protocol ProductionSourceCaptureBackend: AnyObject, Sendable {
    var audioDeviceUniqueID: String? { get }
    var hasAudioOutput: Bool { get }
    var isRunning: Bool { get }
    func reconfigure(
        shouldRestart: @escaping @Sendable () -> Bool
    ) throws -> Bool
    func start() throws
    func stop()
}

extension ProductionAVFoundationVideoCapture: ProductionSourceCaptureBackend {}

struct ProductionSourceCaptureKey: Equatable, Hashable, Sendable {
    let sourceEpoch: UInt64
    let sourceID: String
}

final class ProductionSourceCaptureCoordinator: @unchecked Sendable {
    typealias CaptureFactory = @Sendable (
        String,
        UInt64,
        @escaping ProductionAVFoundationVideoSourceCatalog.FrameHandler,
        ProductionAVFoundationVideoSourceCatalog.AudioHandler?
    ) throws -> any ProductionSourceCaptureBackend

    private struct HandoffKey: Equatable, Hashable {
        let ownerID: String
        let target: CanonicalUDID
    }

    private struct HandoffReservation {
        let captureKey: ProductionSourceCaptureKey
        let token: UUID
    }

    private let captureFactory: CaptureFactory
    private var entries = [ProductionSourceCaptureKey: CaptureEntry]()
    private var handoffs = [HandoffKey: HandoffReservation]()
    private let lock = NSLock()

    convenience init(catalog: ProductionAVFoundationVideoSourceCatalog) {
        self.init { sourceID, sourceEpoch, frameHandler, audioHandler in
            try catalog.makeCapture(
                sourceID: sourceID,
                sourceEpoch: sourceEpoch,
                frameHandler: frameHandler,
                audioHandler: audioHandler
            )
        }
    }

    init(captureFactory: @escaping CaptureFactory) {
        self.captureFactory = captureFactory
    }

    func acquire(
        sourceID: String,
        sourceEpoch: UInt64,
        role: ProductionSourceCaptureRole,
        handoffTarget: CanonicalUDID? = nil,
        handoffOwnerID: String? = nil,
        frameHandler: @escaping ProductionAVFoundationVideoSourceCatalog.FrameHandler,
        audioHandler: ProductionAVFoundationVideoSourceCatalog.AudioHandler? = nil
    ) throws -> ProductionSourceCaptureLease {
        let key = ProductionSourceCaptureKey(
            sourceEpoch: sourceEpoch,
            sourceID: sourceID
        )
        return try lock.withLock {
            let entry: CaptureEntry
            if let existing = entries[key] {
                entry = existing
            } else {
                let generation = UUID()
                let relay = CaptureEntryRelay()
                let capture = try captureFactory(
                    sourceID,
                    sourceEpoch,
                    { [relay] sample in
                        relay.dispatchFrame(generation: generation, sample: sample)
                    },
                    { [relay] sample in
                        relay.dispatchAudio(generation: generation, sample: sample)
                    }
                )
                entry = CaptureEntry(capture: capture, generation: generation)
                relay.entry = entry
                entries[key] = entry
            }
            let token = UUID()
            entry.addConsumer(
                token: token,
                role: role,
                frameHandler: frameHandler,
                audioHandler: audioHandler
            )
            if let handoffTarget, let handoffOwnerID {
                consumeHandoffLocked(
                    HandoffKey(ownerID: handoffOwnerID, target: handoffTarget),
                    matching: key,
                    retaining: entry
                )
            }
            return ProductionSourceCaptureLease(
                coordinator: self,
                key: key,
                token: token
            )
        }
    }

    func cancelHandoff(target: CanonicalUDID, ownerID: String) {
        lock.withLock {
            releaseHandoffLocked(HandoffKey(ownerID: ownerID, target: target))
        }
    }

    fileprivate func start(key: ProductionSourceCaptureKey, token: UUID) throws {
        let entry = lock.withLock { entries[key] }
        guard let entry else { throw AVFoundationVideoSourceError.sourceUnavailable }
        try entry.start(token: token)
    }

    fileprivate func update(
        key: ProductionSourceCaptureKey,
        token: UUID,
        role: ProductionSourceCaptureRole,
        frameHandler: @escaping ProductionAVFoundationVideoSourceCatalog.FrameHandler,
        audioHandler: ProductionAVFoundationVideoSourceCatalog.AudioHandler?
    ) throws {
        guard let entry = lock.withLock({ entries[key] }),
              entry.updateConsumer(
                token: token,
                role: role,
                frameHandler: frameHandler,
                audioHandler: audioHandler
              )
        else { throw AVFoundationVideoSourceError.sourceUnavailable }
    }

    fileprivate func reconfigure(
        key: ProductionSourceCaptureKey,
        token: UUID,
        shouldRestart: @escaping @Sendable () -> Bool
    ) throws -> Bool {
        guard let entry = lock.withLock({ entries[key] }) else { return false }
        return try entry.reconfigure(token: token, shouldRestart: shouldRestart)
    }

    fileprivate func isRunning(
        key: ProductionSourceCaptureKey,
        token: UUID
    ) -> Bool {
        lock.withLock { entries[key] }?.isRunning(token: token) == true
    }

    fileprivate func hasAudioOutput(
        key: ProductionSourceCaptureKey,
        token: UUID
    ) -> Bool {
        lock.withLock { entries[key] }?.hasAudioOutput(token: token) == true
    }

    fileprivate func audioDeviceUniqueID(
        key: ProductionSourceCaptureKey,
        token: UUID
    ) -> String? {
        lock.withLock { entries[key] }?.audioDeviceUniqueID(token: token)
    }

    fileprivate func release(key: ProductionSourceCaptureKey, token: UUID) {
        lock.withLock {
            guard let entry = entries[key] else { return }
            removeHandoffForTokenLocked(token)
            if entry.removeConsumer(token: token) {
                entries.removeValue(forKey: key)
            }
        }
    }

    fileprivate func transferForHandoff(
        key: ProductionSourceCaptureKey,
        token: UUID,
        target: CanonicalUDID,
        ownerID: String
    ) -> Bool {
        lock.withLock {
            guard let entry = entries[key],
                  entry.updateConsumer(
                    token: token,
                    role: .handoff,
                    frameHandler: { _ in },
                    audioHandler: nil
                  )
            else { return false }
            let handoffKey = HandoffKey(ownerID: ownerID, target: target)
            releaseHandoffLocked(handoffKey)
            handoffs[handoffKey] = HandoffReservation(
                captureKey: key,
                token: token
            )
            return true
        }
    }

    private func consumeHandoffLocked(
        _ handoffKey: HandoffKey,
        matching key: ProductionSourceCaptureKey,
        retaining entry: CaptureEntry
    ) {
        guard let reservation = handoffs.removeValue(forKey: handoffKey) else {
            return
        }
        guard reservation.captureKey == key else {
            releaseReservationLocked(reservation)
            return
        }
        _ = entry.removeConsumer(token: reservation.token, stopWhenEmpty: false)
    }

    private func releaseHandoffLocked(_ key: HandoffKey) {
        guard let reservation = handoffs.removeValue(forKey: key) else { return }
        releaseReservationLocked(reservation)
    }

    private func releaseReservationLocked(_ reservation: HandoffReservation) {
        guard let entry = entries[reservation.captureKey] else { return }
        if entry.removeConsumer(token: reservation.token) {
            entries.removeValue(forKey: reservation.captureKey)
        }
    }

    private func removeHandoffForTokenLocked(_ token: UUID) {
        let keys = handoffs.compactMap { key, value in
            value.token == token ? key : nil
        }
        for key in keys { handoffs.removeValue(forKey: key) }
    }

}

final class ProductionSourceCaptureLease: @unchecked Sendable {
    private weak var coordinator: ProductionSourceCaptureCoordinator?
    let key: ProductionSourceCaptureKey
    private let lock = NSLock()
    private var released = false
    private let token: UUID

    fileprivate init(
        coordinator: ProductionSourceCaptureCoordinator,
        key: ProductionSourceCaptureKey,
        token: UUID
    ) {
        self.coordinator = coordinator
        self.key = key
        self.token = token
    }

    var hasAudioOutput: Bool {
        lock.withLock {
            !released && coordinator?.hasAudioOutput(key: key, token: token) == true
        }
    }

    var audioDeviceUniqueID: String? {
        lock.withLock { () -> String? in
            guard !released else { return nil }
            let value: String? = coordinator?.audioDeviceUniqueID(
                key: key,
                token: token
            )
            return value
        }
    }

    var isRunning: Bool {
        lock.withLock {
            !released && coordinator?.isRunning(key: key, token: token) == true
        }
    }

    func start() throws {
        try lock.withLock {
            guard !released, let coordinator else {
                throw AVFoundationVideoSourceError.sourceUnavailable
            }
            try coordinator.start(key: key, token: token)
        }
    }

    func update(
        role: ProductionSourceCaptureRole,
        frameHandler: @escaping ProductionAVFoundationVideoSourceCatalog.FrameHandler,
        audioHandler: ProductionAVFoundationVideoSourceCatalog.AudioHandler? = nil
    ) throws {
        try lock.withLock {
            guard !released, let coordinator else {
                throw AVFoundationVideoSourceError.sourceUnavailable
            }
            try coordinator.update(
                key: key,
                token: token,
                role: role,
                frameHandler: frameHandler,
                audioHandler: audioHandler
            )
        }
    }

    func reconfigure(
        shouldRestart: @escaping @Sendable () -> Bool
    ) throws -> Bool {
        try lock.withLock {
            guard !released, let coordinator else { return false }
            return try coordinator.reconfigure(
                key: key,
                token: token,
                shouldRestart: shouldRestart
            )
        }
    }

    func transferForHandoff(target: CanonicalUDID, ownerID: String) -> Bool {
        lock.withLock {
            guard !released, let coordinator,
                  coordinator.transferForHandoff(
                    key: key,
                    token: token,
                    target: target,
                    ownerID: ownerID
                  )
            else { return false }
            released = true
            return true
        }
    }

    func stop() {
        let release = lock.withLock { () -> ProductionSourceCaptureCoordinator? in
            guard !released else { return nil }
            released = true
            return coordinator
        }
        release?.release(key: key, token: token)
    }

    deinit { stop() }
}

private final class CaptureEntry: @unchecked Sendable {
    private struct Consumer {
        let audioHandler: ProductionAVFoundationVideoSourceCatalog.AudioHandler?
        let frameHandler: ProductionAVFoundationVideoSourceCatalog.FrameHandler
        let role: ProductionSourceCaptureRole
    }

    private enum State: Equatable {
        case idle
        case running
        case starting
        case stopped
    }

    private let capture: any ProductionSourceCaptureBackend
    private let condition = NSCondition()
    private var consumers = [UUID: Consumer]()
    private let generation: UUID
    private var state: State = .idle

    init(capture: any ProductionSourceCaptureBackend, generation: UUID) {
        self.capture = capture
        self.generation = generation
    }

    func addConsumer(
        token: UUID,
        role: ProductionSourceCaptureRole,
        frameHandler: @escaping ProductionAVFoundationVideoSourceCatalog.FrameHandler,
        audioHandler: ProductionAVFoundationVideoSourceCatalog.AudioHandler?
    ) {
        condition.withLock {
            consumers[token] = Consumer(
                audioHandler: audioHandler,
                frameHandler: frameHandler,
                role: role
            )
        }
    }

    func updateConsumer(
        token: UUID,
        role: ProductionSourceCaptureRole,
        frameHandler: @escaping ProductionAVFoundationVideoSourceCatalog.FrameHandler,
        audioHandler: ProductionAVFoundationVideoSourceCatalog.AudioHandler?
    ) -> Bool {
        condition.withLock {
            guard consumers[token] != nil else { return false }
            consumers[token] = Consumer(
                audioHandler: audioHandler,
                frameHandler: frameHandler,
                role: role
            )
            return true
        }
    }

    func start(token: UUID) throws {
        condition.lock()
        while state == .starting { condition.wait() }
        guard consumers[token] != nil, state != .stopped else {
            condition.unlock()
            throw AVFoundationVideoSourceError.sourceUnavailable
        }
        if state == .running, capture.isRunning {
            condition.unlock()
            return
        }
        state = .starting
        condition.unlock()
        do {
            try capture.start()
            condition.withLock {
                state = .running
                condition.broadcast()
            }
        } catch {
            condition.withLock {
                state = .idle
                condition.broadcast()
            }
            throw error
        }
    }

    func removeConsumer(token: UUID, stopWhenEmpty: Bool = true) -> Bool {
        condition.lock()
        consumers.removeValue(forKey: token)
        while state == .starting { condition.wait() }
        let shouldStop = stopWhenEmpty && consumers.isEmpty && state == .running
        let isEmpty = consumers.isEmpty
        if shouldStop { state = .stopped }
        condition.unlock()
        if shouldStop { capture.stop() }
        return isEmpty
    }

    func reconfigure(
        token: UUID,
        shouldRestart: @escaping @Sendable () -> Bool
    ) throws -> Bool {
        guard condition.withLock({ consumers[token] != nil && state == .running }) else {
            return false
        }
        return try capture.reconfigure { [weak self] in
            guard let self else { return false }
            return self.condition.withLock {
                self.consumers[token] != nil && self.state == .running
                    && shouldRestart()
            }
        }
    }

    func isRunning(token: UUID) -> Bool {
        condition.withLock {
            consumers[token] != nil && state == .running && capture.isRunning
        }
    }

    func hasAudioOutput(token: UUID) -> Bool {
        condition.withLock { consumers[token] != nil && capture.hasAudioOutput }
    }

    func audioDeviceUniqueID(token: UUID) -> String? {
        condition.withLock {
            consumers[token] != nil ? capture.audioDeviceUniqueID : nil
        }
    }

    func dispatchFrame(generation: UUID, sample: AVFoundationVideoFrameSample) {
        let handlers = condition.withLock { () -> [ProductionAVFoundationVideoSourceCatalog.FrameHandler] in
            guard self.generation == generation,
                  state == .running || state == .starting
            else { return [] }
            return consumers.values.map(\.frameHandler)
        }
        for handler in handlers { handler(sample) }
    }

    func dispatchAudio(generation: UUID, sample: CMSampleBuffer) {
        let handlers = condition.withLock { () -> [ProductionAVFoundationVideoSourceCatalog.AudioHandler] in
            guard self.generation == generation,
                  state == .running || state == .starting
            else { return [] }
            return consumers.values.compactMap(\.audioHandler)
        }
        for handler in handlers { handler(sample) }
    }
}

private final class CaptureEntryRelay: @unchecked Sendable {
    weak var entry: CaptureEntry?

    func dispatchFrame(
        generation: UUID,
        sample: AVFoundationVideoFrameSample
    ) {
        entry?.dispatchFrame(generation: generation, sample: sample)
    }

    func dispatchAudio(generation: UUID, sample: CMSampleBuffer) {
        entry?.dispatchAudio(generation: generation, sample: sample)
    }
}

private extension NSCondition {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
