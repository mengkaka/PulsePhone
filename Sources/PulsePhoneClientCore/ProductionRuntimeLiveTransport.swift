import Darwin
import Foundation
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions
import PulsePhoneWire

final class ProductionRuntimeLiveTransport: @unchecked Sendable {
    typealias EventHandler = @Sendable (RepositoryJSONObject) -> Void
    typealias ObservationHandler = @Sendable (RuntimeObservation) -> Void
    typealias ResetHandler = @Sendable (ObservationStreamReset) -> Void
    typealias FailureHandler = @Sendable (RuntimeClientError) -> Void

    private struct PendingResponse {
        var frame: RuntimeWireFrame?
        var error: RuntimeClientError?
    }

    private let callbackQueue = DispatchQueue(
        label: "com.pulsephone.runtime-live.callbacks"
    )
    private let readerGroup = DispatchGroup()
    private let state = NSCondition()
    private let writeLock = NSLock()
    private var descriptor: Int32
    private var eventHandler: EventHandler?
    private var failureHandler: FailureHandler?
    private var observationHandler: ObservationHandler?
    private var pending = [CanonicalUUID: PendingResponse]()
    private var resetHandler: ResetHandler?
    private var terminalError: RuntimeClientError?

    init(descriptor: Int32) throws {
        self.descriptor = descriptor
        var timeout = timeval(tv_sec: 0, tv_usec: 0)
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw RuntimeClientError.transportFailure(errno: errno)
        }
        readerGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { self?.readerGroup.leave() }
            self?.readLoop()
        }
    }

    deinit {
        close()
    }

    var isOpen: Bool {
        state.withLock { descriptor >= 0 && terminalError == nil }
    }

    func setEventHandler(_ handler: EventHandler?) {
        state.withLock { eventHandler = handler }
    }

    func setObservationHandler(_ handler: ObservationHandler?) {
        state.withLock { observationHandler = handler }
    }

    func setResetHandler(_ handler: ResetHandler?) {
        state.withLock { resetHandler = handler }
    }

    func setFailureHandler(_ handler: FailureHandler?) {
        state.withLock { failureHandler = handler }
    }

    func ensureOpen() throws {
        try state.withLock {
            if let terminalError { throw terminalError }
            guard descriptor >= 0 else {
                throw RuntimeClientError.closedBeforeResponse
            }
        }
    }

    func request(
        _ frame: RuntimeWireFrame,
        requestID: CanonicalUUID,
        timeoutSeconds: TimeInterval = 60
    ) throws -> RuntimeWireFrame {
        try state.withLock {
            if let terminalError { throw terminalError }
            guard descriptor >= 0, pending[requestID] == nil else {
                throw RuntimeClientError.invalidResponse
            }
            pending[requestID] = PendingResponse()
        }
        do {
            try send(frame)
        } catch {
            _ = state.withLock { pending.removeValue(forKey: requestID) }
            throw error
        }

        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
        state.lock()
        defer { state.unlock() }
        while true {
            guard let response = pending[requestID] else {
                throw terminalError ?? RuntimeClientError.invalidResponse
            }
            if let error = response.error {
                pending.removeValue(forKey: requestID)
                throw error
            }
            if let frame = response.frame {
                pending.removeValue(forKey: requestID)
                return frame
            }
            guard state.wait(until: deadline) else {
                pending.removeValue(forKey: requestID)
                throw RuntimeClientError.transportFailure(errno: ETIMEDOUT)
            }
        }
    }

    func send(_ frame: RuntimeWireFrame) throws {
        let bytes: [UInt8]
        do {
            bytes = try RuntimeWireFrameCodec.encode(frame)
        } catch {
            throw RuntimeClientError.invalidResponse
        }
        writeLock.lock()
        defer { writeLock.unlock() }
        let active = try state.withLock { () throws -> Int32 in
            if let terminalError { throw terminalError }
            guard descriptor >= 0 else {
                throw RuntimeClientError.closedBeforeResponse
            }
            return descriptor
        }
        try Self.writeAll(bytes, to: active)
    }

    func close() {
        let active: Int32 = state.withLock {
            guard descriptor >= 0 else { return -1 }
            let result = descriptor
            descriptor = -1
            terminalError = terminalError ?? .closedBeforeResponse
            for requestID in pending.keys {
                pending[requestID]?.error = terminalError
            }
            state.broadcast()
            return result
        }
        guard active >= 0 else { return }
        _ = Darwin.shutdown(active, SHUT_RDWR)
        _ = Darwin.close(active)
        _ = readerGroup.wait(timeout: .now() + 2)
    }

    private func readLoop() {
        while true {
            let active = state.withLock { descriptor }
            guard active >= 0 else { return }
            do {
                let frame = try RuntimeWireFrameCodec.decode(
                    Self.readFrame(from: active)
                )
                try dispatch(frame)
            } catch let error as RuntimeClientError {
                finish(error)
                return
            } catch {
                finish(.invalidResponse)
                return
            }
        }
    }

    private func dispatch(_ frame: RuntimeWireFrame) throws {
        switch frame.messageType {
        case .response:
            let object = try RepositoryCanonicalJSON.parseDocument(
                frame.payload,
                maximumByteCount: 256 * 1_024
            )
            guard let requestText = object["requestID"]?.stringValue,
                  let requestID = try? CanonicalUUID(requestText)
            else {
                throw RuntimeClientError.invalidResponse
            }
            try state.withLock {
                guard var response = pending[requestID], response.frame == nil else {
                    throw RuntimeClientError.invalidResponse
                }
                response.frame = frame
                pending[requestID] = response
                state.broadcast()
            }
        case .runtimeEvent:
            let event = try RepositoryCanonicalJSON.parseDocument(
                frame.payload,
                maximumByteCount: 256 * 1_024
            )
            if let handler = state.withLock({ eventHandler }) {
                callbackQueue.async { handler(event) }
            }
        case .runtimeObservation:
            let observation = try Self.decode(
                RuntimeObservation.self,
                payload: frame.payload,
                maximumByteCount: RuntimeObservationPublisher.maximumObservationBytes
            )
            if let handler = state.withLock({ observationHandler }) {
                callbackQueue.async { handler(observation) }
            }
        case .observationStreamReset:
            let reset = try Self.decode(
                ObservationStreamReset.self,
                payload: frame.payload,
                maximumByteCount: RuntimeObservationPublisher.maximumObservationBytes
            )
            if let handler = state.withLock({ resetHandler }) {
                callbackQueue.async { handler(reset) }
            }
        case .progress:
            break
        case .protocolError:
            throw RuntimeClientError.invalidResponse
        default:
            throw RuntimeClientError.invalidResponse
        }
    }

    private func finish(_ error: RuntimeClientError) {
        let failure: FailureHandler? = state.withLock {
            guard terminalError == nil else { return nil }
            terminalError = error
            let active = descriptor
            descriptor = -1
            if active >= 0 {
                _ = Darwin.shutdown(active, SHUT_RDWR)
                _ = Darwin.close(active)
            }
            for requestID in pending.keys {
                pending[requestID]?.error = error
            }
            state.broadcast()
            return failureHandler
        }
        if let failure {
            callbackQueue.async { failure(error) }
        }
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        payload: [UInt8],
        maximumByteCount: Int
    ) throws -> T {
        guard payload.count <= maximumByteCount else {
            throw RuntimeClientError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(payload))
        } catch {
            throw RuntimeClientError.invalidResponse
        }
    }

    private static func readFrame(from descriptor: Int32) throws -> [UInt8] {
        let header = try readExact(RuntimeWireFrame.headerByteCount, from: descriptor)
        let payloadLength = Int(
            (UInt32(header[12]) << 24)
                | (UInt32(header[13]) << 16)
                | (UInt32(header[14]) << 8)
                | UInt32(header[15])
        )
        guard payloadLength <= 1 * 1_024 * 1_024 else {
            throw RuntimeClientError.invalidResponse
        }
        return header + (try readExact(payloadLength, from: descriptor))
    }

    private static func readExact(
        _ count: Int,
        from descriptor: Int32
    ) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let result = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    count - offset
                )
            }
            if result > 0 {
                offset += result
            } else if result == 0 {
                throw RuntimeClientError.closedBeforeResponse
            } else if errno == EINTR {
                continue
            } else {
                throw RuntimeClientError.transportFailure(errno: errno)
            }
        }
        return bytes
    }

    private static func writeAll(_ bytes: [UInt8], to descriptor: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let result = bytes.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if result > 0 {
                offset += result
            } else if result == -1, errno == EINTR {
                continue
            } else {
                throw RuntimeClientError.transportFailure(errno: errno)
            }
        }
    }
}

private extension NSCondition {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
