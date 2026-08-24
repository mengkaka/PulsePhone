import Foundation
import PulsePhoneMedia

public protocol AppleRegionWorkerTransport: Sendable {
    func start() async throws -> AppleRegionWorkerMessage
    func detect(_ request: AppleRegionWorkerMessage) async throws -> AppleRegionWorkerMessage
    func shutdown() async
}

public struct AppleRegionCircuitPolicy: Equatable, Sendable {
    public let failureThreshold: UInt64
    public let openDuration: Duration

    public init(
        failureThreshold: UInt64 = 3,
        openDuration: Duration = .seconds(30)
    ) {
        precondition(failureThreshold > 0)
        precondition(openDuration > .zero)
        self.failureThreshold = failureThreshold
        self.openDuration = openDuration
    }
}

public actor AppleRegionAnalyzer {
    public struct Snapshot: Equatable, Sendable {
        public let circuitOpen: Bool
        public let consecutiveFailures: UInt64
        public let initializationAttemptCount: UInt64
        public let initializationCount: UInt64
        public let initializationFailureCount: UInt64
        public let queryCount: UInt64
        public let restartCount: UInt64
        public let stopped: Bool
    }

    public typealias TransportFactory = @Sendable () async throws ->
        any AppleRegionWorkerTransport

    private struct ReadyWorker: Sendable {
        let hello: AppleRegionWorkerMessage
        let transport: any AppleRegionWorkerTransport
    }

    private struct Initialization {
        let id: UUID
        let task: Task<ReadyWorker, Error>
        var waiters: [UUID: CheckedContinuation<ReadyWorker, Error>]
    }

    private enum InitializationCompletion: Sendable {
        case cancelled
        case failed(AppleRegionWorkerError)
        case succeeded(ReadyWorker)
    }

    private enum InitializationWaitError: Error, Sendable {
        case failed(AppleRegionWorkerError)
    }

    private let circuitPolicy: AppleRegionCircuitPolicy
    private let clock = ContinuousClock()
    private let factory: TransportFactory
    private let renderer: ElementImageRenderer
    private var circuitOpenedAt: ContinuousClock.Instant?
    private var consecutiveFailures: UInt64 = 0
    private var initialization: Initialization?
    private var initializationAttemptCount: UInt64 = 0
    private var initializationCount: UInt64 = 0
    private var initializationFailureCount: UInt64 = 0
    private var queryCount: UInt64 = 0
    private var requestID: UInt64 = 0
    private let requestGate = ElementAnalyzerRequestGate()
    private var restartCount: UInt64 = 0
    private var stopped = false
    private var worker: ReadyWorker?

    public init(
        circuitPolicy: AppleRegionCircuitPolicy = .init(),
        renderer: ElementImageRenderer = ElementImageRenderer(),
        transportFactory: @escaping TransportFactory
    ) {
        self.circuitPolicy = circuitPolicy
        self.factory = transportFactory
        self.renderer = renderer
    }

    deinit {
        initialization?.task.cancel()
        if let transport = worker?.transport {
            Task { await transport.shutdown() }
        }
    }

    @discardableResult
    public func prewarm() async -> Bool {
        guard !stopped, !isCircuitOpen else { return false }
        do {
            let ready = try await readyWorker()
            return ready.hello.outcome == .succeeded
        } catch {
            return false
        }
    }

    public func analyze(_ frame: SnapshotFrame) async -> ElementAnalyzerResult {
        queryCount = Self.increment(queryCount)
        let started = clock.now
        var detectionStarted = false
        var inputDimensions: SnapshotImageDimensions?
        var inputEncodeMicroseconds: UInt64?
        var permitAcquired = false
        var queueWaitMilliseconds: UInt64 = 0
        var resizeAndColorSpaceMicroseconds: UInt64?
        var responseDecodeMicroseconds: UInt64?
        var transportOverheadMicroseconds: UInt64?
        var transportRoundTripMicroseconds: UInt64?
        func stageTimings() -> ElementAnalyzerStageTimings {
            ElementAnalyzerStageTimings(
                resizeAndColorSpaceMicroseconds: resizeAndColorSpaceMicroseconds,
                inputEncodeMicroseconds: inputEncodeMicroseconds,
                transportRoundTripMicroseconds: transportRoundTripMicroseconds,
                transportOverheadMicroseconds: transportOverheadMicroseconds,
                responseDecodeMicroseconds: responseDecodeMicroseconds
            )
        }
        guard !stopped else {
            return failure(status: .unavailable, started: started)
        }
        guard !isCircuitOpen else {
            return failure(status: .circuitOpen, started: started)
        }
        do {
            let image = try await frame.derivedImage(
                for: ElementAnalyzerProfiles.appleRegion,
                materialize: renderer.pngMaterializer()
            )
            inputDimensions = image.geometry.inputDimensions
            inputEncodeMicroseconds = image.payload.timings.inputEncodeMicroseconds
            resizeAndColorSpaceMicroseconds =
                image.payload.timings.resizeAndColorSpaceMicroseconds
            guard !stopped else {
                return failure(
                    status: .unavailable,
                    started: started,
                    inputDimensions: inputDimensions,
                    stageTimings: stageTimings()
                )
            }
            guard !isCircuitOpen else {
                return failure(
                    status: .circuitOpen,
                    started: started,
                    inputDimensions: inputDimensions,
                    stageTimings: stageTimings()
                )
            }
            let queueStarted = clock.now
            try await requestGate.acquire()
            permitAcquired = true
            queueWaitMilliseconds = ElementAnalyzerTiming.elapsedMilliseconds(
                since: queueStarted
            )
            let ready = try await readyWorker()
            guard ready.hello.outcome == .succeeded else {
                await requestGate.release()
                permitAcquired = false
                return failure(
                    status: .unavailable,
                    started: started,
                    inputDimensions: inputDimensions,
                    queueWaitMilliseconds: queueWaitMilliseconds,
                    stageTimings: stageTimings()
                )
            }
            requestID = requestID == UInt64.max ? 1 : requestID + 1
            let activeRequestID = requestID
            detectionStarted = true
            let transportStarted = clock.now
            let response: AppleRegionWorkerMessage
            do {
                response = try await ready.transport.detect(.detect(
                    requestID: activeRequestID,
                    inputWidth: image.geometry.inputDimensions.width,
                    inputHeight: image.geometry.inputDimensions.height,
                    imageData: Data(image.payload.bytes)
                ))
            } catch {
                transportRoundTripMicroseconds =
                    ElementAnalyzerTiming.elapsedMicroseconds(since: transportStarted)
                throw error
            }
            transportRoundTripMicroseconds = ElementAnalyzerTiming.elapsedMicroseconds(
                since: transportStarted
            )
            if let workerElapsedMilliseconds = response.elapsedMilliseconds {
                transportOverheadMicroseconds =
                    ElementAnalyzerTiming.transportOverheadMicroseconds(
                        roundTripMicroseconds: transportRoundTripMicroseconds!,
                        remoteElapsedMilliseconds: workerElapsedMilliseconds
                    )
            }
            guard response.type == .result,
                  response.requestID == activeRequestID,
                  response.outcome == .succeeded,
                  let inferenceMilliseconds = response.elapsedMilliseconds,
                  let regions = response.regions
            else {
                throw AppleRegionWorkerError.invalidResponse
            }
            let inputWidth = Double(image.geometry.inputDimensions.width)
            let inputHeight = Double(image.geometry.inputDimensions.height)
            let responseDecodeStarted = clock.now
            let candidates: [ElementAnalyzerCandidate]
            do {
                candidates = try regions.map {
                    region -> ElementAnalyzerCandidate in
                    guard region.x + region.width <= inputWidth,
                          region.y + region.height <= inputHeight
                    else {
                        throw AppleRegionWorkerError.invalidResponse
                    }
                    let input = try SnapshotPixelRect(
                        x: region.x,
                        y: inputHeight - region.y - region.height,
                        width: region.width,
                        height: region.height
                    )
                    guard let source = try image.geometry.mapInputRectToSource(input),
                          source.width > 0,
                          source.height > 0
                    else {
                        throw AppleRegionWorkerError.invalidResponse
                    }
                    return ElementAnalyzerCandidate(
                        frame: source,
                        source: .appleRegion,
                        type: .text,
                        confidence: nil,
                        label: nil
                    )
                }
            } catch {
                responseDecodeMicroseconds =
                    ElementAnalyzerTiming.elapsedMicroseconds(since: responseDecodeStarted)
                throw error
            }
            responseDecodeMicroseconds = ElementAnalyzerTiming.elapsedMicroseconds(
                since: responseDecodeStarted
            )
            consecutiveFailures = 0
            circuitOpenedAt = nil
            await requestGate.release()
            permitAcquired = false
            return ElementAnalyzerResult(
                source: .appleRegion,
                status: .succeeded,
                profileID: ElementAnalyzerProfiles.appleRegion.profileID,
                candidates: candidates,
                elapsedMilliseconds: ElementAnalyzerTiming.elapsedMilliseconds(
                    since: started
                ),
                inferenceMilliseconds: inferenceMilliseconds,
                inputDimensions: image.geometry.inputDimensions,
                queueWaitMilliseconds: queueWaitMilliseconds,
                backend: ready.hello.backend,
                version: ready.hello.version,
                stageTimings: stageTimings()
            )
        } catch is CancellationError {
            if detectionStarted {
                await retireWorker(countFailure: false)
            }
            if permitAcquired { await requestGate.release() }
            return failure(
                status: stopped ? .unavailable : .timedOut,
                started: started,
                inputDimensions: inputDimensions,
                queueWaitMilliseconds: queueWaitMilliseconds,
                stageTimings: stageTimings()
            )
        } catch let error as InitializationWaitError {
            if permitAcquired { await requestGate.release() }
            switch error {
            case .failed(.timedOut):
                return failure(
                    status: .timedOut,
                    started: started,
                    inputDimensions: inputDimensions,
                    queueWaitMilliseconds: queueWaitMilliseconds,
                    stageTimings: stageTimings()
                )
            case .failed(.unavailable):
                return failure(
                    status: .unavailable,
                    started: started,
                    inputDimensions: inputDimensions,
                    queueWaitMilliseconds: queueWaitMilliseconds,
                    stageTimings: stageTimings()
                )
            case .failed:
                return failure(
                    status: .failed,
                    started: started,
                    inputDimensions: inputDimensions,
                    queueWaitMilliseconds: queueWaitMilliseconds,
                    stageTimings: stageTimings()
                )
            }
        } catch let error as AppleRegionWorkerError where error == .timedOut {
            await retireWorker(countFailure: true)
            if permitAcquired { await requestGate.release() }
            return failure(
                status: .timedOut,
                started: started,
                inputDimensions: inputDimensions,
                queueWaitMilliseconds: queueWaitMilliseconds,
                stageTimings: stageTimings()
            )
        } catch is AppleRegionWorkerError {
            await retireWorker(countFailure: true)
            if permitAcquired { await requestGate.release() }
            return failure(
                status: .failed,
                started: started,
                inputDimensions: inputDimensions,
                queueWaitMilliseconds: queueWaitMilliseconds,
                stageTimings: stageTimings()
            )
        } catch {
            if permitAcquired { await requestGate.release() }
            return failure(
                status: .failed,
                started: started,
                inputDimensions: inputDimensions,
                queueWaitMilliseconds: queueWaitMilliseconds,
                stageTimings: stageTimings()
            )
        }
    }

    public func shutdown() async {
        guard !stopped else { return }
        stopped = true
        let currentInitialization = initialization
        initialization = nil
        for waiter in currentInitialization?.waiters.values ?? [:].values {
            waiter.resume(throwing: CancellationError())
        }
        currentInitialization?.task.cancel()
        _ = try? await currentInitialization?.task.value
        await requestGate.cancelAll()
        let transport = worker?.transport
        worker = nil
        await transport?.shutdown()
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            circuitOpen: isCircuitOpen,
            consecutiveFailures: consecutiveFailures,
            initializationAttemptCount: initializationAttemptCount,
            initializationCount: initializationCount,
            initializationFailureCount: initializationFailureCount,
            queryCount: queryCount,
            restartCount: restartCount,
            stopped: stopped
        )
    }

    private var isCircuitOpen: Bool {
        guard let circuitOpenedAt else { return false }
        if circuitOpenedAt.duration(to: clock.now) >= circuitPolicy.openDuration {
            self.circuitOpenedAt = nil
            consecutiveFailures = 0
            return false
        }
        return true
    }

    private func readyWorker() async throws -> ReadyWorker {
        if let worker { return worker }
        guard !stopped else { throw CancellationError() }
        let initializationID: UUID
        if let initialization {
            initializationID = initialization.id
        } else {
            initializationID = startInitialization()
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<ReadyWorker, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let worker {
                    continuation.resume(returning: worker)
                } else if var current = initialization,
                          current.id == initializationID
                {
                    current.waiters[waiterID] = continuation
                    initialization = current
                } else {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            Task {
                await self.cancelInitializationWaiter(
                    initializationID: initializationID,
                    waiterID: waiterID
                )
            }
        }
    }

    private func startInitialization() -> UUID {
        let id = UUID()
        let factory = self.factory
        let task = Task<ReadyWorker, Error> {
            let transport = try await factory()
            do {
                let hello = try await transport.start()
                guard hello.type == .hello,
                      hello.backend == AppleRegionWorkerMessage.expectedBackend,
                      hello.version == AppleRegionWorkerMessage.expectedVersion
                else {
                    throw AppleRegionWorkerError.invalidResponse
                }
                return ReadyWorker(hello: hello, transport: transport)
            } catch {
                await transport.shutdown()
                throw error
            }
        }
        initialization = Initialization(id: id, task: task, waiters: [:])
        initializationAttemptCount = Self.increment(initializationAttemptCount)
        Task { [weak self] in
            let completion: InitializationCompletion
            do {
                completion = .succeeded(try await task.value)
            } catch is CancellationError {
                completion = .cancelled
            } catch let error as AppleRegionWorkerError {
                completion = .failed(error)
            } catch {
                completion = .failed(.unavailable)
            }
            await self?.completeInitialization(id: id, completion: completion)
        }
        return id
    }

    private func completeInitialization(
        id: UUID,
        completion: InitializationCompletion
    ) async {
        guard let current = initialization, current.id == id else { return }
        initialization = nil
        switch completion {
        case .succeeded(let ready) where !stopped:
            initializationCount = Self.increment(initializationCount)
            if initializationCount > 1 {
                restartCount = Self.increment(restartCount)
            }
            worker = ready
            for waiter in current.waiters.values {
                waiter.resume(returning: ready)
            }
        case .succeeded(let ready):
            await ready.transport.shutdown()
            for waiter in current.waiters.values {
                waiter.resume(throwing: CancellationError())
            }
        case .cancelled:
            for waiter in current.waiters.values {
                waiter.resume(throwing: CancellationError())
            }
        case .failed(let error):
            initializationFailureCount = Self.increment(
                initializationFailureCount
            )
            recordFailure()
            for waiter in current.waiters.values {
                waiter.resume(throwing: InitializationWaitError.failed(error))
            }
        }
    }

    private func cancelInitializationWaiter(
        initializationID: UUID,
        waiterID: UUID
    ) {
        guard var current = initialization,
              current.id == initializationID,
              let waiter = current.waiters.removeValue(forKey: waiterID)
        else { return }
        initialization = current
        waiter.resume(throwing: CancellationError())
    }

    private func retireWorker(countFailure: Bool) async {
        let currentInitialization = initialization
        initialization = nil
        for waiter in currentInitialization?.waiters.values ?? [:].values {
            waiter.resume(throwing: CancellationError())
        }
        currentInitialization?.task.cancel()
        _ = try? await currentInitialization?.task.value
        let transport = worker?.transport
        worker = nil
        await transport?.shutdown()
        if countFailure { recordFailure() }
    }

    private func recordFailure() {
        consecutiveFailures = Self.increment(consecutiveFailures)
        if consecutiveFailures >= circuitPolicy.failureThreshold {
            circuitOpenedAt = clock.now
        }
    }

    private func failure(
        status: ElementAnalyzerStatus,
        started: ContinuousClock.Instant,
        inputDimensions: SnapshotImageDimensions? = nil,
        queueWaitMilliseconds: UInt64 = 0,
        stageTimings: ElementAnalyzerStageTimings = .init()
    ) -> ElementAnalyzerResult {
        ElementAnalyzerResult(
            source: .appleRegion,
            status: status,
            profileID: ElementAnalyzerProfiles.appleRegion.profileID,
            elapsedMilliseconds: ElementAnalyzerTiming.elapsedMilliseconds(
                since: started
            ),
            inputDimensions: inputDimensions,
            queueWaitMilliseconds: queueWaitMilliseconds,
            backend: AppleRegionWorkerMessage.expectedBackend,
            version: AppleRegionWorkerMessage.expectedVersion,
            stageTimings: stageTimings
        )
    }

    private static func increment(_ value: UInt64) -> UInt64 {
        value == UInt64.max ? UInt64.max : value + 1
    }
}
