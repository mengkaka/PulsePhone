import Darwin
import Dispatch
import Foundation
import OSLog
import PulsePhoneHostPaths
import PulsePhoneRuntimeKernel
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions
import PulsePhoneWire

enum ProductionCoreDeviceHelperExecutorError: Error, Equatable, Sendable {
    case helperUnavailableBeforeRequest
    case inactive
    case invalidBundledResources
    case invalidHelperMessage
    case invalidRequest
    case resourceBusy
    case helperRejected(code: String, phase: String?)
    case processExited
    case timedOut
    case transportFailure(errno: Int32)
}

enum ProductionCoreDeviceHelperOperationStage: String, Equatable, Sendable {
    case frameAccepted
    case generationReplacement
    case helperStartup
    case oneShot
    case streamCleanup
    case streamOpen
}

enum ProductionCoreDeviceHelperFailureStage: String, Equatable, Sendable {
    case cleanup
    case frameAccepted
    case helperHello
    case helperSpawn
    case inputServiceOpen
    case transport
    case tunnelOrRSD
}

struct ProductionCoreDeviceHelperDiagnosticSnapshot: Equatable, Sendable {
    let activeExecutorGeneration: UInt64?
    let activeProvenance: ProductionCoreDeviceCaptureProvenance?
    let activeStreamCount: Int
    let captureReplacementPending: Bool
    let connectionEpoch: UInt64?
    let lastErrorCode: String?
    let lastFailureOperation: ProductionCoreDeviceHelperOperationStage?
    let lastFailureStage: ProductionCoreDeviceHelperFailureStage?
}

enum ProductionCoreDeviceCaptureProvenance: String, Equatable, Sendable {
    case preCapture
    case postCapture
}

enum ProductionHelperExecutorMode: Equatable, Sendable {
    case coreDevice
    case direct
}

// This is intentionally internal and only passed by test fixtures. Production
// construction always resolves the signed helper from the bundle.
struct TestOnlyHelperLaunchOverride: Sendable {
    let executableURL: URL
    let leadingArguments: [String]

    init(executableURL: URL, leadingArguments: [String] = []) {
        self.executableURL = executableURL
        self.leadingArguments = leadingArguments
    }
}

final class ProductionHelperSupervisorRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let runtimeEpoch: UInt64
    private var supervisor: HelperSupervisor?

    init(runtimeEpoch: UInt64) {
        self.runtimeEpoch = runtimeEpoch
    }

    func bind(manifestStore: HelperManifestStore) {
        lock.withLock {
            guard supervisor == nil else { return }
            supervisor = HelperSupervisor(
                runtimeEpoch: runtimeEpoch,
                manifestStore: manifestStore
            )
        }
    }

    func spawn(
        _ configuration: HelperLaunchConfiguration,
        inheritedRuntimeLockDescriptor: Int32
    ) throws -> SpawnedHelper {
        try lock.withLock {
            guard var current = supervisor else {
                throw ProductionCoreDeviceHelperExecutorError.inactive
            }
            let spawned = try current.spawn(
                configuration,
                inheritedRuntimeLockDescriptor: inheritedRuntimeLockDescriptor
            )
            supervisor = current
            return spawned
        }
    }

    func acceptHello(
        _ hello: HelperHello,
        from helperID: String
    ) throws -> HelperAcceptance {
        try lock.withLock {
            guard var current = supervisor else {
                throw ProductionCoreDeviceHelperExecutorError.inactive
            }
            let acceptance = try current.acceptHello(hello, from: helperID)
            supervisor = current
            return acceptance
        }
    }

    func remove(helperID: String) throws {
        try lock.withLock {
            guard var current = supervisor else {
                throw ProductionCoreDeviceHelperExecutorError.inactive
            }
            try current.remove(helperID: helperID)
            supervisor = current
        }
    }
}

enum ProductionCoreDeviceCaptureTransitionDecision: Equatable, Sendable {
    case alreadyReady
    case deferred
    case ready
    case replace(oldExecutorGeneration: UInt64)
}

struct ProductionCoreDeviceCaptureState: Equatable, Sendable {
    private(set) var captureReady = false
    private(set) var connectionEpoch: UInt64?
    private(set) var replacementPending = false

    mutating func provenanceForSpawn(
        connectionEpoch: UInt64
    ) -> ProductionCoreDeviceCaptureProvenance {
        synchronize(connectionEpoch: connectionEpoch)
        return captureReady ? .postCapture : .preCapture
    }

    mutating func noteCaptureReady(
        connectionEpoch: UInt64,
        activeProvenance: ProductionCoreDeviceCaptureProvenance?,
        activeExecutorGeneration: UInt64?,
        hasActiveWork: Bool
    ) -> ProductionCoreDeviceCaptureTransitionDecision {
        synchronize(connectionEpoch: connectionEpoch)
        captureReady = true
        guard let activeProvenance,
              let activeExecutorGeneration
        else {
            replacementPending = false
            return .ready
        }
        guard activeProvenance == .preCapture else {
            replacementPending = false
            return .alreadyReady
        }
        replacementPending = true
        return hasActiveWork
            ? .deferred
            : .replace(oldExecutorGeneration: activeExecutorGeneration)
    }

    mutating func noteCaptureReadyWhileOneShotActive(
        connectionEpoch: UInt64
    ) -> ProductionCoreDeviceCaptureTransitionDecision {
        synchronize(connectionEpoch: connectionEpoch)
        captureReady = true
        replacementPending = true
        return .deferred
    }

    mutating func pendingDecision(
        connectionEpoch: UInt64,
        activeProvenance: ProductionCoreDeviceCaptureProvenance?,
        activeExecutorGeneration: UInt64?,
        hasActiveWork: Bool
    ) -> ProductionCoreDeviceCaptureTransitionDecision? {
        synchronize(connectionEpoch: connectionEpoch)
        guard replacementPending else { return nil }
        return noteCaptureReady(
            connectionEpoch: connectionEpoch,
            activeProvenance: activeProvenance,
            activeExecutorGeneration: activeExecutorGeneration,
            hasActiveWork: hasActiveWork
        )
    }

    mutating func replacementFinished(connectionEpoch: UInt64) {
        synchronize(connectionEpoch: connectionEpoch)
        replacementPending = false
    }

    mutating func resetAfterDetach(connectionEpoch: UInt64) {
        guard self.connectionEpoch == connectionEpoch else { return }
        self = ProductionCoreDeviceCaptureState()
    }

    private mutating func synchronize(connectionEpoch: UInt64) {
        guard self.connectionEpoch != connectionEpoch else { return }
        self.connectionEpoch = connectionEpoch
        captureReady = false
        replacementPending = false
    }
}

struct ProductionCoreDeviceCaptureReadyResult: Equatable, Sendable {
    enum Disposition: String, Equatable, Sendable {
        case alreadyReady
        case deferred
        case ready
        case replaced
    }

    let connectionEpoch: UInt64
    let disposition: Disposition
    let newExecutorGeneration: UInt64?
    let oldExecutorGeneration: UInt64?
}

final class ProductionCoreDeviceHelperExecutor: @unchecked Sendable {
    private struct RuntimeContext {
        let runtimeLock: RuntimeLock
        let manifestStore: HelperManifestStore
    }

    private struct StreamRecord {
        let actionID: CanonicalUUID
        let deliveryAttemptID: String
        let interactionID: CanonicalUUID
        let routeID: String
        let ownerClientInstanceID: CanonicalUUID?
        var lastAcceptedSequence: UInt64?
        var lifecycleToken: ShutdownInhibitorToken?
    }

    private final class ActiveHelper {
        let captureProvenance: ProductionCoreDeviceCaptureProvenance
        let connectionEpoch: UInt64
        let device: ProductionRuntimeDeviceObservation
        let executorGeneration: UInt64
        let helperID: String
        let rawTransportUDID: String
        let spawned: SpawnedHelper
        var inputBuffer = [UInt8]()
        var machine: HelperWireProtocolMachine
        var streams = [String: StreamRecord]()

        init(
            captureProvenance: ProductionCoreDeviceCaptureProvenance,
            connectionEpoch: UInt64,
            device: ProductionRuntimeDeviceObservation,
            executorGeneration: UInt64,
            helperID: String,
            rawTransportUDID: String,
            spawned: SpawnedHelper,
            machine: HelperWireProtocolMachine
        ) {
            self.captureProvenance = captureProvenance
            self.connectionEpoch = connectionEpoch
            self.device = device
            self.executorGeneration = executorGeneration
            self.helperID = helperID
            self.rawTransportUDID = rawTransportUDID
            self.spawned = spawned
            self.machine = machine
        }
    }

    private static let coreDeviceHelperBuildID = "pulsephone.coredevice-helper.v1"
    private static let directHelperBuildID = "pulsephone.direct-helper.v1"
    static let appListDeadlineMilliseconds: Int32 = 30 * 1_000
    static let installDeadlineMilliseconds: Int32 = 30 * 60 * 1_000
    static let uninstallDeadlineMilliseconds: Int32 = 5 * 60 * 1_000
    static let appLaunchDeadlineMilliseconds: Int32 = 60 * 1_000
    // The direct helper owns a five-minute device-side classic mount budget.
    // The Runtime deadline additionally covers helper startup and receipt of its
    // terminal HelperWire message, so a device-side timeout remains observable.
    static let legacyDeveloperSupportMountDeadlineMilliseconds: Int32 =
        5 * 60 * 1_000 + 30 * 1_000
    static let coreDeviceDeveloperSupportPersonalizationDeadlineMilliseconds: Int32 =
        5 * 60 * 1_000
    static let coreDeviceDeveloperSupportMountDeadlineMilliseconds: Int32 =
        5 * 60 * 1_000
    static let legacyDeveloperSupportProbeDeadlineMilliseconds: Int32 =
        30 * 1_000
    static let legacyDeveloperSupportQueryDeadlineMilliseconds: Int32 =
        10 * 1_000
    static let coreDeviceDeveloperSupportQueryDeadlineMilliseconds: Int32 =
        10 * 1_000
    static let screenshotDeadlineMilliseconds: Int32 = 30 * 1_000
    private static let helperManifestHash =
        ProductionRuntimeServer.executionCatalogHash
    private static let transitionLogger = Logger(
        subsystem: "com.pulsephone.PulsePhoneRuntime",
        category: "capture-generation"
    )
    private static let failureLogger = Logger(
        subsystem: "com.pulsephone.PulsePhoneRuntime",
        category: "coredevice-helper"
    )
    private static let toolbarLatencyLogger = Logger(
        subsystem: "com.pulsephone.PulsePhoneRuntime",
        category: "toolbar-latency"
    )
    private static let geometryStageTraceLogger = Logger(
        subsystem: "com.pulsephone.PulsePhoneRuntime",
        category: "touch-stage-trace"
    )

    static func tracesOneShotRequest(routeID: String) -> Bool {
        routeID.hasPrefix("coredevice.button.")
            || routeID == "coredevice.orientation.rotate"
            || routeID == "coredevice.softwareKeyboardToggle"
    }

    private let captureStateLock = NSLock()
    private let frameAcknowledgementTimeoutMilliseconds: Int32
    private let helperHandshakeTimeoutMilliseconds: Int32
    private let inputTimeoutMilliseconds: Int32
    private let mode: ProductionHelperExecutorMode
    private let runtimeEpoch: UInt64
    private let resourcesURL: URL
    private let supervisorRegistry: ProductionHelperSupervisorRegistry
    private let streamBarrierTimeoutMilliseconds: Int32
    private let testOnlyHelperLaunchOverride: TestOnlyHelperLaunchOverride?
    private let keyboardActivityLock = NSLock()
    private let lock = NSLock()
    private var context: RuntimeContext?
    private var active: ActiveHelper?
    private var activeOneShotCount = 0
    private var keyboardOneShotActive = false
    private var keyboardStreamOpenPending = false
    private var keyboardStreamSessionIDs = Set<String>()
    private var captureState = ProductionCoreDeviceCaptureState()
    private var lastFailure: (
        connectionEpoch: UInt64,
        errorCode: String,
        operation: ProductionCoreDeviceHelperOperationStage,
        stage: ProductionCoreDeviceHelperFailureStage
    )?
    private var nextExecutorGeneration: UInt64 = 1

    init(
        runtimeEpoch: UInt64,
        resourcesURL: URL,
        mode: ProductionHelperExecutorMode = .coreDevice,
        supervisorRegistry: ProductionHelperSupervisorRegistry? = nil,
        inputTimeoutMilliseconds: Int32 = 60_000,
        helperHandshakeTimeoutMilliseconds: Int32 = 5_000,
        streamBarrierTimeoutMilliseconds: Int32 = 2_000,
        frameAcknowledgementTimeoutMilliseconds: Int32 = 1_000,
        testOnlyHelperLaunchOverride: TestOnlyHelperLaunchOverride? = nil
    ) {
        precondition(inputTimeoutMilliseconds > 0)
        precondition(helperHandshakeTimeoutMilliseconds > 0)
        precondition(streamBarrierTimeoutMilliseconds > 0)
        precondition(frameAcknowledgementTimeoutMilliseconds > 0)
        self.frameAcknowledgementTimeoutMilliseconds =
            frameAcknowledgementTimeoutMilliseconds
        self.helperHandshakeTimeoutMilliseconds = helperHandshakeTimeoutMilliseconds
        self.inputTimeoutMilliseconds = inputTimeoutMilliseconds
        self.mode = mode
        self.runtimeEpoch = runtimeEpoch
        self.resourcesURL = resourcesURL
        self.supervisorRegistry = supervisorRegistry
            ?? ProductionHelperSupervisorRegistry(runtimeEpoch: runtimeEpoch)
        self.streamBarrierTimeoutMilliseconds = streamBarrierTimeoutMilliseconds
        self.testOnlyHelperLaunchOverride = testOnlyHelperLaunchOverride
    }

    static func bundled(
        runtimeEpoch: UInt64,
        supervisorRegistry: ProductionHelperSupervisorRegistry? = nil
    ) throws -> ProductionCoreDeviceHelperExecutor {
        ProductionCoreDeviceHelperExecutor(
            runtimeEpoch: runtimeEpoch,
            resourcesURL: try ProductionRuntimeDeviceCoordinator.bundledContractRoot(),
            supervisorRegistry: supervisorRegistry
        )
    }

    static func bundledDirect(
        runtimeEpoch: UInt64,
        supervisorRegistry: ProductionHelperSupervisorRegistry? = nil
    ) throws -> ProductionCoreDeviceHelperExecutor {
        ProductionCoreDeviceHelperExecutor(
            runtimeEpoch: runtimeEpoch,
            resourcesURL: try ProductionRuntimeDeviceCoordinator.bundledContractRoot(),
            mode: .direct,
            supervisorRegistry: supervisorRegistry
        )
    }

    private var lifecycle: RuntimeLifecycleController?

    func bindLifecycle(_ controller: RuntimeLifecycleController) {
        lock.withLock { lifecycle = controller }
    }

    func bind(runtimeLock: RuntimeLock, manifestStore: HelperManifestStore) {
        lock.lock()
        defer { lock.unlock() }
        context = RuntimeContext(
            runtimeLock: runtimeLock,
            manifestStore: manifestStore
        )
        supervisorRegistry.bind(manifestStore: manifestStore)
    }

    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        stopActiveHelper()
        context = nil
    }

    func testOnlyPerformStartupHandshake(
        device: ProductionRuntimeDeviceObservation,
        connectionEpoch: UInt64
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try ensureActive(
            device: device,
            connectionEpoch: connectionEpoch,
            operation: .helperStartup
        )
    }

    func retireForDetach(connectionEpoch: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if active?.connectionEpoch == connectionEpoch {
            stopActiveHelper()
        }
        captureStateLock.withLock {
            captureState.resetAfterDetach(connectionEpoch: connectionEpoch)
        }
        if lastFailure?.connectionEpoch == connectionEpoch {
            lastFailure = nil
        }
    }

    func diagnosticSnapshot() -> ProductionCoreDeviceHelperDiagnosticSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let capture = captureStateLock.withLock {
            (captureState.connectionEpoch, captureState.replacementPending)
        }
        let connectionEpoch = active?.connectionEpoch ?? capture.0
        let currentFailure = lastFailure.flatMap {
            $0.connectionEpoch == connectionEpoch ? $0 : nil
        }
        return ProductionCoreDeviceHelperDiagnosticSnapshot(
            activeExecutorGeneration: active?.executorGeneration,
            activeProvenance: active?.captureProvenance,
            activeStreamCount: active?.streams.count ?? 0,
            captureReplacementPending: capture.1,
            connectionEpoch: connectionEpoch,
            lastErrorCode: currentFailure?.errorCode,
            lastFailureOperation: currentFailure?.operation,
            lastFailureStage: currentFailure?.stage
        )
    }

    func executeOneShot(
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        parentActionID: CanonicalUUID?,
        routeID: String,
        backendPayload: [String: HelperWireJSONValue],
        device: ProductionRuntimeDeviceObservation,
        connectionEpoch: UInt64,
        completionBarrierTimeoutMilliseconds: Int32? = nil,
        onAccepted: (@Sendable () -> Void)? = nil,
        cancellation: ProductionElementSnapshotCancellation? = nil
    ) throws -> RepositoryJSONObject {
        try cancellation?.check()
        let holdsKeyboardResource = try beginKeyboardOneShot(routeID: routeID)
        defer {
            if holdsKeyboardResource { endKeyboardOneShot() }
        }
        beginOneShot()
        defer { endOneShot() }
        lock.lock()
        defer { lock.unlock() }
        defer {
            if mode == .direct { stopActiveHelper() }
        }
        let helper: ActiveHelper
        do {
            helper = try ensureActive(
                device: device,
                connectionEpoch: connectionEpoch,
                operation: .oneShot,
                cancellation: cancellation
            )
        } catch {
            guard mode == .direct else { throw error }
            throw ProductionCoreDeviceHelperExecutorError
                .helperUnavailableBeforeRequest
        }
        let result = try executeOneShotLocked(
            requestID: requestID,
            actionID: actionID,
            parentActionID: parentActionID,
            routeID: routeID,
            backendPayload: backendPayload,
            helper: helper,
            operation: .oneShot,
            onAccepted: onAccepted,
            cancellation: cancellation
        )
        if try Self.resultRetiresGeneration(routeID: routeID, result: result) {
            stopActiveHelper()
        }
        if let completionBarrierTimeoutMilliseconds {
            do {
                try sendBarrier(
                    through: helper,
                    timeoutMilliseconds: completionBarrierTimeoutMilliseconds
                )
            } catch {
                recordFailureLocked(
                    error,
                    operation: .oneShot,
                    stage: .cleanup,
                    connectionEpoch: helper.connectionEpoch,
                    executorGeneration: helper.executorGeneration
                )
                stopActiveHelper()
                throw error
            }
        }
        return result
    }

    static func resultRetiresGeneration(
        routeID: String,
        result: RepositoryJSONObject
    ) throws -> Bool {
        guard let value = result["value"]?.objectValue,
              let disposition = value["generationDisposition"]
        else {
            return false
        }
        guard routeID == "coredevice.screenshot",
              result["outcome"]?.stringValue == "succeeded",
              disposition.stringValue == "retiringAfterResult"
        else {
            throw ProductionCoreDeviceHelperExecutorError.invalidHelperMessage
        }
        return true
    }

    private func executeOneShotLocked(
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        parentActionID: CanonicalUUID?,
        routeID: String,
        backendPayload: [String: HelperWireJSONValue],
        helper: ActiveHelper,
        operation: ProductionCoreDeviceHelperOperationStage,
        onAccepted: (@Sendable () -> Void)?,
        cancellation: ProductionElementSnapshotCancellation? = nil
    ) throws -> RepositoryJSONObject {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let tracesToolbarLatency = Self.tracesOneShotRequest(routeID: routeID)
        let tracesGeometryStage = routeID == "coredevice.displayGeometry.query"
            && ProcessInfo.processInfo.environment[
                "PULSEPHONE_RUNTIME_TOUCH_STAGE_TRACE"
            ] == "1"
        let operationDeadlineNanoseconds = Self.oneShotDeadlineNanoseconds(
            routeID: routeID,
            startedAt: startedAt
        )
        var payload: [String: HelperWireJSONValue] = [
            "actionID": .string(actionID.canonicalString),
            "backendPayload": .object(backendPayload),
            "executorOperationID": .string(routeID),
        ]
        if let parentActionID {
            payload["parentActionID"] = .string(parentActionID.canonicalString)
        }
        var acceptedNotified = false
        do {
            if tracesGeometryStage {
                Self.geometryStageTraceLogger.notice(
                    "stage=displayGeometryExecutorStart actionID=\(actionID.canonicalString, privacy: .public) routeID=\(routeID, privacy: .public) executorGeneration=\(helper.executorGeneration, privacy: .public)"
                )
            }
            try send(
                fields: baseFields(.request, helper: helper).merging([
                    "payload": .object(payload),
                    "requestID": .string(requestID.canonicalString),
                ]) { _, new in new },
                through: helper
            )
            if tracesGeometryStage {
                Self.geometryStageTraceLogger.notice(
                    "stage=displayGeometryRequestSent actionID=\(actionID.canonicalString, privacy: .public) routeID=\(routeID, privacy: .public) executorGeneration=\(helper.executorGeneration, privacy: .public) elapsedUs=\(Self.elapsedMicroseconds(startedAt), privacy: .public)"
                )
            }
            if tracesToolbarLatency {
                Self.toolbarLatencyLogger.notice(
                    "stage=requestSent actionID=\(actionID.canonicalString, privacy: .public) routeID=\(routeID, privacy: .public) elapsedUs=\(Self.elapsedMicroseconds(startedAt), privacy: .public)"
                )
            }
            while true {
                let message = try receive(
                    from: helper,
                    deadlineNanoseconds: operationDeadlineNanoseconds,
                    cancellation: cancellation
                )
                if tracesGeometryStage {
                    Self.geometryStageTraceLogger.notice(
                        "stage=displayGeometryHelperMessage actionID=\(actionID.canonicalString, privacy: .public) routeID=\(routeID, privacy: .public) executorGeneration=\(helper.executorGeneration, privacy: .public) messageType=\(message.type.rawValue, privacy: .public) elapsedUs=\(Self.elapsedMicroseconds(startedAt), privacy: .public)"
                    )
                }
                if tracesToolbarLatency {
                    Self.toolbarLatencyLogger.notice(
                        "stage=helperMessage actionID=\(actionID.canonicalString, privacy: .public) routeID=\(routeID, privacy: .public) messageType=\(message.type.rawValue, privacy: .public) elapsedUs=\(Self.elapsedMicroseconds(startedAt), privacy: .public)"
                    )
                }
                if message.type == .result {
                    guard message.requestID == requestID,
                          let result = message.payload?["result"]?.objectValue
                    else {
                        throw ProductionCoreDeviceHelperExecutorError.invalidHelperMessage
                    }
                    let repositoryResult = try repositoryObject(result)
                    if tracesGeometryStage {
                        let outcome = repositoryResult["outcome"]?.stringValue
                            ?? "missing"
                        let errorCode = repositoryResult["error"]?.objectValue?["code"]?.stringValue ?? "none"
                        Self.geometryStageTraceLogger.notice(
                            "stage=displayGeometryHelperTerminal actionID=\(actionID.canonicalString, privacy: .public) routeID=\(routeID, privacy: .public) executorGeneration=\(helper.executorGeneration, privacy: .public) outcome=\(outcome, privacy: .public) errorCode=\(errorCode, privacy: .public) elapsedUs=\(Self.elapsedMicroseconds(startedAt), privacy: .public)"
                        )
                    }
                    return repositoryResult
                }
                guard message.requestID == requestID,
                      [.accepted, .started, .committed, .progress].contains(message.type)
                else {
                    throw ProductionCoreDeviceHelperExecutorError.invalidHelperMessage
                }
                if message.type == .accepted, !acceptedNotified {
                    acceptedNotified = true
                    onAccepted?()
                }
            }
        } catch {
            if error is CancellationError {
                stopActiveHelper(force: true)
                throw error
            }
            recordFailureLocked(
                error,
                operation: operation,
                stage: .transport,
                connectionEpoch: helper.connectionEpoch,
                executorGeneration: helper.executorGeneration
            )
            stopActiveHelper()
            throw error
        }
    }

    static func oneShotDeadlineNanoseconds(
        routeID: String,
        startedAt: UInt64
    ) -> UInt64? {
        let milliseconds: Int32
        switch routeID {
        case "legacy.dvtLaunch":
            milliseconds = appLaunchDeadlineMilliseconds
        case "direct.installationProxy.browse":
            milliseconds = appListDeadlineMilliseconds
        case "direct.installationProxy.install":
            milliseconds = installDeadlineMilliseconds
        case "direct.installationProxy.uninstall":
            milliseconds = uninstallDeadlineMilliseconds
        case "legacy.developerSupport.queryMounted":
            milliseconds = legacyDeveloperSupportQueryDeadlineMilliseconds
        case "coredevice.developerSupport.queryMounted":
            milliseconds = coreDeviceDeveloperSupportQueryDeadlineMilliseconds
        case "legacy.developerSupport.probeServices":
            milliseconds = legacyDeveloperSupportProbeDeadlineMilliseconds
        case "legacy.developerSupport.mount":
            milliseconds = legacyDeveloperSupportMountDeadlineMilliseconds
        case "coredevice.developerSupport.requestTSS":
            milliseconds = coreDeviceDeveloperSupportPersonalizationDeadlineMilliseconds
        case "coredevice.developerSupport.mount":
            milliseconds = coreDeviceDeveloperSupportMountDeadlineMilliseconds
        case "coredevice.screenshot", "legacy.screenshotr":
            milliseconds = screenshotDeadlineMilliseconds
        default:
            return nil
        }
        let interval = UInt64(milliseconds) * 1_000_000
        let deadline = startedAt.addingReportingOverflow(interval)
        return deadline.overflow ? UInt64.max : deadline.partialValue
    }

    func warmGeneration(
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        preparationAttemptID: CanonicalUUID,
        preparationGroupID: String,
        device: ProductionRuntimeDeviceObservation,
        connectionEpoch: UInt64
    ) throws -> RepositoryJSONObject {
        try executeOneShot(
            requestID: requestID,
            actionID: actionID,
            parentActionID: nil,
            routeID: "coredevice.warmGeneration",
            backendPayload: [
                "operation": .string("warmGeneration"),
                "preparationAttemptID": .string(
                    preparationAttemptID.canonicalString
                ),
                "preparationGroupID": .string(preparationGroupID),
            ],
            device: device,
            connectionEpoch: connectionEpoch
        )
    }

    func openStream(
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        interactionID: CanonicalUUID,
        parentActionID: CanonicalUUID?,
        routeID: String,
        streamPayload: [String: HelperWireJSONValue],
        device: ProductionRuntimeDeviceObservation,
        connectionEpoch: UInt64,
        ownerClientInstanceID: CanonicalUUID? = nil
    ) throws -> (sessionID: CanonicalUUID, executorGeneration: UInt64) {
        let reservesKeyboardResource = try beginKeyboardStreamOpen(routeID: routeID)
        var committedKeyboardSessionID: String?
        defer {
            if reservesKeyboardResource, committedKeyboardSessionID == nil {
                cancelKeyboardStreamOpen()
            }
        }
        lock.lock()
        defer { lock.unlock() }
        let helper = try ensureActive(
            device: device,
            connectionEpoch: connectionEpoch,
            operation: .streamOpen
        )
        let sessionID = CanonicalUUID(value: UUID())
        let lifecycleToken = try lifecycle?.openStream(
            sessionID: sessionID, interactionID: interactionID, commandID: routeID
        )
        var registered = false
        defer {
            if !registered, let lifecycleToken { try? lifecycle?.release(lifecycleToken) }
        }
        let deliveryAttemptID = Self.streamDeliveryAttemptID(sessionID: sessionID)
        var payload: [String: HelperWireJSONValue] = [
            "actionID": .string(actionID.canonicalString),
            "interactionID": .string(interactionID.canonicalString),
            "streamKind": .string(routeID == "coredevice.pointerStream"
                ? "pointer"
                : "keyboard"),
            "streamPayload": .object(
                streamPayload.merging(["routeID": .string(routeID)]) { _, new in new }
            ),
        ]
        if let parentActionID {
            payload["parentActionID"] = .string(parentActionID.canonicalString)
        }
        do {
            try send(
                fields: baseFields(.streamOpen, helper: helper).merging([
                    "deliveryAttemptID": .string(deliveryAttemptID),
                    "payload": .object(payload),
                    "sessionID": .string(sessionID.canonicalString),
                ]) { _, new in new },
                through: helper
            )
            try sendBarrier(
                through: helper,
                timeoutMilliseconds: streamBarrierTimeoutMilliseconds
            )
        } catch {
            recordFailureLocked(
                error,
                operation: .streamOpen,
                stage: .inputServiceOpen,
                connectionEpoch: connectionEpoch,
                executorGeneration: helper.executorGeneration
            )
            stopActiveHelper()
            throw error
        }
        helper.streams[sessionID.canonicalString] = StreamRecord(
            actionID: actionID,
            deliveryAttemptID: deliveryAttemptID,
            interactionID: interactionID,
            routeID: routeID,
            ownerClientInstanceID: ownerClientInstanceID,
            lastAcceptedSequence: nil,
            lifecycleToken: lifecycleToken
        )
        registered = true
        if reservesKeyboardResource {
            commitKeyboardStreamOpen(sessionID: sessionID.canonicalString)
            committedKeyboardSessionID = sessionID.canonicalString
        }
        return (sessionID, helper.executorGeneration)
    }

    func sendStreamFrame(
        _ frame: RuntimeStreamFrameEnvelope,
        payloadOverride: RepositoryJSONObject? = nil
    ) throws -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard let helper = active,
              var stream = helper.streams[frame.sessionID.canonicalString],
              stream.interactionID == frame.interactionID
        else {
            throw ProductionCoreDeviceHelperExecutorError.invalidRequest
        }
        var framePayload = try helperObject(payloadOverride ?? frame.payload)
        framePayload["kind"] = .string(frame.frameKind)
        let acknowledgement: HelperWireMessage
        do {
            try send(
                fields: baseFields(.frame, helper: helper).merging([
                    "deliveryAttemptID": .string(stream.deliveryAttemptID),
                    "payload": .object([
                        "framePayload": .object(framePayload),
                        "interactionID": .string(frame.interactionID.canonicalString),
                        "seq": .unsignedInteger(frame.sequence),
                    ]),
                    "sessionID": .string(frame.sessionID.canonicalString),
                ]) { _, new in new },
                through: helper
            )
            acknowledgement = try receive(
                from: helper,
                timeoutMilliseconds: frameAcknowledgementTimeoutMilliseconds
            )
        } catch {
            recordFailureLocked(
                error,
                operation: .frameAccepted,
                stage: .frameAccepted,
                connectionEpoch: helper.connectionEpoch,
                executorGeneration: helper.executorGeneration
            )
            stopActiveHelper()
            throw error
        }
        guard acknowledgement.type == .frameAccepted,
              acknowledgement.sessionID == frame.sessionID,
              acknowledgement.deliveryAttemptID == stream.deliveryAttemptID,
              acknowledgement.payload?["seq"]?.uintValue == frame.sequence
        else {
            let error = ProductionCoreDeviceHelperExecutorError.invalidHelperMessage
            recordFailureLocked(
                error,
                operation: .frameAccepted,
                stage: .frameAccepted,
                connectionEpoch: helper.connectionEpoch,
                executorGeneration: helper.executorGeneration
            )
            stopActiveHelper()
            throw error
        }
        stream.lastAcceptedSequence = frame.sequence
        helper.streams[frame.sessionID.canonicalString] = stream
        return acknowledgement.payload?["acceptedMonotonicNs"]?.uintValue
    }

    func closeStream(
        sessionID: CanonicalUUID,
        interactionID: CanonicalUUID,
        reason: String,
        cancel: Bool
    ) throws -> (
        actionID: CanonicalUUID,
        lastAcceptedSequence: UInt64?,
        disposition: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let helper = active,
              let stream = helper.streams[sessionID.canonicalString],
              stream.interactionID == interactionID
        else {
            throw ProductionCoreDeviceHelperExecutorError.invalidRequest
        }
        let type: HelperWireMessageID = cancel ? .cancel : .close
        do {
            try send(
                fields: baseFields(type, helper: helper).merging([
                    "deliveryAttemptID": .string(stream.deliveryAttemptID),
                    "payload": .object([
                        "interactionID": .string(interactionID.canonicalString),
                        "reason": .string(reason),
                    ]),
                    "sessionID": .string(sessionID.canonicalString),
                ]) { _, new in new },
                through: helper
            )
            try sendBarrier(
                through: helper,
                timeoutMilliseconds: streamBarrierTimeoutMilliseconds
            )
            try helper.machine.completeStreamCleanup(
                sessionID: sessionID,
                deliveryAttemptID: stream.deliveryAttemptID
            )
        } catch {
            recordFailureLocked(
                error,
                operation: .streamCleanup,
                stage: .cleanup,
                connectionEpoch: helper.connectionEpoch,
                executorGeneration: helper.executorGeneration
            )
            stopActiveHelper()
            throw error
        }
        helper.streams.removeValue(forKey: sessionID.canonicalString)
        defer { if let token = stream.lifecycleToken { try? lifecycle?.release(token) } }
        if stream.routeID == "coredevice.keyboardStream" {
            endKeyboardStream(sessionID: sessionID.canonicalString)
        }
        applyPendingReplacementIfSafeLocked()
        return (
            stream.actionID,
            stream.lastAcceptedSequence,
            cancel ? "cancelled" : "closed"
        )
    }

    func cancelStreamsOwnedBy(_ ownerClientInstanceID: CanonicalUUID) {
        let streams: [(sessionID: CanonicalUUID, interactionID: CanonicalUUID)] = lock.withLock {
            guard let active else { return [] }
            return active.streams.compactMap { sessionID, stream in
                guard stream.ownerClientInstanceID == ownerClientInstanceID,
                      let sessionID = try? CanonicalUUID(sessionID)
                else { return nil }
                return (sessionID, stream.interactionID)
            }
        }
        for stream in streams {
            _ = try? closeStream(
                sessionID: stream.sessionID,
                interactionID: stream.interactionID,
                reason: "clientDisconnected",
                cancel: true
            )
        }
    }

    func markLiveCaptureReady(
        device: ProductionRuntimeDeviceObservation,
        connectionEpoch: UInt64
    ) throws -> ProductionCoreDeviceCaptureReadyResult {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let deferredForOneShot = captureStateLock.withLock { () -> Bool in
            guard activeOneShotCount > 0 else { return false }
            _ = captureState.noteCaptureReadyWhileOneShotActive(
                connectionEpoch: connectionEpoch
            )
            return true
        }
        if deferredForOneShot {
            let result = ProductionCoreDeviceCaptureReadyResult(
                connectionEpoch: connectionEpoch,
                disposition: .deferred,
                newExecutorGeneration: nil,
                oldExecutorGeneration: nil
            )
            logTransition(result, startedAtNanoseconds: startedAt)
            return result
        }

        lock.lock()
        defer { lock.unlock() }
        if let active,
           active.connectionEpoch != connectionEpoch
        {
            stopActiveHelper()
        }
        let decision = captureStateLock.withLock {
            captureState.noteCaptureReady(
                connectionEpoch: connectionEpoch,
                activeProvenance: active?.captureProvenance,
                activeExecutorGeneration: active?.executorGeneration,
                hasActiveWork: active?.streams.isEmpty == false
            )
        }
        let result = try applyCaptureTransitionDecisionLocked(
            decision,
            device: device,
            connectionEpoch: connectionEpoch
        )
        logTransition(result, startedAtNanoseconds: startedAt)
        return result
    }

    private func beginOneShot() {
        captureStateLock.withLock { activeOneShotCount += 1 }
    }

    private func endOneShot() {
        let shouldApply = captureStateLock.withLock { () -> Bool in
            activeOneShotCount = max(0, activeOneShotCount - 1)
            return activeOneShotCount == 0 && captureState.replacementPending
        }
        guard shouldApply else { return }
        lock.withLock { applyPendingReplacementIfSafeLocked() }
    }

    private func applyPendingReplacementIfSafeLocked() {
        let captureSnapshot = captureStateLock.withLock {
            (captureState.connectionEpoch, captureState.replacementPending)
        }
        let connectionEpoch = captureSnapshot.1
            ? captureSnapshot.0
            : active?.connectionEpoch
        guard let connectionEpoch else { return }
        if let active,
           active.connectionEpoch != connectionEpoch
        {
            stopActiveHelper()
        }
        let decision = captureStateLock.withLock {
            captureState.pendingDecision(
                connectionEpoch: connectionEpoch,
                activeProvenance: active?.captureProvenance,
                activeExecutorGeneration: active?.executorGeneration,
                hasActiveWork: active?.streams.isEmpty == false
            )
        }
        guard let decision else { return }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        guard let device = active?.device else {
            let result = ProductionCoreDeviceCaptureReadyResult(
                connectionEpoch: connectionEpoch,
                disposition: .ready,
                newExecutorGeneration: nil,
                oldExecutorGeneration: nil
            )
            logTransition(result, startedAtNanoseconds: startedAt)
            return
        }
        do {
            let result = try applyCaptureTransitionDecisionLocked(
                decision,
                device: device,
                connectionEpoch: connectionEpoch
            )
            logTransition(result, startedAtNanoseconds: startedAt)
        } catch {
            captureStateLock.withLock {
                captureState.replacementFinished(connectionEpoch: connectionEpoch)
            }
            Self.transitionLogger.error(
                "connectionEpoch=\(connectionEpoch, privacy: .public) outcome=capabilityPreparing"
            )
        }
    }

    private func applyCaptureTransitionDecisionLocked(
        _ decision: ProductionCoreDeviceCaptureTransitionDecision,
        device: ProductionRuntimeDeviceObservation,
        connectionEpoch: UInt64
    ) throws -> ProductionCoreDeviceCaptureReadyResult {
        switch decision {
        case .alreadyReady:
            return ProductionCoreDeviceCaptureReadyResult(
                connectionEpoch: connectionEpoch,
                disposition: .alreadyReady,
                newExecutorGeneration: active?.executorGeneration,
                oldExecutorGeneration: nil
            )
        case .deferred:
            return ProductionCoreDeviceCaptureReadyResult(
                connectionEpoch: connectionEpoch,
                disposition: .deferred,
                newExecutorGeneration: nil,
                oldExecutorGeneration: active?.executorGeneration
            )
        case .ready:
            return ProductionCoreDeviceCaptureReadyResult(
                connectionEpoch: connectionEpoch,
                disposition: .ready,
                newExecutorGeneration: nil,
                oldExecutorGeneration: nil
            )
        case .replace(let oldExecutorGeneration):
            stopActiveHelper()
            defer {
                captureStateLock.withLock {
                    captureState.replacementFinished(
                        connectionEpoch: connectionEpoch
                    )
                }
            }
            let helper = try ensureActive(
                device: device,
                connectionEpoch: connectionEpoch,
                operation: .generationReplacement
            )
            guard helper.captureProvenance == .postCapture else {
                stopActiveHelper()
                throw ProductionCoreDeviceHelperExecutorError.invalidRequest
            }
            try warmPostCaptureGenerationLocked(helper)
            return ProductionCoreDeviceCaptureReadyResult(
                connectionEpoch: connectionEpoch,
                disposition: .replaced,
                newExecutorGeneration: helper.executorGeneration,
                oldExecutorGeneration: oldExecutorGeneration
            )
        }
    }

    private func warmPostCaptureGenerationLocked(_ helper: ActiveHelper) throws {
        let requestID = CanonicalUUID(value: UUID())
        let actionID = CanonicalUUID(value: UUID())
        let result = try executeOneShotLocked(
            requestID: requestID,
            actionID: actionID,
            parentActionID: nil,
            routeID: "coredevice.warmGeneration",
            backendPayload: [
                "operation": .string("warmGeneration"),
                "preparationAttemptID": .string(actionID.canonicalString),
                "preparationGroupID": .string("prep.coredevice.v2"),
            ],
            helper: helper,
            operation: .generationReplacement,
            onAccepted: nil
        )
        guard result["outcome"]?.stringValue == "succeeded" else {
            let error = ProductionCoreDeviceHelperExecutorError.helperRejected(
                code: result["error"]?.objectValue?["code"]?.stringValue
                    ?? "developerServicesUnavailable",
                phase: result["error"]?.objectValue?["details"]?
                    .objectValue?["phase"]?.stringValue
            )
            recordFailureLocked(
                error,
                operation: .generationReplacement,
                stage: .transport,
                connectionEpoch: helper.connectionEpoch,
                executorGeneration: helper.executorGeneration
            )
            stopActiveHelper()
            throw error
        }
    }

    private func logTransition(
        _ result: ProductionCoreDeviceCaptureReadyResult,
        startedAtNanoseconds: UInt64
    ) {
        let elapsed = DispatchTime.now().uptimeNanoseconds
            .subtractingReportingOverflow(startedAtNanoseconds)
        let elapsedMilliseconds = elapsed.overflow
            ? 0
            : elapsed.partialValue / 1_000_000
        let oldGeneration = result.oldExecutorGeneration.map(String.init) ?? "none"
        let newGeneration = result.newExecutorGeneration.map(String.init) ?? "none"
        Self.transitionLogger.notice(
            "connectionEpoch=\(result.connectionEpoch, privacy: .public) oldGeneration=\(oldGeneration, privacy: .public) newGeneration=\(newGeneration, privacy: .public) elapsedMs=\(elapsedMilliseconds, privacy: .public) outcome=\(result.disposition.rawValue, privacy: .public)"
        )
    }

    private func ensureActive(
        device: ProductionRuntimeDeviceObservation,
        connectionEpoch: UInt64,
        operation: ProductionCoreDeviceHelperOperationStage,
        cancellation: ProductionElementSnapshotCancellation? = nil
    ) throws -> ActiveHelper {
        try cancellation?.check()
        guard let context else {
            let error = ProductionCoreDeviceHelperExecutorError.inactive
            recordFailureLocked(
                error,
                operation: operation,
                stage: .helperSpawn,
                connectionEpoch: connectionEpoch,
                executorGeneration: nil
            )
            throw error
        }
        if lastFailure?.connectionEpoch != connectionEpoch {
            lastFailure = nil
        }
        if let active,
           active.connectionEpoch == connectionEpoch,
           active.rawTransportUDID == device.rawTransportUDID,
           active.spawned.processIdentity.matchesCurrentProcess()
        {
            return active
        }
        stopActiveHelper()
        guard connectionEpoch > 0 else {
            let error = ProductionCoreDeviceHelperExecutorError.invalidRequest
            recordFailureLocked(
                error,
                operation: operation,
                stage: .helperSpawn,
                connectionEpoch: connectionEpoch,
                executorGeneration: nil
            )
            throw error
        }
        let captureProvenance = captureStateLock.withLock {
            captureState.provenanceForSpawn(connectionEpoch: connectionEpoch)
        }
        let generation = nextExecutorGeneration
        guard generation < UInt64.max else {
            let error = ProductionCoreDeviceHelperExecutorError.invalidRequest
            recordFailureLocked(
                error,
                operation: operation,
                stage: .helperSpawn,
                connectionEpoch: connectionEpoch,
                executorGeneration: generation
            )
            throw error
        }
        nextExecutorGeneration += 1

        let executable: URL
        var helperArguments = testOnlyHelperLaunchOverride?.leadingArguments ?? []
        if let testOnlyHelperLaunchOverride {
            executable = testOnlyHelperLaunchOverride.executableURL
        } else {
            let bundledHelpers = BundledHelperExecutableSet(resourcesURL: resourcesURL)
            executable = bundledHelpers.executableURL(
                for: mode == .direct ? .direct : .coreDevice
            )
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path)
        else {
            let error = ProductionCoreDeviceHelperExecutorError.invalidBundledResources
            recordFailureLocked(
                error,
                operation: operation,
                stage: .helperSpawn,
                connectionEpoch: connectionEpoch,
                executorGeneration: generation
            )
            throw error
        }
        let helperID = mode == .direct
            ? Self.directHelperIdentifier(generation: generation)
            : Self.helperIdentifier(generation: generation)
        let helperBuildID = mode == .direct
            ? Self.directHelperBuildID
            : Self.coreDeviceHelperBuildID
        let helperKind: HelperKind = mode == .direct ? .direct : .coreDevice
        let helperRole = mode == .direct
            ? "production-direct"
            : "production-coredevice"
        if mode == .direct {
            helperArguments.append(contentsOf: ["--mode", "oneshot"])
        }
        helperArguments.append(contentsOf: [
            "--runtime-epoch", String(runtimeEpoch),
            "--connection-epoch", String(connectionEpoch),
            "--executor-generation", String(generation),
            "--raw-transport-udid", device.rawTransportUDID,
            "--helper-build-id", helperBuildID,
            "--manifest-hash", Self.helperManifestHash,
        ])
        if mode == .coreDevice {
            helperArguments.append(contentsOf: Self.facetServiceArguments)
        }
        let configuration = HelperLaunchConfiguration(
            helperID: helperID,
            kind: helperKind,
            role: helperRole,
            executorID: helperID,
            executorGeneration: generation,
            executablePath: executable.path,
            arguments: helperArguments,
            helperBuildID: helperBuildID,
            helperManifestHash: Self.helperManifestHash
        )
        let inherited = try context.runtimeLock.duplicateForChildInheritance()
        defer { _ = Darwin.close(inherited) }
        let spawned: SpawnedHelper
        do {
            spawned = try supervisorRegistry.spawn(
                configuration,
                inheritedRuntimeLockDescriptor: inherited
            )
        } catch {
            recordFailureLocked(
                error,
                operation: operation,
                stage: .helperSpawn,
                connectionEpoch: connectionEpoch,
                executorGeneration: generation
            )
            throw error
        }
        let helper = ActiveHelper(
            captureProvenance: captureProvenance,
            connectionEpoch: connectionEpoch,
            device: device,
            executorGeneration: generation,
            helperID: helperID,
            rawTransportUDID: device.rawTransportUDID,
            spawned: spawned,
            machine: HelperWireProtocolMachine(
                runtimeEpoch: runtimeEpoch,
                executorGeneration: generation
            )
        )
        do {
            let helloMessage = try receive(
                from: helper,
                timeoutMilliseconds: helperHandshakeTimeoutMilliseconds,
                cancellation: cancellation
            )
            guard helloMessage.type == .hello,
                  let helperBuildID = helloMessage.fields["helperBuildID"]?.stringValue,
                  let helperKindValue = helloMessage.fields["helperKind"]?.stringValue,
                  let helperKind = HelperKind(rawValue: helperKindValue),
                  let manifestHash = helloMessage.fields["manifestHash"]?.stringValue,
                  let processStartIdentity = helloMessage.fields["processStartIdentity"]?
                    .stringValue
            else {
                throw ProductionCoreDeviceHelperExecutorError.invalidHelperMessage
            }
            let acceptance = try supervisorRegistry.acceptHello(
                HelperHello(
                    runtimeEpoch: helloMessage.runtimeEpoch,
                    executorGeneration: helloMessage.executorGeneration,
                    helperBuildID: helperBuildID,
                    helperKind: helperKind,
                    manifestHash: manifestHash,
                    processStartIdentity: processStartIdentity
                ),
                from: helperID
            )
            try send(
                fields: baseFields(.helloAccepted, helper: helper).merging([
                    "manifestHash": .string(
                        acceptance.helloAccepted.manifestHash
                    ),
                ]) { _, new in new },
                through: helper
            )
            let ready = try receive(
                from: helper,
                timeoutMilliseconds: helperHandshakeTimeoutMilliseconds,
                cancellation: cancellation
            )
            guard ready.type == .ready else {
                throw ProductionCoreDeviceHelperExecutorError.invalidHelperMessage
            }
            active = helper
            return helper
        } catch {
            helper.spawned.terminateAndReap()
            try? supervisorRegistry.remove(helperID: helperID)
            if error is CancellationError { throw error }
            recordFailureLocked(
                error,
                operation: operation,
                stage: .helperHello,
                connectionEpoch: connectionEpoch,
                executorGeneration: generation
            )
            throw error
        }
    }

    private func sendBarrier(
        through helper: ActiveHelper,
        timeoutMilliseconds: Int32
    ) throws {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let timeoutNanoseconds = UInt64(timeoutMilliseconds) * 1_000_000
        let deadline = startedAt.addingReportingOverflow(timeoutNanoseconds)
        guard !deadline.overflow else {
            throw ProductionCoreDeviceHelperExecutorError.invalidRequest
        }
        let requestID = CanonicalUUID(value: UUID())
        try send(
            fields: baseFields(.request, helper: helper).merging([
                "payload": .object([
                    "actionID": .string(CanonicalUUID(value: UUID()).canonicalString),
                    "backendPayload": .object(["operation": .string("barrier")]),
                    "executorOperationID": .string("coredevice.barrier"),
                ]),
                "requestID": .string(requestID.canonicalString),
            ]) { _, new in new },
            through: helper
        )
        while true {
            let message = try receive(
                from: helper,
                deadlineNanoseconds: deadline.partialValue
            )
            guard message.requestID == requestID else {
                throw ProductionCoreDeviceHelperExecutorError.invalidHelperMessage
            }
            if message.type == .result {
                guard let result = message.payload?["result"]?.objectValue else {
                    throw ProductionCoreDeviceHelperExecutorError.invalidHelperMessage
                }
                if result["outcome"]?.stringValue == "succeeded" { return }
                let error = result["error"]?.objectValue
                throw ProductionCoreDeviceHelperExecutorError.helperRejected(
                    code: error?["code"]?.stringValue ?? "developerServicesUnavailable",
                    phase: error?["details"]?.objectValue?["phase"]?.stringValue
                )
            }
            guard [.accepted, .started, .committed, .progress].contains(message.type) else {
                throw ProductionCoreDeviceHelperExecutorError.invalidHelperMessage
            }
        }
    }

    private func stopActiveHelper(force: Bool = false) {
        guard let helper = active else { return }
        defer {
            for stream in helper.streams.values {
                if let token = stream.lifecycleToken { try? lifecycle?.release(token) }
            }
        }
        active = nil
        resetKeyboardStreams()
        if force {
            if helper.spawned.processIdentity.matchesCurrentProcess() {
                helper.spawned.terminateAndReap()
            } else {
                helper.spawned.closeDescriptors()
            }
            try? supervisorRegistry.remove(helperID: helper.helperID)
            return
        }
        if helper.spawned.processIdentity.matchesCurrentProcess() {
            try? send(
                fields: baseFields(.shutdown, helper: helper).merging([
                    "payload": .object(["reason": .string("runtimeStopping")]),
                ]) { _, new in new },
                through: helper
            )
        }
        if !waitForExit(helper.spawned.processIdentity.pid, milliseconds: 5_000) {
            helper.spawned.terminateAndReap()
        } else {
            helper.spawned.closeDescriptors()
        }
        try? supervisorRegistry.remove(helperID: helper.helperID)
    }

    private static func usesKeyboardOneShotResource(routeID: String) -> Bool {
        routeID == "coredevice.pasteboardSetAndPaste"
            || routeID == "coredevice.keyboardMacro"
            || routeID == "coredevice.softwareKeyboardToggle"
    }

    private func beginKeyboardOneShot(routeID: String) throws -> Bool {
        guard Self.usesKeyboardOneShotResource(routeID: routeID) else {
            return false
        }
        return try keyboardActivityLock.withLock {
            guard !keyboardOneShotActive,
                  !keyboardStreamOpenPending,
                  keyboardStreamSessionIDs.isEmpty
            else {
                throw ProductionCoreDeviceHelperExecutorError.resourceBusy
            }
            keyboardOneShotActive = true
            return true
        }
    }

    private func endKeyboardOneShot() {
        keyboardActivityLock.withLock {
            keyboardOneShotActive = false
        }
    }

    private func beginKeyboardStreamOpen(routeID: String) throws -> Bool {
        guard routeID == "coredevice.keyboardStream" else { return false }
        return try keyboardActivityLock.withLock {
            guard !keyboardOneShotActive,
                  !keyboardStreamOpenPending,
                  keyboardStreamSessionIDs.isEmpty
            else {
                throw ProductionCoreDeviceHelperExecutorError.resourceBusy
            }
            keyboardStreamOpenPending = true
            return true
        }
    }

    private func commitKeyboardStreamOpen(sessionID: String) {
        keyboardActivityLock.withLock {
            keyboardStreamOpenPending = false
            keyboardStreamSessionIDs.insert(sessionID)
        }
    }

    private func cancelKeyboardStreamOpen() {
        keyboardActivityLock.withLock {
            keyboardStreamOpenPending = false
        }
    }

    private func endKeyboardStream(sessionID: String) {
        _ = keyboardActivityLock.withLock {
            keyboardStreamSessionIDs.remove(sessionID)
        }
    }

    private func resetKeyboardStreams() {
        keyboardActivityLock.withLock {
            keyboardStreamOpenPending = false
            keyboardStreamSessionIDs.removeAll()
        }
    }

    private func waitForExit(_ pid: pid_t, milliseconds: UInt64) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + milliseconds * 1_000_000
        var status: Int32 = 0
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let result = Darwin.waitpid(pid, &status, WNOHANG)
            if result == pid || (result == -1 && errno == ECHILD) { return true }
            if result == -1 && errno != EINTR { return false }
            usleep(20_000)
        }
        return false
    }

    private func send(
        fields: [String: HelperWireJSONValue],
        through helper: ActiveHelper
    ) throws {
        let message = try HelperWireCodec.decodeLine(
            HelperWireCodec.encodeLine(
                fields: fields,
                direction: .runtimeToHelper
            ),
            direction: .runtimeToHelper
        )
        try helper.machine.receive(message, direction: .runtimeToHelper)
        try writeAll(
            HelperWireCodec.encodeLine(
                fields: fields,
                direction: .runtimeToHelper
            ),
            to: helper.spawned.commandWriter
        )
    }

    private func receive(
        from helper: ActiveHelper,
        timeoutMilliseconds: Int32? = nil,
        deadlineNanoseconds: UInt64? = nil,
        cancellation: ProductionElementSnapshotCancellation? = nil
    ) throws -> HelperWireMessage {
        let effectiveDeadline: UInt64?
        if let deadlineNanoseconds {
            effectiveDeadline = deadlineNanoseconds
        } else if let timeoutMilliseconds {
            let timeoutNanoseconds = UInt64(timeoutMilliseconds) * 1_000_000
            let deadline = DispatchTime.now().uptimeNanoseconds
                .addingReportingOverflow(timeoutNanoseconds)
            guard !deadline.overflow else {
                throw ProductionCoreDeviceHelperExecutorError.invalidRequest
            }
            effectiveDeadline = deadline.partialValue
        } else {
            effectiveDeadline = nil
        }
        let line = try readLine(
            from: helper.spawned.eventReader,
            buffer: &helper.inputBuffer,
            timeoutMilliseconds: timeoutMilliseconds,
            deadlineNanoseconds: effectiveDeadline,
            cancellation: cancellation
        )
        let message = try HelperWireCodec.decodeLine(
            line,
            direction: .helperToRuntime
        )
        try helper.machine.receive(message, direction: .helperToRuntime)
        return message
    }

    private func readLine(
        from descriptor: Int32,
        buffer: inout [UInt8],
        timeoutMilliseconds: Int32?,
        deadlineNanoseconds: UInt64?,
        cancellation: ProductionElementSnapshotCancellation?
    ) throws -> [UInt8] {
        while true {
            try cancellation?.check()
            if let newline = buffer.firstIndex(of: 0x0a) {
                let line = Array(buffer[...newline])
                buffer.removeFirst(newline + 1)
                return line
            }
            guard buffer.count <= HelperWireCodec.maximumLineBytes else {
                throw ProductionCoreDeviceHelperExecutorError.invalidHelperMessage
            }
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let basePollTimeout: Int32
            if let deadlineNanoseconds {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadlineNanoseconds else {
                    throw ProductionCoreDeviceHelperExecutorError.timedOut
                }
                let remaining = deadlineNanoseconds - now
                let roundedMilliseconds = min(
                    UInt64(Int32.max),
                    (remaining + 999_999) / 1_000_000
                )
                basePollTimeout = Int32(max(1, roundedMilliseconds))
            } else {
                basePollTimeout = timeoutMilliseconds ?? inputTimeoutMilliseconds
            }
            let pollTimeout = cancellation == nil
                ? basePollTimeout : min(basePollTimeout, 50)
            let polled = Darwin.poll(
                &pollDescriptor,
                1,
                pollTimeout
            )
            if polled == 0 {
                try cancellation?.check()
                if pollTimeout < basePollTimeout { continue }
                throw ProductionCoreDeviceHelperExecutorError.timedOut
            }
            guard polled > 0 else {
                if errno == EINTR { continue }
                throw ProductionCoreDeviceHelperExecutorError.transportFailure(
                    errno: errno
                )
            }
            var chunk = [UInt8](repeating: 0, count: 4_096)
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk.prefix(count))
                continue
            }
            if count == 0 {
                throw ProductionCoreDeviceHelperExecutorError.processExited
            }
            if errno != EINTR {
                throw ProductionCoreDeviceHelperExecutorError.transportFailure(
                    errno: errno
                )
            }
        }
    }

    private func writeAll(_ bytes: [UInt8], to descriptor: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if count > 0 {
                offset += count
            } else if count == -1, errno == EINTR {
                continue
            } else {
                throw ProductionCoreDeviceHelperExecutorError.transportFailure(
                    errno: errno
                )
            }
        }
    }

    private func recordFailureLocked(
        _ error: Error,
        operation: ProductionCoreDeviceHelperOperationStage,
        stage defaultStage: ProductionCoreDeviceHelperFailureStage,
        connectionEpoch: UInt64,
        executorGeneration: UInt64?
    ) {
        let mapped = Self.failureProjection(error, defaultStage: defaultStage)
        lastFailure = (
            connectionEpoch: connectionEpoch,
            errorCode: mapped.code,
            operation: operation,
            stage: mapped.stage
        )
        let generation = executorGeneration.map(String.init) ?? "none"
        Self.failureLogger.error(
            "connectionEpoch=\(connectionEpoch, privacy: .public) executorGeneration=\(generation, privacy: .public) operation=\(operation.rawValue, privacy: .public) stage=\(mapped.stage.rawValue, privacy: .public) errorCode=\(mapped.code, privacy: .public) internalError=\(String(describing: error), privacy: .public)"
        )
    }

    private static func failureProjection(
        _ error: Error,
        defaultStage: ProductionCoreDeviceHelperFailureStage
    ) -> (code: String, stage: ProductionCoreDeviceHelperFailureStage) {
        guard let error = error as? ProductionCoreDeviceHelperExecutorError else {
            return ("transportFailure", defaultStage)
        }
        switch error {
        case .helperRejected(let code, let phase):
            let stage: ProductionCoreDeviceHelperFailureStage = switch phase {
            case "openingTunnel", "startingDeviceServices": .tunnelOrRSD
            case "openingInputService": .inputServiceOpen
            case "closingInputService": .cleanup
            default: defaultStage
            }
            return (code, stage)
        case .timedOut:
            return ("executionTimeout", defaultStage)
        case .invalidHelperMessage, .invalidRequest:
            return ("protocolViolation", defaultStage)
        case .resourceBusy:
            return ("resourceBusy", defaultStage)
        case .invalidBundledResources, .inactive:
            return ("capabilityPreparing", defaultStage)
        case .helperUnavailableBeforeRequest, .processExited, .transportFailure:
            return ("transportFailure", defaultStage)
        }
    }

    private func baseFields(
        _ type: HelperWireMessageID,
        helper: ActiveHelper
    ) -> [String: HelperWireJSONValue] {
        [
            "executorGeneration": .unsignedInteger(helper.executorGeneration),
            "messageID": .string(CanonicalUUID(value: UUID()).canonicalString),
            "runtimeEpoch": .unsignedInteger(runtimeEpoch),
            "schemaVersion": .unsignedInteger(1),
            "type": .string(type.rawValue),
        ]
    }

    private func repositoryObject(
        _ value: [String: HelperWireJSONValue]
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: value.map {
            RepositoryJSONMember(key: $0.key, value: try repositoryValue($0.value))
        })
    }

    private func repositoryValue(
        _ value: HelperWireJSONValue
    ) throws -> RepositoryJSONValue {
        switch value {
        case .null:
            return .null
        case .bool(let value):
            return .bool(value)
        case .string(let value):
            return .string(value)
        case .integer(let value):
            return .number(.int64(value))
        case .unsignedInteger(let value):
            return .number(.uint64(value))
        case .double:
            throw ProductionCoreDeviceHelperExecutorError.invalidHelperMessage
        case .array(let values):
            return .array(try values.map(repositoryValue))
        case .object(let values):
            return .object(try repositoryObject(values))
        }
    }

    private func helperObject(
        _ value: RepositoryJSONObject
    ) throws -> [String: HelperWireJSONValue] {
        try Dictionary(uniqueKeysWithValues: value.members.map {
            ($0.key, try helperValue($0.value))
        })
    }

    private func helperValue(
        _ value: RepositoryJSONValue
    ) throws -> HelperWireJSONValue {
        switch value {
        case .null:
            return .null
        case .bool(let value):
            return .bool(value)
        case .string(let value):
            return .string(value)
        case .number(.int64(let value)):
            return .integer(value)
        case .number(.uint64(let value)):
            return .unsignedInteger(value)
        case .number(.decimal):
            throw ProductionCoreDeviceHelperExecutorError.invalidRequest
        case .array(let values):
            return .array(try values.map(helperValue))
        case .object(let value):
            return .object(try helperObject(value))
        }
    }

    private static let facetServiceArguments = [
        "appControl=com.apple.coredevice.appservice",
        "button=com.apple.coredevice.hid.indigo",
        "hid=com.apple.coredevice.hid.universalhidservice",
        "keyboard=com.apple.coredevice.hid.universalhidservice",
        "orientation=com.apple.coredevice.devicecontrol",
        "pasteboard=com.apple.coredevice.pasteboardservice",
        "screenshot=com.apple.coredevice.screencaptureservice",
    ].flatMap { ["--facet-service", $0] }

    static func helperIdentifier(generation: UInt64) -> String {
        "coredevice-\(generation)"
    }

    static func directHelperIdentifier(generation: UInt64) -> String {
        "direct-\(generation)"
    }

    private static func elapsedMicroseconds(_ startedAt: UInt64) -> UInt64 {
        let elapsed = DispatchTime.now().uptimeNanoseconds
            .subtractingReportingOverflow(startedAt)
        return elapsed.overflow ? 0 : elapsed.partialValue / 1_000
    }

    static func streamDeliveryAttemptID(sessionID: CanonicalUUID) -> String {
        "stream.\(sessionID.canonicalString)"
    }
}
