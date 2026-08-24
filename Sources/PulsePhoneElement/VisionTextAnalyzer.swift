import CoreGraphics
import Foundation
import PulsePhoneMedia
import Vision

public struct VisionTextRecognitionPolicy: Equatable, Sendable {
    public static let production = VisionTextRecognitionPolicy(
        automaticallyDetectsLanguage: false,
        minimumTextHeight: 0,
        recognitionLanguages: ["zh-Hans", "en-US"],
        requestRevision: UInt64(VNRecognizeTextRequestRevision3),
        usesLanguageCorrection: true,
        version: "VNRecognizeTextRequest.revision3"
    )

    public let automaticallyDetectsLanguage: Bool
    public let minimumTextHeight: Float
    public let recognitionLanguages: [String]
    public let requestRevision: UInt64
    public let usesLanguageCorrection: Bool
    public let version: String

    private init(
        automaticallyDetectsLanguage: Bool,
        minimumTextHeight: Float,
        recognitionLanguages: [String],
        requestRevision: UInt64,
        usesLanguageCorrection: Bool,
        version: String
    ) {
        self.automaticallyDetectsLanguage = automaticallyDetectsLanguage
        self.minimumTextHeight = minimumTextHeight
        self.recognitionLanguages = recognitionLanguages
        self.requestRevision = requestRevision
        self.usesLanguageCorrection = usesLanguageCorrection
        self.version = version
    }

    fileprivate func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.revision = Int(requestRevision)
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = usesLanguageCorrection
        request.automaticallyDetectsLanguage = automaticallyDetectsLanguage
        request.recognitionLanguages = recognitionLanguages
        request.minimumTextHeight = minimumTextHeight
        request.customWords = []
        return request
    }
}

public actor VisionTextAnalyzer {
    typealias PrewarmOperation = @Sendable (
        VisionTextRecognitionPolicy
    ) async throws -> Void

    private final class RequestCancellation: @unchecked Sendable {
        let request: VNRequest

        init(_ request: VNRequest) {
            self.request = request
        }

        func cancel() {
            request.cancel()
        }
    }

    private final class RequestExecution: @unchecked Sendable {
        let handler: VNImageRequestHandler
        let request: VNRecognizeTextRequest

        init(handler: VNImageRequestHandler, request: VNRecognizeTextRequest) {
            self.handler = handler
            self.request = request
        }

        func perform() throws {
            try handler.perform([request])
        }
    }

    private struct Initialization {
        let id: UUID
        let task: Task<Void, Error>
        var waiters: [UUID: CheckedContinuation<Void, Error>]
    }

    public struct Snapshot: Equatable, Sendable {
        public let automaticallyDetectsLanguage: Bool
        public let initializationAttemptCount: UInt64
        public let initializationCount: UInt64
        public let initializationFailureCount: UInt64
        public let minimumTextHeight: Float
        public let queryCount: UInt64
        public let recognitionLanguages: [String]
        public let requestRevision: UInt64
        public let stopped: Bool
        public let usesLanguageCorrection: Bool
        public let version: String
    }

    private var activeOperation: Task<Void, Error>?
    private var activeRequest: RequestCancellation?
    private var initialization: Initialization?
    private var initializationAttemptCount: UInt64 = 0
    private var initializationCount: UInt64 = 0
    private var initializationFailureCount: UInt64 = 0
    private var initialized = false
    private let policy: VisionTextRecognitionPolicy
    private let prewarmOperation: PrewarmOperation
    private var queryCount: UInt64 = 0
    private let requestGate = ElementAnalyzerRequestGate()
    private var stopped = false

    public init(policy: VisionTextRecognitionPolicy = .production) {
        self.policy = policy
        self.prewarmOperation = { try await Self.performPrewarm(policy: $0) }
    }

    init(
        policy: VisionTextRecognitionPolicy = .production,
        prewarmOperation: @escaping PrewarmOperation
    ) {
        self.policy = policy
        self.prewarmOperation = prewarmOperation
    }

    deinit {
        initialization?.task.cancel()
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            automaticallyDetectsLanguage: policy.automaticallyDetectsLanguage,
            initializationAttemptCount: initializationAttemptCount,
            initializationCount: initializationCount,
            initializationFailureCount: initializationFailureCount,
            minimumTextHeight: policy.minimumTextHeight,
            queryCount: queryCount,
            recognitionLanguages: policy.recognitionLanguages,
            requestRevision: policy.requestRevision,
            stopped: stopped,
            usesLanguageCorrection: policy.usesLanguageCorrection,
            version: policy.version
        )
    }

    @discardableResult
    public func prewarm() async -> Bool {
        guard !stopped else { return false }
        do {
            try await ready()
            return true
        } catch {
            return false
        }
    }

    public func analyze(_ frame: SnapshotFrame) async -> ElementAnalyzerResult {
        let started = ContinuousClock.now
        var inferenceStarted: ContinuousClock.Instant?
        var permitAcquired = false
        var queueWaitMilliseconds: UInt64 = 0
        var responseDecodeMicroseconds: UInt64 = 0
        func stageTimings() -> ElementAnalyzerStageTimings {
            ElementAnalyzerStageTimings(
                resizeAndColorSpaceMicroseconds: 0,
                inputEncodeMicroseconds: 0,
                requestEncodeMicroseconds: 0,
                transportRoundTripMicroseconds: 0,
                transportOverheadMicroseconds: 0,
                responseDecodeMicroseconds: responseDecodeMicroseconds
            )
        }
        queryCount = Self.increment(queryCount)
        guard !stopped else {
            return failure(
                status: .unavailable,
                started: started,
                stageTimings: stageTimings()
            )
        }
        do {
            try await ready()
        } catch is CancellationError {
            return failure(
                status: stopped ? .unavailable : .timedOut,
                started: started,
                stageTimings: stageTimings()
            )
        } catch {
            return failure(
                status: .unavailable,
                started: started,
                stageTimings: stageTimings()
            )
        }

        do {
            try Task.checkCancellation()
            let request = policy.makeRequest()
            let handler: VNImageRequestHandler
            if let pixelBuffer = frame.sourceImage.pixelBuffer {
                handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer)
            } else if let cgImage = frame.sourceImage.cgImage {
                handler = VNImageRequestHandler(cgImage: cgImage)
            } else if let encoded = frame.sourceImage.encodedImage {
                handler = VNImageRequestHandler(data: Data(encoded.bytes))
            } else {
                throw ElementAnalyzerError.imageDecodeFailed
            }
            let queueStarted = ContinuousClock.now
            try await requestGate.acquire()
            permitAcquired = true
            queueWaitMilliseconds = ElementAnalyzerTiming.elapsedMilliseconds(
                since: queueStarted
            )
            let cancellation = RequestCancellation(request)
            let execution = RequestExecution(handler: handler, request: request)
            inferenceStarted = ContinuousClock.now
            let operation = Task.detached(priority: .utility) {
                try execution.perform()
            }
            activeOperation = operation
            activeRequest = cancellation
            try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                cancellation.cancel()
                operation.cancel()
            }
            let inferenceMilliseconds = ElementAnalyzerTiming.elapsedMilliseconds(
                since: inferenceStarted!
            )
            activeOperation = nil
            activeRequest = nil
            await requestGate.release()
            permitAcquired = false
            guard !stopped else {
                return failure(
                    status: .unavailable,
                    started: started,
                    inferenceMilliseconds: inferenceMilliseconds,
                    queueWaitMilliseconds: queueWaitMilliseconds,
                    stageTimings: stageTimings()
                )
            }
            try Task.checkCancellation()
            let dimensions = frame.metadata.pixelDimensions
            let responseDecodeStarted = ContinuousClock.now
            let candidates: [ElementAnalyzerCandidate]
            do {
                candidates = try (request.results ?? []).prefix(2_048).compactMap {
                    observation -> ElementAnalyzerCandidate? in
                    guard let recognized = observation.topCandidates(1).first else {
                        return nil
                    }
                    let box = observation.boundingBox
                    let rect = try SnapshotPixelRect(
                        x: box.minX * Double(dimensions.width),
                        y: (1 - box.maxY) * Double(dimensions.height),
                        width: box.width * Double(dimensions.width),
                        height: box.height * Double(dimensions.height)
                    )
                    return ElementAnalyzerCandidate(
                        frame: rect,
                        source: .vision,
                        type: .text,
                        confidence: Double(recognized.confidence),
                        label: Self.truncatedLabel(recognized.string)
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
            return ElementAnalyzerResult(
                source: .vision,
                status: .succeeded,
                profileID: ElementAnalyzerProfiles.visionProfileID,
                candidates: candidates,
                elapsedMilliseconds: ElementAnalyzerTiming.elapsedMilliseconds(
                    since: started
                ),
                inferenceMilliseconds: inferenceMilliseconds,
                inputDimensions: dimensions,
                queueWaitMilliseconds: queueWaitMilliseconds,
                backend: "Vision.framework",
                version: policy.version,
                stageTimings: stageTimings()
            )
        } catch is CancellationError {
            if permitAcquired {
                activeOperation = nil
                activeRequest = nil
                await requestGate.release()
            }
            return failure(
                status: stopped ? .unavailable : .timedOut,
                started: started,
                inferenceMilliseconds: inferenceStarted.map {
                    ElementAnalyzerTiming.elapsedMilliseconds(since: $0)
                },
                queueWaitMilliseconds: queueWaitMilliseconds,
                stageTimings: stageTimings()
            )
        } catch {
            if permitAcquired {
                activeOperation = nil
                activeRequest = nil
                await requestGate.release()
            }
            return failure(
                status: .failed,
                started: started,
                inferenceMilliseconds: inferenceStarted.map {
                    ElementAnalyzerTiming.elapsedMilliseconds(since: $0)
                },
                queueWaitMilliseconds: queueWaitMilliseconds,
                stageTimings: stageTimings()
            )
        }
    }

    public func shutdown() async {
        guard !stopped else { return }
        stopped = true
        let activeOperation = self.activeOperation
        activeRequest?.cancel()
        activeOperation?.cancel()
        _ = try? await activeOperation?.value
        self.activeOperation = nil
        activeRequest = nil
        let current = initialization
        initialization = nil
        for waiter in current?.waiters.values ?? [:].values {
            waiter.resume(throwing: CancellationError())
        }
        current?.task.cancel()
        _ = try? await current?.task.value
        await requestGate.cancelAll()
        initialized = false
    }

    private func ready() async throws {
        if initialized { return }
        let initializationID: UUID
        if let initialization {
            initializationID = initialization.id
        } else {
            initializationID = startInitialization()
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if initialized {
                    continuation.resume()
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
        let policy = self.policy
        let prewarmOperation = self.prewarmOperation
        let task = Task.detached(priority: .utility) {
            try await prewarmOperation(policy)
        }
        self.initialization = Initialization(
            id: id,
            task: task,
            waiters: [:]
        )
        initializationAttemptCount = Self.increment(initializationAttemptCount)
        Task { [weak self] in
            let succeeded: Bool
            do {
                try await task.value
                succeeded = true
            } catch {
                succeeded = false
            }
            await self?.completeInitialization(id: id, succeeded: succeeded)
        }
        return id
    }

    private func completeInitialization(id: UUID, succeeded: Bool) {
        guard let current = initialization, current.id == id else { return }
        initialization = nil
        if succeeded, !stopped {
            initialized = true
            initializationCount = Self.increment(initializationCount)
            for waiter in current.waiters.values {
                waiter.resume()
            }
        } else {
            if !stopped {
                initializationFailureCount = Self.increment(
                    initializationFailureCount
                )
            }
            for waiter in current.waiters.values {
                waiter.resume(throwing: stopped
                    ? CancellationError()
                    : ElementAnalyzerError.invalidResponse)
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

    private static func performPrewarm(
        policy: VisionTextRecognitionPolicy
    ) async throws {
        let request = policy.makeRequest()
        let supported = Set(try request.supportedRecognitionLanguages())
        guard Set(policy.recognitionLanguages).isSubset(of: supported) else {
            throw ElementAnalyzerError.invalidResponse
        }
        let image = try prewarmImage()
        let handler = VNImageRequestHandler(cgImage: image)
        let cancellation = RequestCancellation(request)
        try await withTaskCancellationHandler {
            try handler.perform([request])
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
    }

    private static func prewarmImage() throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: 64,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ElementAnalyzerError.imageEncodeFailed
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = context.makeImage() else {
            throw ElementAnalyzerError.imageEncodeFailed
        }
        return image
    }

    private static func truncatedLabel(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        var bytes = Array(value.utf8.prefix(1_024))
        while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil {
            bytes.removeLast()
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private func failure(
        status: ElementAnalyzerStatus,
        started: ContinuousClock.Instant,
        inferenceMilliseconds: UInt64? = nil,
        queueWaitMilliseconds: UInt64 = 0,
        stageTimings: ElementAnalyzerStageTimings = .noDerivedInputOrTransport
    ) -> ElementAnalyzerResult {
        ElementAnalyzerResult(
            source: .vision,
            status: status,
            profileID: ElementAnalyzerProfiles.visionProfileID,
            elapsedMilliseconds: ElementAnalyzerTiming.elapsedMilliseconds(
                since: started
            ),
            inferenceMilliseconds: inferenceMilliseconds,
            queueWaitMilliseconds: queueWaitMilliseconds,
            backend: "Vision.framework",
            version: policy.version,
            stageTimings: stageTimings
        )
    }

    private static func increment(_ value: UInt64) -> UInt64 {
        value == UInt64.max ? UInt64.max : value + 1
    }
}
