import Foundation
import PulsePhoneMedia

final class OmniParserSessionDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

public struct OmniParserCircuitPolicy: Equatable, Sendable {
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

enum OmniParserProtocolMode: Equatable, Sendable {
    case currentParse
    case detectorProbe
}

public actor OmniParserAnalyzer {
    public struct Snapshot: Equatable, Sendable {
        public let circuitOpen: Bool
        public let consecutiveFailures: UInt64
        public let probeCount: UInt64
        public let queryCount: UInt64
        public let requestCount: UInt64
    }

    public static let maximumProbeBytes = 64 * 1_024
    public static let maximumRequestBodyBytes = 24 * 1_024 * 1_024
    public static let maximumRequestImageBytes = 16 * 1_024 * 1_024
    public static let maximumResponseBytes = 4 * 1_024 * 1_024
    public static let requestTimeoutSeconds: TimeInterval = 8

    private let circuitPolicy: OmniParserCircuitPolicy
    private let clock = ContinuousClock()
    private let configuration: OmniParserEndpointConfiguration
    private let gate = ElementAnalyzerRequestGate()
    private let renderer: ElementImageRenderer
    private let session: URLSession
    private let sessionDelegate: OmniParserSessionDelegate?
    private let protocolMode: OmniParserProtocolMode
    private var capability: OmniParserServiceCapability?
    private var capabilityTask: Task<OmniParserServiceCapability, Error>?
    private var circuitOpenedAt: ContinuousClock.Instant?
    private var consecutiveFailures: UInt64 = 0
    private var probeCount: UInt64 = 0
    private var queryCount: UInt64 = 0
    private var requestCount: UInt64 = 0
    private var stopped = false

    public init(
        configuration: OmniParserEndpointConfiguration,
        circuitPolicy: OmniParserCircuitPolicy = .init(),
        renderer: ElementImageRenderer = ElementImageRenderer()
    ) {
        let sessionConfiguration = Self.productionSessionConfiguration()
        let sessionDelegate = OmniParserSessionDelegate()
        self.circuitPolicy = circuitPolicy
        self.configuration = configuration
        self.renderer = renderer
        self.protocolMode = .currentParse
        self.session = URLSession(
            configuration: sessionConfiguration,
            delegate: sessionDelegate,
            delegateQueue: nil
        )
        self.sessionDelegate = sessionDelegate
    }

    init(
        configuration: OmniParserEndpointConfiguration,
        circuitPolicy: OmniParserCircuitPolicy = .init(),
        renderer: ElementImageRenderer,
        session: URLSession,
        protocolMode: OmniParserProtocolMode = .currentParse
    ) {
        self.circuitPolicy = circuitPolicy
        self.configuration = configuration
        self.renderer = renderer
        self.protocolMode = protocolMode
        self.session = session
        self.sessionDelegate = nil
    }

    static func productionSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeoutSeconds
        configuration.timeoutIntervalForResource = requestTimeoutSeconds + 2
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        return configuration
    }

    deinit {
        capabilityTask?.cancel()
        session.invalidateAndCancel()
    }

    public func analyze(_ frame: SnapshotFrame) async -> ElementAnalyzerResult {
        queryCount = Self.increment(queryCount)
        let started = clock.now
        guard !stopped else {
            return failure(status: .unavailable, started: started)
        }
        guard !isCircuitOpen else {
            return failure(status: .circuitOpen, started: started)
        }
        let queueStarted = clock.now
        do {
            try await gate.acquire()
        } catch {
            return failure(
                status: stopped ? .unavailable : .timedOut,
                started: started,
                queueWaitMilliseconds: ElementAnalyzerTiming.elapsedMilliseconds(
                    since: queueStarted
                )
            )
        }
        let queueWaitMilliseconds = ElementAnalyzerTiming.elapsedMilliseconds(
            since: queueStarted
        )
        let result = await analyzeWithPermit(
            frame,
            started: started,
            queueWaitMilliseconds: queueWaitMilliseconds
        )
        await gate.release()
        return result
    }

    public func shutdown() async {
        guard !stopped else { return }
        stopped = true
        capabilityTask?.cancel()
        capabilityTask = nil
        capability = nil
        session.invalidateAndCancel()
        await gate.cancelAll()
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            circuitOpen: isCircuitOpen,
            consecutiveFailures: consecutiveFailures,
            probeCount: probeCount,
            queryCount: queryCount,
            requestCount: requestCount
        )
    }

    private var isCircuitOpen: Bool {
        guard let circuitOpenedAt else { return false }
        if circuitOpenedAt.duration(to: clock.now) >= circuitPolicy.openDuration {
            self.circuitOpenedAt = nil
            consecutiveFailures = 0
            capability = nil
            return false
        }
        return true
    }

    private func analyzeWithPermit(
        _ frame: SnapshotFrame,
        started: ContinuousClock.Instant,
        queueWaitMilliseconds: UInt64
    ) async -> ElementAnalyzerResult {
        guard !stopped else {
            return failure(
                status: .unavailable,
                started: started,
                queueWaitMilliseconds: queueWaitMilliseconds
            )
        }
        guard !isCircuitOpen else {
            return failure(
                status: .circuitOpen,
                started: started,
                queueWaitMilliseconds: queueWaitMilliseconds
            )
        }
        guard !Task.isCancelled else {
            return failure(
                status: .timedOut,
                started: started,
                queueWaitMilliseconds: queueWaitMilliseconds
            )
        }

        let service: OmniParserServiceCapability
        do {
            service = try await readyCapability()
        } catch is CancellationError {
            return failure(
                status: .timedOut,
                started: started,
                queueWaitMilliseconds: queueWaitMilliseconds
            )
        } catch let error as URLError where error.code == .timedOut {
            recordFailure()
            return failure(
                status: .timedOut,
                started: started,
                queueWaitMilliseconds: queueWaitMilliseconds
            )
        } catch {
            recordFailure()
            return failure(
                status: .unavailable,
                started: started,
                queueWaitMilliseconds: queueWaitMilliseconds
            )
        }

        var inputDimensions: SnapshotImageDimensions?
        var inputEncodeMicroseconds: UInt64?
        var requestEncodeMicroseconds: UInt64?
        var resizeAndColorSpaceMicroseconds: UInt64?
        var responseDecodeMicroseconds: UInt64?
        var transportOverheadMicroseconds: UInt64?
        var transportRoundTripMicroseconds: UInt64?
        do {
            try Task.checkCancellation()
            let profile = ElementAnalyzerProfiles.omniparser
            let image = try await frame.derivedImage(
                for: profile,
                materialize: renderer.pngMaterializer()
            )
            inputDimensions = image.geometry.inputDimensions
            inputEncodeMicroseconds = image.payload.timings.inputEncodeMicroseconds
            resizeAndColorSpaceMicroseconds =
                image.payload.timings.resizeAndColorSpaceMicroseconds
            let requestID = UUID().uuidString.lowercased()
            let snapshotID = Self.snapshotID(frame.metadata)
            var request = URLRequest(url: configuration.endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = Self.requestTimeoutSeconds
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let requestEncodeStarted = clock.now
            request.httpBody = try service.encodeRequest(
                image: image,
                requestID: requestID,
                snapshotID: snapshotID
            )
            requestEncodeMicroseconds = ElementAnalyzerTiming.elapsedMicroseconds(
                since: requestEncodeStarted
            )
            requestCount = Self.increment(requestCount)
            let transportStarted = clock.now
            let data: Data
            do {
                data = try await Self.data(
                    for: request,
                    session: session,
                    maximumBytes: min(
                        Int(service.maximumResponseBytes),
                        Self.maximumResponseBytes
                    )
                )
            } catch {
                transportRoundTripMicroseconds =
                    ElementAnalyzerTiming.elapsedMicroseconds(since: transportStarted)
                throw error
            }
            transportRoundTripMicroseconds = ElementAnalyzerTiming.elapsedMicroseconds(
                since: transportStarted
            )
            let responseDecodeStarted = clock.now
            let response: OmniParserDetectorResponse
            let candidates: [ElementAnalyzerCandidate]
            do {
                response = try service.decodeResponse(
                    data,
                    requestID: requestID,
                    snapshotID: snapshotID,
                    geometry: image.geometry,
                    profileID: profile.profileID
                )
                candidates = try response.detections.compactMap {
                    detection -> ElementAnalyzerCandidate? in
                    guard let source = try image.geometry.mapInputRectToSource(
                        detection.inputFrame
                    ) else { return nil }
                    return ElementAnalyzerCandidate(
                        frame: source,
                        source: .omniparser,
                        type: .controlCandidate,
                        confidence: detection.confidence,
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
            transportOverheadMicroseconds =
                ElementAnalyzerTiming.transportOverheadMicroseconds(
                    roundTripMicroseconds: transportRoundTripMicroseconds!,
                    remoteElapsedMilliseconds: response.timings.totalMilliseconds
                )
            consecutiveFailures = 0
            circuitOpenedAt = nil
            return ElementAnalyzerResult(
                source: .omniparser,
                status: .succeeded,
                profileID: profile.profileID,
                candidates: candidates,
                elapsedMilliseconds: ElementAnalyzerTiming.elapsedMilliseconds(
                    since: started
                ),
                inferenceMilliseconds: response.timings.inferenceMilliseconds,
                inputDimensions: inputDimensions,
                queueWaitMilliseconds: ElementAnalyzerTiming.adding(
                    queueWaitMilliseconds,
                    response.timings.queueWaitMilliseconds
                ),
                backend: response.backend,
                version: response.version,
                stageTimings: ElementAnalyzerStageTimings(
                    resizeAndColorSpaceMicroseconds: resizeAndColorSpaceMicroseconds,
                    inputEncodeMicroseconds: inputEncodeMicroseconds,
                    requestEncodeMicroseconds: requestEncodeMicroseconds,
                    transportRoundTripMicroseconds: transportRoundTripMicroseconds,
                    transportOverheadMicroseconds: transportOverheadMicroseconds,
                    responseDecodeMicroseconds: responseDecodeMicroseconds
                )
            )
        } catch is CancellationError {
            return failure(
                status: .timedOut,
                started: started,
                inputDimensions: inputDimensions,
                queueWaitMilliseconds: queueWaitMilliseconds,
                stageTimings: ElementAnalyzerStageTimings(
                    resizeAndColorSpaceMicroseconds: resizeAndColorSpaceMicroseconds,
                    inputEncodeMicroseconds: inputEncodeMicroseconds,
                    requestEncodeMicroseconds: requestEncodeMicroseconds,
                    transportRoundTripMicroseconds: transportRoundTripMicroseconds,
                    transportOverheadMicroseconds: transportOverheadMicroseconds,
                    responseDecodeMicroseconds: responseDecodeMicroseconds
                )
            )
        } catch let error as URLError where error.code == .timedOut {
            capability = nil
            recordFailure()
            return failure(
                status: .timedOut,
                started: started,
                inputDimensions: inputDimensions,
                queueWaitMilliseconds: queueWaitMilliseconds,
                stageTimings: ElementAnalyzerStageTimings(
                    resizeAndColorSpaceMicroseconds: resizeAndColorSpaceMicroseconds,
                    inputEncodeMicroseconds: inputEncodeMicroseconds,
                    requestEncodeMicroseconds: requestEncodeMicroseconds,
                    transportRoundTripMicroseconds: transportRoundTripMicroseconds,
                    transportOverheadMicroseconds: transportOverheadMicroseconds,
                    responseDecodeMicroseconds: responseDecodeMicroseconds
                )
            )
        } catch {
            if Self.isServiceFailure(error) {
                capability = nil
                recordFailure()
            }
            return failure(
                status: .failed,
                started: started,
                inputDimensions: inputDimensions,
                queueWaitMilliseconds: queueWaitMilliseconds,
                stageTimings: ElementAnalyzerStageTimings(
                    resizeAndColorSpaceMicroseconds: resizeAndColorSpaceMicroseconds,
                    inputEncodeMicroseconds: inputEncodeMicroseconds,
                    requestEncodeMicroseconds: requestEncodeMicroseconds,
                    transportRoundTripMicroseconds: transportRoundTripMicroseconds,
                    transportOverheadMicroseconds: transportOverheadMicroseconds,
                    responseDecodeMicroseconds: responseDecodeMicroseconds
                )
            )
        }
    }

    private func readyCapability() async throws -> OmniParserServiceCapability {
        if let capability { return capability }
        if protocolMode == .currentParse {
            let value = OmniParserServiceCapability.currentParse()
            capability = value
            return value
        }
        if let capabilityTask { return try await capabilityTask.value }
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = self.session
        let task = Task<OmniParserServiceCapability, Error> {
            let data = try await Self.data(
                for: request,
                session: session,
                maximumBytes: Self.maximumProbeBytes
            )
            return try OmniParserServiceCapability.decodeProbe(data)
        }
        capabilityTask = task
        probeCount = Self.increment(probeCount)
        do {
            let value = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            capabilityTask = nil
            capability = value
            return value
        } catch {
            capabilityTask = nil
            throw error
        }
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
            source: .omniparser,
            status: status,
            profileID: ElementAnalyzerProfiles.omniparser.profileID,
            elapsedMilliseconds: ElementAnalyzerTiming.elapsedMilliseconds(
                since: started
            ),
            inputDimensions: inputDimensions,
            queueWaitMilliseconds: queueWaitMilliseconds,
            backend: "http",
            version: capability?.model?.version,
            stageTimings: stageTimings
        )
    }

    private static func data(
        for request: URLRequest,
        session: URLSession,
        maximumBytes: Int
    ) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            throw ElementAnalyzerError.invalidResponse
        }
        guard response.expectedContentLength < 0
                || response.expectedContentLength <= maximumBytes
        else {
            throw ElementAnalyzerError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(
            max(0, Int(response.expectedContentLength)),
            maximumBytes
        ))
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw ElementAnalyzerError.responseTooLarge
            }
            data.append(byte)
        }
        return data
    }

    private static func snapshotID(_ metadata: SnapshotFrameMetadata) -> String {
        "snapshot-\(metadata.connectionEpoch)-\(metadata.captureGeneration)-\(metadata.frameSequence)"
    }

    private static func increment(_ value: UInt64) -> UInt64 {
        value == UInt64.max ? UInt64.max : value + 1
    }

    private static func isServiceFailure(_ error: Error) -> Bool {
        if error is URLError { return true }
        guard let error = error as? ElementAnalyzerError else {
            return false
        }
        switch error {
        case .invalidResponse, .responseTooLarge, .tooManyCandidates:
            return true
        case .imageDecodeFailed, .imageEncodeFailed, .invalidEndpoint,
             .invalidImageGeometry, .requestTooLarge:
            return false
        }
    }
}
