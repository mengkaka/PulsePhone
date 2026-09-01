import Darwin
import Dispatch
import Foundation
import PulsePhoneHostPaths
import ImageIO
import PulsePhoneElement
import PulsePhoneMedia
import PulsePhoneSharedDefinitions

enum ProductionElementSnapshotPipelineError: Error, Equatable, Sendable {
    case analysisTimedOut
    case busy
    case cancelled
    case invalidCapture
    case invalidRequest
    case stopping
}

enum ProductionElementSnapshotCancellationCause: Equatable, Sendable {
    case authorityChanged
    case deadlineExceeded
    case requestCancelled
    case runtimeStopping
}

enum ProductionElementPendingCancellationDisposition: String, Sendable {
    case alreadyTerminal
    case cancellationRequested
    case notFound
    case notOwned
}

struct ProductionElementPendingCancellationResult: Equatable, Sendable {
    let disposition: ProductionElementPendingCancellationDisposition
    let targetPhase: String?
}

final class ProductionElementSnapshotCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cause: ProductionElementSnapshotCancellationCause?
    private var handlers = [UUID: @Sendable () -> Void]()

    var isCancelled: Bool {
        lock.withLock { cause != nil }
    }

    var cancellationCause: ProductionElementSnapshotCancellationCause? {
        lock.withLock { cause }
    }

    func check() throws {
        if isCancelled { throw CancellationError() }
    }

    func register(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let invoke = lock.withLock {
            if cause != nil { return true }
            handlers[id] = handler
            return false
        }
        if invoke { handler() }
        return id
    }

    func unregister(_ id: UUID) {
        _ = lock.withLock { handlers.removeValue(forKey: id) }
    }

    func cancel(
        cause requestedCause: ProductionElementSnapshotCancellationCause = .requestCancelled
    ) {
        let pending: [@Sendable () -> Void] = lock.withLock {
            guard cause == nil else { return [] }
            cause = requestedCause
            let pending = Array(handlers.values)
            handlers.removeAll(keepingCapacity: false)
            return pending
        }
        pending.forEach { $0() }
    }
}

final class ProductionElementOwnerDisconnectMonitor: @unchecked Sendable {
    private let cancellation: ProductionElementSnapshotCancellation
    private let descriptor: Int32
    private let source: DispatchSourceRead

    init(
        descriptor: Int32,
        cancellation: ProductionElementSnapshotCancellation,
        queue: DispatchQueue = .global(qos: .utility)
    ) {
        self.cancellation = cancellation
        self.descriptor = descriptor
        self.source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.inspect() }
        source.activate()
    }

    deinit {
        source.cancel()
    }

    func stop() {
        source.cancel()
    }

    private func inspect() {
        var byte: UInt8 = 0
        let count = withUnsafeMutablePointer(to: &byte) {
            Darwin.recv(descriptor, $0, 1, MSG_PEEK | MSG_DONTWAIT)
        }
        if count == 0 {
            cancellation.cancel()
            source.cancel()
        } else if count > 0 {
            source.cancel()
        } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
            cancellation.cancel()
            source.cancel()
        }
    }
}

struct ProductionElementSnapshotCapture: Sendable {
    let bytes: [UInt8]
    let captureAttempts: [ElementSnapshotCaptureAttempt]?
    let geometry: DisplayGeometryDTO
    let provider: SnapshotCaptureProvider

    init(
        bytes: [UInt8],
        geometry: DisplayGeometryDTO,
        provider: SnapshotCaptureProvider,
        captureAttempts: [ElementSnapshotCaptureAttempt]? = nil
    ) {
        self.bytes = bytes
        self.captureAttempts = captureAttempts
        self.geometry = geometry
        self.provider = provider
    }
}

struct ProductionElementSnapshotPipelineOutput: Sendable {
    let annotation: ElementAnnotationRenderResult?
    let result: ElementSnapshotResult
}

struct ProductionElementDeviceCaptureKey: Equatable, Sendable {
    let geometry: DisplayGeometryDTO
    let providerPlanID: String
    let targetIdentity: String
}

final class ProductionElementDeviceCaptureCoordinator: @unchecked Sendable {
    typealias Capture = @Sendable (
        ProductionElementSnapshotCancellation
    ) throws -> ProductionElementSnapshotCapture

    private final class InFlightCapture: @unchecked Sendable {
        struct Waiter {
            let cancellation: ProductionElementSnapshotCancellation
            let deadlineNanoseconds: UInt64
        }

        let key: ProductionElementDeviceCaptureKey?
        let operation: Capture
        // Producer ownership keeps one canceled waiter from poisoning its peers.
        let producerCancellation = ProductionElementSnapshotCancellation()
        var captureStartedAtNanoseconds: UInt64?
        var result: Result<ProductionElementSnapshotCapture, Error>?
        var waiters = [UUID: Waiter]()

        init(key: ProductionElementDeviceCaptureKey?, operation: @escaping Capture) {
            self.key = key
            self.operation = operation
        }
    }

    private let captureQueue: DispatchQueue
    private let coalescingWindowNanoseconds: UInt64
    private let condition = NSCondition()
    private let deadlineQueue = DispatchQueue(
        label: "com.pulsephone.element.device-capture-deadlines",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private var inFlight: InFlightCapture?

    init(
        coalescingWindowNanoseconds: UInt64 = 1_000_000,
        captureQueue: DispatchQueue = DispatchQueue(
            label: "com.pulsephone.element.device-capture",
            qos: .userInitiated
        )
    ) {
        self.captureQueue = captureQueue
        self.coalescingWindowNanoseconds = coalescingWindowNanoseconds
    }

    func capture(
        key: ProductionElementDeviceCaptureKey?,
        queryStartedAtNanoseconds: UInt64,
        deadlineNanoseconds: UInt64,
        cancellation: ProductionElementSnapshotCancellation,
        operation: @escaping Capture
    ) throws -> ProductionElementSnapshotCapture {
        let registration = cancellation.register { [weak self] in
            self?.wakeWaiters()
        }
        defer { cancellation.unregister(registration) }

        let waiterID = UUID()
        let waiter = InFlightCapture.Waiter(
            cancellation: cancellation,
            deadlineNanoseconds: deadlineNanoseconds
        )
        var joinedCapture: InFlightCapture?
        while joinedCapture == nil {
            try checkWaitBoundary(
                deadlineNanoseconds: deadlineNanoseconds,
                cancellation: cancellation
            )
            condition.lock()
            if let current = inFlight {
                let compatibleFreshness = current.captureStartedAtNanoseconds
                    .map { queryStartedAtNanoseconds <= $0 } ?? true
                let compatible = key != nil
                    && current.key == key
                    && compatibleFreshness
                if compatible {
                    current.waiters[waiterID] = waiter
                    joinedCapture = current
                    condition.unlock()
                    continue
                }
                waitLocked(until: deadlineNanoseconds)
                condition.unlock()
                continue
            }

            let current = InFlightCapture(key: key, operation: operation)
            current.waiters[waiterID] = waiter
            inFlight = current
            joinedCapture = current
            scheduleCapture(
                current,
                requestDeadlineNanoseconds: deadlineNanoseconds
            )
            condition.unlock()
        }
        guard let current = joinedCapture else {
            throw ProductionElementSnapshotPipelineError.invalidRequest
        }
        return try awaitResult(
            current,
            waiterID: waiterID,
            deadlineNanoseconds: deadlineNanoseconds,
            cancellation: cancellation
        )
    }

    private func scheduleCapture(
        _ current: InFlightCapture,
        requestDeadlineNanoseconds: UInt64
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        let windowEnd = now.addingReportingOverflow(coalescingWindowNanoseconds)
        let admissionDeadline = windowEnd.overflow
            ? requestDeadlineNanoseconds
            : min(requestDeadlineNanoseconds, windowEnd.partialValue)
        captureQueue.asyncAfter(
            deadline: DispatchTime(uptimeNanoseconds: admissionDeadline)
        ) { [weak self] in
            self?.performCapture(current)
        }
    }

    private func performCapture(_ current: InFlightCapture) {
        condition.lock()
        guard inFlight === current, current.result == nil else {
            condition.unlock()
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let hasEligibleWaiter = current.waiters.values.contains {
            !$0.cancellation.isCancelled && now < $0.deadlineNanoseconds
        }
        guard hasEligibleWaiter else {
            current.result = .failure(
                ProductionElementSnapshotPipelineError.cancelled
            )
            inFlight = nil
            condition.broadcast()
            condition.unlock()
            return
        }
        current.captureStartedAtNanoseconds =
            DispatchTime.now().uptimeNanoseconds
        condition.unlock()

        let result = Result {
            try current.operation(current.producerCancellation)
        }
        condition.lock()
        current.result = result
        if inFlight === current { inFlight = nil }
        condition.broadcast()
        condition.unlock()
    }

    private func awaitResult(
        _ current: InFlightCapture,
        waiterID: UUID,
        deadlineNanoseconds: UInt64,
        cancellation: ProductionElementSnapshotCancellation
    ) throws -> ProductionElementSnapshotCapture {
        condition.lock()
        while current.result == nil,
              !cancellation.isCancelled,
              DispatchTime.now().uptimeNanoseconds < deadlineNanoseconds
        {
            waitLocked(until: deadlineNanoseconds)
        }
        let result = current.result
        let boundaryError: ProductionElementSnapshotPipelineError?
        if cancellation.isCancelled {
            boundaryError = cancellation.cancellationCause == .deadlineExceeded
                ? .analysisTimedOut : .cancelled
        } else if DispatchTime.now().uptimeNanoseconds >= deadlineNanoseconds {
            boundaryError = .analysisTimedOut
        } else {
            boundaryError = nil
        }
        precondition(current.waiters.removeValue(forKey: waiterID) != nil)
        let shouldCancelProducer = current.waiters.isEmpty
            && current.result == nil
        let shouldJoinProducer = shouldCancelProducer
            && current.captureStartedAtNanoseconds != nil
        if shouldCancelProducer && !shouldJoinProducer {
            current.result = .failure(
                ProductionElementSnapshotPipelineError.cancelled
            )
            if inFlight === current { inFlight = nil }
            condition.broadcast()
        }
        condition.unlock()
        if shouldCancelProducer {
            current.producerCancellation.cancel()
        }
        if shouldJoinProducer {
            condition.lock()
            while current.result == nil { condition.wait() }
            condition.unlock()
        }
        if let boundaryError { throw boundaryError }
        guard let result else {
            throw ProductionElementSnapshotPipelineError.analysisTimedOut
        }
        return try result.get()
    }

    private func checkWaitBoundary(
        deadlineNanoseconds: UInt64,
        cancellation: ProductionElementSnapshotCancellation
    ) throws {
        if cancellation.isCancelled {
            throw cancellation.cancellationCause == .deadlineExceeded
                ? ProductionElementSnapshotPipelineError.analysisTimedOut
                : ProductionElementSnapshotPipelineError.cancelled
        }
        if DispatchTime.now().uptimeNanoseconds >= deadlineNanoseconds {
            throw ProductionElementSnapshotPipelineError.analysisTimedOut
        }
    }

    private func waitLocked(until deadlineNanoseconds: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadlineNanoseconds else { return }
        let wakeup = DispatchWorkItem { [weak self] in
            self?.wakeWaiters()
        }
        deadlineQueue.asyncAfter(
            deadline: DispatchTime(uptimeNanoseconds: deadlineNanoseconds),
            execute: wakeup
        )
        condition.wait()
        wakeup.cancel()
    }

    private func wakeWaiters() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }
}

final class ProductionElementSnapshotPipeline: @unchecked Sendable {
    typealias Capture = ProductionElementDeviceCaptureCoordinator.Capture
    typealias RenderAnnotation = @Sendable (
        SnapshotFrame,
        ElementSnapshotResult
    ) async throws -> ElementAnnotationRenderResult

    static let jsonOuterSafetyDeadlineSeconds: Double = 27
    static let annotationOuterSafetyDeadlineSeconds: Double = 32

    private enum ActivePhase: String {
        case analysis
        case annotation
        case capture
        case preparing
    }

    private struct Generation {
        let captureGeneration: UInt64
        let frameSequence: UInt64
        let queryStartedAtNanoseconds: UInt64
    }

    private final class BlockingResultBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<Value, Error>?

        func store(_ value: Result<Value, Error>) {
            lock.withLock { self.value = value }
        }

        func load() -> Result<Value, Error>? {
            lock.withLock { value }
        }
    }

    private struct TerminalRequest {
        let completedAtNanoseconds: UInt64
        let ownerClientInstanceID: CanonicalUUID?
        let requestID: CanonicalUUID
    }

    private final class ActiveRequest: @unchecked Sendable {
        let cancellation: ProductionElementSnapshotCancellation
        let ownerClientInstanceID: CanonicalUUID?
        var attemptCancellation: ProductionElementSnapshotCancellation?
        var phase: ActivePhase = .preparing
        var taskCancellation: (@Sendable () -> Void)?

        init(
            cancellation: ProductionElementSnapshotCancellation,
            ownerClientInstanceID: CanonicalUUID?
        ) {
            self.cancellation = cancellation
            self.ownerClientInstanceID = ownerClientInstanceID
        }
    }

    private let analyzer: ElementAnalyzerCoordinator
    private let appleAnalyzer: AppleRegionAnalyzer?
    private let omniManager: OmniParserClientGenerationManager?
    private let visionAnalyzer: VisionTextAnalyzer?
    private let canonicalUDID: CanonicalUDID
    private let captureCoordinator: ProductionElementDeviceCaptureCoordinator
    private let corrector: ElementLocalGeometryCorrector
    private let fusion: ElementFusionEngine
    private let renderAnnotation: RenderAnnotation
    private let condition = NSCondition()
    private let resultBuilder: ElementSnapshotResultBuilder
    private var activeRequests = [CanonicalUUID: ActiveRequest]()
    private var lastCaptureGeneration: UInt64 = 0
    private var lastFrameSequence: UInt64 = 0
    private var recentTerminalRequests = [TerminalRequest]()
    private var stopping = false

    private static let maximumTerminalRequests = 64
    private static let terminalRequestLifetimeNanoseconds: UInt64 =
        300_000_000_000

    init(
        canonicalUDID: CanonicalUDID,
        analyzer: ElementAnalyzerCoordinator,
        appleAnalyzer: AppleRegionAnalyzer? = nil,
        omniManager: OmniParserClientGenerationManager? = nil,
        visionAnalyzer: VisionTextAnalyzer? = nil,
        fusion: ElementFusionEngine = ElementFusionEngine(),
        corrector: ElementLocalGeometryCorrector = ElementLocalGeometryCorrector(),
        resultBuilder: ElementSnapshotResultBuilder = ElementSnapshotResultBuilder(),
        annotationRenderer: ElementAnnotationRenderer = ElementAnnotationRenderer(),
        captureCoordinator: ProductionElementDeviceCaptureCoordinator =
            ProductionElementDeviceCaptureCoordinator(),
        renderAnnotation: RenderAnnotation? = nil
    ) {
        self.analyzer = analyzer
        self.appleAnalyzer = appleAnalyzer
        self.omniManager = omniManager
        self.visionAnalyzer = visionAnalyzer
        self.canonicalUDID = canonicalUDID
        self.captureCoordinator = captureCoordinator
        self.corrector = corrector
        self.fusion = fusion
        self.renderAnnotation = renderAnnotation ?? { frame, result in
            try await annotationRenderer.render(frame: frame, result: result)
        }
        self.resultBuilder = resultBuilder
    }

    static func production(
        canonicalUDID: CanonicalUDID,
        executablePath: String
    ) -> ProductionElementSnapshotPipeline {
        let omniStartup = omniParserStartup()
        let omni = omniStartup.manager
        let vision = VisionTextAnalyzer()
        let apple = AppleRegionAnalyzer(
            transportFactory: {
                AppleRegionSubprocessTransport(executablePath: executablePath)
            }
        )
        let operations = ElementAnalyzerOperations(
            omniparser: { frame in
                guard let omni else {
                    return ElementAnalyzerResult(
                        source: .omniparser,
                        status: .unavailable,
                        profileID: ElementAnalyzerProfiles.omniparser.profileID,
                        backend: omniStartup.unavailableBackend
                    )
                }
                return await omni.analyze(frame)
            },
            vision: { frame in await vision.analyze(frame) },
            appleRegion: { frame in await apple.analyze(frame) },
            prepareVision: {
                guard await vision.prewarm() else {
                    return ElementAnalyzerResult(
                        source: .vision,
                        status: .unavailable,
                        profileID: ElementAnalyzerProfiles.visionProfileID,
                        elapsedMilliseconds: 0,
                        queueWaitMilliseconds: 0,
                        backend: "Vision.framework",
                        version: VisionTextRecognitionPolicy.production.version
                    )
                }
                return nil
            },
            prepareAppleRegion: {
                guard await apple.prewarm() else {
                    return ElementAnalyzerResult(
                        source: .appleRegion,
                        status: .unavailable,
                        profileID: ElementAnalyzerProfiles.appleRegion.profileID,
                        elapsedMilliseconds: 0,
                        queueWaitMilliseconds: 0,
                        backend: AppleRegionWorkerMessage.expectedBackend,
                        version: AppleRegionWorkerMessage.expectedVersion
                    )
                }
                return nil
            }
        )
        return ProductionElementSnapshotPipeline(
            canonicalUDID: canonicalUDID,
            analyzer: ElementAnalyzerCoordinator(operations: operations),
            appleAnalyzer: apple,
            omniManager: omni,
            visionAnalyzer: vision
        )
    }

    private static func omniParserStartup() -> (
        manager: OmniParserClientGenerationManager?,
        unavailableBackend: String
    ) {
        do {
            let environment = ProcessInfo.processInfo.environment
            if environment[OmniParserEndpointConfiguration.environmentKey] != nil {
                let configuration = try OmniParserEndpointConfiguration.resolve(
                    environment: environment,
                    managedEndpoint: nil
                )
                guard let configuration else {
                    return (nil, "configurationUnset")
                }
                return (
                    OmniParserClientGenerationManager(configuration: configuration),
                    "notApplicable"
                )
            }
            let snapshot = try PulsePhoneConfigurationStore.bundled().load()
            let configuration = try OmniParserEndpointConfiguration.resolve(
                environment: environment,
                managedEndpoint: PulsePhoneConfigurationRegistry.omniParserEndpoint(
                    in: snapshot
                )
            )
            guard let configuration else {
                return (nil, "configurationUnset")
            }
            return (
                OmniParserClientGenerationManager(configuration: configuration),
                "notApplicable"
            )
        } catch is PulsePhoneConfigurationStoreError {
            return (nil, "configurationUnreadable")
        } catch {
            return (nil, "configurationInvalid")
        }
    }

    func run(
        requestID: CanonicalUUID,
        cancellation: ProductionElementSnapshotCancellation,
        ownerClientInstanceID: CanonicalUUID? = nil,
        includeAnnotation: Bool,
        artifactID: CanonicalUUID?,
        captureKey: ProductionElementDeviceCaptureKey? = nil,
        capture: @escaping Capture
    ) throws -> ProductionElementSnapshotPipelineOutput {
        let deadline = try Self.deadlineNanoseconds(
            timeoutSeconds: includeAnnotation
                ? Self.annotationOuterSafetyDeadlineSeconds
                : Self.jsonOuterSafetyDeadlineSeconds
        )
        return try withRequest(
            requestID: requestID,
            cancellation: cancellation,
            ownerClientInstanceID: ownerClientInstanceID,
            deadlineNanoseconds: deadline
        ) {
            try self.runAttempt(
                requestID: requestID,
                cancellation: cancellation,
                includeAnnotation: includeAnnotation,
                artifactID: artifactID,
                deadlineNanoseconds: deadline,
                captureKey: captureKey,
                capture: capture
            )
        }
    }

    func withRequest<Value>(
        requestID: CanonicalUUID,
        cancellation: ProductionElementSnapshotCancellation,
        ownerClientInstanceID: CanonicalUUID?,
        deadlineNanoseconds: UInt64,
        operation: () throws -> Value
    ) throws -> Value {
        try beginRequest(
            requestID: requestID,
            cancellation: cancellation,
            ownerClientInstanceID: ownerClientInstanceID
        )
        let deadlineTimer = DispatchSource.makeTimerSource(
            queue: .global(qos: .utility)
        )
        deadlineTimer.schedule(deadline: DispatchTime(uptimeNanoseconds: deadlineNanoseconds))
        deadlineTimer.setEventHandler { [weak cancellation] in
            cancellation?.cancel(cause: .deadlineExceeded)
        }
        deadlineTimer.activate()
        defer {
            deadlineTimer.cancel()
            endRequest(requestID: requestID)
        }
        do {
            try cancellation.check()
        } catch {
            throw ProductionElementSnapshotPipelineError.cancelled
        }
        return try operation()
    }

    func runAttempt(
        requestID: CanonicalUUID,
        cancellation: ProductionElementSnapshotCancellation,
        includeAnnotation: Bool,
        artifactID: CanonicalUUID?,
        deadlineNanoseconds: UInt64,
        analyzerSelection: ElementAnalyzerSelection = .all,
        captureKey: ProductionElementDeviceCaptureKey? = nil,
        capture: @escaping Capture
    ) throws -> ProductionElementSnapshotPipelineOutput {
        guard includeAnnotation == (artifactID != nil) else {
            throw ProductionElementSnapshotPipelineError.invalidRequest
        }
        let (generation, requestCancellation) = try beginAttempt(
            requestID: requestID,
            cancellation: cancellation
        )
        let requestRegistration = requestCancellation.register {
            cancellation.cancel(
                cause: requestCancellation.cancellationCause ?? .requestCancelled
            )
        }
        defer {
            requestCancellation.unregister(requestRegistration)
            endAttempt(requestID: requestID)
        }
        guard !cancellation.isCancelled else {
            throw ProductionElementSnapshotPipelineError.cancelled
        }

        let captureStartedAt = ContinuousClock.now
        let captured: ProductionElementSnapshotCapture
        do {
            captured = try captureCoordinator.capture(
                key: captureKey,
                queryStartedAtNanoseconds: generation.queryStartedAtNanoseconds,
                deadlineNanoseconds: deadlineNanoseconds,
                cancellation: cancellation,
                operation: capture
            )
        } catch is CancellationError {
            throw ProductionElementSnapshotPipelineError.cancelled
        }
        guard !cancellation.isCancelled else {
            throw ProductionElementSnapshotPipelineError.cancelled
        }
        let captureMilliseconds = Self.elapsedMilliseconds(since: captureStartedAt)
        let capturedAt = DispatchTime.now().uptimeNanoseconds
        guard captured.geometry.connectionEpoch > 0,
              !captured.bytes.isEmpty,
              UInt64(captured.bytes.count) <= 64 * 1_024 * 1_024,
              captured.bytes.starts(with: [
                  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
              ])
        else {
            throw ProductionElementSnapshotPipelineError.invalidCapture
        }
        let sourceDecodeStartedAt = ContinuousClock.now
        let sourceData = Data(captured.bytes)
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let imageSource = CGImageSourceCreateWithData(
            sourceData as CFData,
            nil
        ),
              let image = CGImageSourceCreateImageAtIndex(
                  imageSource,
                  0,
                  sourceOptions as CFDictionary
              )
        else {
            throw ProductionElementSnapshotPipelineError.invalidCapture
        }
        let sourceDecodeMicroseconds = Self.elapsedMicroseconds(
            since: sourceDecodeStartedAt
        )
        let sourceImage = try SnapshotSourceImageLease(cgImage: image)
        guard sourceImage.dimensions.width
                <= ElementSnapshotResultBuilder.maximumImageDimension,
              sourceImage.dimensions.height
                <= ElementSnapshotResultBuilder.maximumImageDimension
        else {
            throw ProductionElementSnapshotPipelineError.invalidCapture
        }
        let fence = try SnapshotFreshnessFence(
            queryStartedAtNanoseconds: generation.queryStartedAtNanoseconds,
            baselineFrameSequence: generation.frameSequence - 1,
            maximumFrameAgeNanoseconds: 60_000_000_000,
            validatedAtNanoseconds: capturedAt
        )
        let metadata = try SnapshotFrameMetadata(
            canonicalUDID: canonicalUDID,
            connectionEpoch: captured.geometry.connectionEpoch,
            sourceEpoch: nil,
            sourceID: nil,
            geometry: captured.geometry,
            captureGeneration: generation.captureGeneration,
            frameSequence: generation.frameSequence,
            capturedAtNanoseconds: capturedAt,
            freshnessFence: fence,
            pixelDimensions: sourceImage.dimensions,
            provider: captured.provider,
            settleReason: .queryFenceSatisfied
        )
        let frame = try SnapshotFrame(
            authority: SnapshotFrameAuthority(
                canonicalUDID: canonicalUDID,
                geometry: captured.geometry,
                sourceEpoch: nil,
                sourceID: nil,
                captureGeneration: generation.captureGeneration
            ),
            metadata: metadata,
            sourceImage: sourceImage
        )
        let captureSHA256 = StableBytes.sha256Hex(captured.bytes)
        let artifactID = artifactID
        setActivePhase(.analysis, requestID: requestID)
        return try blockingAwait(
            requestID: requestID,
            timeoutSeconds: try Self.remainingSeconds(
                until: deadlineNanoseconds
            ),
            cancellation: cancellation
        ) {
            try Task.checkCancellation()
            let batch = try await self.analyzer.analyze(
                frame,
                selection: analyzerSelection
            )
            try Task.checkCancellation()
            let fusionStartedAt = ContinuousClock.now
            let fused = try self.fusion.fuse(
                batch,
                dimensions: frame.metadata.pixelDimensions
            )
            let fusionMilliseconds = Self.elapsedMilliseconds(since: fusionStartedAt)
            let corrected = await self.corrector.correct(
                frame: frame,
                candidates: fused
            )
            try Task.checkCancellation()
            var result = try self.resultBuilder.build(
                frame: frame,
                analyzerBatch: batch,
                localGeometry: corrected,
                captureSHA256: captureSHA256,
                timings: ElementSnapshotPipelineTimings(
                    captureMilliseconds: captureMilliseconds,
                    fusionMilliseconds: fusionMilliseconds,
                    sourceDecodeMicroseconds: sourceDecodeMicroseconds
                ),
                captureAttempts: captured.captureAttempts
            )
            guard includeAnnotation, let artifactID else {
                return ProductionElementSnapshotPipelineOutput(
                    annotation: nil,
                    result: result
                )
            }
            try Task.checkCancellation()
            self.setActivePhase(.annotation, requestID: requestID)
            let annotation = try await self.renderAnnotation(frame, result)
            try Task.checkCancellation()
            result = try self.resultBuilder.attachingAnnotation(
                ElementSnapshotAnnotationMetadata(
                    artifactID: artifactID,
                    byteLength: UInt64(annotation.bytes.count),
                    captureSHA256: annotation.captureSHA256,
                    sha256: annotation.sha256,
                    snapshotGeneration: annotation.snapshotGeneration
                ),
                elapsedMilliseconds: annotation.elapsedMilliseconds,
                to: result
            )
            return ProductionElementSnapshotPipelineOutput(
                annotation: annotation,
                result: result
            )
        }
    }

    func cancelOwnedPendingWork(
        targetRequestID: CanonicalUUID,
        ownerClientInstanceID: CanonicalUUID
    ) -> ProductionElementPendingCancellationResult {
        condition.lock()
        defer { condition.unlock() }
        pruneTerminalRequests(now: DispatchTime.now().uptimeNanoseconds)
        if let active = activeRequests[targetRequestID] {
            guard active.ownerClientInstanceID == ownerClientInstanceID else {
                return ProductionElementPendingCancellationResult(
                    disposition: .notOwned,
                    targetPhase: active.phase.rawValue
                )
            }
            active.cancellation.cancel()
            return ProductionElementPendingCancellationResult(
                disposition: .cancellationRequested,
                targetPhase: active.phase.rawValue
            )
        }
        if let terminal = recentTerminalRequests.last(where: {
            $0.requestID == targetRequestID
        }) {
            return ProductionElementPendingCancellationResult(
                disposition: terminal.ownerClientInstanceID == ownerClientInstanceID
                    ? .alreadyTerminal : .notOwned,
                targetPhase: "terminal"
            )
        }
        return ProductionElementPendingCancellationResult(
            disposition: .notFound,
            targetPhase: nil
        )
    }

    func shutdown() {
        condition.lock()
        stopping = true
        let requests = activeRequests.values.map {
            (
                cancellation: $0.cancellation,
                attemptCancellation: $0.attemptCancellation,
                taskCancellation: $0.taskCancellation
            )
        }
        condition.unlock()
        requests.forEach {
            $0.cancellation.cancel(cause: .runtimeStopping)
            $0.attemptCancellation?.cancel(cause: .runtimeStopping)
            $0.taskCancellation?()
        }
        condition.lock()
        while !activeRequests.isEmpty {
            condition.wait()
        }
        condition.unlock()
        guard appleAnalyzer != nil || omniManager != nil
                || visionAnalyzer != nil
        else { return }
        _ = try? blockingAwait(
            timeoutSeconds: 3,
            cancellation: ProductionElementSnapshotCancellation(),
            cancelWhenStopping: false
        ) {
            if let omniManager = self.omniManager {
                await omniManager.shutdown()
            }
            if let appleAnalyzer = self.appleAnalyzer {
                await appleAnalyzer.shutdown()
            }
            if let visionAnalyzer = self.visionAnalyzer {
                await visionAnalyzer.shutdown()
            }
            return true
        }
    }

    private func beginRequest(
        requestID: CanonicalUUID,
        cancellation: ProductionElementSnapshotCancellation,
        ownerClientInstanceID: CanonicalUUID?
    ) throws {
        condition.lock()
        defer { condition.unlock() }
        guard !stopping else {
            throw ProductionElementSnapshotPipelineError.stopping
        }
        guard !cancellation.isCancelled else {
            throw ProductionElementSnapshotPipelineError.cancelled
        }
        guard activeRequests[requestID] == nil else {
            throw ProductionElementSnapshotPipelineError.invalidRequest
        }
        activeRequests[requestID] = ActiveRequest(
            cancellation: cancellation,
            ownerClientInstanceID: ownerClientInstanceID
        )
    }

    private func beginAttempt(
        requestID: CanonicalUUID,
        cancellation: ProductionElementSnapshotCancellation
    ) throws -> (Generation, ProductionElementSnapshotCancellation) {
        condition.lock()
        defer { condition.unlock() }
        guard !stopping else {
            throw ProductionElementSnapshotPipelineError.stopping
        }
        guard let active = activeRequests[requestID],
              !active.cancellation.isCancelled,
              !cancellation.isCancelled
        else {
            throw ProductionElementSnapshotPipelineError.cancelled
        }
        guard active.attemptCancellation == nil else {
            throw ProductionElementSnapshotPipelineError.busy
        }
        guard lastCaptureGeneration < UInt64.max,
              lastFrameSequence < UInt64.max
        else {
            throw ProductionElementSnapshotPipelineError.invalidRequest
        }
        active.attemptCancellation = cancellation
        active.phase = .capture
        lastCaptureGeneration += 1
        lastFrameSequence += 1
        return (
            Generation(
                captureGeneration: lastCaptureGeneration,
                frameSequence: lastFrameSequence,
                queryStartedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
            ),
            active.cancellation
        )
    }

    private func endAttempt(requestID: CanonicalUUID) {
        condition.lock()
        if let active = activeRequests[requestID] {
            active.attemptCancellation = nil
            active.taskCancellation = nil
            active.phase = .preparing
        }
        condition.unlock()
    }

    private func endRequest(requestID: CanonicalUUID) {
        condition.lock()
        if let active = activeRequests.removeValue(forKey: requestID) {
            let now = DispatchTime.now().uptimeNanoseconds
            pruneTerminalRequests(now: now)
            recentTerminalRequests.append(TerminalRequest(
                completedAtNanoseconds: now,
                ownerClientInstanceID: active.ownerClientInstanceID,
                requestID: requestID
            ))
            if recentTerminalRequests.count > Self.maximumTerminalRequests {
                recentTerminalRequests.removeFirst(
                    recentTerminalRequests.count - Self.maximumTerminalRequests
                )
            }
        }
        condition.broadcast()
        condition.unlock()
    }

    private func setActivePhase(
        _ phase: ActivePhase,
        requestID: CanonicalUUID
    ) {
        condition.lock()
        activeRequests[requestID]?.phase = phase
        condition.unlock()
    }

    private func pruneTerminalRequests(now: UInt64) {
        recentTerminalRequests.removeAll { request in
            guard now >= request.completedAtNanoseconds else { return true }
            return now - request.completedAtNanoseconds
                >= Self.terminalRequestLifetimeNanoseconds
        }
    }

    private func blockingAwait<Value: Sendable>(
        requestID: CanonicalUUID? = nil,
        timeoutSeconds: Double,
        cancellation: ProductionElementSnapshotCancellation,
        cancelWhenStopping: Bool = true,
        operation: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        let box = BlockingResultBox<Value>()
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task.detached {
            do {
                box.store(.success(try await operation()))
            } catch {
                box.store(.failure(error))
            }
            semaphore.signal()
        }
        let cancelTask: @Sendable () -> Void = { task.cancel() }
        condition.lock()
        if let requestID {
            activeRequests[requestID]?.taskCancellation = cancelTask
        }
        let cancelForStop = cancelWhenStopping && stopping
        condition.unlock()
        let registration = cancellation.register(cancelTask)
        defer { cancellation.unregister(registration) }
        if cancelForStop { task.cancel() }
        guard semaphore.wait(timeout: .now() + timeoutSeconds) == .success else {
            task.cancel()
            semaphore.wait()
            throw ProductionElementSnapshotPipelineError.analysisTimedOut
        }
        guard let result = box.load() else {
            throw ProductionElementSnapshotPipelineError.analysisTimedOut
        }
        do {
            return try result.get()
        } catch is CancellationError {
            throw ProductionElementSnapshotPipelineError.cancelled
        }
    }

    private static func elapsedMilliseconds(
        since started: ContinuousClock.Instant
    ) -> UInt64 {
        let components = started.duration(to: .now).components
        let seconds = max(0, components.seconds)
        let milliseconds = max(0, components.attoseconds)
            / 1_000_000_000_000_000
        let base = UInt64(seconds).multipliedReportingOverflow(by: 1_000)
        guard !base.overflow else { return UInt64.max }
        let total = base.partialValue.addingReportingOverflow(
            UInt64(milliseconds)
        )
        return total.overflow ? UInt64.max : total.partialValue
    }

    private static func elapsedMicroseconds(
        since started: ContinuousClock.Instant
    ) -> UInt64 {
        let components = started.duration(to: .now).components
        let seconds = max(0, components.seconds)
        let microseconds = max(0, components.attoseconds)
            / 1_000_000_000_000
        let base = UInt64(seconds).multipliedReportingOverflow(by: 1_000_000)
        guard !base.overflow else { return UInt64.max }
        let total = base.partialValue.addingReportingOverflow(
            UInt64(microseconds)
        )
        return total.overflow ? UInt64.max : total.partialValue
    }

    private static func deadlineNanoseconds(
        timeoutSeconds: Double
    ) throws -> UInt64 {
        guard timeoutSeconds > 0 else {
            throw ProductionElementSnapshotPipelineError.analysisTimedOut
        }
        let duration = UInt64(timeoutSeconds * 1_000_000_000)
        let deadline = DispatchTime.now().uptimeNanoseconds
            .addingReportingOverflow(duration)
        guard !deadline.overflow else {
            throw ProductionElementSnapshotPipelineError.invalidRequest
        }
        return deadline.partialValue
    }

    private static func remainingSeconds(until deadlineNanoseconds: UInt64) throws
        -> Double
    {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadlineNanoseconds else {
            throw ProductionElementSnapshotPipelineError.analysisTimedOut
        }
        return Double(deadlineNanoseconds - now) / 1_000_000_000
    }
}
