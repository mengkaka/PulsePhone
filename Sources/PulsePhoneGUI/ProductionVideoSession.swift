import AppKit
import AVFoundation
import CoreImage
import Foundation
import OSLog
import PulsePhoneMedia
import PulsePhoneSharedDefinitions

public struct ProductionVideoSourceMapping: Equatable, Sendable {
    public let connectionEpoch: UInt64
    public let geometry: DisplayGeometryDTO
    public let mappingProofID: String
    public let sourceEpoch: UInt64
    public let sourceID: String

    public init(
        connectionEpoch: UInt64,
        geometry: DisplayGeometryDTO,
        mappingProofID: String,
        sourceEpoch: UInt64,
        sourceID: String
    ) {
        self.connectionEpoch = connectionEpoch
        self.geometry = geometry
        self.mappingProofID = mappingProofID
        self.sourceEpoch = sourceEpoch
        self.sourceID = sourceID
    }
}

struct ProductionVideoSnapshot: Sendable {
    let activeFormatHeight: UInt64
    let activeFormatWidth: UInt64
    let connectionEpochs: [UInt64]
    let droppedFrameCount: UInt64
    let enqueuedFrameCount: UInt64
    let enqueueMonotonicNanoseconds: [UInt64]
    let formatRevision: UInt64
    let latencyMicroseconds: [UInt64]
    let receivedFrameCount: UInt64
    let sourceEpoch: UInt64
    let sourceEpochs: [UInt64]
}

struct ProductionVideoPresentationTracker: Sendable {
    enum Observation: Equatable, Sendable {
        case anomalous
        case candidate(token: UUID, deadlineNanoseconds: UInt64, sampleCount: Int)
        case committed(LiveSamplePresentationFormat)
        case unchanged
    }

    private struct Candidate: Equatable, Sendable {
        let deadlineNanoseconds: UInt64
        let height: UInt64
        var sampleCount: Int
        let token: UUID
        let width: UInt64
    }

    static let debounceNanoseconds: UInt64 = 400_000_000
    private(set) var current: LiveSamplePresentationFormat?
    private var candidate: Candidate?
    private let sourceEpoch: UInt64

    init(sourceEpoch: UInt64) {
        self.sourceEpoch = sourceEpoch
    }

    mutating func observe(
        width: UInt64,
        height: UInt64,
        at nanoseconds: UInt64
    ) -> Observation {
        guard width > 0, height > 0 else {
            candidate = nil
            return .anomalous
        }
        guard let current else {
            let established = try! LiveSamplePresentationFormat(
                sourceEpoch: sourceEpoch,
                width: width,
                height: height,
                formatRevision: 1
            )
            self.current = established
            candidate = nil
            return .committed(established)
        }
        guard current.dimensions.widthUnits != width
                || current.dimensions.heightUnits != height
        else {
            candidate = nil
            return .unchanged
        }

        let next = try! LiveSamplePresentationFormat(
            sourceEpoch: sourceEpoch,
            width: width,
            height: height,
            formatRevision: current.formatRevision
        )
        guard abs(next.normalizedShape - current.normalizedShape)
                <= LiveSamplePresentationFormat.normalizedShapeTolerance
        else {
            candidate = nil
            return .anomalous
        }

        if var candidate,
           candidate.width == width,
           candidate.height == height,
           nanoseconds <= candidate.deadlineNanoseconds
        {
            candidate.sampleCount += 1
            self.candidate = candidate
        } else {
            let deadline = nanoseconds.addingReportingOverflow(
                Self.debounceNanoseconds
            )
            candidate = Candidate(
                deadlineNanoseconds: deadline.overflow
                    ? UInt64.max
                    : deadline.partialValue,
                height: height,
                sampleCount: 1,
                token: UUID(),
                width: width
            )
        }

        guard let candidate = self.candidate else { return .anomalous }
        if candidate.sampleCount >= 3 {
            return commit(candidate)
        }
        return .candidate(
            token: candidate.token,
            deadlineNanoseconds: candidate.deadlineNanoseconds,
            sampleCount: candidate.sampleCount
        )
    }

    mutating func commitCandidate(
        token: UUID,
        at nanoseconds: UInt64
    ) -> LiveSamplePresentationFormat? {
        guard let candidate,
              candidate.token == token,
              candidate.sampleCount >= 2,
              nanoseconds >= candidate.deadlineNanoseconds
        else { return nil }
        guard case .committed(let format) = commit(candidate) else { return nil }
        return format
    }

    mutating func discardCandidate() {
        candidate = nil
    }

    private mutating func commit(_ candidate: Candidate) -> Observation {
        guard let current, current.formatRevision < UInt64.max else {
            self.candidate = nil
            return .anomalous
        }
        let format = try! LiveSamplePresentationFormat(
            sourceEpoch: sourceEpoch,
            width: candidate.width,
            height: candidate.height,
            formatRevision: current.formatRevision + 1
        )
        self.current = format
        self.candidate = nil
        return .committed(format)
    }
}

struct ProductionCaptureReconfigurationState: Equatable, Sendable {
    static let delayNanoseconds: UInt64 = 600_000_000

    private(set) var handledGeometryRevisions = Set<UInt64>()
    private var inProgressGeometries = [UInt64: DisplayGeometryDTO]()
    private(set) var scheduledGeometry: DisplayGeometryDTO?

    var inProgressGeometry: DisplayGeometryDTO? {
        inProgressGeometries.count == 1
            ? inProgressGeometries.values.first
            : nil
    }

    var isPendingOrInProgress: Bool {
        scheduledGeometry != nil || !inProgressGeometries.isEmpty
    }

    mutating func schedule(
        geometry: DisplayGeometryDTO,
        presentation: LiveSamplePresentationFormat?
    ) -> Bool {
        guard geometry.geometryRevision > 0,
              let presentation,
              !presentation.aligns(with: geometry),
              !handledGeometryRevisions.contains(geometry.geometryRevision),
              scheduledGeometry?.geometryRevision != geometry.geometryRevision
        else { return false }
        handledGeometryRevisions.insert(geometry.geometryRevision)
        scheduledGeometry = geometry
        return true
    }

    mutating func beginAttempt(
        geometry: DisplayGeometryDTO,
        currentBinding: VideoBindingIdentity,
        presentation: LiveSamplePresentationFormat?
    ) -> Bool {
        guard scheduledGeometry == geometry else { return false }
        scheduledGeometry = nil
        guard currentBinding.connectionEpoch == geometry.connectionEpoch,
              currentBinding.geometryRevision == geometry.geometryRevision,
              let presentation,
              !presentation.aligns(with: geometry)
        else { return false }
        inProgressGeometries[geometry.geometryRevision] = geometry
        return true
    }

    @discardableResult
    mutating func finishAttempt(for geometry: DisplayGeometryDTO) -> Bool {
        guard inProgressGeometries[geometry.geometryRevision] == geometry else {
            return false
        }
        inProgressGeometries.removeValue(forKey: geometry.geometryRevision)
        return true
    }

    mutating func stop() {
        scheduledGeometry = nil
        inProgressGeometries.removeAll(keepingCapacity: false)
    }
}

struct ProductionPerformanceVideoLineage: Sendable {
    private(set) var connectionEpochs = [UInt64]()
    private(set) var sourceEpochs = [UInt64]()

    private let baseGeometry: DisplayGeometryDTO
    private let mappingProofID: String
    private let sourceID: String
    private var currentConnectionEpoch: UInt64
    private var currentGeometryRevision: UInt64
    private var hasBoundSource = false
    private var sourceWasAbsent = false

    init(mapping: ProductionVideoSourceMapping) {
        baseGeometry = mapping.geometry
        mappingProofID = mapping.mappingProofID
        sourceID = mapping.sourceID
        currentConnectionEpoch = mapping.connectionEpoch
        currentGeometryRevision = mapping.geometry.geometryRevision
    }

    mutating func recordSourceAbsent() {
        if hasBoundSource { sourceWasAbsent = true }
    }

    func matches(sourceID: String) -> Bool {
        self.sourceID == sourceID
    }

    mutating func mapping(
        for descriptor: VideoSourceDescriptor
    ) throws -> ProductionVideoSourceMapping? {
        guard descriptor.sourceID == sourceID else { return nil }
        if sourceWasAbsent {
            guard currentConnectionEpoch < UInt64.max,
                  currentGeometryRevision < UInt64.max
            else { return nil }
            currentConnectionEpoch += 1
            currentGeometryRevision += 1
        }
        let geometry = try DisplayGeometryDTO(
            connectionEpoch: currentConnectionEpoch,
            geometryRevision: currentGeometryRevision,
            logicalHeight: baseGeometry.logicalHeight,
            logicalWidth: baseGeometry.logicalWidth,
            orientation: baseGeometry.orientation
        )
        sourceWasAbsent = false
        hasBoundSource = true
        if !connectionEpochs.contains(currentConnectionEpoch) {
            connectionEpochs.append(currentConnectionEpoch)
        }
        if !sourceEpochs.contains(descriptor.sourceEpoch) {
            sourceEpochs.append(descriptor.sourceEpoch)
        }
        return ProductionVideoSourceMapping(
            connectionEpoch: currentConnectionEpoch,
            geometry: geometry,
            mappingProofID: mappingProofID,
            sourceEpoch: descriptor.sourceEpoch,
            sourceID: descriptor.sourceID
        )
    }
}

struct ProductionVisualChangeProbeAccumulator: Sendable {
    struct TerminalObservation: Equatable, Sendable {
        let actionID: CanonicalUUID
        let changed: Bool
        let commandID: String
        let differenceMilli: UInt64
        let elapsedNanoseconds: UInt64
    }

    private struct Pending: Sendable {
        let actionID: CanonicalUUID
        var baseline: [UInt8]?
        let clickedAtNanoseconds: UInt64
        let commandID: String
    }

    private var pending: Pending?

    mutating func arm(
        actionID: CanonicalUUID,
        commandID: String,
        clickedAtNanoseconds: UInt64,
        baseline: [UInt8]? = nil
    ) {
        pending = Pending(
            actionID: actionID,
            baseline: baseline,
            clickedAtNanoseconds: clickedAtNanoseconds,
            commandID: commandID
        )
    }

    mutating func observe(
        fingerprint: [UInt8]?,
        capturedAtNanoseconds: UInt64,
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        difference: ([UInt8], [UInt8]) -> UInt64?
    ) -> TerminalObservation? {
        guard var pending,
              capturedAtNanoseconds >= pending.clickedAtNanoseconds
        else { return nil }
        let elapsed = capturedAtNanoseconds - pending.clickedAtNanoseconds
        guard let fingerprint else {
            guard elapsed >= timeoutNanoseconds else { return nil }
            self.pending = nil
            return TerminalObservation(
                actionID: pending.actionID,
                changed: false,
                commandID: pending.commandID,
                differenceMilli: 0,
                elapsedNanoseconds: elapsed
            )
        }
        guard let baseline = pending.baseline else {
            guard elapsed < timeoutNanoseconds else {
                self.pending = nil
                return TerminalObservation(
                    actionID: pending.actionID,
                    changed: false,
                    commandID: pending.commandID,
                    differenceMilli: 0,
                    elapsedNanoseconds: elapsed
                )
            }
            pending.baseline = fingerprint
            self.pending = pending
            return nil
        }
        guard let differenceMilli = difference(baseline, fingerprint) else {
            return nil
        }
        let changed = differenceMilli >= 30
        guard changed || elapsed >= timeoutNanoseconds else { return nil }
        self.pending = nil
        return TerminalObservation(
            actionID: pending.actionID,
            changed: changed,
            commandID: pending.commandID,
            differenceMilli: differenceMilli,
            elapsedNanoseconds: elapsed
        )
    }

    mutating func clear() {
        pending = nil
    }
}

final class ProductionPerformanceVideoLifecycle: @unchecked Sendable {
    private struct ActiveSession {
        let descriptor: VideoSourceDescriptor
        let session: ProductionBoundVideoSession
    }

    private let catalog: ProductionAVFoundationVideoSourceCatalog
    private var completedSnapshots = [ProductionVideoSnapshot]()
    private var active: ActiveSession?
    private var lineage: ProductionPerformanceVideoLineage
    private let queue = DispatchQueue(
        label: "dev.pulsephone.performance.video-lifecycle",
        qos: .userInitiated
    )
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var stopped = false
    private let target: CanonicalUDID

    init(
        target: CanonicalUDID,
        mapping: ProductionVideoSourceMapping,
        catalog: ProductionAVFoundationVideoSourceCatalog =
            ProductionAVFoundationVideoSourceCatalog()
    ) {
        self.catalog = catalog
        self.lineage = ProductionPerformanceVideoLineage(mapping: mapping)
        self.target = target
        queue.setSpecific(key: queueKey, value: 1)
    }

    func start() {
        catalog.startMonitoring { [weak self] inventory in
            self?.queue.async { [weak self] in
                self?.apply(inventory)
            }
        }
    }

    func stop() {
        catalog.stopMonitoring()
        syncOnQueue {
            guard !stopped else { return }
            stopped = true
            stopActiveSession()
        }
    }

    func snapshot() -> ProductionVideoSnapshot? {
        syncOnQueue {
            var snapshots = completedSnapshots
            if let active { snapshots.append(active.session.snapshot()) }
            guard let latest = snapshots.last else { return nil }
            return ProductionVideoSnapshot(
                activeFormatHeight: latest.activeFormatHeight,
                activeFormatWidth: latest.activeFormatWidth,
                connectionEpochs: lineage.connectionEpochs,
                droppedFrameCount: Self.sum(snapshots.map(\.droppedFrameCount)),
                enqueuedFrameCount: Self.sum(snapshots.map(\.enqueuedFrameCount)),
                enqueueMonotonicNanoseconds: snapshots.flatMap {
                    $0.enqueueMonotonicNanoseconds
                },
                formatRevision: latest.formatRevision,
                latencyMicroseconds: snapshots.flatMap(\.latencyMicroseconds),
                receivedFrameCount: Self.sum(snapshots.map(\.receivedFrameCount)),
                sourceEpoch: latest.sourceEpoch,
                sourceEpochs: lineage.sourceEpochs
            )
        }
    }

    private func apply(_ inventory: VideoSourceInventory) {
        guard !stopped else { return }
        guard let descriptor = inventory.sources.first(where: {
            lineage.matches(sourceID: $0.sourceID)
        }) else {
            lineage.recordSourceAbsent()
            stopActiveSession()
            return
        }
        if active?.descriptor == descriptor { return }
        stopActiveSession()
        var candidateLineage = lineage
        do {
            guard let mapping = try candidateLineage.mapping(for: descriptor) else {
                return
            }
            let session = try ProductionBoundVideoSession.start(
                target: target,
                mapping: mapping,
                catalog: catalog,
                inventory: inventory
            )
            lineage = candidateLineage
            active = ActiveSession(descriptor: descriptor, session: session)
        } catch {
            return
        }
    }

    private func stopActiveSession() {
        guard let active else { return }
        active.session.stop()
        completedSnapshots.append(active.session.snapshot())
        self.active = nil
    }

    private func syncOnQueue<T>(_ body: () -> T) -> T {
        DispatchQueue.getSpecific(key: queueKey) == nil
            ? queue.sync(execute: body)
            : body()
    }

    private static func sum(_ values: [UInt64]) -> UInt64 {
        values.reduce(0) { partial, value in
            let result = partial.addingReportingOverflow(value)
            return result.overflow ? UInt64.max : result.partialValue
        }
    }

    deinit {
        stop()
    }
}

private protocol ProductionBoundVideoCaptureControlling: AnyObject, Sendable {
    var audioDeviceUniqueID: String? { get }
    var hasAudioOutput: Bool { get }
    var isRunning: Bool { get }
    func reconfigure(
        shouldRestart: @escaping @Sendable () -> Bool
    ) throws -> Bool
    func stop()
}

extension ProductionAVFoundationVideoCapture: ProductionBoundVideoCaptureControlling {}
extension ProductionSourceCaptureLease: ProductionBoundVideoCaptureControlling {}

enum ProductionVideoCaptureLivenessOutcome: Equatable, Sendable {
    case inactive
    case pending(afterNanoseconds: UInt64)
    case stalled
}

struct ProductionVideoCaptureLivenessState: Equatable, Sendable {
    static let timeoutNanoseconds: UInt64 = 2_000_000_000

    private(set) var lastSampleAtNanoseconds: UInt64?
    private(set) var stalled = false

    mutating func observeSample(atNanoseconds value: UInt64) {
        guard !stalled else { return }
        lastSampleAtNanoseconds = value
    }

    mutating func evaluate(
        atNanoseconds now: UInt64,
        captureIsRunning: Bool
    ) -> ProductionVideoCaptureLivenessOutcome {
        guard !stalled, captureIsRunning, let lastSampleAtNanoseconds else {
            return .inactive
        }
        guard now >= lastSampleAtNanoseconds else {
            return .pending(afterNanoseconds: Self.timeoutNanoseconds)
        }
        let age = now - lastSampleAtNanoseconds
        guard age >= Self.timeoutNanoseconds else {
            return .pending(afterNanoseconds: Self.timeoutNanoseconds - age)
        }
        stalled = true
        return .stalled
    }
}

final class ProductionBoundVideoSession: @unchecked Sendable {
    typealias CaptureReadyHandler = @Sendable (
        VideoBindingIdentity
    ) -> Void
    typealias PresentationHandler = @Sendable (
        LiveSamplePresentationFormat
    ) -> Void
    typealias DisplayGateHandler = @Sendable (Bool) -> Void
    typealias StallHandler = @Sendable (VideoBindingIdentity) -> Void

    enum VisualChangeProbeArmOutcome: String, Sendable {
        case armed
        case fingerprintUnavailable
        case noLatestFrame
        case noVideoSession
        case settlementUnavailable
        case sessionStopped
    }

    let displayLayer = AVSampleBufferDisplayLayer()

    private static let videoLatencyLogger = Logger(
        subsystem: "com.pulsephone.PulsePhone",
        category: "video-latency"
    )
    private static let audioPreviewLogger = Logger(
        subsystem: "com.pulsephone.PulsePhone",
        category: "audio-preview"
    )

    private var capture: (any ProductionBoundVideoCaptureControlling)?
    private let captureReadyHandler: CaptureReadyHandler?
    private var captureReadySignaled = false
    private let collector: ProductionVideoObservationCollector
    private let imageContext = CIContext(options: nil)
    let liveSnapshotFrameProvider: LiveSnapshotFrameProvider
    private let lock = NSLock()
    private var latestFrame: (
        sampleBuffer: CMSampleBuffer,
        capturedAtNanoseconds: UInt64,
        sequence: UInt64,
        binding: VideoBindingIdentity
    )?
    private var audioRenderer: AVSampleBufferAudioRenderer?
    private var audioSynchronizer: AVSampleBufferRenderSynchronizer?
    private var audioPlayback: AudioPreviewPCMPlayer?
    private var audioPreviewDeviceUniqueID: String?
    private var audioPreviewProcess: Process?
    private var audioPreviewUsesMuxedCapture = false
    private var audioMuted = true
    private var audioClockStarted = false
    private var captureReconfiguration = ProductionCaptureReconfigurationState()
    private var captureReconfigurationWorkItem: DispatchWorkItem?
    private var didLogPixelBufferFormat = false
    private var visualChangeProbe = ProductionVisualChangeProbeAccumulator()
    private var latestAcceptedFingerprint: [UInt8]?
    private var liveness = ProductionVideoCaptureLivenessState()
    private var livenessWorkItem: DispatchWorkItem?
    private let stallHandler: StallHandler?
    private var stopped = false

    private init(
        binding: VideoBindingIdentity,
        geometry: DisplayGeometryDTO,
        sourceWidth: UInt64,
        sourceHeight: UInt64,
        audioAuthorized: Bool,
        captureReadyHandler: CaptureReadyHandler?,
        presentationHandler: PresentationHandler?,
        displayGateHandler: DisplayGateHandler?,
        stallHandler: StallHandler?
    ) throws {
        self.captureReadyHandler = captureReadyHandler
        self.stallHandler = stallHandler
        liveSnapshotFrameProvider = try LiveSnapshotFrameProvider(
            binding: binding,
            geometry: geometry
        )
        collector = ProductionVideoObservationCollector(
            binding: binding,
            geometry: geometry,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            presentationHandler: presentationHandler,
            displayGateHandler: displayGateHandler
        )
        if audioAuthorized {
            let renderer = AVSampleBufferAudioRenderer()
            let synchronizer = AVSampleBufferRenderSynchronizer()
            synchronizer.addRenderer(renderer)
            synchronizer.setRate(0, time: .zero)
            renderer.volume = 0
            audioRenderer = renderer
            audioSynchronizer = synchronizer
        } else {
            audioRenderer = nil
            audioSynchronizer = nil
        }
        displayLayer.videoGravity = .resizeAspect
    }

    static func start(
        target: CanonicalUDID,
        mapping: ProductionVideoSourceMapping,
        captureReadyHandler: CaptureReadyHandler? = nil,
        presentationHandler: PresentationHandler? = nil,
        displayGateHandler: DisplayGateHandler? = nil,
        stallHandler: StallHandler? = nil
    ) throws -> ProductionBoundVideoSession {
        let catalog = ProductionAVFoundationVideoSourceCatalog()
        let inventory = try catalog.refresh()
        return try start(
            target: target,
            mapping: mapping,
            catalog: catalog,
            inventory: inventory,
            captureReadyHandler: captureReadyHandler,
            presentationHandler: presentationHandler,
            displayGateHandler: displayGateHandler,
            stallHandler: stallHandler
        )
    }

    static func start(
        target: CanonicalUDID,
        mapping: ProductionVideoSourceMapping,
        catalog: ProductionAVFoundationVideoSourceCatalog,
        inventory: VideoSourceInventory,
        captureReadyHandler: CaptureReadyHandler? = nil,
        presentationHandler: PresentationHandler? = nil,
        displayGateHandler: DisplayGateHandler? = nil,
        stallHandler: StallHandler? = nil
    ) throws -> ProductionBoundVideoSession {
        let claim = try VideoSourceMappingClaim(
            sourceID: mapping.sourceID,
            sourceEpoch: mapping.sourceEpoch,
            canonicalUDID: target,
            mappingProofID: mapping.mappingProofID
        )
        let resolution = try inventory.resolve(target: target, claims: [claim])
        let binding = try VideoBinding.make(
            target: target,
            connectionEpoch: mapping.connectionEpoch,
            geometry: mapping.geometry,
            resolution: resolution
        )
        guard case .mapped(let resolved) = resolution else {
            throw VideoBindingError.sourceUnavailable
        }
        let sourceWidth = resolved.descriptor.hasActiveFormat
            ? resolved.descriptor.activeFormatWidth
            : mapping.geometry.logicalWidth
        let sourceHeight = resolved.descriptor.hasActiveFormat
            ? resolved.descriptor.activeFormatHeight
            : mapping.geometry.logicalHeight
        let session = try ProductionBoundVideoSession(
            binding: binding,
            geometry: mapping.geometry,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            audioAuthorized: AVCaptureDevice.authorizationStatus(for: .audio)
                == .authorized,
            captureReadyHandler: captureReadyHandler,
            presentationHandler: presentationHandler,
            displayGateHandler: displayGateHandler,
            stallHandler: stallHandler
        )
        let capture = try catalog.makeCapture(
            sourceID: mapping.sourceID,
            sourceEpoch: mapping.sourceEpoch,
            frameHandler: { [weak session] sample in
                session?.receive(sample)
            },
            audioHandler: { [weak session] sample in
                session?.receiveAudio(sample)
            }
        )
        session.capture = capture
        try capture.start()
        session.audioPreviewDeviceUniqueID = capture.audioDeviceUniqueID
        session.audioPreviewUsesMuxedCapture = capture.audioDeviceUniqueID == nil
            && capture.hasAudioOutput
        if !capture.hasAudioOutput {
            session.audioRenderer = nil
            session.audioSynchronizer = nil
        }
        return session
    }

    static func start(
        target: CanonicalUDID,
        mapping: ProductionVideoSourceMapping,
        captureLease: ProductionSourceCaptureLease,
        inventory: VideoSourceInventory,
        captureReadyHandler: CaptureReadyHandler? = nil,
        presentationHandler: PresentationHandler? = nil,
        displayGateHandler: DisplayGateHandler? = nil,
        stallHandler: StallHandler? = nil
    ) throws -> ProductionBoundVideoSession {
        let claim = try VideoSourceMappingClaim(
            sourceID: mapping.sourceID,
            sourceEpoch: mapping.sourceEpoch,
            canonicalUDID: target,
            mappingProofID: mapping.mappingProofID
        )
        let resolution = try inventory.resolve(target: target, claims: [claim])
        let binding = try VideoBinding.make(
            target: target,
            connectionEpoch: mapping.connectionEpoch,
            geometry: mapping.geometry,
            resolution: resolution
        )
        guard case .mapped(let resolved) = resolution else {
            throw VideoBindingError.sourceUnavailable
        }
        let sourceWidth = resolved.descriptor.hasActiveFormat
            ? resolved.descriptor.activeFormatWidth
            : mapping.geometry.logicalWidth
        let sourceHeight = resolved.descriptor.hasActiveFormat
            ? resolved.descriptor.activeFormatHeight
            : mapping.geometry.logicalHeight
        let session = try ProductionBoundVideoSession(
            binding: binding,
            geometry: mapping.geometry,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            audioAuthorized: AVCaptureDevice.authorizationStatus(for: .audio)
                == .authorized,
            captureReadyHandler: captureReadyHandler,
            presentationHandler: presentationHandler,
            displayGateHandler: displayGateHandler,
            stallHandler: stallHandler
        )
        session.audioPreviewDeviceUniqueID = captureLease.audioDeviceUniqueID
        session.audioPreviewUsesMuxedCapture = captureLease.audioDeviceUniqueID == nil
            && captureLease.hasAudioOutput
        session.capture = captureLease
        try captureLease.update(
            role: .bound,
            frameHandler: { [weak session] sample in
                session?.receive(sample)
            },
            audioHandler: { [weak session] sample in
                session?.receiveAudio(sample)
            }
        )
        if !captureLease.hasAudioOutput {
            session.audioRenderer = nil
            session.audioSynchronizer = nil
        }
        return session
    }

    var bindingIdentity: VideoBindingIdentity { collector.bindingIdentity }

    var isWithholdingLiveResizeFrames: Bool {
        collector.isWithholdingLiveResizeFrames
    }

    func beginLiveResize(frozenPresentation: LiveSamplePresentationFormat?) {
        collector.beginLiveResize(frozenPresentation: frozenPresentation)
        if frozenPresentation == nil {
            liveSnapshotFrameProvider.setWithheld(false)
        }
    }

    func endLiveResize() {
        collector.endLiveResize()
        liveSnapshotFrameProvider.setWithheld(false)
    }

    var audioAvailable: Bool {
        lock.withLock {
            audioPreviewDeviceUniqueID != nil || capture?.hasAudioOutput == true
        }
    }

    func setAudioMuted(_ muted: Bool) {
        if muted {
            let playback = lock.withLock { () -> AudioPreviewPCMPlayer? in
                audioMuted = true
                audioRenderer?.volume = 0
                audioClockStarted = false
                audioSynchronizer?.setRate(0, time: .invalid)
                audioRenderer?.flush()
                let playback = audioPlayback
                audioPlayback = nil
                return playback
            }
            playback?.stop()
            stopAudioPreviewProcess()
            return
        }

        let deviceID = lock.withLock { () -> String? in
            audioMuted = false
            if audioPreviewUsesMuxedCapture {
                if audioPlayback == nil {
                    do {
                        audioPlayback = try AudioPreviewPCMPlayer()
                        Self.audioPreviewLogger.notice(
                            "action=start mode=in-process outcome=launched"
                        )
                    } catch {
                        Self.audioPreviewLogger.error(
                            "action=start mode=in-process outcome=failed"
                        )
                    }
                }
                audioRenderer?.volume = 0
                return nil
            }
            audioRenderer?.volume = 1
            return audioPreviewDeviceUniqueID
        }
        if let deviceID {
            startAudioPreviewProcess(deviceID: deviceID)
        }
    }

    private func startAudioPreviewProcess(deviceID: String) {
        Self.audioPreviewLogger.notice(
            "action=start deviceID=\(deviceID, privacy: .public)"
        )
        lock.lock()
        if let process = audioPreviewProcess, process.isRunning {
            lock.unlock()
            return
        }
        audioPreviewProcess = nil
        lock.unlock()

        guard let executablePath = ProcessInfo.processInfo.arguments.first else {
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            AudioPreviewHelperProcessEntrypoint.roleArgument,
            deviceID,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Self.audioPreviewLogger.error("action=start outcome=launchFailed")
            return
        }
        Self.audioPreviewLogger.notice("action=start outcome=launched")
        lock.withLock {
            if stopped || audioMuted {
                process.terminate()
            } else {
                audioPreviewProcess = process
            }
        }
    }

    private func stopAudioPreviewProcess() {
        let process = lock.withLock { () -> Process? in
            let process = audioPreviewProcess
            audioPreviewProcess = nil
            return process
        }
        guard let process, process.isRunning else { return }
        Self.audioPreviewLogger.notice("action=stop outcome=terminating")
        process.terminate()
        process.waitUntilExit()
    }

    private func setAudioPreviewDeviceUniqueID(_ value: String?) {
        lock.withLock {
            audioPreviewDeviceUniqueID = value
        }
    }

    func beginVisualChangeProbe(
        actionID: CanonicalUUID,
        commandID: String,
        clickedAtNanoseconds: UInt64
    ) -> VisualChangeProbeArmOutcome {
        return lock.withLock {
            guard !stopped else { return .sessionStopped }
            do {
                try liveSnapshotFrameProvider.recordAction(
                    actionID: actionID,
                    startedAtNanoseconds: clickedAtNanoseconds
                )
            } catch {
                return .settlementUnavailable
            }
            visualChangeProbe.arm(
                actionID: actionID,
                commandID: commandID,
                clickedAtNanoseconds: clickedAtNanoseconds,
                baseline: latestAcceptedFingerprint
            )
            return .armed
        }
    }

    func rebindGeometry(_ geometry: DisplayGeometryDTO) -> Bool {
        guard collector.rebindGeometry(geometry) else { return false }
        lock.withLock {
            latestAcceptedFingerprint = nil
            latestFrame = nil
        }
        let reconfigurationPending = scheduleCaptureReconfigurationIfNeeded(
            for: geometry
        )
        do {
            try liveSnapshotFrameProvider.rebind(
                binding: collector.bindingIdentity,
                geometry: geometry,
                reconfiguring: reconfigurationPending
            )
        } catch {
            liveSnapshotFrameProvider.markStalled()
            return false
        }
        return true
    }

    private func scheduleCaptureReconfigurationIfNeeded(
        for geometry: DisplayGeometryDTO
    ) -> Bool {
        let presentation = collector.currentPresentation
        let shouldSchedule = lock.withLock { () -> Bool in
            guard !stopped,
                  captureReconfiguration.schedule(
                      geometry: geometry,
                      presentation: presentation
                  )
            else { return false }
            captureReconfigurationWorkItem?.cancel()
            return true
        }
        guard shouldSchedule else {
            return lock.withLock {
                captureReconfiguration.isPendingOrInProgress
            }
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.performCaptureReconfiguration(for: geometry)
        }
        let installed = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            captureReconfigurationWorkItem = workItem
            return true
        }
        guard installed else { return false }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: DispatchTime.now()
                + .nanoseconds(Int(ProductionCaptureReconfigurationState
                    .delayNanoseconds)),
            execute: workItem
        )
        Self.videoLatencyLogger.notice(
            "stage=captureReconfiguration outcome=scheduled connectionEpoch=\(geometry.connectionEpoch, privacy: .public) geometryRevision=\(geometry.geometryRevision, privacy: .public)"
        )
        return true
    }

    private func performCaptureReconfiguration(
        for geometry: DisplayGeometryDTO
    ) {
        let presentation = collector.currentPresentation
        let binding = collector.bindingIdentity
        let shouldAttempt = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            return captureReconfiguration.beginAttempt(
                geometry: geometry,
                currentBinding: binding,
                presentation: presentation
            )
        }
        guard shouldAttempt else {
            synchronizeLiveReconfigurationGate()
            Self.videoLatencyLogger.notice(
                "stage=captureReconfiguration outcome=cancelled connectionEpoch=\(geometry.connectionEpoch, privacy: .public) geometryRevision=\(geometry.geometryRevision, privacy: .public)"
            )
            return
        }
        guard collector.beginCaptureReconfiguration(for: geometry) else {
            finishCaptureReconfiguration(for: geometry)
            Self.videoLatencyLogger.notice(
                "stage=captureReconfiguration outcome=cancelled connectionEpoch=\(geometry.connectionEpoch, privacy: .public) geometryRevision=\(geometry.geometryRevision, privacy: .public)"
            )
            return
        }
        defer { finishCaptureReconfiguration(for: geometry) }
        do {
            guard let capture = lock.withLock({ stopped ? nil : self.capture }) else {
                return
            }
            let restarted = try capture.reconfigure { [weak self, weak capture] in
                guard let self, let capture else { return false }
                return self.lock.withLock {
                    !self.stopped
                        && self.capture.map { $0 === capture } == true
                }
            }
            guard restarted else {
                let stillExpected = lock.withLock { !stopped }
                if stillExpected { liveSnapshotFrameProvider.markStalled() }
                Self.videoLatencyLogger.notice(
                    "stage=captureReconfiguration outcome=cancelled connectionEpoch=\(geometry.connectionEpoch, privacy: .public) geometryRevision=\(geometry.geometryRevision, privacy: .public)"
                )
                return
            }
            Self.videoLatencyLogger.notice(
                "stage=captureReconfiguration outcome=succeeded connectionEpoch=\(geometry.connectionEpoch, privacy: .public) geometryRevision=\(geometry.geometryRevision, privacy: .public)"
            )
        } catch {
            liveSnapshotFrameProvider.markStalled()
            Self.videoLatencyLogger.error(
                "stage=captureReconfiguration outcome=failed connectionEpoch=\(geometry.connectionEpoch, privacy: .public) geometryRevision=\(geometry.geometryRevision, privacy: .public) code=captureConfigurationFailed"
            )
        }
    }

    private func finishCaptureReconfiguration(
        for geometry: DisplayGeometryDTO
    ) {
        let pending = lock.withLock { () -> Bool in
            captureReconfiguration.finishAttempt(for: geometry)
            let pending = captureReconfiguration.isPendingOrInProgress
            if !pending { captureReconfigurationWorkItem = nil }
            return pending
        }
        liveSnapshotFrameProvider.setReconfiguring(pending)
    }

    private func synchronizeLiveReconfigurationGate() {
        let pending = lock.withLock { () -> Bool in
            let pending = captureReconfiguration.isPendingOrInProgress
            if !pending { captureReconfigurationWorkItem = nil }
            return pending
        }
        liveSnapshotFrameProvider.setReconfiguring(pending)
    }

    func latestScreenshotPreviewFrame() -> ScreenshotPreviewFrame? {
        let frame = lock.withLock { latestFrame }
        guard let frame,
              let pixelBuffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer)
        else { return nil }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = imageContext.createCGImage(image, from: image.extent),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(
                  using: .png,
                  properties: [:]
              ),
              let artifact = try? GUIScreenshotPNGArtifact(bytes: [UInt8](data))
        else { return nil }
        return ScreenshotPreviewFrame(
            artifact: artifact,
            capturedAtNanoseconds: frame.capturedAtNanoseconds,
            identity: VideoFrameIdentity(
                binding: frame.binding,
                frameSequence: frame.sequence
            )
        )
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        captureReconfiguration.stop()
        captureReconfigurationWorkItem?.cancel()
        captureReconfigurationWorkItem = nil
        livenessWorkItem?.cancel()
        livenessWorkItem = nil
        let active = capture
        capture = nil
        let renderer = audioRenderer
        audioRenderer = nil
        audioSynchronizer = nil
        let playback = audioPlayback
        audioPlayback = nil
        latestAcceptedFingerprint = nil
        latestFrame = nil
        visualChangeProbe.clear()
        lock.unlock()
        stopAudioPreviewProcess()
        playback?.stop()
        liveSnapshotFrameProvider.retire()
        collector.stop()
        renderer?.flush()
        active?.stop()
    }

    func snapshot() -> ProductionVideoSnapshot {
        collector.snapshot()
    }

    private func receive(_ sample: AVFoundationVideoFrameSample) {
        if sample.frameSequence.isMultiple(of: 30),
           let presentationAge = ProductionSampleBufferDisplay
            .presentationAgeMicroseconds(sample.sampleBuffer)
        {
            Self.videoLatencyLogger.notice(
                "stage=sample sourceEpoch=\(sample.sourceEpoch, privacy: .public) sequence=\(sample.frameSequence, privacy: .public) presentationAgeUs=\(presentationAge, privacy: .public)"
            )
        }
        var visualFingerprint: [UInt8]?
        let reception = collector.receive(
            sourceID: sample.sourceID,
            sourceEpoch: sample.sourceEpoch,
            frameSequence: sample.frameSequence,
            activeFormatWidth: sample.activeFormatWidth,
            activeFormatHeight: sample.activeFormatHeight,
            delegateMonotonicNanoseconds: sample.delegateMonotonicNanoseconds
        ) { binding in
            self.logPixelBufferFormatIfNeeded(sample.sampleBuffer)
            visualFingerprint = self.observeVisualChange(in: sample)
            DispatchQueue.main.async { [displayLayer = self.displayLayer] in
                ProductionSampleBufferDisplay.enqueue(
                    sample.sampleBuffer,
                    on: displayLayer
                )
            }
            self.lock.withLock {
                guard !self.stopped else { return }
                self.latestFrame = (
                    sample.sampleBuffer,
                    sample.delegateMonotonicNanoseconds,
                    sample.frameSequence,
                    binding
                )
            }
            return SystemMonotonicClock().now().nanoseconds
        }
        switch reception {
        case .dropped:
            break
        case .enqueued(let acceptedBinding):
            liveSnapshotFrameProvider.setWithheld(false)
            liveSnapshotFrameProvider.publish(
                sampleBuffer: sample.sampleBuffer,
                capturedAtNanoseconds: sample.delegateMonotonicNanoseconds,
                frameSequence: sample.frameSequence,
                binding: acceptedBinding,
                visualFingerprint: visualFingerprint
            )
            observeLivenessSample(atNanoseconds: sample.delegateMonotonicNanoseconds)
            signalCaptureReady(binding: acceptedBinding)
        case .withheld(let acceptedBinding):
            liveSnapshotFrameProvider.setWithheld(true)
            observeLivenessSample(atNanoseconds: sample.delegateMonotonicNanoseconds)
            signalCaptureReady(binding: acceptedBinding)
        }
    }

    private func receiveAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.withLock {
            guard !stopped, !audioMuted else { return }
            if audioPreviewUsesMuxedCapture {
                audioPlayback?.enqueue(sampleBuffer: sampleBuffer)
                return
            }
            if !audioClockStarted {
                let presentationTime = CMSampleBufferGetPresentationTimeStamp(
                    sampleBuffer
                )
                guard presentationTime.isValid else { return }
                audioSynchronizer?.setRate(1, time: presentationTime)
                audioClockStarted = true
            }
            audioRenderer?.enqueue(sampleBuffer)
        }
    }

    private func observeVisualChange(
        in sample: AVFoundationVideoFrameSample
    ) -> [UInt8]? {
        let fingerprint = frameFingerprint(sample.sampleBuffer)
        let observation = lock.withLock {
            let observation = visualChangeProbe.observe(
                fingerprint: fingerprint,
                capturedAtNanoseconds: sample.delegateMonotonicNanoseconds,
                difference: Self.fingerprintDifferenceMilli
            )
            latestAcceptedFingerprint = fingerprint
            return observation
        }
        if let observation {
            Self.videoLatencyLogger.notice(
                "stage=contentChange actionID=\(observation.actionID.canonicalString, privacy: .public) commandID=\(observation.commandID, privacy: .public) clickToSampleUs=\(observation.elapsedNanoseconds / 1_000, privacy: .public) differenceMilli=\(observation.differenceMilli, privacy: .public) outcome=\(observation.changed ? "changed" : "timedOut", privacy: .public)"
            )
        }
        return fingerprint
    }

    private func logPixelBufferFormatIfNeeded(_ sampleBuffer: CMSampleBuffer) {
        let shouldLog = lock.withLock { () -> Bool in
            guard !stopped, !didLogPixelBufferFormat else { return false }
            didLogPixelBufferFormat = true
            return true
        }
        guard shouldLog else { return }
        Self.videoLatencyLogger.notice(
            "stage=pixelBufferFormat \(Self.sampleBufferFormatDescription(sampleBuffer), privacy: .public)"
        )
    }

    private func signalCaptureReady(binding: VideoBindingIdentity) {
        let callback = lock.withLock { () -> CaptureReadyHandler? in
            guard !stopped, !captureReadySignaled else { return nil }
            captureReadySignaled = true
            return captureReadyHandler
        }
        callback?(binding)
    }

    private func observeLivenessSample(atNanoseconds value: UInt64) {
        let workItem = lock.withLock { () -> DispatchWorkItem? in
            guard !stopped else { return nil }
            liveness.observeSample(atNanoseconds: value)
            guard livenessWorkItem == nil else { return nil }
            let workItem = DispatchWorkItem { [weak self] in
                self?.evaluateLiveness()
            }
            livenessWorkItem = workItem
            return workItem
        }
        if let workItem {
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + .nanoseconds(Int(
                    ProductionVideoCaptureLivenessState.timeoutNanoseconds
                )),
                execute: workItem
            )
        }
    }

    private func evaluateLiveness() {
        let running = lock.withLock { !stopped && capture?.isRunning == true }
        let binding = collector.bindingIdentity
        let evaluation = lock.withLock { () -> (
            outcome: ProductionVideoCaptureLivenessOutcome,
            callback: StallHandler?
        ) in
            livenessWorkItem = nil
            let outcome = liveness.evaluate(
                atNanoseconds: SystemMonotonicClock().now().nanoseconds,
                captureIsRunning: running
            )
            return (
                outcome,
                outcome == .stalled && !stopped ? stallHandler : nil
            )
        }
        switch evaluation.outcome {
        case .inactive:
            return
        case .stalled:
            liveSnapshotFrameProvider.markStalled()
            evaluation.callback?(binding)
        case .pending(let delay):
            let workItem = DispatchWorkItem { [weak self] in
                self?.evaluateLiveness()
            }
            let installed = lock.withLock { () -> Bool in
                guard !stopped, livenessWorkItem == nil else { return false }
                livenessWorkItem = workItem
                return true
            }
            if installed {
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + .nanoseconds(Int(delay)),
                    execute: workItem
                )
            }
        }
    }

    private func frameFingerprint(_ sampleBuffer: CMSampleBuffer) -> [UInt8]? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }
        return Self.pixelBufferFingerprint(pixelBuffer) ?? Self.frameFingerprint(
            CIImage(cvPixelBuffer: pixelBuffer),
            imageContext: imageContext
        )
    }

    static func pixelBufferFingerprint(_ pixelBuffer: CVPixelBuffer) -> [UInt8]? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        if CVPixelBufferGetPlaneCount(pixelBuffer) > 0,
           let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        {
            return sampledFingerprint(
                baseAddress: baseAddress,
                bytesPerPixel: 1,
                bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
                componentOffsets: (0, 0, 0),
                height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
                width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            )
        }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }
        let componentOffsets: (Int, Int, Int)
        let bytesPerPixel: Int
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_32ARGB, kCVPixelFormatType_32ABGR:
            componentOffsets = (1, 2, 3)
            bytesPerPixel = 4
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA:
            componentOffsets = (0, 1, 2)
            bytesPerPixel = 4
        case kCVPixelFormatType_OneComponent8:
            componentOffsets = (0, 0, 0)
            bytesPerPixel = 1
        default:
            return nil
        }
        return sampledFingerprint(
            baseAddress: baseAddress,
            bytesPerPixel: bytesPerPixel,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            componentOffsets: componentOffsets,
            height: CVPixelBufferGetHeight(pixelBuffer),
            width: CVPixelBufferGetWidth(pixelBuffer)
        )
    }

    static func pixelBufferFormatDescription(
        _ pixelBuffer: CVPixelBuffer
    ) -> String {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        let layouts: [String]
        if planeCount > 0 {
            layouts = (0..<planeCount).map { plane in
                "\(plane):\(CVPixelBufferGetWidthOfPlane(pixelBuffer, plane))x\(CVPixelBufferGetHeightOfPlane(pixelBuffer, plane))@\(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane))"
            }
        } else {
            layouts = [
                "0:\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))@\(CVPixelBufferGetBytesPerRow(pixelBuffer))",
            ]
        }
        return "pixelFormat=\(fourCC(pixelFormat)) "
            + "pixelFormatNumeric=\(pixelFormat) "
            + "planeCount=\(planeCount) "
            + "planes=\(layouts.joined(separator: ";"))"
    }

    static func sampleBufferFormatDescription(
        _ sampleBuffer: CMSampleBuffer
    ) -> String {
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            return "outcome=pixelBuffer "
                + pixelBufferFormatDescription(pixelBuffer)
        }
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return "outcome=missingImageBuffer mediaType=none mediaSubtype=none"
        }
        return "outcome=missingImageBuffer "
            + "mediaType=\(fourCC(CMFormatDescriptionGetMediaType(format))) "
            + "mediaSubtype=\(fourCC(CMFormatDescriptionGetMediaSubType(format)))"
    }

    private static func fourCC(_ value: OSType) -> String {
        let shifts: [OSType] = [24, 16, 8, 0]
        return String(shifts.map { shift -> Character in
            let byte = UInt8(truncatingIfNeeded: value >> shift)
            guard (32...126).contains(byte) else { return "." }
            return Character(UnicodeScalar(byte))
        })
    }

    private static func sampledFingerprint(
        baseAddress: UnsafeMutableRawPointer,
        bytesPerPixel: Int,
        bytesPerRow: Int,
        componentOffsets: (Int, Int, Int),
        height: Int,
        width: Int
    ) -> [UInt8]? {
        guard bytesPerPixel > 0, bytesPerRow >= width * bytesPerPixel,
              height > 0, width > 0
        else { return nil }
        let source = baseAddress.assumingMemoryBound(to: UInt8.self)
        var bytes = [UInt8]()
        bytes.reserveCapacity(16 * 16 * 4)
        for row in 0..<16 {
            let y = min(height - 1, (row * height + height / 2) / 16)
            for column in 0..<16 {
                let x = min(width - 1, (column * width + width / 2) / 16)
                let offset = y * bytesPerRow + x * bytesPerPixel
                bytes.append(source[offset + componentOffsets.0])
                bytes.append(source[offset + componentOffsets.1])
                bytes.append(source[offset + componentOffsets.2])
                bytes.append(255)
            }
        }
        return bytes
    }

    static func frameFingerprint(
        _ image: CIImage,
        imageContext: CIContext
    ) -> [UInt8]? {
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0
        else { return nil }
        let translated = image.transformed(by: CGAffineTransform(
            translationX: -extent.minX,
            y: -extent.minY
        ))
        let scaled = translated.transformed(by: CGAffineTransform(
            scaleX: 16 / extent.width,
            y: 16 / extent.height
        ))
        let bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        guard let image = imageContext.createCGImage(scaled, from: bounds) else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: 16 * 16 * 4)
        guard let bitmap = CGContext(
            data: &bytes,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 16 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        bitmap.interpolationQuality = .none
        bitmap.draw(image, in: bounds)
        return bytes
    }

    static func fingerprintDifferenceMilli(
        _ lhs: [UInt8],
        _ rhs: [UInt8]
    ) -> UInt64? {
        guard lhs.count == rhs.count, !lhs.isEmpty, lhs.count.isMultiple(of: 4)
        else { return nil }
        var difference: UInt64 = 0
        for index in lhs.indices where index % 4 != 3 {
            difference += UInt64(abs(Int(lhs[index]) - Int(rhs[index])))
        }
        let componentCount = UInt64(lhs.count / 4 * 3)
        return difference * 1_000 / (componentCount * 255)
    }

    deinit {
        stop()
    }
}

enum ProductionVideoFrameReception: Equatable, Sendable {
    case dropped
    case enqueued(VideoBindingIdentity)
    case withheld(VideoBindingIdentity)
}

final class ProductionVideoObservationCollector: @unchecked Sendable {
    private var binding: VideoBindingIdentity
    private var geometry: DisplayGeometryDTO?
    private var droppedFrameCount: UInt64 = 0
    private var enqueuedFrameCount: UInt64 = 0
    private var enqueueMonotonicNanoseconds = [UInt64]()
    private var latencyMicroseconds = [UInt64]()
    private let lock = NSLock()
    private let displayGateHandler: ProductionBoundVideoSession.DisplayGateHandler?
    private var liveResizeFrozenOrientation: LiveSamplePresentationOrientation?
    private var liveResizeWithholding = false
    private var liveResizeWithheldFrameCount: UInt64 = 0
    private let presentationHandler: ProductionBoundVideoSession.PresentationHandler?
    private var presentationDeadlineWorkItem: DispatchWorkItem?
    private var presentationTracker: ProductionVideoPresentationTracker
    private var receivedFrameCount: UInt64 = 0
    private var sourceHeight: UInt64
    private var sourceWidth: UInt64
    private var stopped = false

    init(
        binding: VideoBindingIdentity,
        geometry: DisplayGeometryDTO? = nil,
        sourceWidth: UInt64,
        sourceHeight: UInt64,
        presentationHandler: ProductionBoundVideoSession.PresentationHandler? = nil,
        displayGateHandler: ProductionBoundVideoSession.DisplayGateHandler? = nil
    ) {
        self.binding = binding
        self.geometry = geometry
        self.presentationHandler = presentationHandler
        self.displayGateHandler = displayGateHandler
        self.presentationTracker = ProductionVideoPresentationTracker(
            sourceEpoch: binding.sourceEpoch
        )
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
    }

    var bindingIdentity: VideoBindingIdentity {
        lock.withLock { binding }
    }

    var currentPresentation: LiveSamplePresentationFormat? {
        lock.withLock { presentationTracker.current }
    }

    var isWithholdingLiveResizeFrames: Bool {
        lock.withLock { liveResizeWithholding }
    }

    var withheldLiveResizeFrameCount: UInt64 {
        lock.withLock { liveResizeWithheldFrameCount }
    }

    func beginLiveResize(frozenPresentation: LiveSamplePresentationFormat?) {
        var notify = false
        lock.lock()
        liveResizeFrozenOrientation = frozenPresentation?.orientation
        if frozenPresentation == nil, liveResizeWithholding {
            liveResizeWithholding = false
            notify = true
        }
        lock.unlock()
        if notify { displayGateHandler?(false) }
    }

    func endLiveResize() {
        var notify = false
        lock.lock()
        liveResizeFrozenOrientation = nil
        if liveResizeWithholding {
            liveResizeWithholding = false
            notify = true
        }
        lock.unlock()
        if notify { displayGateHandler?(false) }
    }

    func rebindGeometry(_ geometry: DisplayGeometryDTO) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped,
              geometry.connectionEpoch == binding.connectionEpoch
        else { return false }
        if geometry.geometryRevision == binding.geometryRevision {
            return self.geometry == geometry
        }
        guard geometry.geometryRevision > binding.geometryRevision else {
            return false
        }
        binding = VideoBindingIdentity(
            canonicalUDID: binding.canonicalUDID,
            connectionEpoch: binding.connectionEpoch,
            sourceID: binding.sourceID,
            sourceEpoch: binding.sourceEpoch,
            geometryRevision: geometry.geometryRevision
        )
        self.geometry = geometry
        return true
    }

    func beginCaptureReconfiguration(
        for geometry: DisplayGeometryDTO
    ) -> Bool {
        lock.lock()
        guard !stopped,
              binding.connectionEpoch == geometry.connectionEpoch,
              binding.geometryRevision == geometry.geometryRevision,
              let presentation = presentationTracker.current,
              !presentation.aligns(with: geometry)
        else {
            lock.unlock()
            return false
        }
        presentationTracker.discardCandidate()
        cancelPresentationDeadline()
        lock.unlock()
        return true
    }

    @discardableResult
    func receive(
        sourceID: String,
        sourceEpoch: UInt64,
        frameSequence: UInt64,
        activeFormatWidth: UInt64,
        activeFormatHeight: UInt64,
        delegateMonotonicNanoseconds: UInt64,
        enqueue: (VideoBindingIdentity) -> UInt64
    ) -> ProductionVideoFrameReception {
        var presentation: LiveSamplePresentationFormat?
        var gateTransition: Bool?
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return .dropped
        }
        let frame = VideoFrameIdentity(
            binding: VideoBindingIdentity(
                canonicalUDID: binding.canonicalUDID,
                connectionEpoch: binding.connectionEpoch,
                sourceID: sourceID,
                sourceEpoch: sourceEpoch,
                geometryRevision: binding.geometryRevision
            ),
            frameSequence: frameSequence
        )
        receivedFrameCount += 1
        guard case .accepted = VideoBinding.validate(frame: frame, against: binding)
        else {
            droppedFrameCount += 1
            lock.unlock()
            return .dropped
        }
        guard activeFormatWidth > 0, activeFormatHeight > 0 else {
            droppedFrameCount += 1
            lock.unlock()
            return .dropped
        }
        let observation = presentationTracker.observe(
            width: activeFormatWidth,
            height: activeFormatHeight,
            at: delegateMonotonicNanoseconds
        )
        switch observation {
        case .committed(let format):
            cancelPresentationDeadline()
            sourceWidth = format.dimensions.widthUnits
            sourceHeight = format.dimensions.heightUnits
            presentation = format
        case .candidate(let token, let deadlineNanoseconds, let sampleCount):
            if sampleCount >= 2 {
                schedulePresentationDeadline(
                    token: token,
                    deadlineNanoseconds: deadlineNanoseconds
                )
            } else {
                cancelPresentationDeadline()
            }
        case .anomalous, .unchanged:
            cancelPresentationDeadline()
        }
        let frameOrientation: LiveSamplePresentationOrientation =
            activeFormatWidth > activeFormatHeight ? .landscape : .portrait
        let shouldWithhold = liveResizeFrozenOrientation.map {
            $0 != frameOrientation
        } ?? false
        if liveResizeWithholding != shouldWithhold {
            liveResizeWithholding = shouldWithhold
            gateTransition = shouldWithhold
        }
        if shouldWithhold {
            liveResizeWithheldFrameCount &+= 1
            let acceptedBinding = binding
            lock.unlock()
            if let gateTransition { displayGateHandler?(gateTransition) }
            if let presentation { presentationHandler?(presentation) }
            return .withheld(acceptedBinding)
        }
        let enqueuedAt = enqueue(binding)
        let latency = enqueuedAt >= delegateMonotonicNanoseconds
            ? (enqueuedAt - delegateMonotonicNanoseconds) / 1_000
            : 0
        enqueuedFrameCount += 1
        enqueueMonotonicNanoseconds.append(enqueuedAt)
        latencyMicroseconds.append(latency)
        let acceptedBinding = binding
        lock.unlock()
        if let gateTransition { displayGateHandler?(gateTransition) }
        if let presentation { presentationHandler?(presentation) }
        return .enqueued(acceptedBinding)
    }

    func stop() {
        lock.lock()
        stopped = true
        liveResizeFrozenOrientation = nil
        liveResizeWithholding = false
        cancelPresentationDeadline()
        lock.unlock()
    }

    func snapshot() -> ProductionVideoSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ProductionVideoSnapshot(
            activeFormatHeight: sourceHeight,
            activeFormatWidth: sourceWidth,
            connectionEpochs: [binding.connectionEpoch],
            droppedFrameCount: droppedFrameCount,
            enqueuedFrameCount: enqueuedFrameCount,
            enqueueMonotonicNanoseconds: enqueueMonotonicNanoseconds,
            formatRevision: presentationTracker.current?.formatRevision ?? 0,
            latencyMicroseconds: latencyMicroseconds,
            receivedFrameCount: receivedFrameCount,
            sourceEpoch: binding.sourceEpoch,
            sourceEpochs: [binding.sourceEpoch]
        )
    }

    private func schedulePresentationDeadline(
        token: UUID,
        deadlineNanoseconds: UInt64
    ) {
        presentationDeadlineWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.commitPresentationCandidate(
                token: token,
                at: DispatchTime.now().uptimeNanoseconds
            )
        }
        presentationDeadlineWorkItem = item
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: DispatchTime(uptimeNanoseconds: deadlineNanoseconds),
            execute: item
        )
    }

    private func cancelPresentationDeadline() {
        presentationDeadlineWorkItem?.cancel()
        presentationDeadlineWorkItem = nil
    }

    private func commitPresentationCandidate(token: UUID, at nanoseconds: UInt64) {
        lock.lock()
        guard !stopped,
              let format = presentationTracker.commitCandidate(
                  token: token,
                  at: nanoseconds
              )
        else {
            lock.unlock()
            return
        }
        presentationDeadlineWorkItem = nil
        sourceWidth = format.dimensions.widthUnits
        sourceHeight = format.dimensions.heightUnits
        lock.unlock()
        presentationHandler?(format)
    }
}
