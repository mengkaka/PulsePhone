import Darwin
import Foundation
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneHostPaths
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions
import PulsePhoneWire

public enum RuntimeClientActivation: Sendable {
    case ensureRunning
    case existingOnly
}

public enum RuntimeClientError: Error, Equatable, Sendable {
    case invalidBundledResources
    case socketUnavailable(errno: Int32)
    case transportFailure(errno: Int32)
    case interrupted
    case closedBeforeResponse
    case invalidResponse
    case incompatibleRuntime
    case targetMismatch
    case runtimeStopping
}

public final class RuntimeSocketEOFReceipt: @unchecked Sendable {
    public static let defaultTimeout = MonotonicDuration(
        nanoseconds: 20_000_000_000
    )

    private let stateLock = NSLock()
    private var descriptor: Int32?

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        closeDescriptor()
    }

    public func waitForEOF(
        timeout: MonotonicDuration = RuntimeSocketEOFReceipt.defaultTimeout
    ) throws -> Bool {
        let descriptor = try stateLock.withLock { () throws -> Int32 in
            guard let descriptor = self.descriptor else {
                throw RuntimeClientError.invalidResponse
            }
            self.descriptor = nil
            return descriptor
        }
        defer { _ = Darwin.close(descriptor) }

        let clock = SystemMonotonicClock()
        let deadline = try clock.now().advanced(by: timeout)
        while true {
            let now = clock.now()
            guard now < deadline else { return false }
            let remaining = try deadline.duration(since: now).nanoseconds
            let milliseconds = min(
                UInt64(Int32.max),
                max(1, (remaining + 999_999) / 1_000_000)
            )
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let result = Darwin.poll(
                &pollDescriptor,
                1,
                Int32(milliseconds)
            )
            if result == 0 { return false }
            if result < 0 {
                if errno == EINTR { continue }
                throw RuntimeClientError.transportFailure(errno: errno)
            }
            if pollDescriptor.revents & Int16(POLLERR | POLLNVAL) != 0 {
                return false
            }
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 0 { return true }
            if count > 0 { return false }
            if errno == EINTR { continue }
            throw RuntimeClientError.transportFailure(errno: errno)
        }
    }

    private func closeDescriptor() {
        let descriptor = stateLock.withLock { () -> Int32? in
            defer { self.descriptor = nil }
            return self.descriptor
        }
        if let descriptor { _ = Darwin.close(descriptor) }
    }
}

public struct RuntimeStopTransportResponse: Sendable {
    public let accepted: Bool
    public let errorCode: String?
    public let eofReceipt: RuntimeSocketEOFReceipt

    init(
        accepted: Bool,
        errorCode: String?,
        eofReceipt: RuntimeSocketEOFReceipt
    ) {
        self.accepted = accepted
        self.errorCode = errorCode
        self.eofReceipt = eofReceipt
    }
}

public enum ProductionRuntimeLiveSessionError: Error, Equatable, Sendable {
    case operationFailed(code: String)
}

public struct ProductionRuntimeLiveStream: Equatable, Sendable {
    public let acceptedGeometry: DisplayGeometryDTO?
    public let actionID: CanonicalUUID
    public let executorGeneration: UInt64
    public let interactionID: CanonicalUUID
    public let sessionID: CanonicalUUID

    public init(
        acceptedGeometry: DisplayGeometryDTO? = nil,
        actionID: CanonicalUUID,
        executorGeneration: UInt64,
        interactionID: CanonicalUUID,
        sessionID: CanonicalUUID
    ) {
        self.acceptedGeometry = acceptedGeometry
        self.actionID = actionID
        self.executorGeneration = executorGeneration
        self.interactionID = interactionID
        self.sessionID = sessionID
    }
}

public struct ProductionRuntimeCaptureReadyTransition: Sendable {
    public let geometry: DisplayGeometryDTO?
    public let value: RepositoryJSONObject

    public init(
        value: RepositoryJSONObject,
        expectedConnectionEpoch: UInt64
    ) throws {
        guard expectedConnectionEpoch > 0,
              Self.uint(value["connectionEpoch"]) == expectedConnectionEpoch
        else {
            throw RuntimeClientError.invalidResponse
        }
        let geometryKeys = [
            "geometryRevision", "logicalHeight", "logicalWidth", "orientation",
        ]
        let presentCount = geometryKeys.reduce(into: 0) { count, key in
            if value[key] != nil { count += 1 }
        }
        guard presentCount == 0 || presentCount == geometryKeys.count else {
            throw RuntimeClientError.invalidResponse
        }
        if presentCount == 0 {
            geometry = nil
        } else {
            guard let revision = Self.uint(value["geometryRevision"]),
                  revision > 0,
                  let height = Self.uint(value["logicalHeight"]),
                  let width = Self.uint(value["logicalWidth"]),
                  let orientationText = value["orientation"]?.stringValue,
                  let orientation = DisplayOrientationDTO(
                      rawValue: orientationText
                  ),
                  let parsed = try? DisplayGeometryDTO(
                      connectionEpoch: expectedConnectionEpoch,
                      geometryRevision: revision,
                      logicalHeight: height,
                      logicalWidth: width,
                      orientation: orientation
                  )
            else {
                throw RuntimeClientError.invalidResponse
            }
            geometry = parsed
        }
        self.value = value
    }

    private static func uint(_ value: RepositoryJSONValue?) -> UInt64? {
        guard let number = value?.numberValue else { return nil }
        return try? number.requireUInt64()
    }
}

public struct RuntimeClientResponse: Sendable {
    public let acknowledgement: RuntimeHelloAck
    public let result: RepositoryJSONObject
}

public typealias RuntimeClientPreparationProgressHandler = @Sendable (
    PreparationProgressV1
) -> Void

public struct RuntimeClientScreenshotResponse: Sendable {
    public let acknowledgement: RuntimeHelloAck
    public let artifact: ScreenshotReceivedArtifact?
    public let result: RepositoryJSONObject
}

public struct RuntimeClientElementAnnotationArtifact: Sendable {
    public let artifact: ScreenshotReceivedArtifact
    public let artifactID: CanonicalUUID
    public let captureSHA256: String
    public let pixelHeight: UInt64
    public let pixelWidth: UInt64
    public let snapshotGeneration: UInt64
}

public struct RuntimeClientElementSnapshotResponse: Sendable {
    public let acknowledgement: RuntimeHelloAck
    public let annotation: RuntimeClientElementAnnotationArtifact?
    public let result: RepositoryJSONObject
}

public final class RuntimeClientElementSnapshotInterruption: @unchecked Sendable {
    private struct Registration {
        let handler: @Sendable () -> Void
        let id: UUID
    }

    private let deliveryQueue = DispatchQueue(
        label: "com.pulsephone.client.element-snapshot-interruption",
        qos: .userInitiated
    )
    private let deliveryFinished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var deliveryCompleted = false
    private var deliveryStarted = false
    private var interrupted = false
    private var registration: Registration?

    public init() {}

    public func interrupt() {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            interrupted = true
            guard !deliveryStarted, let registration else { return nil }
            deliveryStarted = true
            return registration.handler
        }
        scheduleDelivery(handler)
    }

    fileprivate func check() throws {
        guard !lock.withLock({ interrupted }) else {
            throw RuntimeClientError.interrupted
        }
    }

    fileprivate func register(
        _ handler: @escaping @Sendable () -> Void
    ) -> UUID {
        let id = UUID()
        let deliverImmediately = lock.withLock { () -> Bool in
            precondition(registration == nil)
            registration = Registration(handler: handler, id: id)
            guard interrupted, !deliveryStarted else { return false }
            deliveryStarted = true
            return true
        }
        if deliverImmediately { scheduleDelivery(handler) }
        return id
    }

    fileprivate func unregister(_ id: UUID) {
        lock.withLock {
            if registration?.id == id { registration = nil }
        }
    }

    fileprivate func waitForDelivery(timeoutSeconds: Double) {
        let shouldWait = lock.withLock {
            deliveryStarted && !deliveryCompleted
        }
        guard shouldWait else { return }
        _ = deliveryFinished.wait(
            timeout: .now() + max(0, timeoutSeconds)
        )
    }

    public var isInterrupted: Bool {
        lock.withLock { interrupted }
    }

    private func scheduleDelivery(_ handler: (@Sendable () -> Void)?) {
        guard let handler else { return }
        deliveryQueue.async { [self] in
            handler()
            lock.withLock { deliveryCompleted = true }
            deliveryFinished.signal()
        }
    }
}

public enum ProductionRuntimeContractIdentity {
    public static let runtimeCompatibilityID = "runtime.compat.v4"
    public static let executionCatalogHash =
        "494f0e80a087941a7651163bbdedd3e567559de57f1cdb88da7020ce296d76cf"

    public static func load(
        resourcesURL: URL
    ) throws -> RuntimeCompatibilityIdentity {
        return try RuntimeCompatibilityIdentity(
            runtimeCompatibilityID: runtimeCompatibilityID,
            executionCatalogHash: executionCatalogHash
        )
    }
}

public struct RuntimeClient: Sendable {
    public static let requestTimeoutSeconds = 60
    public static let preparationRequestTimeoutSeconds = 20 * 60 + 10
    public static let installRequestTimeoutSeconds = 30 * 60 + 10
    public static let uninstallRequestTimeoutSeconds = 5 * 60 + 10

    private let canonicalAppPath: CanonicalAppPath
    private let clientBuildID: String
    private let compatibility: RuntimeCompatibilityIdentity
    private let role: RuntimeClientRole

    public init(
        canonicalAppPath: CanonicalAppPath,
        clientBuildID: String = "pulsephone.client.v1",
        compatibility: RuntimeCompatibilityIdentity,
        role: RuntimeClientRole
    ) {
        self.canonicalAppPath = canonicalAppPath
        self.clientBuildID = clientBuildID
        self.compatibility = compatibility
        self.role = role
    }

    public static func bundled(role: RuntimeClientRole) throws -> Self {
        let appPath = try CanonicalAppPath.resolveCurrentExecutable()
        return RuntimeClient(
            canonicalAppPath: appPath,
            compatibility: try ProductionRuntimeContractIdentity.load(
                resourcesURL: appPath.resourcesURL
            ),
            role: role
        )
    }

    public static func testing(
        canonicalAppPath: CanonicalAppPath
    ) throws -> Self {
        RuntimeClient(
            canonicalAppPath: canonicalAppPath,
            compatibility: try RuntimeCompatibilityIdentity(
                runtimeCompatibilityID:
                    ProductionRuntimeContractIdentity.runtimeCompatibilityID,
                executionCatalogHash:
                    ProductionRuntimeContractIdentity.executionCatalogHash
            ),
            role: .cli
        )
    }

    /// Fixture-only overload while pre-release tests are migrated away from
    /// static developer-image handshake identity.
    public static func testing(
        canonicalAppPath: CanonicalAppPath,
        developerImageCatalogRevision _: String,
        developerImageCatalogHash _: String
    ) throws -> Self {
        try testing(canonicalAppPath: canonicalAppPath)
    }

    public func health(
        canonicalUDID: CanonicalUDID,
        activation: RuntimeClientActivation
    ) throws -> RuntimeClientResponse {
        try request(
            operation: .runtimeHealth,
            canonicalUDID: canonicalUDID,
            body: object([
                ("canonicalUDID", .string(canonicalUDID.rawValue)),
            ]),
            activation: activation
        )
    }

    public func requestStopIfIdle(
        canonicalUDID: CanonicalUDID,
        requestID: CanonicalUUID = CanonicalUUID(value: UUID())
    ) throws -> RuntimeStopTransportResponse {
        let (descriptor, _) = try openNormalConnection(
            canonicalUDID: canonicalUDID,
            activation: .existingOnly
        )
        do {
            try writeRequest(
                operation: .runtimeStopIfIdle,
                body: object([
                    ("canonicalUDID", .string(canonicalUDID.rawValue)),
                ]),
                requestID: requestID,
                to: descriptor
            )
            while true {
                let frame = try RuntimeWireFrameCodec.decode(
                    readFrame(from: descriptor)
                )
                guard frame.messageType != .protocolError else {
                    throw RuntimeClientError.invalidResponse
                }
                guard frame.messageType == .response else { continue }
                let result = try parseResponse(
                    frame,
                    requestID: requestID,
                    operation: .runtimeStopIfIdle
                )
                return try stopTransportResponse(
                    result: result,
                    descriptor: descriptor
                )
            }
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    public func probeIncompatibleRuntime(
        canonicalUDID: CanonicalUDID
    ) throws {
        let requestID = CanonicalUUID(value: UUID())
        let (response, descriptor) = try bootstrapRequest(
            operation: .probeRuntimeLite,
            canonicalUDID: canonicalUDID,
            requestID: requestID
        )
        defer { _ = Darwin.close(descriptor) }
        guard response.ok,
              let result = response.result,
              result["canonicalUDID"]?.stringValue == canonicalUDID.rawValue
        else {
            throw RuntimeClientError.targetMismatch
        }
    }

    public func retireIncompatibleRuntimeIfIdle(
        canonicalUDID: CanonicalUDID,
        requestID: CanonicalUUID = CanonicalUUID(value: UUID())
    ) throws -> RuntimeStopTransportResponse {
        let (response, descriptor) = try bootstrapRequest(
            operation: .retireIfIdle,
            canonicalUDID: canonicalUDID,
            requestID: requestID
        )
        if response.ok {
            guard let result = response.result,
                  result["canonicalUDID"]?.stringValue == canonicalUDID.rawValue,
                  result["disposition"]?.stringValue == "retiring"
            else {
                _ = Darwin.close(descriptor)
                throw RuntimeClientError.invalidResponse
            }
        }
        return RuntimeStopTransportResponse(
            accepted: response.ok,
            errorCode: response.error?.code,
            eofReceipt: RuntimeSocketEOFReceipt(descriptor: descriptor)
        )
    }

    public func request(
        operation: RuntimeOperationID,
        canonicalUDID: CanonicalUDID,
        body: RepositoryJSONObject,
        activation: RuntimeClientActivation,
        requestID: CanonicalUUID = CanonicalUUID(value: UUID()),
        timeoutSeconds: Int? = Self.requestTimeoutSeconds,
        onPreparationProgress: RuntimeClientPreparationProgressHandler? = nil
    ) throws -> RuntimeClientResponse {
        try request(
            operation: operation,
            canonicalUDID: canonicalUDID,
            body: body,
            activation: activation,
            requestID: requestID,
            clientInstanceID: CanonicalUUID(value: UUID()),
            timeoutSeconds: timeoutSeconds,
            onPreparationProgress: onPreparationProgress
        )
    }

    private func request(
        operation: RuntimeOperationID,
        canonicalUDID: CanonicalUDID,
        body: RepositoryJSONObject,
        activation: RuntimeClientActivation,
        requestID: CanonicalUUID,
        clientInstanceID: CanonicalUUID,
        timeoutSeconds: Int? = Self.requestTimeoutSeconds,
        onPreparationProgress: RuntimeClientPreparationProgressHandler? = nil
    ) throws -> RuntimeClientResponse {
        let (descriptor, acknowledgement) = try openNormalConnection(
            canonicalUDID: canonicalUDID,
            activation: activation,
            clientInstanceID: clientInstanceID,
            timeoutSeconds: timeoutSeconds
        )
        defer { _ = Darwin.close(descriptor) }
        try writeRequest(
            operation: operation,
            body: body,
            requestID: requestID,
            to: descriptor
        )
        while true {
            let bytes = try readFrame(from: descriptor)
            let frame = try RuntimeWireFrameCodec.decode(bytes)
            guard frame.messageType != .protocolError else {
                throw RuntimeClientError.invalidResponse
            }
            if frame.messageType == .progress {
                onPreparationProgress?(try parsePreparationProgress(
                    frame,
                    requestID: requestID
                ))
                continue
            }
            guard frame.messageType == .response else {
                continue
            }
            let response = try parseResponse(
                frame,
                requestID: requestID,
                operation: operation
            )
            return RuntimeClientResponse(
                acknowledgement: acknowledgement,
                result: response
            )
        }
    }

    public func requestScreenshot(
        canonicalUDID: CanonicalUDID,
        body: RepositoryJSONObject,
        activation: RuntimeClientActivation,
        requestID: CanonicalUUID,
        timeoutSeconds: Int = Self.requestTimeoutSeconds,
        onPreparationProgress: RuntimeClientPreparationProgressHandler? = nil
    ) throws -> RuntimeClientScreenshotResponse {
        let (descriptor, acknowledgement) = try openNormalConnection(
            canonicalUDID: canonicalUDID,
            activation: activation,
            timeoutSeconds: timeoutSeconds
        )
        defer { _ = Darwin.close(descriptor) }
        try writeRequest(
            operation: .commandSubmit,
            body: body,
            requestID: requestID,
            to: descriptor
        )
        var artifact: (id: CanonicalUUID, value: ScreenshotReceivedArtifact)?
        while true {
            let received = try readFrameReceivingDescriptor(from: descriptor)
            let frame = try RuntimeWireFrameCodec.decode(received.bytes)
            switch frame.messageType {
            case .progress:
                guard received.descriptor == nil else {
                    _ = Darwin.close(received.descriptor!)
                    throw RuntimeClientError.invalidResponse
                }
                onPreparationProgress?(try parsePreparationProgress(
                    frame,
                    requestID: requestID
                ))
            case .artifactFD:
                guard artifact == nil, let transferred = received.descriptor else {
                    if let transferred = received.descriptor { _ = Darwin.close(transferred) }
                    throw RuntimeClientError.invalidResponse
                }
                artifact = try receiveScreenshotArtifact(
                    frame: frame,
                    descriptor: transferred,
                    requestID: requestID
                )
            case .response:
                guard received.descriptor == nil else {
                    _ = Darwin.close(received.descriptor!)
                    throw RuntimeClientError.invalidResponse
                }
                let response = try parseResponse(
                    frame,
                    requestID: requestID,
                    operation: .commandSubmit
                )
                if response["outcome"]?.stringValue == "succeeded" {
                    guard let artifact,
                          response["value"]?.objectValue?["artifactID"]?.stringValue
                            == artifact.id.canonicalString
                    else {
                        throw RuntimeClientError.invalidResponse
                    }
                    return RuntimeClientScreenshotResponse(
                        acknowledgement: acknowledgement,
                        artifact: artifact.value,
                        result: response
                    )
                }
                guard artifact == nil else {
                    throw RuntimeClientError.invalidResponse
                }
                return RuntimeClientScreenshotResponse(
                    acknowledgement: acknowledgement,
                    artifact: nil,
                    result: response
                )
            case .protocolError:
                if let transferred = received.descriptor { _ = Darwin.close(transferred) }
                throw RuntimeClientError.invalidResponse
            default:
                guard received.descriptor == nil else {
                    _ = Darwin.close(received.descriptor!)
                    throw RuntimeClientError.invalidResponse
                }
            }
        }
    }

    public func requestElementSnapshot(
        canonicalUDID: CanonicalUDID,
        body: RepositoryJSONObject,
        activation: RuntimeClientActivation,
        requestID: CanonicalUUID,
        expectsAnnotation: Bool,
        interruption: RuntimeClientElementSnapshotInterruption? = nil,
        timeoutSeconds: Int = Self.requestTimeoutSeconds,
        onPreparationProgress: RuntimeClientPreparationProgressHandler? = nil
    ) throws -> RuntimeClientElementSnapshotResponse {
        try interruption?.check()
        let clientInstanceID = CanonicalUUID(value: UUID())
        let (descriptor, acknowledgement) = try openNormalConnection(
            canonicalUDID: canonicalUDID,
            activation: activation,
            clientInstanceID: clientInstanceID,
            timeoutSeconds: timeoutSeconds
        )
        defer { _ = Darwin.close(descriptor) }
        do {
            try interruption?.check()
            try writeRequest(
                operation: .commandSubmit,
                body: body,
                requestID: requestID,
                to: descriptor
            )
            let interruptionRegistration = interruption?.register {
                _ = Darwin.shutdown(descriptor, SHUT_RDWR)
                try? sendOwnedCancellation(
                    canonicalUDID: canonicalUDID,
                    targetRequestID: requestID,
                    reason: "clientInterrupted",
                    clientInstanceID: clientInstanceID
                )
            }
            defer {
                if let interruptionRegistration {
                    interruption?.unregister(interruptionRegistration)
                }
            }
            var annotation: RuntimeClientElementAnnotationArtifact?
            while true {
                let received = try readFrameReceivingDescriptor(from: descriptor)
            let frame = try RuntimeWireFrameCodec.decode(received.bytes)
            switch frame.messageType {
            case .progress:
                guard received.descriptor == nil else {
                    _ = Darwin.close(received.descriptor!)
                    throw RuntimeClientError.invalidResponse
                }
                onPreparationProgress?(try parsePreparationProgress(
                    frame,
                    requestID: requestID
                ))
            case .artifactFD:
                    guard expectsAnnotation,
                          annotation == nil,
                          let transferred = received.descriptor
                    else {
                        if let transferred = received.descriptor {
                            _ = Darwin.close(transferred)
                        }
                        throw RuntimeClientError.invalidResponse
                    }
                    annotation = try receiveElementAnnotationArtifact(
                        frame: frame,
                        descriptor: transferred,
                        requestID: requestID
                    )
                case .response:
                    guard received.descriptor == nil else {
                        _ = Darwin.close(received.descriptor!)
                        throw RuntimeClientError.invalidResponse
                    }
                    let response = try parseResponse(
                        frame,
                        requestID: requestID,
                        operation: .commandSubmit
                    )
                    guard response["outcome"]?.stringValue == "succeeded" else {
                        try interruption?.check()
                        guard annotation == nil else {
                            throw RuntimeClientError.invalidResponse
                        }
                        return RuntimeClientElementSnapshotResponse(
                            acknowledgement: acknowledgement,
                            annotation: nil,
                            result: response
                        )
                    }
                    guard let value = response["value"]?.objectValue else {
                        throw RuntimeClientError.invalidResponse
                    }
                    try validateElementSnapshotResponse(
                        value,
                        annotation: annotation,
                        expectsAnnotation: expectsAnnotation
                    )
                    try interruption?.check()
                    return RuntimeClientElementSnapshotResponse(
                        acknowledgement: acknowledgement,
                        annotation: annotation,
                        result: response
                    )
                case .protocolError:
                    if let transferred = received.descriptor {
                        _ = Darwin.close(transferred)
                    }
                    throw RuntimeClientError.invalidResponse
                default:
                    guard received.descriptor == nil else {
                        _ = Darwin.close(received.descriptor!)
                        throw RuntimeClientError.invalidResponse
                    }
                }
            }
        } catch {
            if interruption?.isInterrupted == true {
                interruption?.waitForDelivery(timeoutSeconds: 1)
                throw RuntimeClientError.interrupted
            }
            if let reason = Self.elementCancellationReason(for: error) {
                try? sendOwnedCancellation(
                    canonicalUDID: canonicalUDID,
                    targetRequestID: requestID,
                    reason: reason,
                    clientInstanceID: clientInstanceID
                )
            }
            throw error
        }
    }

    private func sendOwnedCancellation(
        canonicalUDID: CanonicalUDID,
        targetRequestID: CanonicalUUID,
        reason: String,
        clientInstanceID: CanonicalUUID
    ) throws {
        let (descriptor, _) = try openNormalConnection(
            canonicalUDID: canonicalUDID,
            activation: .existingOnly,
            clientInstanceID: clientInstanceID,
            timeoutSeconds: 1
        )
        defer { _ = Darwin.close(descriptor) }
        try writeRequest(
            operation: .runtimeCancelOwnedPendingWork,
            body: try object([
                ("canonicalUDID", .string(canonicalUDID.rawValue)),
                ("reason", .string(reason)),
                (
                    "targetRequestID",
                    .string(targetRequestID.canonicalString)
                ),
            ]),
            requestID: CanonicalUUID(value: UUID()),
            to: descriptor
        )
    }

    private static func elementCancellationReason(for error: Error) -> String? {
        guard case RuntimeClientError.transportFailure(let code) = error else {
            return nil
        }
        if code == EAGAIN || code == EWOULDBLOCK {
            return "clientDeadlineExceeded"
        }
        if code == EINTR {
            return "clientInterrupted"
        }
        return nil
    }

    public func openLiveSession(
        canonicalUDID: CanonicalUDID,
        activation: RuntimeClientActivation
    ) throws -> ProductionRuntimeLiveSession {
        let clientInstanceID = CanonicalUUID(value: UUID())
        let (descriptor, acknowledgement) = try openNormalConnection(
            canonicalUDID: canonicalUDID,
            activation: activation,
            clientInstanceID: clientInstanceID
        )
        return try ProductionRuntimeLiveSession(
            acknowledgement: acknowledgement,
            canonicalUDID: canonicalUDID,
            clientInstanceID: clientInstanceID,
            descriptor: descriptor,
            oneShotSubmitter: { commandID, rawArguments, actionID in
                let arguments = try self.stringObject(rawArguments)
                return try self.request(
                    operation: .commandSubmit,
                    canonicalUDID: canonicalUDID,
                    body: try self.object([
                        ("actionID", .string(actionID.canonicalString)),
                        ("canonicalUDID", .string(canonicalUDID.rawValue)),
                        ("commandID", .string(commandID)),
                        ("normalizedArguments", .object(arguments)),
                    ]),
                    activation: .existingOnly,
                    requestID: CanonicalUUID(value: UUID()),
                    clientInstanceID: clientInstanceID,
                    timeoutSeconds: Self.commandRequestTimeoutSeconds(commandID)
                ).result
            }
        )
    }

    private func openNormalConnection(
        canonicalUDID: CanonicalUDID,
        activation: RuntimeClientActivation,
        clientInstanceID: CanonicalUUID = CanonicalUUID(value: UUID()),
        timeoutSeconds: Int? = Self.requestTimeoutSeconds
    ) throws -> (Int32, RuntimeHelloAck) {
        if case .ensureRunning = activation {
            _ = try RuntimeBootstrapCoordinator().ensureRunning(
                for: canonicalUDID,
                from: canonicalAppPath
            )
        }
        let descriptor: Int32
        do {
            descriptor = try connect(
                canonicalUDID: canonicalUDID,
                timeoutSeconds: timeoutSeconds
            )
        } catch let error as RuntimeClientError {
            guard case .socketUnavailable = error,
                  case .ensureRunning = activation
            else {
                throw error
            }
            // The trusted socket node can survive just long enough for the old
            // Runtime to be classified as alive after its listener has closed.
            // Wait for that verified generation to settle before replacing it.
            _ = try RuntimeBootstrapCoordinator().recoverAfterSocketUnavailable(
                for: canonicalUDID,
                from: canonicalAppPath
            )
            descriptor = try connect(
                canonicalUDID: canonicalUDID,
                timeoutSeconds: timeoutSeconds
            )
        }
        do {
            let hello = try RuntimeHello(
                wireRange: RuntimeWireRange(minimum: 1, maximum: 1),
                clientBuildID: clientBuildID,
                compatibility: compatibility,
                clientInstanceID: clientInstanceID,
                role: role
            )
            try writeAll(
                RuntimeHandshakeCodec.encodeHello(hello),
                to: descriptor
            )
            let helloBytes = try readFrame(from: descriptor)
            let helloFrame = try RuntimeWireFrameCodec.decode(helloBytes)
            if helloFrame.messageType == .helloReject {
                _ = try RuntimeHandshakeCodec.decodeReject(helloBytes)
                throw RuntimeClientError.incompatibleRuntime
            }
            let acknowledgement = try RuntimeHandshakeCodec.decodeAck(helloBytes)
            guard acknowledgement.canonicalUDID == canonicalUDID else {
                throw RuntimeClientError.targetMismatch
            }
            guard acknowledgement.compatibility == compatibility else {
                throw RuntimeClientError.incompatibleRuntime
            }
            guard !acknowledgement.quiescing else {
                throw RuntimeClientError.runtimeStopping
            }
            return (descriptor, acknowledgement)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func bootstrapRequest(
        operation: BootstrapOperation,
        canonicalUDID: CanonicalUDID,
        requestID: CanonicalUUID
    ) throws -> (BootstrapResponse, Int32) {
        let descriptor = try connect(canonicalUDID: canonicalUDID)
        do {
            let hello = try RuntimeHello(
                wireRange: RuntimeWireRange(minimum: 1, maximum: 1),
                clientBuildID: clientBuildID,
                compatibility: compatibility,
                clientInstanceID: CanonicalUUID(value: UUID()),
                role: role
            )
            try writeAll(
                RuntimeHandshakeCodec.encodeHello(hello),
                to: descriptor
            )
            let helloBytes = try readFrame(from: descriptor)
            let helloFrame = try RuntimeWireFrameCodec.decode(helloBytes)
            guard helloFrame.messageType == .helloReject else {
                throw RuntimeClientError.invalidResponse
            }
            _ = try RuntimeHandshakeCodec.decodeReject(helloBytes)

            try writeAll(
                BootstrapControlCodec.encodeRequest(BootstrapRequest(
                    requestID: requestID,
                    operation: operation
                )),
                to: descriptor
            )
            let response = try BootstrapControlCodec.decodeResponse(
                readFrame(from: descriptor)
            )
            guard response.requestID == requestID,
                  response.operation == operation
            else {
                throw RuntimeClientError.invalidResponse
            }
            return (response, descriptor)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func stopTransportResponse(
        result: RepositoryJSONObject,
        descriptor: Int32
    ) throws -> RuntimeStopTransportResponse {
        let outcome = result["outcome"]?.stringValue
        if outcome == StandardOutcome.succeeded.rawValue {
            guard let value = result["value"]?.objectValue,
                  ["alreadyStopping", "stopping"].contains(
                    value["disposition"]?.stringValue
                  )
            else {
                throw RuntimeClientError.invalidResponse
            }
            return RuntimeStopTransportResponse(
                accepted: true,
                errorCode: nil,
                eofReceipt: RuntimeSocketEOFReceipt(descriptor: descriptor)
            )
        }
        guard outcome == StandardOutcome.failed.rawValue,
              let code = result["error"]?.objectValue?["code"]?.stringValue
        else {
            throw RuntimeClientError.invalidResponse
        }
        return RuntimeStopTransportResponse(
            accepted: false,
            errorCode: code,
            eofReceipt: RuntimeSocketEOFReceipt(descriptor: descriptor)
        )
    }

    private func writeRequest(
        operation: RuntimeOperationID,
        body: RepositoryJSONObject,
        requestID: CanonicalUUID,
        to descriptor: Int32
    ) throws {
        let payload = try object([
            ("body", .object(body)),
            ("operation", .string(operation.rawValue)),
        ])
        let request = try object([
            ("payload", .object(payload)),
            ("requestID", .string(requestID.canonicalString)),
            ("schemaVersion", .number(.uint64(1))),
        ])
        try writeAll(
            RuntimeWireFrameCodec.encode(RuntimeWireFrame(
                messageType: .request,
                payload: RepositoryCanonicalJSON.encodeDocument(request)
            )),
            to: descriptor
        )
    }

    private func connect(
        canonicalUDID: CanonicalUDID,
        timeoutSeconds: Int? = Self.requestTimeoutSeconds
    ) throws -> Int32 {
        let path = try RuntimeSocketPath.current(for: canonicalUDID).path
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw RuntimeClientError.socketUnavailable(errno: errno)
        }
        do {
            try configure(descriptor, timeoutSeconds: timeoutSeconds)
            var address = try socketAddress(path: path)
            let addressLength = socklen_t(address.sun_len)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, addressLength)
                }
            }
            guard result == 0 else {
                throw RuntimeClientError.socketUnavailable(errno: errno)
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func configure(
        _ descriptor: Int32,
        timeoutSeconds: Int? = Self.requestTimeoutSeconds
    ) throws {
        if let timeoutSeconds, timeoutSeconds <= 0 {
            throw RuntimeClientError.invalidResponse
        }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw RuntimeClientError.transportFailure(errno: errno)
        }
        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw RuntimeClientError.transportFailure(errno: errno)
        }
        guard let timeoutSeconds else { return }
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, size
        ) == 0,
        setsockopt(
            descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, size
        ) == 0 else {
            throw RuntimeClientError.transportFailure(errno: errno)
        }
    }

    public static func commandRequestTimeoutSeconds(_ commandID: String) -> Int {
        switch commandID {
        case "app.install":
            return installRequestTimeoutSeconds
        case "app.uninstall":
            return uninstallRequestTimeoutSeconds
        default:
            return requestTimeoutSeconds
        }
    }

    private func socketAddress(path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        let offset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)!
        let length = offset + bytes.count + 1
        guard length <= MemoryLayout<sockaddr_un>.size,
              length <= Int(UInt8.max)
        else {
            throw RuntimeClientError.invalidResponse
        }
        var address = sockaddr_un()
        address.sun_len = UInt8(length)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    private func parsePreparationProgress(
        _ frame: RuntimeWireFrame,
        requestID: CanonicalUUID
    ) throws -> PreparationProgressV1 {
        guard frame.messageType == .progress else {
            throw RuntimeClientError.invalidResponse
        }
        let envelope = try RepositoryCanonicalJSON.parseDocument(
            frame.payload,
            maximumByteCount: 16 * 1_024
        )
        let allowedEnvelopeKeys: Set<String> = [
            "payload", "preparationAttemptID", "progressKind", "requestID",
            "schemaVersion",
        ]
        let envelopeKeys = Set(envelope.members.map(\.key))
        guard envelopeKeys.isSubset(of: allowedEnvelopeKeys),
              envelope["schemaVersion"]?.numberValue
                .flatMap({ try? $0.requireUInt64() }) == 1,
              envelope["requestID"]?.stringValue == requestID.canonicalString,
              envelope["progressKind"]?.stringValue == "preparation",
              let payload = envelope["payload"]?.objectValue
        else {
            throw RuntimeClientError.invalidResponse
        }
        let allowedPayloadKeys: Set<String> = [
            "completedBytes", "fraction", "phase", "phaseSequence",
            "preparationAttemptID", "preparationGroupID", "retryAfterMs",
            "sharedAcquisition", "sourceKind", "stateRevision", "totalBytes",
        ]
        let payloadKeys = Set(payload.members.map(\.key))
        guard payloadKeys.isSubset(of: allowedPayloadKeys),
              let phaseText = payload["phase"]?.stringValue,
              let phase = PreparationWirePhase(rawValue: phaseText),
              let phaseSequence = payload["phaseSequence"]?.numberValue
                .flatMap({ try? $0.requireUInt64() }),
              let attemptText = payload["preparationAttemptID"]?.stringValue,
              let attemptID = try? CanonicalUUID(attemptText),
              let groupID = payload["preparationGroupID"]?.stringValue,
              let stateRevision = payload["stateRevision"]?.numberValue
                .flatMap({ try? $0.requireUInt64() })
        else {
            throw RuntimeClientError.invalidResponse
        }
        if let outerAttemptID = envelope["preparationAttemptID"]?.stringValue,
           outerAttemptID != attemptID.canonicalString {
            throw RuntimeClientError.invalidResponse
        }
        let completedBytes = try optionalUInt(payload["completedBytes"])
        let totalBytes = try optionalUInt(payload["totalBytes"])
        let retryAfterMs = try optionalUInt(payload["retryAfterMs"])
        let fraction = try optionalFraction(payload["fraction"])
        let sharedAcquisition = try optionalBool(payload["sharedAcquisition"])
        let sourceKind: PreparationProgressSourceKind?
        if let sourceText = payload["sourceKind"]?.stringValue {
            guard let parsed = PreparationProgressSourceKind(rawValue: sourceText)
            else { throw RuntimeClientError.invalidResponse }
            sourceKind = parsed
        } else if payload["sourceKind"] == nil {
            sourceKind = nil
        } else {
            throw RuntimeClientError.invalidResponse
        }
        do {
            return try PreparationProgressV1(
                completedBytes: completedBytes,
                fraction: fraction,
                phase: phase,
                phaseSequence: phaseSequence,
                preparationAttemptID: attemptID,
                preparationGroupID: groupID,
                retryAfterMs: retryAfterMs,
                sharedAcquisition: sharedAcquisition,
                sourceKind: sourceKind,
                stateRevision: stateRevision,
                totalBytes: totalBytes
            )
        } catch {
            throw RuntimeClientError.invalidResponse
        }
    }

    private func optionalUInt(
        _ value: RepositoryJSONValue?
    ) throws -> UInt64? {
        guard let value else { return nil }
        guard let number = value.numberValue,
              let parsed = try? number.requireUInt64()
        else { throw RuntimeClientError.invalidResponse }
        return parsed
    }

    private func optionalFraction(
        _ value: RepositoryJSONValue?
    ) throws -> Double? {
        guard let value else { return nil }
        guard case .decimal(let decimal)? = value.numberValue,
              let parsed = Double(decimal.canonicalString),
              parsed.isFinite
        else { throw RuntimeClientError.invalidResponse }
        return parsed
    }

    private func optionalBool(
        _ value: RepositoryJSONValue?
    ) throws -> Bool? {
        guard let value else { return nil }
        guard case .bool(let parsed) = value else {
            throw RuntimeClientError.invalidResponse
        }
        return parsed
    }

    private func parseResponse(
        _ frame: RuntimeWireFrame,
        requestID: CanonicalUUID,
        operation: RuntimeOperationID
    ) throws -> RepositoryJSONObject {
        let object = try RepositoryCanonicalJSON.parseDocument(
            frame.payload,
            maximumByteCount: 256 * 1_024
        )
        guard exactKeys(object) == ["payload", "requestID", "schemaVersion"],
              uint(object["schemaVersion"]) == 1,
              object["requestID"]?.stringValue == requestID.canonicalString,
              let payload = object["payload"]?.objectValue,
              payload["operation"]?.stringValue == operation.rawValue,
              let result = payload["result"]?.objectValue
        else {
            throw RuntimeClientError.invalidResponse
        }
        return result
    }

    private func readFrame(from descriptor: Int32) throws -> [UInt8] {
        let header = try readExact(
            RuntimeWireFrame.headerByteCount,
            from: descriptor
        )
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

    private func readFrameReceivingDescriptor(
        from descriptor: Int32
    ) throws -> (bytes: [UInt8], descriptor: Int32?) {
        var header = [UInt8](
            repeating: 0,
            count: RuntimeWireFrame.headerByteCount
        )
        var control = [UInt8](repeating: 0, count: 64)
        var receivedDescriptor: Int32?
        let firstCount = header.withUnsafeMutableBytes { headerBuffer in
            control.withUnsafeMutableBytes { controlBuffer in
                var vector = iovec(
                    iov_base: headerBuffer.baseAddress,
                    iov_len: headerBuffer.count
                )
                return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                    var message = msghdr(
                        msg_name: nil,
                        msg_namelen: 0,
                        msg_iov: vectorPointer,
                        msg_iovlen: 1,
                        msg_control: controlBuffer.baseAddress,
                        msg_controllen: socklen_t(controlBuffer.count),
                        msg_flags: 0
                    )
                    let count = Darwin.recvmsg(descriptor, &message, 0)
                    guard count > 0 else { return count }
                    guard message.msg_flags & MSG_CTRUNC == 0 else { return -2 }
                    if message.msg_controllen > 0 {
                        let alignment = MemoryLayout<UInt32>.alignment
                        let headerSize = Self.aligned(
                            MemoryLayout<cmsghdr>.size,
                            to: alignment
                        )
                        guard Int(message.msg_controllen)
                            >= headerSize + MemoryLayout<Int32>.size
                        else { return -2 }
                        let ancillary = controlBuffer.baseAddress!
                            .assumingMemoryBound(to: cmsghdr.self).pointee
                        guard ancillary.cmsg_level == SOL_SOCKET,
                              ancillary.cmsg_type == SCM_RIGHTS,
                              Int(ancillary.cmsg_len)
                                == headerSize + MemoryLayout<Int32>.size
                        else { return -2 }
                        receivedDescriptor = controlBuffer.load(
                            fromByteOffset: headerSize,
                            as: Int32.self
                        )
                    }
                    return count
                }
            }
        }
        if firstCount == 0 { throw RuntimeClientError.closedBeforeResponse }
        if firstCount == -2 {
            if let receivedDescriptor { _ = Darwin.close(receivedDescriptor) }
            throw RuntimeClientError.invalidResponse
        }
        guard firstCount > 0 else {
            throw RuntimeClientError.transportFailure(errno: errno)
        }
        if let receivedDescriptor,
           fcntl(receivedDescriptor, F_SETFD, FD_CLOEXEC) != 0
        {
            _ = Darwin.close(receivedDescriptor)
            throw RuntimeClientError.transportFailure(errno: errno)
        }
        if firstCount < header.count {
            let remaining = try readExact(
                header.count - firstCount,
                from: descriptor
            )
            header.replaceSubrange(firstCount..<header.count, with: remaining)
        }
        let payloadLength = Int(
            (UInt32(header[12]) << 24)
                | (UInt32(header[13]) << 16)
                | (UInt32(header[14]) << 8)
                | UInt32(header[15])
        )
        guard payloadLength <= 1 * 1_024 * 1_024 else {
            if let receivedDescriptor { _ = Darwin.close(receivedDescriptor) }
            throw RuntimeClientError.invalidResponse
        }
        do {
            return (
                header + (try readExact(payloadLength, from: descriptor)),
                receivedDescriptor
            )
        } catch {
            if let receivedDescriptor { _ = Darwin.close(receivedDescriptor) }
            throw error
        }
    }

    private func receiveScreenshotArtifact(
        frame: RuntimeWireFrame,
        descriptor: Int32,
        requestID: CanonicalUUID
    ) throws -> (id: CanonicalUUID, value: ScreenshotReceivedArtifact) {
        defer { _ = Darwin.close(descriptor) }
        let metadata = try RepositoryCanonicalJSON.parseDocument(
            frame.payload,
            maximumByteCount: 256 * 1_024
        )
        guard exactKeys(metadata) == [
            "artifactID", "captureSHA256", "contentType", "pixelHeight",
            "pixelWidth", "purpose", "requestID", "schemaVersion", "sizeBytes",
            "snapshotGeneration",
        ],
        uint(metadata["schemaVersion"]) == 1,
        metadata["requestID"]?.stringValue == requestID.canonicalString,
        let artifactValue = metadata["artifactID"]?.stringValue,
        let artifactID = try? CanonicalUUID(artifactValue),
        metadata["contentType"]?.stringValue == "image/png",
        metadata["purpose"]?.stringValue == "deviceScreenshot",
        isNull(metadata["captureSHA256"]),
        isNull(metadata["pixelHeight"]),
        isNull(metadata["pixelWidth"]),
        isNull(metadata["snapshotGeneration"]),
        let size = uint(metadata["sizeBytes"]),
        size <= 64 * 1_024 * 1_024
        else {
            throw RuntimeClientError.invalidResponse
        }
        var status = stat()
        let flags = fcntl(descriptor, F_GETFL)
        guard fstat(descriptor, &status) == 0,
              status.st_uid == geteuid(),
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_nlink == 0,
              status.st_size >= 0,
              UInt64(status.st_size) == size,
              flags >= 0,
              flags & O_ACCMODE == O_RDONLY,
              lseek(descriptor, 0, SEEK_SET) == 0
        else {
            throw RuntimeClientError.invalidResponse
        }
        let bytes = try readExact(Int(size), from: descriptor)
        return (
            artifactID,
            try ScreenshotReceivedArtifact(
                bytes: bytes,
                contentType: "image/png",
                readOnly: true
            )
        )
    }

    private func receiveElementAnnotationArtifact(
        frame: RuntimeWireFrame,
        descriptor: Int32,
        requestID: CanonicalUUID
    ) throws -> RuntimeClientElementAnnotationArtifact {
        defer { _ = Darwin.close(descriptor) }
        let metadata = try RepositoryCanonicalJSON.parseDocument(
            frame.payload,
            maximumByteCount: 256 * 1_024
        )
        guard exactKeys(metadata) == [
            "artifactID", "captureSHA256", "contentType", "pixelHeight",
            "pixelWidth", "purpose", "requestID", "schemaVersion", "sizeBytes",
            "snapshotGeneration",
        ],
        uint(metadata["schemaVersion"]) == 1,
        metadata["requestID"]?.stringValue == requestID.canonicalString,
        let artifactValue = metadata["artifactID"]?.stringValue,
        let artifactID = try? CanonicalUUID(artifactValue),
        metadata["contentType"]?.stringValue == "image/png",
        metadata["purpose"]?.stringValue == "elementAnnotation",
        let captureSHA256 = metadata["captureSHA256"]?.stringValue,
        StableBytes.isLowercaseHex(captureSHA256, byteCount: 32),
        let pixelHeight = uint(metadata["pixelHeight"]),
        let pixelWidth = uint(metadata["pixelWidth"]),
        (1...65_535).contains(pixelHeight),
        (1...65_535).contains(pixelWidth),
        let snapshotGeneration = uint(metadata["snapshotGeneration"]),
        snapshotGeneration > 0,
        let size = uint(metadata["sizeBytes"]),
        size > 0,
        size <= 64 * 1_024 * 1_024
        else {
            throw RuntimeClientError.invalidResponse
        }
        var status = stat()
        let flags = fcntl(descriptor, F_GETFL)
        guard fstat(descriptor, &status) == 0,
              status.st_uid == geteuid(),
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_nlink == 0,
              status.st_size >= 0,
              UInt64(status.st_size) == size,
              flags >= 0,
              flags & O_ACCMODE == O_RDONLY,
              lseek(descriptor, 0, SEEK_SET) == 0
        else {
            throw RuntimeClientError.invalidResponse
        }
        let bytes = try readExact(Int(size), from: descriptor)
        return RuntimeClientElementAnnotationArtifact(
            artifact: try ScreenshotReceivedArtifact(
                bytes: bytes,
                contentType: "image/png",
                readOnly: true
            ),
            artifactID: artifactID,
            captureSHA256: captureSHA256,
            pixelHeight: pixelHeight,
            pixelWidth: pixelWidth,
            snapshotGeneration: snapshotGeneration
        )
    }

    private func validateElementSnapshotResponse(
        _ value: RepositoryJSONObject,
        annotation: RuntimeClientElementAnnotationArtifact?,
        expectsAnnotation: Bool
    ) throws {
        guard let capture = value["capture"]?.objectValue,
              let generation = uint(value["snapshotGeneration"]),
              generation > 0,
              let captureSHA256 = capture["sha256"]?.stringValue,
              StableBytes.isLowercaseHex(captureSHA256, byteCount: 32),
              let pixelHeight = uint(capture["pixelHeight"]),
              let pixelWidth = uint(capture["pixelWidth"]),
              (1...65_535).contains(pixelHeight),
              (1...65_535).contains(pixelWidth)
        else {
            throw RuntimeClientError.invalidResponse
        }
        guard expectsAnnotation else {
            guard annotation == nil, value["annotation"] == nil else {
                throw RuntimeClientError.invalidResponse
            }
            return
        }
        guard let annotation,
              let metadata = value["annotation"]?.objectValue,
              exactKeys(metadata) == [
                  "artifactID", "byteLength", "captureSHA256", "contentType",
                  "sha256", "snapshotGeneration",
              ],
              metadata["artifactID"]?.stringValue
                == annotation.artifactID.canonicalString,
              uint(metadata["byteLength"])
                == UInt64(annotation.artifact.bytes.count),
              metadata["captureSHA256"]?.stringValue == captureSHA256,
              metadata["contentType"]?.stringValue == "image/png",
              metadata["sha256"]?.stringValue
                == StableBytes.sha256Hex(annotation.artifact.bytes),
              uint(metadata["snapshotGeneration"]) == generation,
              annotation.captureSHA256 == captureSHA256,
              annotation.pixelHeight == pixelHeight,
              annotation.pixelWidth == pixelWidth,
              annotation.snapshotGeneration == generation
        else {
            throw RuntimeClientError.invalidResponse
        }
    }

    private static func aligned(_ value: Int, to alignment: Int) -> Int {
        (value + alignment - 1) & ~(alignment - 1)
    }

    private func readExact(
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

    private func writeAll(_ bytes: [UInt8], to descriptor: Int32) throws {
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

    private func object(
        _ members: [(String, RepositoryJSONValue)]
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: members.map {
            RepositoryJSONMember(key: $0.0, value: $0.1)
        })
    }

    private func stringObject(
        _ values: [String: String]
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: values.map {
            RepositoryJSONMember(key: $0.key, value: .string($0.value))
        })
    }

    private func exactKeys(_ object: RepositoryJSONObject) -> [String] {
        object.members.map(\.key).sorted()
    }

    private func uint(_ value: RepositoryJSONValue?) -> UInt64? {
        try? value?.numberValue?.requireUInt64()
    }

    private func isNull(_ value: RepositoryJSONValue?) -> Bool {
        guard case .null? = value else { return false }
        return true
    }
}

public final class ProductionRuntimeLiveSession: @unchecked Sendable {
    fileprivate typealias OneShotSubmitter = @Sendable (
        String,
        [String: String],
        CanonicalUUID
    ) throws -> RepositoryJSONObject

    public let acknowledgement: RuntimeHelloAck
    public let canonicalUDID: CanonicalUDID
    public let clientInstanceID: CanonicalUUID

    private let lock = NSLock()
    private let oneShotSubmitter: OneShotSubmitter
    private var attachment: LiveAttachment?
    private var liveOwnershipAttachment: LiveAttachment?
    private var ownedStreams = [CanonicalUUID: ProductionRuntimeLiveStream]()
    private var observationHandler: (@Sendable (RuntimeObservation) -> Void)?
    private var resetHandler: (@Sendable (ObservationStreamReset) -> Void)?
    private var runtimeEventHandler: (@Sendable (RepositoryJSONObject) -> Void)?
    private let transport: ProductionRuntimeLiveTransport
    private var transportFailureHandler: (@Sendable (RuntimeClientError) -> Void)?

    fileprivate init(
        acknowledgement: RuntimeHelloAck,
        canonicalUDID: CanonicalUDID,
        clientInstanceID: CanonicalUUID,
        descriptor: Int32,
        oneShotSubmitter: @escaping OneShotSubmitter
    ) throws {
        self.acknowledgement = acknowledgement
        self.canonicalUDID = canonicalUDID
        self.clientInstanceID = clientInstanceID
        self.oneShotSubmitter = oneShotSubmitter
        do {
            self.transport = try ProductionRuntimeLiveTransport(
                descriptor: descriptor
            )
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
        self.transport.setEventHandler { [weak self] event in
            self?.receiveRuntimeEvent(event)
        }
        self.transport.setObservationHandler { [weak self] observation in
            self?.receiveRuntimeObservation(observation)
        }
        self.transport.setResetHandler { [weak self] reset in
            self?.receiveObservationReset(reset)
        }
        self.transport.setFailureHandler { [weak self] failure in
            self?.receiveTransportFailure(failure)
        }
    }

    deinit {
        closeBestEffort()
    }

    public var currentAttachment: LiveAttachment? {
        lock.lock()
        defer { lock.unlock() }
        return attachment
    }

    public var ownedStreamCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return ownedStreams.count
    }

    public func setRuntimeEventHandler(
        _ handler: (@Sendable (RepositoryJSONObject) -> Void)?
    ) {
        lock.withLock { runtimeEventHandler = handler }
    }

    public func setRuntimeObservationHandler(
        _ handler: (@Sendable (RuntimeObservation) -> Void)?
    ) {
        lock.withLock { observationHandler = handler }
    }

    public func setObservationResetHandler(
        _ handler: (@Sendable (ObservationStreamReset) -> Void)?
    ) {
        lock.withLock { resetHandler = handler }
    }

    public func setTransportFailureHandler(
        _ handler: (@Sendable (RuntimeClientError) -> Void)?
    ) {
        lock.withLock { transportFailureHandler = handler }
    }

    public func attach(
        observationTopics: [String] = [
            "availability", "capability", "deviceCondition", "geometry",
            "preparation", "runtimeState",
        ]
    ) throws -> LiveAttachment {
        lock.lock()
        defer { lock.unlock() }
        guard liveOwnershipAttachment == nil else {
            throw RuntimeClientError.invalidResponse
        }
        let response = try requestLocked(
            operation: .runtimeAttachLive,
            body: try object([
                ("canonicalUDID", .string(canonicalUDID.rawValue)),
                ("observationTopics", .array(observationTopics.map {
                    .string($0)
                })),
            ])
        )
        let value = try succeededValue(response)
        guard let epoch = uint(value["connectionEpoch"]),
              let ownerText = value["liveOwnerID"]?.stringValue,
              let ownerID = try? CanonicalUUID(ownerText),
              let revision = uint(value["stateRevision"]),
              let subscriptionText = value["subscriptionID"]?.stringValue,
              let subscriptionID = try? CanonicalUUID(subscriptionText)
        else {
            throw RuntimeClientError.invalidResponse
        }
        let attached = try LiveAttachment(
            canonicalUDID: canonicalUDID,
            liveOwnerID: ownerID,
            subscriptionID: subscriptionID,
            connectionEpoch: epoch,
            stateRevision: revision
        )
        attachment = attached
        liveOwnershipAttachment = attached
        return attached
    }

    public func availability() throws -> RepositoryJSONObject {
        lock.lock()
        defer { lock.unlock() }
        let value = try succeededValue(requestLocked(
            operation: .runtimeGetAvailabilitySnapshot,
            body: try object([
                ("canonicalUDID", .string(canonicalUDID.rawValue)),
            ])
        ))
        try adoptReconnectSnapshotLocked(value)
        return value
    }

    public func prepareCapabilities() throws -> RepositoryJSONObject {
        lock.lock()
        defer { lock.unlock() }
        return try succeededValue(requestLocked(
            operation: .runtimePrepareCapabilities,
            body: try object([
                ("canonicalUDID", .string(canonicalUDID.rawValue)),
            ])
        ))
    }

    public func markLiveCaptureReady(
        captureActivationID: CanonicalUUID
    ) throws -> ProductionRuntimeCaptureReadyTransition {
        lock.lock()
        defer { lock.unlock() }
        guard let attachment else {
            throw RuntimeClientError.invalidResponse
        }
        let value = try succeededValue(requestLocked(
            operation: .runtimeMarkLiveCaptureReady,
            body: try object([
                ("canonicalUDID", .string(canonicalUDID.rawValue)),
                ("captureActivationID", .string(
                    captureActivationID.canonicalString
                )),
                ("connectionEpoch", .number(.uint64(
                    attachment.connectionEpoch
                ))),
                ("liveOwnerID", .string(
                    attachment.liveOwnerID.canonicalString
                )),
                ("subscriptionID", .string(
                    attachment.subscriptionID.canonicalString
                )),
            ])
        ))
        guard uint(value["connectionEpoch"]) == attachment.connectionEpoch,
              value["captureProvenance"]?.stringValue == "postCapture",
              let disposition = value["disposition"]?.stringValue,
              ["alreadyReady", "deferred", "ready", "replaced"].contains(
                  disposition
              )
        else {
            throw RuntimeClientError.invalidResponse
        }
        return try ProductionRuntimeCaptureReadyTransition(
            value: value,
            expectedConnectionEpoch: attachment.connectionEpoch
        )
    }

    public func submit(
        commandID: String,
        rawArguments: [String: String] = [:],
        actionID: CanonicalUUID = CanonicalUUID(value: UUID())
    ) throws -> RepositoryJSONObject {
        lock.lock()
        defer { lock.unlock() }
        try transport.ensureOpen()
        return try oneShotSubmitter(commandID, rawArguments, actionID)
    }

    public func recordLocalAction(_ body: RepositoryJSONObject) throws {
        try recordLocalAction(
            body,
            requestID: CanonicalUUID(value: UUID())
        )
    }

    public func recordLocalAction(
        _ body: RepositoryJSONObject,
        requestID: CanonicalUUID
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try writeRequest(
            operation: .runtimeRecordLocalAction,
            body: body,
            requestID: requestID
        )
    }

    public func openStream(
        commandID: String,
        rawArguments: [String: String],
        actionID: CanonicalUUID = CanonicalUUID(value: UUID()),
        interactionID: CanonicalUUID = CanonicalUUID(value: UUID())
    ) throws -> ProductionRuntimeLiveStream {
        lock.lock()
        defer { lock.unlock() }
        guard attachment != nil else { throw RuntimeClientError.invalidResponse }
        let intent = try object([
            ("actionID", .string(actionID.canonicalString)),
            ("canonicalUDID", .string(canonicalUDID.rawValue)),
            ("commandID", .string(commandID)),
            ("normalizedArguments", .object(try stringObject(rawArguments))),
        ])
        let response = try requestLocked(
            operation: .streamOpen,
            body: try object([
                ("intent", .object(intent)),
                ("interactionID", .string(interactionID.canonicalString)),
            ])
        )
        let value = try succeededValue(response)
        guard let responseAction = value["actionID"]?.stringValue,
              let returnedActionID = try? CanonicalUUID(responseAction),
              returnedActionID == actionID,
              let generation = uint(value["executorGeneration"]),
              let responseInteraction = value["interactionID"]?.stringValue,
              let returnedInteractionID = try? CanonicalUUID(responseInteraction),
              returnedInteractionID == interactionID,
              let sessionText = value["sessionID"]?.stringValue,
              let sessionID = try? CanonicalUUID(sessionText)
        else {
            throw RuntimeClientError.invalidResponse
        }
        let acceptedGeometry: DisplayGeometryDTO?
        if commandID == "gui.pointer.interaction" {
            guard let connectionEpoch = uint(value["connectionEpoch"]),
                  let geometryRevision = uint(value["geometryRevision"]),
                  let logicalHeight = uint(value["logicalHeight"]),
                  let logicalWidth = uint(value["logicalWidth"]),
                  let orientationText = value["orientation"]?.stringValue,
                  let orientation = DisplayOrientationDTO(rawValue: orientationText),
                  connectionEpoch == attachment?.connectionEpoch,
                  let geometry = try? DisplayGeometryDTO(
                    connectionEpoch: connectionEpoch,
                    geometryRevision: geometryRevision,
                    logicalHeight: logicalHeight,
                    logicalWidth: logicalWidth,
                    orientation: orientation
                  )
            else {
                cancelRejectedStreamLocked(ProductionRuntimeLiveStream(
                    actionID: actionID,
                    executorGeneration: generation,
                    interactionID: interactionID,
                    sessionID: sessionID
                ))
                throw RuntimeClientError.invalidResponse
            }
            acceptedGeometry = geometry
        } else {
            acceptedGeometry = nil
        }
        let stream = ProductionRuntimeLiveStream(
            acceptedGeometry: acceptedGeometry,
            actionID: actionID,
            executorGeneration: generation,
            interactionID: interactionID,
            sessionID: sessionID
        )
        ownedStreams[sessionID] = stream
        return stream
    }

    private func cancelRejectedStreamLocked(_ stream: ProductionRuntimeLiveStream) {
        guard ownedStreams[stream.sessionID] == nil else { return }
        ownedStreams[stream.sessionID] = stream
        defer { ownedStreams.removeValue(forKey: stream.sessionID) }
        _ = try? finishStreamLocked(
            stream,
            operation: .streamCancel,
            reason: "protocolViolation",
            expectedLastSequence: nil
        )
    }

    public func sendFrame(
        stream: ProductionRuntimeLiveStream,
        sequence: UInt64,
        frameKind: String,
        payload: RepositoryJSONObject,
        clientSubmittedMonotonicNanoseconds: UInt64? = nil
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard ownedStreams[stream.sessionID] == stream else {
            throw RuntimeClientError.invalidResponse
        }
        var members: [(String, RepositoryJSONValue)] = [
            ("frameKind", .string(frameKind)),
            ("interactionID", .string(stream.interactionID.canonicalString)),
            ("payload", .object(payload)),
            ("schemaVersion", .number(.uint64(1))),
            ("seq", .number(.uint64(sequence))),
            ("sessionID", .string(stream.sessionID.canonicalString)),
        ]
        if let clientSubmittedMonotonicNanoseconds {
            members.append((
                "clientSubmittedMonotonicNs",
                .number(.uint64(clientSubmittedMonotonicNanoseconds))
            ))
        }
        try transport.send(RuntimeWireFrame(
            messageType: .streamFrame,
            payload: RepositoryCanonicalJSON.encodeDocument(try object(members))
        ))
    }

    @discardableResult
    public func closeStream(
        _ stream: ProductionRuntimeLiveStream,
        expectedLastSequence: UInt64? = nil,
        reason: String = "completed"
    ) throws -> RepositoryJSONObject {
        try finishStream(
            stream,
            operation: .streamClose,
            reason: reason,
            expectedLastSequence: expectedLastSequence
        )
    }

    @discardableResult
    public func cancelStream(
        _ stream: ProductionRuntimeLiveStream,
        reason: String = "ownerLost"
    ) throws -> RepositoryJSONObject {
        try finishStream(
            stream,
            operation: .streamCancel,
            reason: reason,
            expectedLastSequence: nil
        )
    }

    @discardableResult
    public func detach() throws -> LiveDetachResult {
        lock.lock()
        defer { lock.unlock() }
        return try detachLocked()
    }

    public func close() throws {
        lock.lock()
        defer { lock.unlock() }
        guard transport.isOpen else {
            attachment = nil
            liveOwnershipAttachment = nil
            ownedStreams.removeAll()
            transport.close()
            return
        }
        var firstError: Error?
        for stream in ownedStreams.values.sorted(by: {
            $0.sessionID.canonicalString < $1.sessionID.canonicalString
        }) {
            do {
                _ = try finishStreamLocked(
                    stream,
                    operation: .streamCancel,
                    reason: "ownerLost",
                    expectedLastSequence: nil
                )
            } catch {
                if firstError == nil { firstError = error }
                ownedStreams.removeValue(forKey: stream.sessionID)
            }
        }
        if liveOwnershipAttachment != nil {
            do { _ = try detachLocked() }
            catch { if firstError == nil { firstError = error } }
        }
        transport.close()
        attachment = nil
        liveOwnershipAttachment = nil
        ownedStreams.removeAll()
        if let firstError { throw firstError }
    }

    private func closeBestEffort() {
        try? close()
    }

    private func finishStream(
        _ stream: ProductionRuntimeLiveStream,
        operation: RuntimeOperationID,
        reason: String,
        expectedLastSequence: UInt64?
    ) throws -> RepositoryJSONObject {
        lock.lock()
        defer { lock.unlock() }
        return try finishStreamLocked(
            stream,
            operation: operation,
            reason: reason,
            expectedLastSequence: expectedLastSequence
        )
    }

    private func finishStreamLocked(
        _ stream: ProductionRuntimeLiveStream,
        operation: RuntimeOperationID,
        reason: String,
        expectedLastSequence: UInt64?
    ) throws -> RepositoryJSONObject {
        guard ownedStreams[stream.sessionID] == stream else {
            throw RuntimeClientError.invalidResponse
        }
        var members: [(String, RepositoryJSONValue)] = [
            ("interactionID", .string(stream.interactionID.canonicalString)),
            ("reason", .string(reason)),
            ("sessionID", .string(stream.sessionID.canonicalString)),
        ]
        if let expectedLastSequence {
            members.append((
                "expectedLastSeq", .number(.uint64(expectedLastSequence))
            ))
        }
        let response = try requestLocked(
            operation: operation,
            body: try object(members)
        )
        let value = try succeededValue(response)
        ownedStreams.removeValue(forKey: stream.sessionID)
        return value
    }

    private func detachLocked() throws -> LiveDetachResult {
        guard ownedStreams.isEmpty else { throw RuntimeClientError.invalidResponse }
        guard let attachment = liveOwnershipAttachment else {
            return LiveDetachResult(detached: true)
        }
        let response = try requestLocked(
            operation: .runtimeDetachLive,
            body: try object([
                ("canonicalUDID", .string(canonicalUDID.rawValue)),
                ("liveOwnerID", .string(attachment.liveOwnerID.canonicalString)),
                ("subscriptionID", .string(attachment.subscriptionID.canonicalString)),
            ])
        )
        let value = try succeededValue(response)
        guard case .bool(true)? = value["detached"] else {
            throw RuntimeClientError.invalidResponse
        }
        self.attachment = nil
        liveOwnershipAttachment = nil
        return LiveDetachResult(detached: true)
    }

    private func receiveRuntimeEvent(_ event: RepositoryJSONObject) {
        guard uint(event["schemaVersion"]) == 1,
              event["connectionID"]?.stringValue
                == acknowledgement.connectionID.canonicalString,
              let kind = event["eventKind"]?.stringValue
        else { return }
        if kind == "deviceDisconnected",
           let disconnectedEpoch = uint(event["connectionEpoch"])
        {
            lock.withLock {
                guard let ownership = liveOwnershipAttachment,
                      ownership.connectionEpoch == disconnectedEpoch
                else { return }
                attachment = nil
                ownedStreams.removeAll()
            }
        } else if kind == "availabilityInvalidated" {
            lock.withLock {
                guard liveOwnershipAttachment != nil else { return }
                guard let response = try? requestLocked(
                    operation: .runtimeGetAvailabilitySnapshot,
                    body: try object([
                        ("canonicalUDID", .string(canonicalUDID.rawValue)),
                    ])
                ),
                let value = try? succeededValue(response)
                else { return }
                try? adoptReconnectSnapshotLocked(value)
            }
        }
        let handler = lock.withLock { runtimeEventHandler }
        handler?(event)
    }

    private func receiveRuntimeObservation(_ observation: RuntimeObservation) {
        let handler = lock.withLock { observationHandler }
        handler?(observation)
    }

    private func receiveObservationReset(_ reset: ObservationStreamReset) {
        let handler = lock.withLock { resetHandler }
        handler?(reset)
    }

    private func receiveTransportFailure(_ failure: RuntimeClientError) {
        let handler = lock.withLock { () -> (@Sendable (RuntimeClientError) -> Void)? in
            attachment = nil
            ownedStreams.removeAll()
            return transportFailureHandler
        }
        handler?(failure)
    }

    private func adoptReconnectSnapshotLocked(
        _ snapshot: RepositoryJSONObject
    ) throws {
        guard let ownership = liveOwnershipAttachment,
              let connectionEpoch = uint(snapshot["connectionEpoch"]),
              let stateRevision = uint(snapshot["stateRevision"]),
              connectionEpoch > ownership.connectionEpoch
        else { return }
        let replacement = try LiveAttachment(
            canonicalUDID: ownership.canonicalUDID,
            liveOwnerID: ownership.liveOwnerID,
            subscriptionID: ownership.subscriptionID,
            connectionEpoch: connectionEpoch,
            stateRevision: stateRevision
        )
        attachment = replacement
        liveOwnershipAttachment = replacement
        ownedStreams.removeAll()
    }

    private func requestLocked(
        operation: RuntimeOperationID,
        body: RepositoryJSONObject,
        requestID: CanonicalUUID = CanonicalUUID(value: UUID())
    ) throws -> RepositoryJSONObject {
        let frame = try transport.request(
            requestFrame(
                operation: operation,
                body: body,
                requestID: requestID
            ),
            requestID: requestID
        )
        return try parseResponse(
            frame,
            requestID: requestID,
            operation: operation
        )
    }

    private func succeededValue(
        _ result: RepositoryJSONObject
    ) throws -> RepositoryJSONObject {
        guard result["outcome"]?.stringValue == "succeeded",
              let value = result["value"]?.objectValue
        else {
            let code = result["error"]?.objectValue?["code"]?.stringValue
                ?? "outcomeUnknown"
            throw ProductionRuntimeLiveSessionError.operationFailed(code: code)
        }
        return value
    }

    private func writeRequest(
        operation: RuntimeOperationID,
        body: RepositoryJSONObject,
        requestID: CanonicalUUID
    ) throws {
        try transport.send(requestFrame(
            operation: operation,
            body: body,
            requestID: requestID
        ))
    }

    private func requestFrame(
        operation: RuntimeOperationID,
        body: RepositoryJSONObject,
        requestID: CanonicalUUID
    ) throws -> RuntimeWireFrame {
        let payload = try object([
            ("body", .object(body)),
            ("operation", .string(operation.rawValue)),
        ])
        let request = try object([
            ("payload", .object(payload)),
            ("requestID", .string(requestID.canonicalString)),
            ("schemaVersion", .number(.uint64(1))),
        ])
        return RuntimeWireFrame(
            messageType: .request,
            payload: RepositoryCanonicalJSON.encodeDocument(request)
        )
    }

    private func parseResponse(
        _ frame: RuntimeWireFrame,
        requestID: CanonicalUUID,
        operation: RuntimeOperationID
    ) throws -> RepositoryJSONObject {
        let object = try RepositoryCanonicalJSON.parseDocument(
            frame.payload,
            maximumByteCount: 256 * 1_024
        )
        guard object.members.map(\.key).sorted() == [
            "payload", "requestID", "schemaVersion",
        ],
        uint(object["schemaVersion"]) == 1,
        object["requestID"]?.stringValue == requestID.canonicalString,
        let payload = object["payload"]?.objectValue,
        payload["operation"]?.stringValue == operation.rawValue,
        let result = payload["result"]?.objectValue
        else {
            throw RuntimeClientError.invalidResponse
        }
        return result
    }

    private func stringObject(
        _ values: [String: String]
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: values.map {
            RepositoryJSONMember(key: $0.key, value: .string($0.value))
        })
    }

    private func object(
        _ members: [(String, RepositoryJSONValue)]
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: members.map {
            RepositoryJSONMember(key: $0.0, value: $0.1)
        })
    }

    private func uint(_ value: RepositoryJSONValue?) -> UInt64? {
        try? value?.numberValue?.requireUInt64()
    }
}

public struct ProductionCommandSubmissionRuntime: CommandSubmissionRuntime {
    private let client: RuntimeClient
    private let canonicalUDID: CanonicalUDID

    public init(client: RuntimeClient, canonicalUDID: CanonicalUDID) {
        self.client = client
        self.canonicalUDID = canonicalUDID
    }

    public func submit(
        _ intent: CommandSubmissionIntent
    ) throws -> [CommandSubmissionEvent] {
        guard intent.canonicalUDID == canonicalUDID else {
            throw RuntimeClientError.targetMismatch
        }
        let arguments = try RepositoryJSONObject(members:
            intent.rawArguments.map {
                RepositoryJSONMember(key: $0.key, value: .string($0.value))
            }
        )
        let body = try RepositoryJSONObject(members: [
            RepositoryJSONMember(
                key: "actionID",
                value: .string(intent.actionID.canonicalString)
            ),
            RepositoryJSONMember(
                key: "canonicalUDID",
                value: .string(canonicalUDID.rawValue)
            ),
            RepositoryJSONMember(key: "commandID", value: .string(intent.commandID)),
            RepositoryJSONMember(
                key: "normalizedArguments",
                value: .object(arguments)
            ),
        ])
        let response = try client.request(
            operation: .commandSubmit,
            canonicalUDID: canonicalUDID,
            body: body,
            activation: .ensureRunning,
            requestID: intent.requestID,
            timeoutSeconds: RuntimeClient.commandRequestTimeoutSeconds(
                intent.commandID
            )
        )
        let outcome = StandardOutcome(
            rawValue: response.result["outcome"]?.stringValue ?? ""
        ) ?? .outcomeUnknown
        let commitState = CommitState(
            rawValue: response.result["commitState"]?.stringValue ?? ""
        ) ?? .unknown
        let errorCode = response.result["error"]?.objectValue?["code"]?.stringValue
        let routeID = response.result["value"]?.objectValue?["resolvedRouteID"]?
            .stringValue ?? "runtime.production"
        let terminal = try CommandSubmissionTerminal(
            outcome: outcome,
            commitState: commitState,
            routeID: routeID,
            errorCode: outcome == .succeeded ? nil : (errorCode ?? "outcomeUnknown")
        )
        return [
            .accepted,
            .authoritativePlan(
                routeID: routeID,
                sourceRevision: 0,
                resumedAfterPreparation: false
            ),
            .queued,
            .terminal(terminal),
        ]
    }
}
