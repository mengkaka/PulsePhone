import Darwin
import Dispatch
import Foundation
import OSLog
import PulsePhoneBackendAdapters
import PulsePhoneCommandPlanner
import PulsePhoneDeveloperImageAssets
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneElement
import PulsePhoneHostPaths
import PulsePhoneLogging
import PulsePhoneMedia
import PulsePhoneRuntimeKernel
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions
import PulsePhoneWire

public enum ProductionRuntimeServerError: Error, Equatable, Sendable {
    case invalidBundledResources
    case processIdentityUnavailable
    case acceptFailed(errno: Int32)
    case closedFrame
    case transportFailure(errno: Int32)
    case invalidFrame
}

public enum ProductionRuntimeBackendDisposition: Sendable {
    case artifact(
        descriptor: Int32,
        artifactID: CanonicalUUID,
        sizeBytes: UInt64,
        binding: ArtifactFDContentBinding,
        value: RepositoryJSONObject
    )
    case failed(code: String)
    case failedWithDetails(code: String, details: RepositoryJSONObject)
    case outcomeUnknown(code: String)
    case standard(result: RepositoryJSONObject)
    case succeeded(value: RepositoryJSONObject)
}

private enum PreparationReadinessRecoveryResult: Equatable, Sendable {
    case ready
    case notMounted
    case mountedStateCheckFailed
    case serviceWarmupFailed
    case staleConnection

    var reason: String {
        switch self {
        case .ready:
            return "runDevicePrepare"
        case .notMounted:
            return "developerSupportNotMounted"
        case .mountedStateCheckFailed:
            return "mountedStateCheckFailed"
        case .serviceWarmupFailed:
            return "serviceWarmupFailed"
        case .staleConnection:
            return "connectionEpochChanged"
        }
    }
}

private final class ProductionPreparationProgressPublisher: @unchecked Sendable {
    private let attemptID: CanonicalUUID
    private let groupID: String
    private let handler: ProductionRuntimeOperationBackend.PreparationProgressHandler?
    private var sequence: UInt64 = 0

    init(
        attemptID: CanonicalUUID,
        groupID: String,
        handler: ProductionRuntimeOperationBackend.PreparationProgressHandler?
    ) {
        self.attemptID = attemptID
        self.groupID = groupID
        self.handler = handler
    }

    func publish(
        _ phase: PreparationWirePhase,
        completedBytes: UInt64? = nil,
        totalBytes: UInt64? = nil,
        sourceKind: PreparationProgressSourceKind? = nil
    ) {
        guard let handler else { return }
        sequence += 1
    guard
      let progress = try? PreparationProgressV1(
            completedBytes: completedBytes,
            fraction: progressFraction(
                completedBytes: completedBytes,
                totalBytes: totalBytes
            ),
            phase: phase,
            phaseSequence: sequence,
            preparationAttemptID: attemptID,
            preparationGroupID: groupID,
            sourceKind: sourceKind,
            stateRevision: sequence,
            totalBytes: totalBytes
      )
    else {
            return
        }
        handler(progress)
    }

    private func progressFraction(
        completedBytes: UInt64?,
        totalBytes: UInt64?
    ) -> Double? {
        guard let completedBytes, let totalBytes, totalBytes > 0 else {
            return nil
        }
        return Double(completedBytes) / Double(totalBytes)
    }
}

enum ProductionRuntimeCommandPlanningError: Error, Equatable {
    case geometryUnavailable
    case invalidArgument
}

public struct ProductionRuntimeOperationBackend: Sendable {
    struct ElementCaptureMetadata: Equatable, Sendable {
        let attempts: [ElementSnapshotCaptureAttempt]?
        let provider: SnapshotCaptureProvider
    }

  public typealias CaptureReadyHandler =
    @Sendable (
        UInt64,
        CanonicalUUID
    ) throws -> ProductionRuntimeBackendDisposition
  public typealias Handler =
    @Sendable (RuntimeRequestEnvelope) throws
        -> ProductionRuntimeBackendDisposition
  public typealias StreamFrameHandler =
    @Sendable (RuntimeStreamFrameEnvelope) throws
        -> Void
  public typealias PreparationProgressHandler =
    @Sendable (
        PreparationProgressV1
    ) -> Void
  public typealias ProgressReportingHandler =
    @Sendable (
        RuntimeRequestEnvelope,
        PreparationProgressHandler
    ) throws -> ProductionRuntimeBackendDisposition
  typealias ContextualHandler =
    @Sendable (
        RuntimeRequestEnvelope,
        CanonicalUUID?,
        ProductionElementSnapshotCancellation?,
        PreparationProgressHandler?
    ) throws -> ProductionRuntimeBackendDisposition
  typealias ContextualStreamFrameHandler =
    @Sendable (
        RuntimeStreamFrameEnvelope,
        CanonicalUUID?
    ) throws -> Void

    public static let routedOperations: Set<RuntimeOperationID> = [
        .commandSubmit,
        .runtimeCancelOwnedPendingWork,
        .runtimeClearActionLogs,
        .runtimeGetAvailabilitySnapshot,
        .runtimePrepareCapabilities,
        .runtimeStartDiagnostics,
        .runtimeStartReplayTrace,
        .runtimeStopDiagnostics,
        .runtimeStopReplayTrace,
        .streamCancel,
        .streamClose,
        .streamOpen,
    ]

    private let captureReadyHandler: CaptureReadyHandler?
  private let coordinateProjectionStore: ProductionRuntimeCoordinateProjectionStore?
    private let handler: ContextualHandler
    private let streamFrameHandler: ContextualStreamFrameHandler?
    let deviceCoordinator: ProductionRuntimeDeviceCoordinator?
    private let helperExecutor: ProductionCoreDeviceHelperExecutor?
    private let directHelperExecutor: ProductionCoreDeviceHelperExecutor?
    private let elementSnapshotPipeline: ProductionElementSnapshotPipeline?
    private let recordingStore: ProductionRuntimeRecordingStore?
    private let screenshotStore: ProductionScreenshotArtifactStore?
  private let pointerObservationSink: ProductionRuntimePointerObservationSink?
    private static let toolbarLatencyLogger = Logger(
        subsystem: "com.pulsephone.PulsePhoneRuntime",
        category: "toolbar-latency"
    )
    private static let pointerLatencyLogger = Logger(
        subsystem: "com.pulsephone.PulsePhoneRuntime",
        category: "pointer-latency"
    )
    private static let touchRouteAuditLogger = Logger(
        subsystem: "com.pulsephone.PulsePhoneRuntime",
        category: "touch-route-audit"
    )
    private static let touchStageTraceLogger = Logger(
        subsystem: "com.pulsephone.PulsePhoneRuntime",
        category: "touch-stage-trace"
    )
    private static let appInstallLogger = Logger(
        subsystem: "com.pulsephone.PulsePhoneRuntime",
        category: "app-install"
    )
    private static let elementSnapshotLogger = Logger(
        subsystem: "com.pulsephone.PulsePhoneRuntime",
        category: "element-snapshot"
    )
    private static let developerSupportLogger = Logger(
        subsystem: "com.pulsephone.PulsePhoneRuntime",
        category: "developer-support"
    )
  private static let modernElementCaptureProviderOrder: [SnapshotCaptureProvider] = [
    .dvt, .coreDevice, .axAudit,
  ]
    private static let modernElementCaptureProviderPlanID =
        modernElementCaptureProviderOrder.map(\.rawValue).joined(separator: "->")

    public init(
        handler: @escaping Handler,
        streamFrameHandler: StreamFrameHandler? = nil,
        captureReadyHandler: CaptureReadyHandler? = nil
    ) {
        self.captureReadyHandler = captureReadyHandler
        self.coordinateProjectionStore = nil
        self.handler = { request, _, _, _ in try handler(request) }
        if let streamFrameHandler {
            self.streamFrameHandler = { frame, _ in
                try streamFrameHandler(frame)
            }
        } else {
            self.streamFrameHandler = nil
        }
        self.deviceCoordinator = nil
        self.helperExecutor = nil
        self.directHelperExecutor = nil
        self.elementSnapshotPipeline = nil
        self.recordingStore = nil
        self.screenshotStore = nil
        self.pointerObservationSink = nil
    }

    public init(progressReportingHandler: @escaping ProgressReportingHandler) {
        self.captureReadyHandler = nil
        self.coordinateProjectionStore = nil
        self.handler = { request, _, _, progress in
            try progressReportingHandler(request, progress ?? { _ in })
        }
        self.streamFrameHandler = nil
        self.deviceCoordinator = nil
        self.helperExecutor = nil
        self.directHelperExecutor = nil
        self.elementSnapshotPipeline = nil
        self.recordingStore = nil
        self.screenshotStore = nil
        self.pointerObservationSink = nil
    }

    init(
        deviceCoordinator: ProductionRuntimeDeviceCoordinator,
        captureReadyHandler: CaptureReadyHandler? = nil,
        handler: @escaping Handler
    ) {
        self.captureReadyHandler = captureReadyHandler
        self.coordinateProjectionStore = nil
        self.handler = { request, _, _, _ in try handler(request) }
        self.streamFrameHandler = nil
        self.deviceCoordinator = deviceCoordinator
        self.helperExecutor = nil
        self.directHelperExecutor = nil
        self.elementSnapshotPipeline = nil
        self.recordingStore = nil
        self.screenshotStore = nil
        self.pointerObservationSink = nil
    }

    init(
        pointerObservationSink: ProductionRuntimePointerObservationSink,
        handler: @escaping ContextualHandler
    ) {
        self.captureReadyHandler = nil
        self.coordinateProjectionStore = nil
        self.handler = handler
        self.streamFrameHandler = nil
        self.deviceCoordinator = nil
        self.helperExecutor = nil
        self.directHelperExecutor = nil
        self.elementSnapshotPipeline = nil
        self.recordingStore = nil
        self.screenshotStore = nil
        self.pointerObservationSink = pointerObservationSink
    }

    init(
        deviceCoordinator: ProductionRuntimeDeviceCoordinator,
        helperExecutor: ProductionCoreDeviceHelperExecutor,
        directHelperExecutor: ProductionCoreDeviceHelperExecutor? = nil,
        elementSnapshotPipeline: ProductionElementSnapshotPipeline? = nil,
        recordingStore: ProductionRuntimeRecordingStore?,
        screenshotStore: ProductionScreenshotArtifactStore,
        coordinateProjectionStore: ProductionRuntimeCoordinateProjectionStore,
        pointerObservationSink: ProductionRuntimePointerObservationSink,
        captureReadyHandler: @escaping CaptureReadyHandler,
        handler: @escaping ContextualHandler
    ) {
        self.captureReadyHandler = captureReadyHandler
        self.coordinateProjectionStore = coordinateProjectionStore
        self.handler = handler
        self.streamFrameHandler = nil
        self.deviceCoordinator = deviceCoordinator
        self.helperExecutor = helperExecutor
        self.directHelperExecutor = directHelperExecutor
        self.elementSnapshotPipeline = elementSnapshotPipeline
        self.recordingStore = recordingStore
        self.screenshotStore = screenshotStore
        self.pointerObservationSink = pointerObservationSink
    }

    public func handle(
        _ request: RuntimeRequestEnvelope,
        clientInstanceID: CanonicalUUID? = nil
    ) throws -> ProductionRuntimeBackendDisposition {
        try handle(
            request,
            clientInstanceID: clientInstanceID,
            elementCancellation: nil,
            preparationProgress: nil
        )
    }

    func handle(
        _ request: RuntimeRequestEnvelope,
        clientInstanceID: CanonicalUUID?,
        elementCancellation: ProductionElementSnapshotCancellation? = nil,
        preparationProgress: PreparationProgressHandler? = nil
    ) throws -> ProductionRuntimeBackendDisposition {
        guard Self.routedOperations.contains(request.operation) else {
            throw ProductionRuntimeServerError.invalidFrame
        }
        return try handler(
            request,
            clientInstanceID,
            elementCancellation,
            preparationProgress
        )
    }

    public func markLiveCaptureReady(
        connectionEpoch: UInt64,
        captureActivationID: CanonicalUUID
    ) throws -> ProductionRuntimeBackendDisposition {
        guard let captureReadyHandler else {
            return .failed(code: "capabilityPreparing")
        }
        do {
            return try captureReadyHandler(connectionEpoch, captureActivationID)
        } catch {
            return .failed(code: "capabilityPreparing")
        }
    }

    func refreshDuplicateCaptureReady(
        connectionEpoch: UInt64
    ) -> ProductionRuntimeBackendDisposition {
        var geometry: DisplayGeometryDTO?
        if let coordinator = deviceCoordinator,
           let helperExecutor,
           let snapshot = try? coordinator.refresh(),
           snapshot.connectionEpoch == connectionEpoch,
           let device = snapshot.device
        {
            geometry = try? Self.synchronizeCoordinateGeometry(
                coordinator: coordinator,
                helperExecutor: helperExecutor,
                device: device,
                snapshot: snapshot
            ).geometry
        }
        var members: [(String, RepositoryJSONValue)] = [
            ("captureProvenance", .string("postCapture")),
            ("connectionEpoch", .number(.uint64(connectionEpoch))),
            ("disposition", .string("alreadyReady")),
        ]
        if let geometry {
            Self.appendGeometry(geometry, to: &members)
        }
        guard let value = try? Self.object(members) else {
            return .failed(code: "capabilityPreparing")
        }
        return .succeeded(value: value)
    }

    func retireLiveGeneration(connectionEpoch: UInt64) {
        coordinateProjectionStore?.invalidateAll()
        helperExecutor?.retireForDetach(connectionEpoch: connectionEpoch)
        directHelperExecutor?.retireForDetach(connectionEpoch: connectionEpoch)
    }

    func refreshConnectionTransition(
        allowDetachment: Bool = true
    ) throws
        -> ProductionRuntimeConnectionTransition?
    {
        try deviceCoordinator?.refreshConnectionTransition(
            allowDetachment: allowDetachment
        )
    }

    func confirmDisconnected() throws
        -> ProductionRuntimeConnectionTransition?
    {
        try deviceCoordinator?.confirmDisconnected()
    }

    var hasPersistentLiveDemand: Bool {
        deviceCoordinator?.hasPersistentLiveDemand ?? false
    }

    var hasConnectedDevice: Bool {
        deviceCoordinator?.hasConnectedDevice ?? false
    }

    func installPointerObservationHandler(
        _ handler: @escaping ProductionRuntimePointerObservationSink.Handler
    ) {
        pointerObservationSink?.install(handler)
    }

    func probeConnectionPresence() throws -> Bool? {
        try deviceCoordinator?.probeConnectionPresence()
    }

    func executorDiagnosticSnapshot() -> ProductionCoreDeviceHelperDiagnosticSnapshot? {
        helperExecutor?.diagnosticSnapshot()
    }

    static func executorSummary(
        _ executor: ProductionCoreDeviceHelperDiagnosticSnapshot?
    ) throws -> RepositoryJSONObject {
        var members = [(String, RepositoryJSONValue)]()
        if let generation = executor?.activeExecutorGeneration {
      members.append(
        (
                "activeExecutorGeneration", .number(.uint64(generation))
            ))
        }
        if let provenance = executor?.activeProvenance {
            members.append(("activeProvenance", .string(provenance.rawValue)))
        }
    members.append(
      (
            "activeStreamCount",
            .number(.uint64(UInt64(executor?.activeStreamCount ?? 0)))
        ))
    members.append(
      (
            "captureReplacementPending",
            .bool(executor?.captureReplacementPending ?? false)
        ))
        if let connectionEpoch = executor?.connectionEpoch {
      members.append(
        (
                "connectionEpoch", .number(.uint64(connectionEpoch))
            ))
        }
        if let code = executor?.lastErrorCode {
            members.append(("lastErrorCode", .string(code)))
        }
        if let operation = executor?.lastFailureOperation {
            members.append(("lastFailureOperation", .string(operation.rawValue)))
        }
        if let stage = executor?.lastFailureStage {
            members.append(("lastFailureStage", .string(stage.rawValue)))
        }
        return try object(members)
    }

    public static func bundled(
        canonicalUDID: CanonicalUDID,
        runtimeEpoch: UInt64
    ) throws -> ProductionRuntimeOperationBackend {
        let coordinator = try ProductionRuntimeDeviceCoordinator.bundled(
            canonicalUDID: canonicalUDID
        )
    // Static developer-image compatibility data is not a Runtime startup
    // dependency. Device preparation pins its own dynamic catalog snapshot.
    let developerImageCatalog: DeveloperImageCatalogV1? = nil
    let developerImageRoot = URL(
      fileURLWithPath: try POSIXHostPathSystem()
                .makeHostPathLayout().developerImageStoreDirectory)
    let developerImageStore = try DeveloperImageAssetStore(
      rootURL: developerImageRoot
    )
    let dynamicDeveloperImageCatalogStore = try DynamicDeveloperImageCatalogStore(
      rootURL: developerImageRoot
    )
    let dynamicDeveloperImageAssetCache = try DynamicDeveloperImageAssetCache(
      rootURL: developerImageRoot
        )
        let supervisorRegistry = ProductionHelperSupervisorRegistry(
            runtimeEpoch: runtimeEpoch
        )
        let helperExecutor = try ProductionCoreDeviceHelperExecutor.bundled(
            runtimeEpoch: runtimeEpoch,
            supervisorRegistry: supervisorRegistry
        )
    let directHelperExecutor =
      try ProductionCoreDeviceHelperExecutor
            .bundledDirect(
                runtimeEpoch: runtimeEpoch,
                supervisorRegistry: supervisorRegistry
            )
        let screenshotStore = try ProductionScreenshotArtifactStore.bundled(
            canonicalUDID: canonicalUDID,
            runtimeEpoch: runtimeEpoch
        )
        let elementSnapshotPipeline = ProductionElementSnapshotPipeline.production(
            canonicalUDID: canonicalUDID,
            executablePath: Bundle.main.executablePath
                ?? CommandLine.arguments.first
                ?? ""
        )
        let coordinateProjectionStore =
            ProductionRuntimeCoordinateProjectionStore()
        let pointerObservationSink =
            ProductionRuntimePointerObservationSink()
        let preparationJobs = ProductionPreparationJobManager()
        let recordingStore = try? ProductionRuntimeRecordingStore.bundled(
            canonicalUDID: canonicalUDID
        )
        return ProductionRuntimeOperationBackend(
            deviceCoordinator: coordinator,
            helperExecutor: helperExecutor,
            directHelperExecutor: directHelperExecutor,
            elementSnapshotPipeline: elementSnapshotPipeline,
            recordingStore: recordingStore,
            screenshotStore: screenshotStore,
            coordinateProjectionStore: coordinateProjectionStore,
            pointerObservationSink: pointerObservationSink,
            captureReadyHandler: { connectionEpoch, _ in
                let snapshot = try coordinator.refresh()
                guard snapshot.connectionEpoch == connectionEpoch,
                      let device = snapshot.device
                else {
                    return .failed(code: "deviceDisconnected")
                }
                do {
                    var prewarmedGeometry: DisplayGeometryDTO?
                    let transition = try helperExecutor.markLiveCaptureReady(
                        device: device,
                        connectionEpoch: connectionEpoch
                    )
                    if transition.disposition != .deferred {
                        do {
                            let observed = try queryDisplayGeometry(
                                helperExecutor: helperExecutor,
                                device: device,
                                connectionEpoch: connectionEpoch,
                                requestedRevision: max(1, snapshot.geometryRevision)
                            )
                            let updated = try coordinator.synchronizeGeometry(
                                connectionEpoch: connectionEpoch,
                                logicalWidth: observed.logicalWidth,
                                logicalHeight: observed.logicalHeight,
                                orientation: observed.orientation
                            )
                            pointerLatencyLogger.notice(
                                "stage=geometryPrewarm outcome=succeeded connectionEpoch=\(connectionEpoch, privacy: .public) geometryRevision=\(updated.geometryRevision, privacy: .public)"
                            )
                            prewarmedGeometry = updated.geometry
                        } catch {
                            pointerLatencyLogger.error(
                                "stage=geometryPrewarm outcome=failed connectionEpoch=\(connectionEpoch, privacy: .public)"
                            )
                        }
                    }
                    var members: [(String, RepositoryJSONValue)] = [
                        ("captureProvenance", .string("postCapture")),
                        ("connectionEpoch", .number(.uint64(connectionEpoch))),
                        ("disposition", .string(transition.disposition.rawValue)),
                    ]
                    if let generation = transition.newExecutorGeneration {
            members.append(
              (
                            "newExecutorGeneration", .number(.uint64(generation))
                        ))
                    }
                    if let generation = transition.oldExecutorGeneration {
            members.append(
              (
                            "oldExecutorGeneration", .number(.uint64(generation))
                        ))
                    }
                    if let prewarmedGeometry {
                        appendGeometry(prewarmedGeometry, to: &members)
                    }
                    return .succeeded(value: try object(members))
                } catch ProductionCoreDeviceHelperExecutorError.invalidRequest {
                    return .failed(code: "protocolViolation")
                } catch {
                    return .failed(code: "capabilityPreparing")
                }
            }
        ) { request, clientInstanceID, elementCancellation, preparationProgress in
            switch request.operation {
            case .commandSubmit:
                recordTraceInvocation(request, store: recordingStore)
                let result = try executeCommand(
                    request,
                    coordinator: coordinator,
                    helperExecutor: helperExecutor,
                    directHelperExecutor: directHelperExecutor,
                    elementSnapshotPipeline: elementSnapshotPipeline,
                    screenshotStore: screenshotStore,
                    clientInstanceID: clientInstanceID,
                    elementCancellation: elementCancellation,
                    pointerObservationSink: pointerObservationSink,
                    developerImageCatalog: developerImageCatalog,
                    developerImageStore: developerImageStore,
          dynamicDeveloperImageCatalogStore: dynamicDeveloperImageCatalogStore,
          dynamicDeveloperImageAssetCache: dynamicDeveloperImageAssetCache,
                    preparationJobs: preparationJobs,
                    preparationProgress: preparationProgress,
                    selectedXcodeSnapshotProvider: {
                        ProductionSelectedXcodeSnapshot.capture(entry: $0)
                    }
                )
                recordTraceResult(
                    request,
                    result: result,
                    store: recordingStore
                )
                recordDiagnostic(
                    operation: request.operation,
                    outcome: terminalOutcome(result),
                    store: recordingStore
                )
                return result
            case .streamOpen:
                return try executeStreamOpen(
                    request,
                    coordinator: coordinator,
                    helperExecutor: helperExecutor,
                    coordinateProjectionStore: coordinateProjectionStore,
                    directHelperExecutor: directHelperExecutor,
                    developerImageCatalog: developerImageCatalog,
                    developerImageStore: developerImageStore,
          dynamicDeveloperImageCatalogStore: dynamicDeveloperImageCatalogStore,
          dynamicDeveloperImageAssetCache: dynamicDeveloperImageAssetCache,
                    preparationJobs: preparationJobs,
                    selectedXcodeSnapshotProvider: {
                        ProductionSelectedXcodeSnapshot.capture(entry: $0)
                    }
                )
            case .runtimePrepareCapabilities:
                return try executePreparationRequest(
                    request,
                    coordinator: coordinator,
                    helperExecutor: helperExecutor,
                    directHelperExecutor: directHelperExecutor,
                    developerImageCatalog: developerImageCatalog,
                    developerImageStore: developerImageStore,
          dynamicDeveloperImageCatalogStore: dynamicDeveloperImageCatalogStore,
          dynamicDeveloperImageAssetCache: dynamicDeveloperImageAssetCache,
                    preparationJobs: preparationJobs,
                    preparationProgress: preparationProgress,
                    selectedXcodeSnapshotProvider: {
                        ProductionSelectedXcodeSnapshot.capture(entry: $0)
                    }
                )
            case .runtimeCancelOwnedPendingWork:
                return try executeCancelOwnedPendingWork(
                    request,
                    canonicalUDID: canonicalUDID,
                    clientInstanceID: clientInstanceID,
                    pipeline: elementSnapshotPipeline
                )
            case .runtimeClearActionLogs:
                do {
                    let result = try ProductionActionLogMaintenance.bundled()
                        .clear(canonicalUDID: canonicalUDID)
                    guard result.outcome == .succeeded else {
            return .failed(
              code: result.skippedCount > 0
                            ? "controlBusy"
                            : "localWriteFailed")
                    }
          return .succeeded(
            value: try object([
              (
                "deletedFileCount",
                .number(
                  .uint64(
                            UInt64(result.deletedFileCount)
                  ))
              ),
                        ("deletedRecordCount", .number(.uint64(0))),
                        ("scanComplete", .bool(result.scanComplete)),
                        ("writerState", .string("unchanged")),
                    ]))
                } catch ProductionActionLogMaintenanceError.maintenanceBusy {
                    return .failed(code: "controlBusy")
                } catch ProductionActionLogMaintenanceError.unsafeHostPath {
                    return .failed(code: "unsafeHostPath")
                } catch {
                    return .failed(code: "localWriteFailed")
                }
            case .runtimeGetAvailabilitySnapshot:
                return .succeeded(value: try coordinator.availabilityValue())
            case .runtimeStartDiagnostics:
                guard let recordingStore else {
                    return .failed(code: "unsafeHostPath")
                }
                do {
                    let started = try recordingStore.startDiagnostics()
                    recordDiagnostic(
                        operation: request.operation,
                        outcome: .succeeded,
                        store: recordingStore
                    )
          return .succeeded(
            value: try object([
                        ("absolutePath", .string(started.absolutePath)),
                        (
                            "diagnosticsSessionID",
                            .string(started.sessionID.canonicalString)
                        ),
                    ]))
                } catch {
                    return recordingFailure(error, diagnostics: true)
                }
            case .runtimeStartReplayTrace:
                guard let recordingStore else {
                    return .failed(code: "unsafeHostPath")
                }
                do {
                    let started = try recordingStore.startTrace()
          return .succeeded(
            value: try object([
                        ("absolutePath", .string(started.absolutePath)),
                        ("traceID", .string(started.traceID.canonicalString)),
                    ]))
                } catch {
                    return recordingFailure(error, diagnostics: false)
                }
            case .runtimeStopDiagnostics:
                guard let recordingStore else {
                    return .failed(code: "noActiveDiagnostics")
                }
                recordDiagnostic(
                    operation: request.operation,
                    outcome: .succeeded,
                    store: recordingStore
                )
                do {
                    let stopped = try recordingStore.stopDiagnostics()
          return .succeeded(
            value: try object([
                        ("absolutePath", .string(stopped.absolutePath)),
                        (
                            "completeness",
                .string(
                  stopped.completeness == .complete
                                ? "complete" : "partial")
                        ),
                        (
                            "diagnosticsSessionID",
                            .string(stopped.sessionID.canonicalString)
                        ),
                    ]))
                } catch {
                    return recordingFailure(error, diagnostics: true)
                }
            case .runtimeStopReplayTrace:
                guard let recordingStore else {
                    return .failed(code: "noActiveTrace")
                }
                do {
                    let stopped = try recordingStore.stopTrace()
                    recordDiagnostic(
                        operation: request.operation,
                        outcome: .succeeded,
                        store: recordingStore
                    )
          return .succeeded(
            value: try object([
                        ("absolutePath", .string(stopped.absolutePath)),
                        (
                            "completeness",
                .string(
                  stopped.completeness == .complete
                                ? "complete" : "partial")
                        ),
                        ("traceID", .string(stopped.traceID.canonicalString)),
                    ]))
                } catch {
                    return recordingFailure(error, diagnostics: false)
                }
            case .streamCancel, .streamClose:
                return try executeStreamClose(
                    request,
                    helperExecutor: helperExecutor,
                    coordinateProjectionStore: coordinateProjectionStore
                )
            case .runtimeAttachLive, .runtimeDetachLive, .runtimeHealth,
                 .runtimeMarkLiveCaptureReady,
                 .runtimeRecordLocalAction, .runtimeRuntimeStatus,
                 .runtimeStopIfIdle:
                throw ProductionRuntimeServerError.invalidFrame
            }
        }
    }

    func bind(
        runtimeLock: RuntimeLock,
        manifestStore: HelperManifestStore
    ) {
        helperExecutor?.bind(
            runtimeLock: runtimeLock,
            manifestStore: manifestStore
        )
        directHelperExecutor?.bind(
            runtimeLock: runtimeLock,
            manifestStore: manifestStore
        )
    }

    func shutdown() {
        recordingStore?.shutdown()
        helperExecutor?.shutdown()
        directHelperExecutor?.shutdown()
        elementSnapshotPipeline?.shutdown()
        screenshotStore?.shutdown()
    }

    func recordingSnapshot() -> ProductionRuntimeRecordingSnapshot? {
        recordingStore?.snapshot
    }

    func stopReplayTraceForBootstrap() throws -> ReplayTraceFinalization {
        guard let recordingStore else {
            throw ProductionRuntimeRecordingError.noActiveTrace
        }
        return try recordingStore.stopTrace()
    }

    func handleStreamFrame(
        _ frame: RuntimeStreamFrameEnvelope,
        clientInstanceID: CanonicalUUID? = nil
    ) throws {
        if let streamFrameHandler {
            try streamFrameHandler(frame, clientInstanceID)
            return
        }
        guard let helperExecutor else {
            throw ProductionRuntimeServerError.invalidFrame
        }
        guard let coordinateProjectionStore else {
            throw ProductionRuntimeServerError.invalidFrame
        }
        let currentGeometry = try deviceCoordinator?
            .commandAdmissionSnapshot().geometry
        do {
            let payload = try coordinateProjectionStore.payload(
                for: frame,
                currentGeometry: currentGeometry
            )
            let acceptedAt = try helperExecutor.sendStreamFrame(
                frame,
                payloadOverride: payload
            )
            if let clientInstanceID,
               let currentGeometry,
               let frameKind = RuntimePointerFrameKind(
                   rawValue: frame.frameKind
               ),
               let x = frame.payload["x"]?.stringValue,
               let y = frame.payload["y"]?.stringValue,
               let edge = frame.payload["edge"]?.stringValue
            {
                pointerObservationSink?.publishAccepted(
                    clientInstanceID: clientInstanceID,
                    interactionID: frame.interactionID,
                    plan: ProductionRuntimePointerObservationPlan(
                        connectionEpoch: currentGeometry.connectionEpoch,
            frames: [
              ProductionRuntimeScheduledPointerProjection(
                            delayMilliseconds: 0,
                            projection: RuntimePointerProjection(
                                edge: edge,
                                frameKind: frameKind,
                                x: x,
                                y: y
                            )
              )
            ]
                    )
                )
            }
            if frame.frameKind == "begin" {
                Self.pointerLatencyLogger.notice(
                    "stage=p2 sessionID=\(frame.sessionID.canonicalString, privacy: .public) interactionID=\(frame.interactionID.canonicalString, privacy: .public) sequence=\(frame.sequence, privacy: .public) acceptedMonotonicNs=\(acceptedAt ?? 0, privacy: .public) clientSubmittedMonotonicNs=\(frame.clientSubmittedMonotonicNanoseconds ?? 0, privacy: .public)"
                )
            }
        } catch {
            coordinateProjectionStore.remove(
                sessionID: frame.sessionID,
                interactionID: frame.interactionID
            )
            throw error
        }
    }

    private static func recordTraceInvocation(
        _ request: RuntimeRequestEnvelope,
        store: ProductionRuntimeRecordingStore?
    ) {
        guard let store,
              let actionText = request.body["actionID"]?.stringValue,
              let actionID = try? CanonicalUUID(actionText),
              let commandID = request.body["commandID"]?.stringValue,
              let event = try? ReplayTraceSemanticEvent(
                  actionID: actionID,
                  commandID: commandID,
                  eventKind: .invocation,
                  payloadByteCount: UInt64(
                      RepositoryCanonicalJSON.encodeDocument(request.body).count
                  )
              )
        else { return }
        store.recordTrace(event)
    }

    private static func recordTraceResult(
        _ request: RuntimeRequestEnvelope,
        result: ProductionRuntimeBackendDisposition,
        store: ProductionRuntimeRecordingStore?
    ) {
        guard let store,
              let actionText = request.body["actionID"]?.stringValue,
              let actionID = try? CanonicalUUID(actionText),
              let commandID = request.body["commandID"]?.stringValue,
              let event = try? ReplayTraceSemanticEvent(
                  actionID: actionID,
                  commandID: commandID,
                  eventKind: .result,
                  outcome: terminalOutcome(result)
              )
        else { return }
        store.recordTrace(event)
    }

    private static func recordDiagnostic(
        operation: RuntimeOperationID,
        outcome: ActionLogTerminalOutcome,
        store: ProductionRuntimeRecordingStore?
    ) {
    guard
      let event = try? DiagnosticLogEvent(
            category: .backend,
            code: "\(operation.rawValue).\(outcome.rawValue)"
      )
    else { return }
        store?.recordDiagnostic(event)
    }

    private static func terminalOutcome(
        _ result: ProductionRuntimeBackendDisposition
    ) -> ActionLogTerminalOutcome {
        switch result {
        case .artifact, .succeeded:
            return .succeeded
        case .failed, .failedWithDetails:
            return .failed
        case .outcomeUnknown:
            return .outcomeUnknown
        case .standard(let value):
            return ActionLogTerminalOutcome(
                rawValue: value["outcome"]?.stringValue ?? "failed"
            ) ?? .failed
        }
    }

    private static func recordingFailure(
        _ error: Error,
        diagnostics: Bool
    ) -> ProductionRuntimeBackendDisposition {
        switch error as? ProductionRuntimeRecordingError {
        case .diagnosticsAlreadyActive:
            return .failed(code: "diagnosticsAlreadyActive")
        case .noActiveDiagnostics:
            return .failed(code: "noActiveDiagnostics")
        case .noActiveTrace:
            return .failed(code: "noActiveTrace")
        case .traceAlreadyActive:
            return .failed(code: "traceAlreadyActive")
        case .unsafeHostPath:
            return .failed(code: "unsafeHostPath")
        case .diagnosticWriteFailed, .traceWriteFailed, .none:
      return .failed(
        code: diagnostics
                ? "diagnosticWriteFailed"
                : "traceWriteFailed")
        }
    }

    static func executeCommand(
        _ request: RuntimeRequestEnvelope,
        coordinator: ProductionRuntimeDeviceCoordinator,
        helperExecutor: ProductionCoreDeviceHelperExecutor,
        directHelperExecutor: ProductionCoreDeviceHelperExecutor,
        elementSnapshotPipeline: ProductionElementSnapshotPipeline? = nil,
        screenshotStore: ProductionScreenshotArtifactStore,
        clientInstanceID: CanonicalUUID?,
        elementCancellation: ProductionElementSnapshotCancellation? = nil,
        pointerObservationSink: ProductionRuntimePointerObservationSink,
        developerImageCatalog: DeveloperImageCatalogV1? = nil,
        developerImageStore: DeveloperImageAssetStore? = nil,
    dynamicDeveloperImageCatalogStore: DynamicDeveloperImageCatalogStore? = nil,
    dynamicDeveloperImageAssetCache: DynamicDeveloperImageAssetCache? = nil,
        preparationJobs: ProductionPreparationJobManager? = nil,
        preparationProgress: PreparationProgressHandler? = nil,
    selectedXcodeSnapshotProvider:
      @escaping @Sendable (
            DeveloperImageCatalogEntryV1
        ) -> SelectedXcodeSnapshot? = { _ in nil }
    ) throws -> ProductionRuntimeBackendDisposition {
        guard let commandID = request.body["commandID"]?.stringValue,
              let argumentsObject = request.body["normalizedArguments"]?.objectValue,
              let actionID = canonicalUUID(request.body["actionID"]),
              let arguments = stringArguments(argumentsObject)
        else {
            return .failed(code: "invalidArgument")
        }
        let admissionStartedAt = DispatchTime.now().uptimeNanoseconds
        logTouchStage(
            "admissionStart",
            commandID: commandID,
            actionID: actionID
        )
        if commandID.hasPrefix("button.") {
            toolbarLatencyLogger.notice(
                "stage=admissionStart commandID=\(commandID, privacy: .public) actionID=\(actionID.canonicalString, privacy: .public)"
            )
        }
        let parentActionID = optionalCanonicalUUID(request.body["parentActionID"])
        if commandID == "app.install" {
            guard let ipaPath = arguments["ipaPath"],
                  validIPAPathForExecution(ipaPath)
            else {
                return .failedWithDetails(
                    code: "invalidIPAPath",
                    details: try invalidIPAPathDetails()
                )
            }
        }
        if commandID == "element.snapshot" {
            return try executeElementSnapshot(
                request: request,
                actionID: actionID,
                parentActionID: parentActionID,
                arguments: arguments,
                coordinator: coordinator,
                helperExecutor: helperExecutor,
                directHelperExecutor: directHelperExecutor,
                screenshotStore: screenshotStore,
                pipeline: elementSnapshotPipeline,
                ownerClientInstanceID: clientInstanceID,
                cancellation: elementCancellation,
                developerImageCatalog: developerImageCatalog,
                developerImageStore: developerImageStore,
        dynamicDeveloperImageCatalogStore: dynamicDeveloperImageCatalogStore,
        dynamicDeveloperImageAssetCache: dynamicDeveloperImageAssetCache,
                preparationJobs: preparationJobs,
                preparationProgress: preparationProgress,
                selectedXcodeSnapshotProvider: selectedXcodeSnapshotProvider
            )
        }
        if commandID == "screenshot.cli" || commandID == "screenshot.gui" {
            do {
                if let preparationFailure = try executeHybridCapturePreparationPreflight(
                    commandID: commandID,
                    actionID: actionID,
                    arguments: arguments,
                    coordinator: coordinator,
                    helperExecutor: helperExecutor,
                    directHelperExecutor: directHelperExecutor,
                    developerImageCatalog: developerImageCatalog,
                    developerImageStore: developerImageStore,
          dynamicDeveloperImageCatalogStore: dynamicDeveloperImageCatalogStore,
          dynamicDeveloperImageAssetCache: dynamicDeveloperImageAssetCache,
                    preparationJobs: preparationJobs,
                    selectedXcodeSnapshotProvider: selectedXcodeSnapshotProvider
                ) {
                    return preparationFailure
                }
                let (snapshot, routeID) = try coordinator.planScreenshot(
                    commandID: commandID,
                    rawArguments: arguments
                )
                guard let device = snapshot.device else {
                    return .failed(code: "deviceDisconnected")
                }
                return try executeScreenshot(
                    request: request,
                    actionID: actionID,
                    parentActionID: parentActionID,
                    routeID: routeID,
                    device: device,
                    connectionEpoch: snapshot.connectionEpoch,
                    helperExecutor: routeID
                        == ScreenshotRoute.legacyScreenshotR.rawValue
                        ? directHelperExecutor
                        : helperExecutor,
                    screenshotStore: screenshotStore
                )
            } catch ProductionRuntimeDeviceCoordinatorError.screenshotUnavailable(
                let reason
            ) {
                return .failed(code: reason)
            } catch {
                return .failed(code: "invalidArgument")
            }
        }
        var snapshot = try coordinator.commandAdmissionSnapshot()
        logTouchStage(
            "admissionComplete",
            commandID: commandID,
            actionID: actionID,
            connectionEpoch: snapshot.connectionEpoch
        )
        guard let device = snapshot.device else {
            return .failed(code: "deviceDisconnected")
        }
        let requiresPreparationBeforeGeometry: Bool
        do {
            switch try coordinator.plan(
                commandID: commandID,
                rawArguments: arguments,
                snapshot: snapshot
            ) {
            case .awaitingPreparation:
                requiresPreparationBeforeGeometry = true
            case .unknown(let reason) where reason == "displayGeometryUnavailable":
                requiresPreparationBeforeGeometry = true
            case .planned, .unavailable, .unknown, .notRuntimePlannable:
                requiresPreparationBeforeGeometry = false
            }
        } catch {
            return .failed(code: "invalidArgument")
        }
        if requiresPreparationBeforeGeometry {
            if let preparationFailure = try executeImplicitPreparationIfNeeded(
                commandID: commandID,
                actionID: actionID,
                device: device,
                snapshot: snapshot,
                coordinator: coordinator,
                helperExecutor: helperExecutor,
                directHelperExecutor: directHelperExecutor,
                developerImageCatalog: developerImageCatalog,
                developerImageStore: developerImageStore,
        dynamicDeveloperImageCatalogStore: dynamicDeveloperImageCatalogStore,
        dynamicDeveloperImageAssetCache: dynamicDeveloperImageAssetCache,
                preparationJobs: preparationJobs,
                selectedXcodeSnapshotProvider: selectedXcodeSnapshotProvider
            ) {
                return preparationFailure
            }
            snapshot = try coordinator.commandAdmissionSnapshot()
        }
        var rotateGeometryWasInvalidated = false
        defer {
            if rotateGeometryWasInvalidated {
                do {
                    _ = try recoverInvalidatedRotateGeometry(
                        coordinator: coordinator,
                        connectionEpoch: snapshot.connectionEpoch,
                        query: { requestedRevision in
                            try queryDisplayGeometry(
                                helperExecutor: helperExecutor,
                                device: device,
                                connectionEpoch: snapshot.connectionEpoch,
                                requestedRevision: requestedRevision
                            )
                        }
                    )
                } catch {
                    pointerLatencyLogger.error(
                        "stage=rotateGeometryRecovery outcome=failed connectionEpoch=\(snapshot.connectionEpoch, privacy: .public)"
                    )
                }
            }
        }
        let planning: PlanningResult
        do {
            let result = try planCommandForExecution(
                commandID: commandID,
                rawArguments: arguments,
                coordinator: coordinator,
                snapshot: snapshot,
                refreshCoordinateGeometry: { current in
                    logTouchStage(
                        "geometryStart",
                        commandID: commandID,
                        actionID: actionID,
                        connectionEpoch: current.connectionEpoch
                    )
                    let updated = try synchronizeCoordinateGeometry(
                        coordinator: coordinator,
                        helperExecutor: helperExecutor,
                        device: device,
                        snapshot: current
                    )
                    logTouchStage(
                        "geometryComplete",
                        commandID: commandID,
                        actionID: actionID,
                        connectionEpoch: updated.connectionEpoch
                    )
                    return updated
                }
            )
            snapshot = result.snapshot
            planning = result.planning
            logTouchStage(
                "planningComplete",
                commandID: commandID,
                actionID: actionID,
                connectionEpoch: snapshot.connectionEpoch
            )
        } catch ProductionRuntimeCommandPlanningError.geometryUnavailable {
            if isCoordinateCommand(commandID) {
                touchRouteAuditLogger.error(
                    "stage=geometryRefresh outcome=failed commandID=\(commandID, privacy: .public) actionID=\(actionID.canonicalString, privacy: .public)"
                )
            }
            return .failed(code: "capabilityUnavailable")
        } catch {
            return .failed(code: "invalidArgument")
        }
        switch planning {
        case .awaitingPreparation:
            logTouchPlanning(commandID: commandID, actionID: actionID, outcome: "awaitingPreparation")
            if let preparationFailure = try executeImplicitPreparationIfNeeded(
                commandID: commandID,
                actionID: actionID,
                device: device,
                snapshot: snapshot,
                coordinator: coordinator,
                helperExecutor: helperExecutor,
                directHelperExecutor: directHelperExecutor,
                developerImageCatalog: developerImageCatalog,
                developerImageStore: developerImageStore,
        dynamicDeveloperImageCatalogStore: dynamicDeveloperImageCatalogStore,
        dynamicDeveloperImageAssetCache: dynamicDeveloperImageAssetCache,
                preparationJobs: preparationJobs,
                selectedXcodeSnapshotProvider: selectedXcodeSnapshotProvider
            ) {
                return preparationFailure
            }
            return .failed(code: "capabilityPreparing")
        case .unavailable(let reason), .unknown(let reason):
            logTouchPlanning(commandID: commandID, actionID: actionID, outcome: reason)
            return try planningFailure(
                commandID: commandID,
                reason: reason,
                snapshot: snapshot,
                coordinator: coordinator
            )
        case .notRuntimePlannable:
            logTouchPlanning(commandID: commandID, actionID: actionID, outcome: "notRuntimePlannable")
            return .failed(code: "invalidArgument")
        case .planned(let plan):
            guard plan.kind == .oneShot, let candidate = plan.candidates.first else {
                logTouchPlanning(commandID: commandID, actionID: actionID, outcome: "noOneShotCandidate")
                return .failed(code: "capabilityUnavailable")
            }
      logTouchPlanning(
        commandID: commandID, actionID: actionID, outcome: "planned", routeID: candidate.routeID)
      guard
        let backendPayload = try helperBackendPayload(
                commandID: commandID,
                arguments: arguments,
                snapshot: snapshot
        )
      else {
        logTouchPlanning(
          commandID: commandID, actionID: actionID, outcome: "payloadUnavailable",
          routeID: candidate.routeID)
                return .failed(code: "capabilityUnavailable")
            }
            let pointerObservationPlan = try pointerObservationPlan(
                commandID: commandID,
                arguments: arguments,
                connectionEpoch: snapshot.connectionEpoch
            )
            if commandID == "device.rotate" {
                let invalidated = try coordinator.invalidateGeometry(
                    connectionEpoch: snapshot.connectionEpoch,
                    geometryRevision: snapshot.geometryRevision
                )
                guard invalidated.geometry == nil,
                      invalidated.geometryRevision == snapshot.geometryRevision
                else {
                    return .failed(code: "capabilityUnavailable")
                }
                rotateGeometryWasInvalidated = true
            }
            do {
                let executorStartedAt = DispatchTime.now().uptimeNanoseconds
                if commandID.hasPrefix("button.") {
                    toolbarLatencyLogger.notice(
                        "stage=executorStart commandID=\(commandID, privacy: .public) actionID=\(actionID.canonicalString, privacy: .public) admissionUs=\(elapsedMicroseconds(admissionStartedAt, executorStartedAt), privacy: .public)"
                    )
                }
        let executor =
          usesDirectHelper(routeID: candidate.routeID)
                    ? directHelperExecutor
                    : helperExecutor
                logTouchStage(
                    "helperOneShotStart",
                    commandID: commandID,
                    actionID: actionID,
                    connectionEpoch: snapshot.connectionEpoch,
                    routeID: candidate.routeID
                )
                if commandID == "app.install" {
                    appInstallLogger.notice(
                        "stage=started actionID=\(actionID.canonicalString, privacy: .public) commandID=app.install routeID=\(candidate.routeID, privacy: .public) pathRedacted=true"
                    )
                }
                let result = try executor.executeOneShot(
                    requestID: request.requestID,
                    actionID: actionID,
                    parentActionID: parentActionID,
                    routeID: candidate.routeID,
                    backendPayload: backendPayload,
                    device: device,
                    connectionEpoch: snapshot.connectionEpoch,
                    completionBarrierTimeoutMilliseconds: [
                        "coredevice.keyboardMacro",
                        "coredevice.softwareKeyboardToggle",
                    ].contains(candidate.routeID) ? 2_000 : nil,
                    onAccepted: {
                        guard let clientInstanceID,
                              let pointerObservationPlan
                        else { return }
                        pointerObservationSink.publishAccepted(
                            clientInstanceID: clientInstanceID,
                            interactionID: actionID,
                            plan: pointerObservationPlan
                        )
                    }
                )
                if isCoordinateCommand(commandID) {
                    let outcome = result["outcome"]?.stringValue ?? "missing"
                    let errorCode = result["error"]?.objectValue?["code"]?.stringValue ?? "none"
                    logTouchStage(
                        "helperOneShotTerminal",
                        commandID: commandID,
                        actionID: actionID,
                        connectionEpoch: snapshot.connectionEpoch,
                        routeID: candidate.routeID,
                        outcome: outcome,
                        errorCode: errorCode
                    )
                    touchRouteAuditLogger.notice(
                        "stage=helperTerminal commandID=\(commandID, privacy: .public) actionID=\(actionID.canonicalString, privacy: .public) routeID=\(candidate.routeID, privacy: .public) outcome=\(outcome, privacy: .public) errorCode=\(errorCode, privacy: .public)"
                    )
                }
                if commandID == "app.install" {
                    let outcome = result["outcome"]?.stringValue ?? "invalidResponse"
          let errorCode =
            result["error"]?.objectValue?["code"]?
                        .stringValue ?? "none"
                    appInstallLogger.notice(
                        "stage=terminal actionID=\(actionID.canonicalString, privacy: .public) commandID=app.install routeID=\(candidate.routeID, privacy: .public) outcome=\(outcome, privacy: .public) errorCode=\(errorCode, privacy: .public) pathRedacted=true"
                    )
                }
                let executorCompletedAt = DispatchTime.now().uptimeNanoseconds
                if commandID.hasPrefix("button.") {
                    toolbarLatencyLogger.notice(
                        "stage=executorEnd commandID=\(commandID, privacy: .public) actionID=\(actionID.canonicalString, privacy: .public) executorUs=\(elapsedMicroseconds(executorStartedAt, executorCompletedAt), privacy: .public) totalUs=\(elapsedMicroseconds(admissionStartedAt, executorCompletedAt), privacy: .public)"
                    )
                }
        return .standard(
          result: try projectCommandResult(
                    commandID: commandID,
                    arguments: arguments,
                    helperResult: result,
                    coordinator: coordinator,
                    connectionEpoch: snapshot.connectionEpoch,
                    previousGeometry: snapshot.geometry
                ))
            } catch ProductionCoreDeviceHelperExecutorError
        .helperUnavailableBeforeRequest
      {
                if commandID == "app.launch" {
          return .standard(
            result: try appLaunchFailedResult(
                        stage: "helperStartup"
                    ))
                }
                if commandID == "app.list" {
          return .standard(
            result: try appListFailureResult(
                        code: "backendFailed",
                        stage: "helperStartup"
                    ))
                }
                if commandID == "app.install" {
                    logInstallExecutorFailure(
                        actionID: actionID,
                        routeID: candidate.routeID,
                        code: "installFailed",
                        outcome: "failed"
                    )
                    return .standard(
                        result: try installFailedNotCommittedResult(
                            stage: "helperStartup"
                        )
                    )
                }
                if commandID == "app.uninstall" {
                    return .standard(
                        result: try uninstallFailedNotCommittedResult(
                            stage: "helperStartup"
                        )
                    )
                }
                return .outcomeUnknown(code: "transportFailure")
            } catch ProductionCoreDeviceHelperExecutorError.invalidRequest {
                if commandID == "app.list" {
          return .standard(
            result: try appListFailureResult(
                        code: "backendFailed",
                        stage: "resultNormalize"
                    ))
                }
                if commandID == "app.install" {
                    logInstallExecutorFailure(
                        actionID: actionID,
                        routeID: candidate.routeID,
                        code: "invalidArgument",
                        outcome: "failed"
                    )
                }
                if commandID == "app.uninstall" {
                    return .standard(
                        result: try uninstallFailedNotCommittedResult(
                            stage: "requestValidation"
                        )
                    )
                }
                return .failed(code: "invalidArgument")
            } catch ProductionCoreDeviceHelperExecutorError.resourceBusy {
                return .failed(code: "resourceBusy")
            } catch ProductionCoreDeviceHelperExecutorError.timedOut {
                if commandID == "app.launch" {
                    return .standard(result: try appLaunchOutcomeUnknownResult())
                }
                if commandID == "app.list" {
          return .standard(
            result: try appListFailureResult(
                        code: "executionTimeout",
                        stage: "browseDeadline"
                    ))
                }
                if commandID == "app.install" {
                    logInstallExecutorFailure(
                        actionID: actionID,
                        routeID: candidate.routeID,
                        code: "outcomeUnknown"
                    )
                    return .standard(result: try installOutcomeUnknownResult())
                }
                if commandID == "app.uninstall" {
                    return .standard(result: try uninstallOutcomeUnknownResult())
                }
                return .outcomeUnknown(code: "executionTimeout")
            } catch {
                if commandID == "app.launch" {
                    return .standard(result: try appLaunchOutcomeUnknownResult())
                }
                if commandID == "app.list" {
          return .standard(
            result: try appListFailureResult(
                        code: "transportFailure",
                        stage: "browseReceive"
                    ))
                }
                if commandID == "app.install" {
                    logInstallExecutorFailure(
                        actionID: actionID,
                        routeID: candidate.routeID,
                        code: "outcomeUnknown"
                    )
                    return .standard(result: try installOutcomeUnknownResult())
                }
                if commandID == "app.uninstall" {
                    return .standard(result: try uninstallOutcomeUnknownResult())
                }
                return .outcomeUnknown(code: "transportFailure")
            }
        }
    }

    static func usesDirectHelper(routeID: String) -> Bool {
        routeID == "direct.installationProxy.browse"
            || routeID == "direct.installationProxy.install"
            || routeID == "direct.installationProxy.uninstall"
            || routeID == "legacy.dvtLaunch"
            || routeID == ScreenshotRoute.legacyScreenshotR.rawValue
    }

    static func appLaunchOutcomeUnknownResult() throws -> RepositoryJSONObject {
        try object([
            ("commitState", .string("unknown")),
      (
        "error",
        .object(
          try object([
                ("code", .string("outcomeUnknown")),
            (
              "details",
              .object(
                try object([
                  ("reason", .string("commitStateUnknown"))
                ]))
            ),
          ]))
      ),
            ("outcome", .string("outcomeUnknown")),
        ])
    }

    static func appLaunchFailedResult(
        stage: String
    ) throws -> RepositoryJSONObject {
        try object([
            ("commitState", .string("notCommitted")),
      (
        "error",
        .object(
          try object([
                ("code", .string("appLaunchFailed")),
            (
              "details",
              .object(
                try object([
                    ("commitState", .string("notCommitted")),
                    ("stage", .string(stage)),
                ]))
            ),
          ]))
      ),
            ("outcome", .string("failed")),
        ])
    }

    static func appListFailureResult(
        code: String,
        stage: String
    ) throws -> RepositoryJSONObject {
        try object([
            ("commitState", .string("notCommitted")),
      (
        "error",
        .object(
          try object([
                ("code", .string(code)),
            (
              "details",
              .object(
                try object([
                    ("commitState", .string("notCommitted")),
                    ("stage", .string(stage)),
                ]))
            ),
          ]))
      ),
            ("outcome", .string("failed")),
        ])
    }

    static func invalidIPAPathDetails() throws -> RepositoryJSONObject {
        try object([
            ("argumentName", .string("ipaPath")),
            ("reason", .string("notCanonicalRegularIPA")),
        ])
    }

    static func installOutcomeUnknownResult() throws -> RepositoryJSONObject {
        try object([
            ("commitState", .string("unknown")),
      (
        "error",
        .object(
          try object([
                ("code", .string("outcomeUnknown")),
            (
              "details",
              .object(
                try object([
                  ("reason", .string("commitStateUnknown"))
                ]))
            ),
          ]))
      ),
            ("outcome", .string("outcomeUnknown")),
        ])
    }

    static func installFailedNotCommittedResult(
        stage: String
    ) throws -> RepositoryJSONObject {
        try object([
            ("commitState", .string("notCommitted")),
      (
        "error",
        .object(
          try object([
                ("code", .string("installFailed")),
            (
              "details",
              .object(
                try object([
                    ("commitState", .string("notCommitted")),
                    ("stage", .string(stage)),
                ]))
            ),
          ]))
      ),
            ("outcome", .string("failed")),
        ])
    }

    static func uninstallOutcomeUnknownResult() throws -> RepositoryJSONObject {
        try installOutcomeUnknownResult()
    }

    static func uninstallFailedNotCommittedResult(
        stage: String
    ) throws -> RepositoryJSONObject {
        try object([
            ("commitState", .string("notCommitted")),
      (
        "error",
        .object(
          try object([
                ("code", .string("uninstallFailed")),
            (
              "details",
              .object(
                try object([
                    ("commitState", .string("notCommitted")),
                    ("stage", .string(stage)),
                ]))
            ),
          ]))
      ),
            ("outcome", .string("failed")),
        ])
    }

    private static func logInstallExecutorFailure(
        actionID: CanonicalUUID,
        routeID: String,
        code: String,
        outcome: String = "outcomeUnknown"
    ) {
        appInstallLogger.error(
            "stage=terminal actionID=\(actionID.canonicalString, privacy: .public) commandID=app.install routeID=\(routeID, privacy: .public) outcome=\(outcome, privacy: .public) errorCode=\(code, privacy: .public) pathRedacted=true"
        )
    }

    private struct ElementCaptureDispositionError: Error {
        let disposition: ProductionRuntimeBackendDisposition
    }

    private struct ElementAuthorityChangedError: Error {}

    private static func executeElementSnapshot(
        request: RuntimeRequestEnvelope,
        actionID: CanonicalUUID,
        parentActionID: CanonicalUUID?,
        arguments: [String: String],
        coordinator: ProductionRuntimeDeviceCoordinator,
        helperExecutor: ProductionCoreDeviceHelperExecutor,
        directHelperExecutor: ProductionCoreDeviceHelperExecutor,
        screenshotStore: ProductionScreenshotArtifactStore,
        pipeline: ProductionElementSnapshotPipeline?,
        ownerClientInstanceID: CanonicalUUID?,
        cancellation: ProductionElementSnapshotCancellation?,
        developerImageCatalog: DeveloperImageCatalogV1?,
        developerImageStore: DeveloperImageAssetStore?,
    dynamicDeveloperImageCatalogStore: DynamicDeveloperImageCatalogStore? = nil,
    dynamicDeveloperImageAssetCache: DynamicDeveloperImageAssetCache? = nil,
        preparationJobs: ProductionPreparationJobManager? = nil,
        preparationProgress: PreparationProgressHandler? = nil,
    selectedXcodeSnapshotProvider:
      @escaping @Sendable (
            DeveloperImageCatalogEntryV1
        ) -> SelectedXcodeSnapshot? = { _ in nil }
    ) throws -> ProductionRuntimeBackendDisposition {
        guard let pipeline,
              Set(arguments.keys).isSubset(of: [
                  "format", "internalAnalyzers",
              ])
        else {
            return .failed(code: "invalidArgument")
        }
        let format = arguments["format"] ?? "json"
        guard ["annotated", "both", "json"].contains(format) else {
            return .failed(code: "invalidArgument")
        }
    guard
      let analyzerSelection = elementAnalyzerSelection(
            rawValue: arguments["internalAnalyzers"]
      )
    else {
            return .failed(code: "invalidArgument")
        }
        let includeAnnotation = format != "json"
    let annotationArtifactID =
      includeAnnotation
            ? CanonicalUUID(value: UUID()) : nil
        var planningArguments = [
            "force": "false",
            "format": format,
        ]
        if includeAnnotation {
            planningArguments["outputPath"] =
                "/__pulsephone_client_owned__/element-annotation.png"
        }

        do {
            if let preparationFailure = try executeHybridCapturePreparationPreflight(
                commandID: "element.snapshot",
                actionID: actionID,
                arguments: planningArguments,
                coordinator: coordinator,
                helperExecutor: helperExecutor,
                directHelperExecutor: directHelperExecutor,
                developerImageCatalog: developerImageCatalog,
                developerImageStore: developerImageStore,
        dynamicDeveloperImageCatalogStore: dynamicDeveloperImageCatalogStore,
        dynamicDeveloperImageAssetCache: dynamicDeveloperImageAssetCache,
                preparationJobs: preparationJobs,
                selectedXcodeSnapshotProvider: selectedXcodeSnapshotProvider
            ) {
                return preparationFailure
            }
      let requestCancellation =
        cancellation
                ?? ProductionElementSnapshotCancellation()
            let timeoutNanoseconds = UInt64(
                elementOuterSafetyDeadlineSeconds(
                    includeAnnotation: includeAnnotation
                ) * 1_000_000_000
            )
            let deadline = DispatchTime.now().uptimeNanoseconds
                .addingReportingOverflow(timeoutNanoseconds)
            guard !deadline.overflow else {
                return .failed(code: "internalFailure")
            }
            return try pipeline.withRequest(
                requestID: request.requestID,
                cancellation: requestCancellation,
                ownerClientInstanceID: ownerClientInstanceID,
                deadlineNanoseconds: deadline.partialValue
            ) {
                for attemptIndex in 0...1 {
                    if DispatchTime.now().uptimeNanoseconds >= deadline.partialValue {
                        throw ProductionElementSnapshotPipelineError.analysisTimedOut
                    }
                    let attemptCancellation = ProductionElementSnapshotCancellation()
                    do {
                        let (snapshot, routeID) = try coordinator.planScreenshot(
                            commandID: "element.snapshot",
                            rawArguments: planningArguments
                        )
                        guard let device = snapshot.device else {
                            return .failed(code: "deviceDisconnected")
                        }
            let geometrySnapshot =
              snapshot.geometry == nil
                            ? try synchronizeCoordinateGeometry(
                                coordinator: coordinator,
                                helperExecutor: helperExecutor,
                                device: device,
                                snapshot: snapshot
                            )
                            : snapshot
            guard
              let authority = ProductionRuntimeElementSnapshotAuthority(
                            snapshot: geometrySnapshot
              )
            else {
                            return .failed(code: "capabilityUnavailable")
                        }
                        let geometry = authority.geometry
            let authorityObserver =
              coordinator
                            .observeElementSnapshotAuthority(authority) {
                                attemptCancellation.cancel(cause: .authorityChanged)
                            }
                        defer {
                            coordinator.removeElementSnapshotAuthorityObserver(
                                authorityObserver
                            )
                        }
            let captureExecutor =
              routeID
                            == ScreenshotRoute.legacyScreenshotR.rawValue
                            ? directHelperExecutor : helperExecutor
                        let captureRequestID = CanonicalUUID(value: UUID())
                        let captureKey = ProductionElementDeviceCaptureKey(
                            geometry: geometry,
                            providerPlanID: routeID
                                == ScreenshotRoute.modernCoreDevice.rawValue
                                ? Self.modernElementCaptureProviderPlanID
                                : "legacyScreenshotR",
                            targetIdentity: authority.uniqueDeviceID
                        )
                        let output = try pipeline.runAttempt(
                            requestID: request.requestID,
                            cancellation: attemptCancellation,
                            includeAnnotation: includeAnnotation,
                            artifactID: annotationArtifactID,
                            deadlineNanoseconds: deadline.partialValue,
                            analyzerSelection: analyzerSelection,
                            captureKey: captureKey,
                            capture: { producerCancellation in
                                let capture = try captureElementImage(
                                    requestID: captureRequestID,
                                    actionID: actionID,
                                    parentActionID: parentActionID,
                                    routeID: routeID,
                                    device: device,
                                    connectionEpoch: authority.connectionEpoch,
                                    geometry: geometry,
                                    helperExecutor: captureExecutor,
                                    screenshotStore: screenshotStore,
                                    cancellation: producerCancellation
                                )
                                try requireCurrentElementAuthority(
                                    coordinator: coordinator,
                                    authority: authority,
                                    cancellation: producerCancellation
                                )
                                return capture
                            }
                        )
                        try requireCurrentElementAuthority(
                            coordinator: coordinator,
                            authority: authority,
                            cancellation: attemptCancellation
                        )
            guard
              try elementResponseFitsWireCap(
                            value: output.result.root,
                            request: request,
                            actionID: actionID,
                            parentActionID: parentActionID
              )
            else {
                            return .failed(code: "artifactTooLarge")
                        }
                        guard let annotation = output.annotation,
                              let annotationArtifactID
                        else {
                            try checkElementAttemptCancellation(attemptCancellation)
                            return .succeeded(value: output.result.root)
                        }
                        let binding = try ElementAnnotationArtifactBinding(
                            snapshotGeneration: annotation.snapshotGeneration,
                            captureSHA256: annotation.captureSHA256,
                            pixelWidth: annotation.dimensions.width,
                            pixelHeight: annotation.dimensions.height
                        )
                        try checkElementAttemptCancellation(attemptCancellation)
                        let delivery = try screenshotStore.storeGeneratedPNG(
                            artifactID: annotationArtifactID,
                            bytes: annotation.bytes
                        )
                        do {
                            try checkElementAttemptCancellation(attemptCancellation)
                        } catch {
                            _ = Darwin.close(delivery.descriptor)
                            throw error
                        }
                        return .artifact(
                            descriptor: delivery.descriptor,
                            artifactID: delivery.artifactID,
                            sizeBytes: delivery.byteCount,
                            binding: .elementAnnotation(binding),
                            value: output.result.root
                        )
                    } catch ProductionElementSnapshotPipelineError.cancelled
                        where attemptCancellation.cancellationCause == .authorityChanged
                            && !requestCancellation.isCancelled
                    {
                        if attemptIndex == 0 { continue }
            return .failed(
              code: coordinator.hasConnectedDevice
                            ? "capabilityUnavailable" : "deviceDisconnected")
                    } catch is ElementAuthorityChangedError {
                        guard !requestCancellation.isCancelled else {
                            throw ProductionElementSnapshotPipelineError.cancelled
                        }
                        if attemptIndex == 0 { continue }
            return .failed(
              code: coordinator.hasConnectedDevice
                            ? "capabilityUnavailable" : "deviceDisconnected")
                    }
                }
                return .failed(code: "capabilityUnavailable")
            }
        } catch let error as ElementCaptureDispositionError {
            return error.disposition
        } catch ProductionRuntimeDeviceCoordinatorError.screenshotUnavailable(
            let reason
        ) {
            return .failed(code: reason)
        } catch ProductionElementSnapshotPipelineError.busy {
            return .failed(code: "capabilityUnavailable")
        } catch ProductionElementSnapshotPipelineError.analysisTimedOut {
            return .failed(code: "executionTimeout")
        } catch ProductionElementSnapshotPipelineError.cancelled {
            return .failed(code: "executionTimeout")
        } catch ProductionElementSnapshotPipelineError.stopping {
            return .failed(code: "capabilityUnavailable")
        } catch ProductionElementSnapshotPipelineError.invalidCapture {
            return .failed(code: "artifactValidationFailed")
        } catch is ElementSnapshotAnalysisError {
            return .failed(code: "partialFailure")
        } catch let error as ScreenshotArtifactError {
            return .failed(code: screenshotErrorCode(error))
        } catch is ArtifactFDProtocolError {
            return .failed(code: "artifactValidationFailed")
        } catch let error as ElementSnapshotResultBuildError {
            elementSnapshotLogger.error(
                "stage=terminal actionID=\(actionID.canonicalString, privacy: .public) commandID=element.snapshot outcome=failed errorCode=internalFailure errorType=ElementSnapshotResultBuildError errorCase=\(String(describing: error), privacy: .public)"
            )
            return .failed(code: "internalFailure")
        } catch {
            elementSnapshotLogger.error(
                "stage=terminal actionID=\(actionID.canonicalString, privacy: .public) commandID=element.snapshot outcome=failed errorCode=internalFailure errorType=\(String(reflecting: type(of: error)), privacy: .public)"
            )
            return .failed(code: "internalFailure")
        }
    }

    static func elementOuterSafetyDeadlineSeconds(
        includeAnnotation: Bool
    ) -> Double {
        includeAnnotation
            ? ProductionElementSnapshotPipeline.annotationOuterSafetyDeadlineSeconds
            : ProductionElementSnapshotPipeline.jsonOuterSafetyDeadlineSeconds
    }

    static func elementAnalyzerSelection(
        rawValue: String?
    ) -> ElementAnalyzerSelection? {
        rawValue.map(ElementAnalyzerSelection.init(canonicalString:)) ?? .all
    }

    static func executeCancelOwnedPendingWork(
        _ request: RuntimeRequestEnvelope,
        canonicalUDID: CanonicalUDID,
        clientInstanceID: CanonicalUUID?,
        pipeline: ProductionElementSnapshotPipeline?
    ) throws -> ProductionRuntimeBackendDisposition {
        let allowedReasons: Set<String> = [
            "clientDeadlineExceeded",
            "clientDisconnected",
            "clientInterrupted",
            "ownerCancelled",
        ]
        guard request.operation == .runtimeCancelOwnedPendingWork,
              Set(request.body.members.map(\.key)) == [
                  "canonicalUDID", "reason", "targetRequestID",
              ],
              request.body["canonicalUDID"]?.stringValue
                == canonicalUDID.rawValue,
              let reason = request.body["reason"]?.stringValue,
              allowedReasons.contains(reason),
              let targetRequestID = canonicalUUID(
                  request.body["targetRequestID"]
              ),
              let clientInstanceID
        else {
            return .failed(code: "invalidArgument")
        }
    let result =
      pipeline?.cancelOwnedPendingWork(
            targetRequestID: targetRequestID,
            ownerClientInstanceID: clientInstanceID
      )
      ?? ProductionElementPendingCancellationResult(
            disposition: .notFound,
            targetPhase: nil
        )
        var members: [(String, RepositoryJSONValue)] = [
            ("disposition", .string(result.disposition.rawValue)),
            ("targetRequestID", .string(targetRequestID.canonicalString)),
        ]
        if let targetPhase = result.targetPhase {
            members.append(("targetPhase", .string(targetPhase)))
        }
        return .succeeded(value: try object(members))
    }

    private static func elementResponseFitsWireCap(
        value: RepositoryJSONObject,
        request: RuntimeRequestEnvelope,
        actionID: CanonicalUUID,
        parentActionID: CanonicalUUID?
    ) throws -> Bool {
        var payloadMembers: [(String, RepositoryJSONValue)] = [
            ("actionID", .string(actionID.canonicalString)),
            ("operation", .string(request.operation.rawValue)),
      (
        "result",
        .object(
          try object([
                ("commitState", .string("notCommitted")),
                ("outcome", .string("succeeded")),
                ("value", .object(value)),
          ]))
      ),
        ]
        if let parentActionID {
      payloadMembers.append(
        (
                "parentActionID",
                .string(parentActionID.canonicalString)
            ))
        }
        let envelope = try object([
            ("payload", .object(try object(payloadMembers))),
            ("requestID", .string(request.requestID.canonicalString)),
            ("schemaVersion", .number(.uint64(1))),
        ])
        return RepositoryCanonicalJSON.encodeDocument(envelope).count
            <= 256 * 1_024
    }

    private static func requireCurrentElementAuthority(
        coordinator: ProductionRuntimeDeviceCoordinator,
        authority: ProductionRuntimeElementSnapshotAuthority,
        cancellation: ProductionElementSnapshotCancellation
    ) throws {
        try checkElementAttemptCancellation(cancellation)
        let current = try coordinator.commandAdmissionSnapshot()
        guard ProductionRuntimeElementSnapshotAuthority(snapshot: current) == authority else {
            cancellation.cancel(cause: .authorityChanged)
            throw ElementAuthorityChangedError()
        }
        try checkElementAttemptCancellation(cancellation)
    }

    private static func checkElementAttemptCancellation(
        _ cancellation: ProductionElementSnapshotCancellation
    ) throws {
        guard let cause = cancellation.cancellationCause else { return }
        if cause == .authorityChanged { throw ElementAuthorityChangedError() }
        throw ProductionElementSnapshotPipelineError.cancelled
    }

    private static func captureElementImage(
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        parentActionID: CanonicalUUID?,
        routeID: String,
        device: ProductionRuntimeDeviceObservation,
        connectionEpoch: UInt64,
        geometry: DisplayGeometryDTO,
        helperExecutor: ProductionCoreDeviceHelperExecutor,
        screenshotStore: ProductionScreenshotArtifactStore,
        cancellation: ProductionElementSnapshotCancellation
    ) throws -> ProductionElementSnapshotCapture {
        guard let route = ScreenshotRoute(rawValue: routeID) else {
            throw ElementCaptureDispositionError(
                disposition: .failed(code: "capabilityUnavailable")
            )
        }
        let artifactID = CanonicalUUID(value: UUID())
        let reservation: ProductionScreenshotArtifactReservation
        do {
            reservation = try screenshotStore.reserve(artifactID: artifactID)
        } catch {
            throw ElementCaptureDispositionError(
                disposition: .failed(code: "unsafeHostPath")
            )
        }
        do {
            var backendPayload: [String: HelperWireJSONValue] = [
                "artifactID": .string(artifactID.canonicalString),
                "commandID": .string("element.snapshot"),
                "operation": .string("screenshot"),
                "reservationPath": .string(reservation.internalPath),
            ]
            if route == .modernCoreDevice {
                backendPayload["captureProviderOrder"] = .array(
                    modernElementCaptureProviderOrder.map {
                        .string($0.rawValue)
                    }
                )
            }
            let result = try helperExecutor.executeOneShot(
                requestID: requestID,
                actionID: actionID,
                parentActionID: parentActionID,
                routeID: routeID,
                backendPayload: backendPayload,
                device: device,
                connectionEpoch: connectionEpoch,
                cancellation: cancellation
            )
            guard result["outcome"]?.stringValue == "succeeded" else {
                screenshotStore.cancel(reservation)
                throw ElementCaptureDispositionError(
                    disposition: .standard(result: result)
                )
            }
            guard let value = result["value"]?.objectValue,
                  value["artifactID"]?.stringValue == artifactID.canonicalString,
                  let byteCount = value["byteCount"]?.numberValue.flatMap({
                      try? $0.requireUInt64()
                  }),
                  let formatText = value["format"]?.stringValue,
                  let backendFormat = ScreenshotBackendFormat(rawValue: formatText),
                  let captureMetadata = elementCaptureMetadata(
                    route: route,
                    value: value
                  )
            else {
                screenshotStore.cancel(reservation)
                throw ElementCaptureDispositionError(
                    disposition: .failed(code: "artifactValidationFailed")
                )
            }
            let delivery = try screenshotStore.complete(
                reservation,
                byteCount: byteCount,
                format: backendFormat
            )
            defer { _ = Darwin.close(delivery.descriptor) }
            return ProductionElementSnapshotCapture(
                bytes: try readElementCapture(
                    descriptor: delivery.descriptor,
                    expectedByteCount: delivery.byteCount
                ),
                geometry: geometry,
                provider: captureMetadata.provider,
                captureAttempts: captureMetadata.attempts
            )
        } catch let error as ElementCaptureDispositionError {
            screenshotStore.cancel(reservation)
            throw error
        } catch ProductionCoreDeviceHelperExecutorError.timedOut {
            screenshotStore.cancel(reservation)
            throw ElementCaptureDispositionError(
                disposition: .outcomeUnknown(code: "executionTimeout")
            )
        } catch is CancellationError {
            screenshotStore.cancel(reservation)
            throw CancellationError()
        } catch let error as ScreenshotArtifactError {
            screenshotStore.cancel(reservation)
            throw ElementCaptureDispositionError(
                disposition: .failed(code: screenshotErrorCode(error))
            )
        } catch {
            screenshotStore.cancel(reservation)
            throw ElementCaptureDispositionError(
                disposition: .outcomeUnknown(code: "transportFailure")
            )
        }
    }

    static func elementCaptureMetadata(
        route: ScreenshotRoute,
        value: RepositoryJSONObject
    ) -> ElementCaptureMetadata? {
        switch route {
        case .legacyScreenshotR:
            guard value["captureProvider"] == nil,
                  value["generationDisposition"] == nil,
                  value["_pulsephoneCaptureAttempts"] == nil
            else { return nil }
            return ElementCaptureMetadata(
                attempts: nil,
                provider: .legacyScreenshotR
            )
        case .modernCoreDevice:
            guard let provider = value["captureProvider"]?.stringValue else {
                return nil
            }
            let captureProvider: SnapshotCaptureProvider
            switch provider {
            case "coreDevice":
                captureProvider = .coreDevice
            case "dvt":
                captureProvider = .dvt
            case "axAudit":
                captureProvider = .axAudit
            default:
                return nil
            }
      guard
        let attempts = elementCaptureAttempts(
                value["_pulsephoneCaptureAttempts"],
                finalProvider: captureProvider
        )
      else { return nil }
            if attempts.count == 1 {
                guard value["generationDisposition"] == nil else { return nil }
            } else {
        guard
          value["generationDisposition"]?.stringValue
                        == "retiringAfterResult"
                else { return nil }
            }
            return ElementCaptureMetadata(
                attempts: attempts,
                provider: captureProvider
            )
        }
    }

    private static func elementCaptureAttempts(
        _ value: RepositoryJSONValue?,
        finalProvider: SnapshotCaptureProvider
    ) -> [ElementSnapshotCaptureAttempt]? {
        guard let rawAttempts = value?.arrayValue,
              (1...3).contains(rawAttempts.count)
        else { return nil }
        let providerOrder = modernElementCaptureProviderOrder
        let expectedProviders = Array(providerOrder.prefix(rawAttempts.count))
        guard expectedProviders.last == finalProvider else { return nil }

        var attempts = [ElementSnapshotCaptureAttempt]()
        for (index, rawAttempt) in rawAttempts.enumerated() {
            guard let object = rawAttempt.objectValue,
        Set(object.members.map(\.key))
          == Set([
                      "errorCode", "provider", "stage", "status", "timings",
                  ]),
                  object["provider"]?.stringValue
                    == expectedProviders[index].rawValue,
                  let statusText = object["status"]?.stringValue,
                  let status = ElementSnapshotCaptureAttemptStatus(
                    rawValue: statusText
                  ),
        status
          == (index == rawAttempts.count - 1
                    ? .succeeded : .failed),
                  let timings = elementCaptureAttemptTimings(
                    object["timings"]
                  )
            else { return nil }

            let errorCode: ElementSnapshotCaptureFailureCode?
            let failureStage: ElementSnapshotCaptureFailureStage?
            switch status {
            case .succeeded:
                guard isJSONNull(object["errorCode"]),
                      isJSONNull(object["stage"])
                else { return nil }
                errorCode = nil
                failureStage = nil
            case .failed:
        guard
          object["errorCode"]?.stringValue
                        == ElementSnapshotCaptureFailureCode
                            .developerServicesUnavailable.rawValue,
                      let rawStage = object["stage"]?.stringValue,
                      let normalizedStage = elementCaptureFailureStage(
                        rawStage,
                        provider: expectedProviders[index]
                      )
                else { return nil }
                errorCode = .developerServicesUnavailable
                failureStage = normalizedStage
            }
      attempts.append(
        ElementSnapshotCaptureAttempt(
                provider: expectedProviders[index],
                status: status,
                errorCode: errorCode,
                failureStage: failureStage,
                timings: timings
            ))
        }
        return attempts
    }

    private static func elementCaptureFailureStage(
        _ value: String,
        provider: SnapshotCaptureProvider
    ) -> ElementSnapshotCaptureFailureStage? {
        switch (provider, value) {
        case (.coreDevice, "screenshotServiceOpen"),
             (.dvt, "dvtScreenshotServiceOpen"):
            return .serviceOpen
        case (.coreDevice, "screenshotCaptureOrValidate"),
             (.dvt, "dvtScreenshotCaptureOrValidate"),
             (.axAudit, "axAuditScreenshotCaptureOrValidate"):
            return .captureOrValidate
        case (.axAudit, "axAuditScreenshotServiceOpen"):
            return .serviceOpen
        default:
            return nil
        }
    }

    private static func elementCaptureAttemptTimings(
        _ value: RepositoryJSONValue?
    ) -> ElementSnapshotCaptureAttemptTimings? {
        guard let object = value?.objectValue,
      Set(object.members.map(\.key))
        == Set([
                  "captureMicroseconds",
                  "queueWaitMicroseconds",
                  "serviceCloseMicroseconds",
                  "serviceOpenMicroseconds",
                  "totalMicroseconds",
              ])
        else { return nil }
        let keys = [
            "captureMicroseconds",
            "queueWaitMicroseconds",
            "serviceCloseMicroseconds",
            "serviceOpenMicroseconds",
            "totalMicroseconds",
        ]
        var values = [String: UInt64]()
        for key in keys {
      guard
        let timing = object[key]?.numberValue.flatMap({
                try? $0.requireUInt64()
        }), timing <= 30_000_000
      else { return nil }
            values[key] = timing
        }
        return ElementSnapshotCaptureAttemptTimings(
            captureMicroseconds: values["captureMicroseconds"]!,
            queueWaitMicroseconds: values["queueWaitMicroseconds"]!,
            serviceCloseMicroseconds: values["serviceCloseMicroseconds"]!,
            serviceOpenMicroseconds: values["serviceOpenMicroseconds"]!,
            totalMicroseconds: values["totalMicroseconds"]!
        )
    }

    private static func isJSONNull(_ value: RepositoryJSONValue?) -> Bool {
        guard case .some(.null) = value else { return false }
        return true
    }

    private static func readElementCapture(
        descriptor: Int32,
        expectedByteCount: UInt64
    ) throws -> [UInt8] {
        guard expectedByteCount > 0,
              expectedByteCount <= 64 * 1_024 * 1_024,
              expectedByteCount <= UInt64(Int.max),
              lseek(descriptor, 0, SEEK_SET) == 0
        else {
            throw ScreenshotArtifactError.artifactValidationFailed
        }
        var bytes = [UInt8](repeating: 0, count: Int(expectedByteCount))
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    buffer.count - offset
                )
            }
            if count > 0 {
                offset += count
            } else if count == -1, errno == EINTR {
                continue
            } else {
                throw ScreenshotArtifactError.artifactValidationFailed
            }
        }
    guard
      bytes.starts(with: [
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
      ])
    else {
            throw ScreenshotArtifactError.artifactValidationFailed
        }
        return bytes
    }

    private static func executeScreenshot(
        request: RuntimeRequestEnvelope,
        actionID: CanonicalUUID,
        parentActionID: CanonicalUUID?,
        routeID: String,
        device: ProductionRuntimeDeviceObservation,
        connectionEpoch: UInt64,
        helperExecutor: ProductionCoreDeviceHelperExecutor,
        screenshotStore: ProductionScreenshotArtifactStore
    ) throws -> ProductionRuntimeBackendDisposition {
        guard ScreenshotRoute(rawValue: routeID) != nil else {
            return .failed(code: "capabilityUnavailable")
        }
        let artifactID = CanonicalUUID(value: UUID())
        let reservation: ProductionScreenshotArtifactReservation
        do {
            reservation = try screenshotStore.reserve(artifactID: artifactID)
        } catch {
            return .failedWithDetails(
                code: "unsafeHostPath",
                details: try screenshotHostPathDetails(reason: "anchorInvalid")
            )
        }
        do {
            let result = try helperExecutor.executeOneShot(
                requestID: request.requestID,
                actionID: actionID,
                parentActionID: parentActionID,
                routeID: routeID,
                backendPayload: [
                    "artifactID": .string(artifactID.canonicalString),
          "commandID": .string(
            request.body["commandID"]?.stringValue
                        ?? "screenshot.gui"),
                    "operation": .string("screenshot"),
                    "reservationPath": .string(reservation.internalPath),
                ],
                device: device,
                connectionEpoch: connectionEpoch
            )
            guard result["outcome"]?.stringValue == "succeeded" else {
                screenshotStore.cancel(reservation)
                return .standard(result: result)
            }
            guard let value = result["value"]?.objectValue,
                  value["artifactID"]?.stringValue == artifactID.canonicalString,
                  let byteCount = value["byteCount"]?.numberValue.flatMap({
                      try? $0.requireUInt64()
                  }),
                  let formatText = value["format"]?.stringValue,
                  let format = ScreenshotBackendFormat(rawValue: formatText)
            else {
                screenshotStore.cancel(reservation)
                return .failedWithDetails(
                    code: "artifactValidationFailed",
                    details: try screenshotArtifactDetails(
                        stage: "runtimeValidation",
                        artifactID: artifactID
                    )
                )
            }
            let delivery = try screenshotStore.complete(
                reservation,
                byteCount: byteCount,
                format: format
            )
            return .artifact(
                descriptor: delivery.descriptor,
                artifactID: delivery.artifactID,
                sizeBytes: delivery.byteCount,
                binding: .deviceScreenshot,
                value: try object([
                    ("artifactID", .string(delivery.artifactID.canonicalString)),
                    ("byteCount", .number(.uint64(delivery.byteCount))),
                    ("format", .string("png")),
                ])
            )
        } catch ProductionCoreDeviceHelperExecutorError.timedOut {
            screenshotStore.cancel(reservation)
            return .outcomeUnknown(code: "executionTimeout")
        } catch let error as ScreenshotArtifactError {
            screenshotStore.cancel(reservation)
            let code = screenshotErrorCode(error)
            if code == "unsafeHostPath" {
                return .failedWithDetails(
                    code: code,
                    details: try screenshotHostPathDetails(
                        reason: "inodeMismatch"
                    )
                )
            }
            if [
                "artifactTooLarge",
                "artifactValidationFailed",
                "unsupportedScreenshotFormat",
            ].contains(code) {
                return .failedWithDetails(
                    code: code,
                    details: try screenshotArtifactDetails(
                        stage: code == "unsupportedScreenshotFormat"
                            ? "formatConversion"
                            : "runtimeValidation",
                        artifactID: artifactID
                    )
                )
            }
            return .failed(code: code)
        } catch {
            screenshotStore.cancel(reservation)
            return .outcomeUnknown(code: "transportFailure")
        }
    }

    private static func screenshotErrorCode(
        _ error: ScreenshotArtifactError
    ) -> String {
        switch error {
        case .artifactTooLarge: "artifactTooLarge"
        case .artifactValidationFailed: "artifactValidationFailed"
        case .backendFormatConversionFailed: "artifactValidationFailed"
        case .preparationNotReady: "capabilityPreparing"
        case .unsupportedScreenshotFormat: "unsupportedScreenshotFormat"
        case .unsafeHostPath: "unsafeHostPath"
        default: "protocolViolation"
        }
    }

    private static func screenshotArtifactDetails(
        stage: String,
        artifactID: CanonicalUUID
    ) throws -> RepositoryJSONObject {
        try object([
            ("artifactID", .string(artifactID.canonicalString)),
            ("stage", .string(stage)),
        ])
    }

    private static func screenshotHostPathDetails(
        reason: String
    ) throws -> RepositoryJSONObject {
        try object([
            ("pathClass", .string("screenshotReservation")),
            ("reason", .string(reason)),
        ])
    }

    static func executeStreamOpen(
        _ request: RuntimeRequestEnvelope,
        coordinator: ProductionRuntimeDeviceCoordinator,
        helperExecutor: ProductionCoreDeviceHelperExecutor,
        coordinateProjectionStore: ProductionRuntimeCoordinateProjectionStore,
        directHelperExecutor: ProductionCoreDeviceHelperExecutor,
        developerImageCatalog: DeveloperImageCatalogV1?,
        developerImageStore: DeveloperImageAssetStore?,
    dynamicDeveloperImageCatalogStore: DynamicDeveloperImageCatalogStore? = nil,
    dynamicDeveloperImageAssetCache: DynamicDeveloperImageAssetCache? = nil,
        preparationJobs: ProductionPreparationJobManager? = nil,
        preparationProgress: PreparationProgressHandler? = nil,
    selectedXcodeSnapshotProvider:
      @escaping @Sendable (
            DeveloperImageCatalogEntryV1
        ) -> SelectedXcodeSnapshot? = { _ in nil }
    ) throws -> ProductionRuntimeBackendDisposition {
        guard let intent = request.body["intent"]?.objectValue,
              let commandID = intent["commandID"]?.stringValue,
              let argumentsObject = intent["normalizedArguments"]?.objectValue,
              let interactionID = canonicalUUID(request.body["interactionID"]),
              let arguments = stringArguments(argumentsObject)
        else {
            return .failed(code: "invalidArgument")
        }
        var snapshot = try coordinator.commandAdmissionSnapshot()
        guard let device = snapshot.device else {
            return .failed(code: "deviceDisconnected")
        }
        let initialPlanning = try coordinator.plan(
            commandID: commandID,
            rawArguments: arguments,
            snapshot: snapshot
        )
        // Streams report an unavailable planning state while their Developer
        // Support capability is being prepared. Pointer streams additionally
        // require geometry before the planner can expose that state. In both
        // cases prepare before opening a service or querying geometry.
        let requiresImplicitPreparation: Bool
        switch initialPlanning {
        case .awaitingPreparation:
            requiresImplicitPreparation = true
        case .unavailable(let reason) where reason == "capabilityPreparing":
            requiresImplicitPreparation = true
    case .unknown(let reason)
    where commandID == "gui.pointer.interaction"
            && reason == "displayGeometryUnavailable":
            requiresImplicitPreparation = true
        case .unavailable(let reason), .unknown(let reason):
            return try planningFailure(
                commandID: commandID,
                reason: reason,
                snapshot: snapshot,
                coordinator: coordinator
            )
        case .notRuntimePlannable:
            return .failed(code: "invalidArgument")
        case .planned:
            requiresImplicitPreparation = false
        }
        if requiresImplicitPreparation {
            if let preparationFailure = try executeImplicitPreparationIfNeeded(
                commandID: commandID,
                actionID: canonicalUUID(intent["actionID"])
                    ?? CanonicalUUID(value: UUID()),
                device: device,
                snapshot: snapshot,
                coordinator: coordinator,
                helperExecutor: helperExecutor,
                directHelperExecutor: directHelperExecutor,
                developerImageCatalog: developerImageCatalog,
                developerImageStore: developerImageStore,
        dynamicDeveloperImageCatalogStore: dynamicDeveloperImageCatalogStore,
        dynamicDeveloperImageAssetCache: dynamicDeveloperImageAssetCache,
                preparationJobs: preparationJobs,
                selectedXcodeSnapshotProvider: selectedXcodeSnapshotProvider
            ) {
                return preparationFailure
            }
            snapshot = try coordinator.commandAdmissionSnapshot()
        }
        if commandID == "gui.pointer.interaction" {
            guard let width = UInt64(arguments["logicalWidth"] ?? ""),
                  let height = UInt64(arguments["logicalHeight"] ?? ""),
                  let revision = UInt64(arguments["geometryRevision"] ?? ""),
                  let orientationText = arguments["orientation"],
                  let orientation = DisplayOrientationDTO(
                    rawValue: orientationText
                  )
            else {
                return .failed(code: "invalidArgument")
            }
            let requested: DisplayGeometryDTO
            do {
                requested = try DisplayGeometryDTO(
                    connectionEpoch: snapshot.connectionEpoch,
                    geometryRevision: revision,
                    logicalHeight: height,
                    logicalWidth: width,
                    orientation: orientation
                )
            } catch {
                return .failed(code: "invalidArgument")
            }
            do {
                snapshot = try admitPointerGeometry(
                    requested: requested,
                    snapshot: snapshot,
                    query: {
                        try queryDisplayGeometry(
                            helperExecutor: helperExecutor,
                            device: device,
                            connectionEpoch: snapshot.connectionEpoch,
                            requestedRevision: revision
                        )
                    },
                    update: { geometry in
                        try coordinator.updateGeometry(
                            connectionEpoch: geometry.connectionEpoch,
                            geometryRevision: geometry.geometryRevision,
                            logicalWidth: geometry.logicalWidth,
                            logicalHeight: geometry.logicalHeight,
                            orientation: geometry.orientation
                        )
                    }
                )
            } catch {
                return .failed(code: "capabilityUnavailable")
            }
        }
        let planning = try coordinator.plan(
            commandID: commandID,
            rawArguments: arguments,
            snapshot: snapshot
        )
        switch planning {
        case .unavailable(let reason), .unknown(let reason):
            return try planningFailure(
                commandID: commandID,
                reason: reason,
                snapshot: snapshot,
                coordinator: coordinator
            )
        case .awaitingPreparation:
            return .failed(code: "capabilityPreparing")
        case .notRuntimePlannable:
            return .failed(code: "invalidArgument")
        case .planned(let plan):
            guard plan.kind == .stream, let candidate = plan.candidates.first else {
                return .failed(code: "capabilityUnavailable")
            }
      let actionID =
        canonicalUUID(intent["actionID"])
                ?? CanonicalUUID(value: UUID())
            let parentActionID = optionalCanonicalUUID(intent["parentActionID"])
            do {
                let opened = try helperExecutor.openStream(
                    requestID: request.requestID,
                    actionID: actionID,
                    interactionID: interactionID,
                    parentActionID: parentActionID,
                    routeID: candidate.routeID,
                    streamPayload: try helperObject(arguments),
                    device: device,
                    connectionEpoch: snapshot.connectionEpoch
                )
                if commandID == "gui.pointer.interaction" {
                    guard let geometry = snapshot.geometry else {
                        _ = try? helperExecutor.closeStream(
                            sessionID: opened.sessionID,
                            interactionID: interactionID,
                            reason: "geometryUnavailable",
                            cancel: true
                        )
                        return .failed(code: "capabilityUnavailable")
                    }
                    coordinateProjectionStore.registerPointer(
                        sessionID: opened.sessionID,
                        interactionID: interactionID,
                        geometry: geometry
                    )
                } else {
                    coordinateProjectionStore.registerKeyboard(
                        sessionID: opened.sessionID,
                        interactionID: interactionID
                    )
                }
                var members: [(String, RepositoryJSONValue)] = [
                    ("actionID", .string(actionID.canonicalString)),
          (
            "executorGeneration",
            .number(
              .uint64(
                        opened.executorGeneration
              ))
          ),
                    ("interactionID", .string(interactionID.canonicalString)),
          (
            "openedAtMonotonicNs",
            .number(
              .uint64(
                        DispatchTime.now().uptimeNanoseconds
              ))
          ),
                    ("sessionID", .string(opened.sessionID.canonicalString)),
                ]
                if commandID == "gui.pointer.interaction",
                   let geometry = snapshot.geometry
                {
                    members.append(contentsOf: [
            (
              "connectionEpoch",
              .number(
                .uint64(
                            geometry.connectionEpoch
                ))
            ),
            (
              "geometryRevision",
              .number(
                .uint64(
                            geometry.geometryRevision
                ))
            ),
            (
              "logicalHeight",
              .number(
                .uint64(
                            geometry.logicalHeight
                ))
            ),
            (
              "logicalWidth",
              .number(
                .uint64(
                            geometry.logicalWidth
                ))
            ),
                        ("orientation", .string(geometry.orientation.rawValue)),
                    ])
                }
                return .succeeded(value: try object(members))
            } catch ProductionCoreDeviceHelperExecutorError.timedOut {
                return .failed(code: "executionTimeout")
            } catch {
                return .outcomeUnknown(code: "transportFailure")
            }
        }
    }

    /// Hybrid capture routes must inspect preparation before route selection,
    /// because modern screenshots otherwise reject awaiting preparation first.
    private static func executeHybridCapturePreparationPreflight(
        commandID: String,
        actionID: CanonicalUUID,
        arguments: [String: String],
        coordinator: ProductionRuntimeDeviceCoordinator,
        helperExecutor: ProductionCoreDeviceHelperExecutor,
        directHelperExecutor: ProductionCoreDeviceHelperExecutor,
        developerImageCatalog: DeveloperImageCatalogV1?,
        developerImageStore: DeveloperImageAssetStore?,
    dynamicDeveloperImageCatalogStore: DynamicDeveloperImageCatalogStore?,
    dynamicDeveloperImageAssetCache: DynamicDeveloperImageAssetCache?,
        preparationJobs: ProductionPreparationJobManager?,
    selectedXcodeSnapshotProvider:
      @escaping @Sendable (
            DeveloperImageCatalogEntryV1
        ) -> SelectedXcodeSnapshot?
    ) throws -> ProductionRuntimeBackendDisposition? {
        let snapshot = try coordinator.commandAdmissionSnapshot()
        guard let device = snapshot.device else {
            return .failed(code: "deviceDisconnected")
        }
        switch try coordinator.plan(
            commandID: commandID,
            rawArguments: arguments,
            snapshot: snapshot
        ) {
        case .awaitingPreparation, .notRuntimePlannable(.hybrid):
            return try executeImplicitPreparationIfNeeded(
                commandID: commandID,
                actionID: actionID,
                device: device,
                snapshot: snapshot,
                coordinator: coordinator,
                helperExecutor: helperExecutor,
                directHelperExecutor: directHelperExecutor,
                developerImageCatalog: developerImageCatalog,
                developerImageStore: developerImageStore,
        dynamicDeveloperImageCatalogStore: dynamicDeveloperImageCatalogStore,
        dynamicDeveloperImageAssetCache: dynamicDeveloperImageAssetCache,
                preparationJobs: preparationJobs,
                selectedXcodeSnapshotProvider: selectedXcodeSnapshotProvider
            )
        case .unavailable(let reason), .unknown(let reason):
            return try planningFailure(
                commandID: commandID,
                reason: reason,
                snapshot: snapshot,
                coordinator: coordinator
            )
        case .notRuntimePlannable, .planned:
            return .failed(code: "invalidArgument")
        }
    }

    /// DDI-dependent ordinary operations only create or join the Runtime-owned
    /// preparation job. They never wait for it or replay the original action.
    private static func executeImplicitPreparationIfNeeded(
        commandID: String,
        actionID: CanonicalUUID,
        device: ProductionRuntimeDeviceObservation,
        snapshot: ProductionRuntimeDeviceSnapshot,
        coordinator: ProductionRuntimeDeviceCoordinator,
        helperExecutor: ProductionCoreDeviceHelperExecutor,
        directHelperExecutor: ProductionCoreDeviceHelperExecutor,
        developerImageCatalog: DeveloperImageCatalogV1?,
        developerImageStore: DeveloperImageAssetStore?,
    dynamicDeveloperImageCatalogStore: DynamicDeveloperImageCatalogStore?,
    dynamicDeveloperImageAssetCache: DynamicDeveloperImageAssetCache?,
        preparationJobs: ProductionPreparationJobManager?,
    selectedXcodeSnapshotProvider:
      @escaping @Sendable (
            DeveloperImageCatalogEntryV1
        ) -> SelectedXcodeSnapshot?
    ) throws -> ProductionRuntimeBackendDisposition? {
    guard
      let osMajor = UInt64(
            device.facts.productVersion.split(separator: ".").first ?? ""
      )
    else {
            return .failedWithDetails(
                code: "unsupportedPreparationGroup",
                details: try developerSupportDetails(
                    groupID: "prep.legacy.developer.v2",
                    phase: "checkingDevice"
                )
            )
        }
        let route: DeveloperSupportOSRoute
        do {
            route = try coordinator.developerSupportRoute(osMajor: osMajor)
        } catch {
            return .failedWithDetails(
                code: "unsupportedPreparationGroup",
                details: try developerSupportDetails(
                    groupID: osMajor >= 17
                        ? "prep.coredevice.v2"
                        : "prep.legacy.developer.v2",
                    phase: "checkingDevice"
                )
            )
        }
    guard
      !coordinator.isPreparationReady(
            groupID: route.preparationGroupID,
            snapshot: snapshot
      )
    else {
            return nil
        }

        let recoveryResult: PreparationReadinessRecoveryResult
        switch route.route {
        case .personalized:
            recoveryResult = restoreCurrentModernPreparationReadinessIfEligible(
                actionID: actionID,
                coordinator: coordinator,
                device: device,
                groupID: route.preparationGroupID,
                helperExecutor: helperExecutor,
                snapshot: snapshot
            )
        case .classic:
            recoveryResult = restoreCurrentClassicPreparationReadinessIfEligible(
                actionID: actionID,
                coordinator: coordinator,
                dynamicDeveloperImageCatalogStore: dynamicDeveloperImageCatalogStore,
                device: device,
                groupID: route.preparationGroupID,
                directHelperExecutor: directHelperExecutor,
                snapshot: snapshot
            )
        case .none:
            recoveryResult = .mountedStateCheckFailed
        }
        if recoveryResult == .ready {
            return nil
        }

        let preparationRequest = RuntimeRequestEnvelope(
            requestID: CanonicalUUID(value: UUID()),
            operation: .runtimePrepareCapabilities,
            body: try object([
        (
          "actionContext",
          .object(
            try object([
              ("actionID", .string(actionID.canonicalString))
            ]))
        ),
                ("canonicalUDID", .string(device.facts.uniqueDeviceID)),
                ("mode", .string(ProductionPreparationJobManager.RequestMode.startOnly.rawValue)),
            ])
        )
        guard let preparationJobs else {
            return .failedWithDetails(
                code: "capabilityPreparing",
                details: try preparationRemediationDetails(
                    coordinator: coordinator,
                    groupID: route.preparationGroupID,
                    reason: recoveryResult.reason
                )
            )
        }
        _ = preparationJobs.submit(
            key: .init(
                connectionEpoch: snapshot.connectionEpoch,
                preparationGroupID: route.preparationGroupID
            ),
            mode: .startOnly,
            observerID: preparationRequest.requestID,
            progress: nil
        ) { attemptID, progress in
            try executePreparation(
                preparationRequest,
                coordinator: coordinator,
                helperExecutor: helperExecutor,
                directHelperExecutor: directHelperExecutor,
                developerImageCatalog: developerImageCatalog,
                developerImageStore: developerImageStore,
        dynamicDeveloperImageCatalogStore: dynamicDeveloperImageCatalogStore,
        dynamicDeveloperImageAssetCache: dynamicDeveloperImageAssetCache,
                preparationAttemptID: attemptID,
                preparationProgress: progress,
                selectedXcodeSnapshotProvider: selectedXcodeSnapshotProvider
            )
        }
        developerSupportLogger.notice(
            "stage=implicitPrepareStarted commandID=\(commandID, privacy: .public) preparationGroupID=\(route.preparationGroupID, privacy: .public) connectionEpoch=\(snapshot.connectionEpoch, privacy: .public)"
        )
        return .failedWithDetails(
            code: "capabilityPreparing",
            details: try preparationRemediationDetails(
                coordinator: coordinator,
                groupID: route.preparationGroupID,
                reason: recoveryResult.reason
            )
        )
    }

    static func executePreparationRequest(
        _ request: RuntimeRequestEnvelope,
        coordinator: ProductionRuntimeDeviceCoordinator,
        helperExecutor: ProductionCoreDeviceHelperExecutor,
        directHelperExecutor: ProductionCoreDeviceHelperExecutor?,
        developerImageCatalog: DeveloperImageCatalogV1?,
        developerImageStore: DeveloperImageAssetStore?,
    dynamicDeveloperImageCatalogStore: DynamicDeveloperImageCatalogStore? = nil,
    dynamicDeveloperImageAssetCache: DynamicDeveloperImageAssetCache? = nil,
        preparationJobs: ProductionPreparationJobManager,
        preparationProgress: PreparationProgressHandler?,
    selectedXcodeSnapshotProvider:
      @escaping @Sendable (
            DeveloperImageCatalogEntryV1
        ) -> SelectedXcodeSnapshot?
    ) throws -> ProductionRuntimeBackendDisposition {
        let mode = try preparationRequestMode(request)
        let snapshot = try coordinator.refresh()
        guard let device = snapshot.device else {
            return .failed(code: "deviceDisconnected")
        }
        let groupID = try preparationGroupID(for: device, coordinator: coordinator)
        if mode == .startOnly,
           !coordinator.isPreparationReady(groupID: groupID, snapshot: snapshot)
        {
            let actionID = request.body["actionContext"]?.objectValue
                .flatMap { canonicalUUID($0["actionID"]) }
                ?? CanonicalUUID(value: UUID())
            let recovery: PreparationReadinessRecoveryResult
            let osMajor = UInt64(
                device.facts.productVersion.split(separator: ".").first ?? ""
            )
            let route = try? coordinator.developerSupportRoute(
                osMajor: osMajor ?? 0
            )
            switch route?.route {
            case .personalized:
                recovery = restoreCurrentModernPreparationReadinessIfEligible(
                    actionID: actionID,
                    coordinator: coordinator,
                    device: device,
                    groupID: groupID,
                    helperExecutor: helperExecutor,
                    snapshot: snapshot
                )
            case .classic:
                recovery = restoreCurrentClassicPreparationReadinessIfEligible(
                    actionID: actionID,
                    coordinator: coordinator,
                    dynamicDeveloperImageCatalogStore: dynamicDeveloperImageCatalogStore,
                    device: device,
                    groupID: groupID,
                    directHelperExecutor: directHelperExecutor,
                    snapshot: snapshot
                )
            default:
                recovery = .mountedStateCheckFailed
            }
            if recovery == .ready {
                return .succeeded(
                    value: try object([
                        ("disposition", .string("alreadyReady")),
                        ("preparationGroupID", .string(groupID)),
                    ])
                )
            }
        }
        if mode == .startOnly,
           coordinator.isPreparationReady(groupID: groupID, snapshot: snapshot)
        {
      return .succeeded(
        value: try object([
                ("disposition", .string("alreadyReady")),
                ("preparationGroupID", .string(groupID)),
            ]))
        }
        let result = preparationJobs.submit(
            key: .init(
                connectionEpoch: snapshot.connectionEpoch,
                preparationGroupID: groupID
            ),
            mode: mode,
            observerID: request.requestID,
            progress: preparationProgress
        ) { attemptID, progress in
            try executePreparation(
                request,
                coordinator: coordinator,
                helperExecutor: helperExecutor,
                directHelperExecutor: directHelperExecutor,
                developerImageCatalog: developerImageCatalog,
                developerImageStore: developerImageStore,
        dynamicDeveloperImageCatalogStore: dynamicDeveloperImageCatalogStore,
        dynamicDeveloperImageAssetCache: dynamicDeveloperImageAssetCache,
                preparationAttemptID: attemptID,
                preparationProgress: progress,
                selectedXcodeSnapshotProvider: selectedXcodeSnapshotProvider
            )
        }
        if mode == .startOnly {
            return .failedWithDetails(
                code: "capabilityPreparing",
                details: try preparationRemediationDetails(
                    coordinator: coordinator,
                    groupID: groupID,
                    reason: "runDevicePrepare"
                )
            )
        }
        return result ?? .outcomeUnknown(code: "runtimeFailed")
    }

    private static func preparationRequestMode(
        _ request: RuntimeRequestEnvelope
    ) throws -> ProductionPreparationJobManager.RequestMode {
        let raw = request.body["mode"]?.stringValue ?? "waitForTerminal"
        guard let mode = ProductionPreparationJobManager.RequestMode(rawValue: raw) else {
            throw ProductionRuntimeServerError.invalidFrame
        }
        return mode
    }

    private static func preparationGroupID(
        for device: ProductionRuntimeDeviceObservation,
        coordinator: ProductionRuntimeDeviceCoordinator
    ) throws -> String {
    guard
      let osMajor = UInt64(
            device.facts.productVersion.split(separator: ".").first ?? ""
      )
    else {
            throw ProductionRuntimeServerError.invalidFrame
        }
        return try coordinator.developerSupportRoute(osMajor: osMajor)
            .preparationGroupID
    }

    private static func preparationRemediationDetails(
        coordinator: ProductionRuntimeDeviceCoordinator,
        groupID: String,
        reason: String = "runDevicePrepare"
    ) throws -> RepositoryJSONObject {
        try object([
            (
                "capabilityID",
        .string(
          coordinator.preparationCapabilityIDs(groupID: groupID)?
                    .first ?? "developer-support")
            ),
            ("preparationGroup", .string(groupID)),
            ("reason", .string(reason)),
            ("remediation", .string("runDevicePrepare")),
            ("state", .string("preparingDevice")),
        ])
    }

    static func executePreparation(
        _ request: RuntimeRequestEnvelope,
        coordinator: ProductionRuntimeDeviceCoordinator,
        helperExecutor: ProductionCoreDeviceHelperExecutor,
        directHelperExecutor: ProductionCoreDeviceHelperExecutor? = nil,
        developerImageCatalog: DeveloperImageCatalogV1? = nil,
        developerImageStore: DeveloperImageAssetStore? = nil,
    dynamicDeveloperImageCatalogStore: DynamicDeveloperImageCatalogStore? = nil,
    dynamicDeveloperImageAssetCache: DynamicDeveloperImageAssetCache? = nil,
        remoteDeveloperImageCatalog: ControlledRemoteDeveloperImageCatalog? = nil,
        preparationAttemptID: CanonicalUUID? = nil,
        preparationProgress: PreparationProgressHandler? = nil,
    selectedXcodeSnapshotProvider:
      @Sendable (
            DeveloperImageCatalogEntryV1
        ) -> SelectedXcodeSnapshot? = { _ in nil }
    ) throws -> ProductionRuntimeBackendDisposition {
        let snapshot = try coordinator.refresh()
        guard let device = snapshot.device else {
            return .failed(code: "deviceDisconnected")
        }
    guard
      let osMajor = UInt64(
            device.facts.productVersion.split(separator: ".").first ?? ""
      )
    else {
            return .failedWithDetails(
                code: "unsupportedPreparationGroup",
                details: try developerSupportDetails(
                    groupID: "prep.legacy.developer.v2",
                    phase: "checkingDevice"
                )
            )
        }
        let route: DeveloperSupportOSRoute
        do {
            route = try coordinator.developerSupportRoute(osMajor: osMajor)
        } catch {
            return .failedWithDetails(
                code: "unsupportedPreparationGroup",
                details: try developerSupportDetails(
                    groupID: osMajor >= 17
                        ? "prep.coredevice.v2"
                        : "prep.legacy.developer.v2",
                    phase: "checkingDevice"
                )
            )
        }
        let groupID = route.preparationGroupID
    guard
      let capabilityIDs = coordinator.preparationCapabilityIDs(
            groupID: groupID
      )
    else {
            return .failedWithDetails(
                code: "unsupportedPreparationGroup",
                details: try developerSupportDetails(
                    groupID: groupID,
                    phase: "checkingDevice"
                )
            )
        }
    let actionID =
      request.body["actionContext"]?.objectValue
            .flatMap { canonicalUUID($0["actionID"]) }
            ?? CanonicalUUID(value: UUID())
    let preparationAttemptID =
      preparationAttemptID
            ?? CanonicalUUID(value: UUID())
        let progress = ProductionPreparationProgressPublisher(
            attemptID: preparationAttemptID,
            groupID: groupID,
            handler: preparationProgress
        )
        progress.publish(.checkingDevice)
    if let dynamicDeveloperImageCatalogStore,
      let dynamicDeveloperImageAssetCache
    {
      let result = try executeDynamicPreparation(
        request: request,
        actionID: actionID,
        preparationAttemptID: preparationAttemptID,
        capabilityIDs: capabilityIDs,
        groupID: groupID,
        route: route,
        device: device,
        connectionEpoch: snapshot.connectionEpoch,
        helperExecutor: helperExecutor,
        directHelperExecutor: directHelperExecutor,
        catalogStore: dynamicDeveloperImageCatalogStore,
        assetCache: dynamicDeveloperImageAssetCache,
        progress: progress
      )
      if case .succeeded = result {
        let marked = try coordinator.markPreparationReady(
          groupID: groupID,
          connectionEpoch: snapshot.connectionEpoch
        )
        guard coordinator.isPreparationReady(
          groupID: groupID,
          snapshot: marked
        ) else {
          return .failedWithDetails(
            code: "preparationFailed",
            details: try developerSupportDetails(
              groupID: groupID,
              phase: "markingReady"
            )
          )
        }
        if route.route == .classic {
          guard recordClassicPreparationRehydrationEligibility(
            developerImageStore: developerImageStore,
            device: device,
            groupID: groupID
          ) else {
            return .failedWithDetails(
              code: "developerSupportUnavailable",
              details: try developerSupportDetails(
                groupID: groupID,
                phase: "persistingReadiness"
              )
            )
          }
        }
      }
      return result
    }
        switch route.route {
        case .classic:
            guard let directHelperExecutor else {
                return .failedWithDetails(
                    code: "developerSupportUnavailable",
                    details: try developerSupportDetails(
                        groupID: groupID,
                        phase: "startingDeviceServices"
                    )
                )
            }
            do {
                let result = try executeClassicPreparation(
                    request: request,
                    actionID: actionID,
                    preparationAttemptID: preparationAttemptID,
                    capabilityIDs: capabilityIDs,
                    groupID: groupID,
                    device: device,
                    connectionEpoch: snapshot.connectionEpoch,
                    directHelperExecutor: directHelperExecutor,
                    developerImageCatalog: developerImageCatalog,
                    developerImageStore: developerImageStore,
                    progress: progress,
                    selectedXcodeSnapshotProvider: selectedXcodeSnapshotProvider
                )
                if case .succeeded = result {
                    let marked = try coordinator.markPreparationReady(
                        groupID: groupID,
            connectionEpoch: snapshot.connectionEpoch
          )
                    guard coordinator.isPreparationReady(
                        groupID: groupID,
                        snapshot: marked
                    ) else {
                        return .failedWithDetails(
                            code: "preparationFailed",
                            details: try developerSupportDetails(
                                groupID: groupID,
                                phase: "markingReady"
                            )
                        )
                    }
                    guard recordClassicPreparationRehydrationEligibility(
                        developerImageStore: developerImageStore,
                        device: device,
                        groupID: groupID
                    ) else {
                        return .failedWithDetails(
                            code: "developerSupportUnavailable",
                            details: try developerSupportDetails(
                                groupID: groupID,
                                phase: "persistingReadiness"
                            )
                        )
                    }
                }
        return result
      } catch ProductionCoreDeviceHelperExecutorError.timedOut {
        return .failedWithDetails(
          code: "preparationTimeout",
          details: try developerSupportDetails(
            groupID: groupID,
            phase: "mounting",
            retryStage: "devicePreparation"
          )
        )
      } catch ProductionCoreDeviceHelperExecutorError
        .helperUnavailableBeforeRequest
      {
        return .failedWithDetails(
          code: "developerSupportUnavailable",
          details: try developerSupportDetails(
            groupID: groupID,
            phase: "startingDeviceServices",
            retryStage: "serviceStartup"
          )
        )
      } catch ProductionCoreDeviceHelperExecutorError.invalidRequest {
        return .failed(code: "preparationFailed")
      } catch {
        return .standard(result: try preparationOutcomeUnknownResult())
      }
    case .personalized:
      let result = try executeModernPreparation(
        request: request,
        actionID: actionID,
        preparationAttemptID: preparationAttemptID,
        capabilityIDs: capabilityIDs,
        groupID: groupID,
        coordinator: coordinator,
        device: device,
        connectionEpoch: snapshot.connectionEpoch,
        helperExecutor: helperExecutor,
        developerImageCatalog: developerImageCatalog,
        developerImageStore: developerImageStore,
        remoteDeveloperImageCatalog: remoteDeveloperImageCatalog,
        progress: progress,
        selectedXcodeSnapshotProvider: selectedXcodeSnapshotProvider
      )
      if case .succeeded = result {
        let marked = try coordinator.markPreparationReady(
          groupID: groupID,
          connectionEpoch: snapshot.connectionEpoch
        )
        guard coordinator.isPreparationReady(
          groupID: groupID,
          snapshot: marked
        ) else {
          return .failedWithDetails(
            code: "preparationFailed",
            details: try developerSupportDetails(
              groupID: groupID,
              phase: "markingReady"
            )
          )
        }
        guard recordModernPreparationRehydrationEligibility(
          developerImageStore: developerImageStore,
          device: device,
          groupID: groupID
        ) else {
          return .failedWithDetails(
            code: "developerSupportUnavailable",
            details: try developerSupportDetails(
              groupID: groupID,
              phase: "persistingReadiness"
            )
          )
        }
      }
      return result
    case .none:
      return .failedWithDetails(
        code: "unsupportedPreparationGroup",
        details: try developerSupportDetails(
          groupID: groupID,
          phase: "checkingDevice"
        )
      )
    }
  }

  private static func executeDynamicPreparation(
    request: RuntimeRequestEnvelope,
    actionID: CanonicalUUID,
    preparationAttemptID: CanonicalUUID,
    capabilityIDs: [String],
    groupID: String,
    route: DeveloperSupportOSRoute,
    device: ProductionRuntimeDeviceObservation,
    connectionEpoch: UInt64,
    helperExecutor: ProductionCoreDeviceHelperExecutor,
    directHelperExecutor: ProductionCoreDeviceHelperExecutor?,
    catalogStore: DynamicDeveloperImageCatalogStore,
    assetCache: DynamicDeveloperImageAssetCache,
    progress: ProductionPreparationProgressPublisher
  ) throws -> ProductionRuntimeBackendDisposition {
    switch route.route {
    case .personalized:
      return try executeDynamicModernPreparation(
        actionID: actionID,
        preparationAttemptID: preparationAttemptID,
        capabilityIDs: capabilityIDs,
        groupID: groupID,
        device: device,
        connectionEpoch: connectionEpoch,
        helperExecutor: helperExecutor,
        catalogStore: catalogStore,
        assetCache: assetCache,
        progress: progress
      )
    case .classic:
      guard let directHelperExecutor else {
        return .failedWithDetails(
          code: "developerSupportUnavailable",
          details: try developerSupportDetails(
            groupID: groupID,
            phase: "startingDeviceServices"
          )
        )
      }
      return try executeDynamicClassicPreparation(
        request: request,
        actionID: actionID,
        preparationAttemptID: preparationAttemptID,
        capabilityIDs: capabilityIDs,
        groupID: groupID,
        device: device,
        connectionEpoch: connectionEpoch,
        directHelperExecutor: directHelperExecutor,
        catalogStore: catalogStore,
        assetCache: assetCache,
        progress: progress
      )
    case .none:
      return .failedWithDetails(
        code: "unsupportedPreparationGroup",
        details: try developerSupportDetails(
          groupID: groupID,
          phase: "checkingDevice"
        )
      )
    }
  }

  private static func executeDynamicModernPreparation(
    actionID: CanonicalUUID,
    preparationAttemptID: CanonicalUUID,
    capabilityIDs: [String],
    groupID: String,
    device: ProductionRuntimeDeviceObservation,
    connectionEpoch: UInt64,
    helperExecutor: ProductionCoreDeviceHelperExecutor,
    catalogStore: DynamicDeveloperImageCatalogStore,
    assetCache: DynamicDeveloperImageAssetCache,
    progress: ProductionPreparationProgressPublisher
  ) throws -> ProductionRuntimeBackendDisposition {
    progress.publish(.queryingMountedImage)
    let query = try executeMountedPersonalizedQuery(
      actionID: actionID,
      device: device,
      connectionEpoch: connectionEpoch,
      helperExecutor: helperExecutor
    )
    guard query["outcome"]?.stringValue == "succeeded" else {
      return .standard(result: query)
    }
    guard let queryValue = query["value"]?.objectValue,
      case .bool(let mounted)? = queryValue["mounted"]
    else { return .failed(code: "preparationFailed") }
    if mounted {
      return try modernPreparationSuccess(
        assetDisposition: .mountedOnly,
        capabilityIDs: capabilityIDs,
        connectionEpoch: connectionEpoch,
        disposition: .alreadyReady,
        groupID: groupID,
        mountDisposition: .alreadyMounted,
        preparationAttemptID: nil,
        provenance: queryValue["provenance"]?.stringValue
          ?? "mountedUnknownUnverified",
        actionID: actionID,
        device: device,
        helperExecutor: helperExecutor,
        progress: progress
      )
    }

    progress.publish(.resolvingDeveloperSupport)
    let snapshot: DynamicDeveloperImageCatalogSnapshot
    let selection: DynamicDeveloperImageSelection
    do {
      snapshot = try catalogStore.snapshot()
      selection =
        try DynamicDeveloperImageCatalog.exactBaseAsset(
          in: snapshot.catalog,
          buildID: device.facts.buildVersion
        )
        ?? catalogStore.localCandidate(
          buildID: device.facts.buildVersion,
          snapshot: snapshot
        )
        ?? DynamicDeveloperImageCatalog.baseAsset(
          in: snapshot.catalog,
          baseAssetID: snapshot.catalog.defaultCandidateBaseAssetID,
          provenance: .defaultCandidate
        )
        ?? { throw DynamicDeveloperImageCatalogStoreError.candidateIncompatible }()
    } catch let error as DynamicDeveloperImageCatalogStoreError {
      return try dynamicCatalogFailure(error, groupID: groupID)
    } catch {
      return try dynamicCatalogFailure(.catalogUnavailable, groupID: groupID)
    }

    let acquired:
      (
        disposition: PreparationAssetDisposition,
        lease: DynamicDeveloperImageAssetLease
      )
    do {
      acquired = try acquireDynamicAssetForPreparation(
        selection.asset,
        assetCache: assetCache,
        willAcquireRemote: {
          progress.publish(
            .downloading,
            completedBytes: 0,
            totalBytes: selection.asset.archiveSize,
            sourceKind: .approvedRemote
          )
        }
      )
    } catch let error as DynamicDeveloperImageAssetCacheError {
      return try dynamicAssetAcquisitionFailure(error, groupID: groupID)
    } catch {
      return .failed(code: "developerImageDownloadFailed")
    }
    let assetDisposition = acquired.disposition
    let assetLease = acquired.lease
    if assetDisposition == .downloaded {
      progress.publish(
        .validating,
        completedBytes: selection.asset.archiveSize,
        totalBytes: selection.asset.archiveSize,
        sourceKind: .approvedRemote
      )
    }

    let tss: RepositoryJSONObject
    do {
      tss = try withExtendedLifetime(assetLease) {
        progress.publish(.personalizing)
        return try executePersonalizedHelperOperation(
          .requestTSS,
          routeID: "coredevice.developerSupport.requestTSS",
          actionID: actionID,
          preparationAttemptID: preparationAttemptID,
          snapshot: snapshot,
          selection: selection,
          device: device,
          connectionEpoch: connectionEpoch,
          helperExecutor: helperExecutor
        )
      }
    } catch ProductionCoreDeviceHelperExecutorError.timedOut {
      return try dynamicPersonalizationTimeoutFailure(groupID: groupID)
    }
    guard tss["outcome"]?.stringValue == "succeeded" else {
      return .standard(result: tss)
    }
    let mount = try withExtendedLifetime(assetLease) {
      progress.publish(.mounting)
      return try executePersonalizedHelperOperation(
        .mount,
        routeID: "coredevice.developerSupport.mount",
        actionID: actionID,
        preparationAttemptID: preparationAttemptID,
        snapshot: snapshot,
        selection: selection,
        device: device,
        connectionEpoch: connectionEpoch,
        helperExecutor: helperExecutor
      )
    }
    guard mount["outcome"]?.stringValue == "succeeded" else {
      return .standard(result: mount)
    }
    guard let mountValue = mount["value"]?.objectValue,
      case .bool(true)? = mountValue["mounted"],
      case .bool(true)? = mountValue["mountCommitted"]
    else { return .failed(code: "preparationFailed") }
    let result = try modernPreparationSuccess(
      assetDisposition: assetDisposition,
      capabilityIDs: capabilityIDs,
      connectionEpoch: connectionEpoch,
      disposition: .ready,
      groupID: groupID,
      mountDisposition: .mounted,
      preparationAttemptID: preparationAttemptID,
      provenance: mountValue["provenance"]?.stringValue ?? "approved",
      actionID: actionID,
      device: device,
      helperExecutor: helperExecutor,
      progress: progress
    )
    if case .succeeded = result, selection.provenance == .defaultCandidate {
      try? catalogStore.recordSuccessfulDefaultCandidate(
        iosVersion: device.facts.productVersion,
        buildID: device.facts.buildVersion,
        selection: selection,
        snapshot: snapshot,
        serviceProfileID: groupID
      )
    }
    return result
  }

  private static func executeDynamicClassicPreparation(
    request: RuntimeRequestEnvelope,
    actionID: CanonicalUUID,
    preparationAttemptID: CanonicalUUID,
    capabilityIDs: [String],
    groupID: String,
    device: ProductionRuntimeDeviceObservation,
    connectionEpoch: UInt64,
    directHelperExecutor: ProductionCoreDeviceHelperExecutor,
    catalogStore: DynamicDeveloperImageCatalogStore,
    assetCache: DynamicDeveloperImageAssetCache,
    progress: ProductionPreparationProgressPublisher
  ) throws -> ProductionRuntimeBackendDisposition {
    progress.publish(.queryingMountedImage)
    let query = try executeMountedClassicQuery(
      request: request,
      actionID: actionID,
      device: device,
      connectionEpoch: connectionEpoch,
      directHelperExecutor: directHelperExecutor
    )
    guard query["outcome"]?.stringValue == "succeeded" else {
      return .standard(result: query)
    }
    guard let queryValue = query["value"]?.objectValue,
      case .bool(let mounted)? = queryValue["mounted"]
    else { return .failed(code: "preparationFailed") }

    progress.publish(.resolvingDeveloperSupport)
    let snapshot: DynamicDeveloperImageCatalogSnapshot
    let asset: DynamicDeveloperImageAssetReference
    do {
      snapshot = try catalogStore.snapshot()
      guard
        let selected = DynamicDeveloperImageCatalog.classicDDI(
          in: snapshot.catalog,
          iosVersion: device.facts.productVersion
        )
      else {
        return .failedWithDetails(
          code: "matchingDDIUnavailable",
          details: try developerSupportDetails(
            groupID: groupID,
            phase: "resolvingDeveloperSupport"
          )
        )
      }
      asset = selected
    } catch let error as DynamicDeveloperImageCatalogStoreError {
      return try dynamicCatalogFailure(error, groupID: groupID)
    } catch {
      return try dynamicCatalogFailure(.catalogUnavailable, groupID: groupID)
    }

    if mounted {
      progress.publish(.probingServices)
      let probe = try executeClassicHelperOperation(
        .probeServices,
        routeID: "legacy.developerSupport.probeServices",
        request: request,
        actionID: actionID,
        preparationAttemptID: preparationAttemptID,
        snapshot: snapshot,
        asset: asset,
        device: device,
        connectionEpoch: connectionEpoch,
        directHelperExecutor: directHelperExecutor
      )
      guard probe["outcome"]?.stringValue == "succeeded" else {
        return .standard(result: probe)
      }
      return try classicPreparationSuccess(
        assetDisposition: .mountedOnly,
        capabilityIDs: capabilityIDs,
        connectionEpoch: connectionEpoch,
        disposition: .alreadyReady,
        groupID: groupID,
        mountDisposition: .alreadyMounted,
        preparationAttemptID: nil,
        provenance: queryValue["provenance"]?.stringValue
          ?? "mountedUnknownUnverified"
      )
    }

    let acquired:
      (
        disposition: PreparationAssetDisposition,
        lease: DynamicDeveloperImageAssetLease
      )
    do {
      acquired = try acquireDynamicAssetForPreparation(
        asset,
        assetCache: assetCache,
        willAcquireRemote: {
          progress.publish(
            .downloading,
            completedBytes: 0,
            totalBytes: asset.archiveSize,
            sourceKind: .approvedRemote
          )
        }
      )
    } catch let error as DynamicDeveloperImageAssetCacheError {
      return try dynamicAssetAcquisitionFailure(error, groupID: groupID)
    } catch {
      return .failed(code: "developerImageDownloadFailed")
    }
    let assetDisposition = acquired.disposition
    let assetLease = acquired.lease
    if assetDisposition == .downloaded {
      progress.publish(
        .validating,
        completedBytes: asset.archiveSize,
        totalBytes: asset.archiveSize,
        sourceKind: .approvedRemote
      )
    }
    let mount: RepositoryJSONObject
    do {
      mount = try withExtendedLifetime(assetLease) {
        progress.publish(.mounting)
        return try executeClassicHelperOperation(
          .mount,
          routeID: "legacy.developerSupport.mount",
          request: request,
          actionID: actionID,
          preparationAttemptID: preparationAttemptID,
          snapshot: snapshot,
          asset: asset,
          device: device,
          connectionEpoch: connectionEpoch,
          directHelperExecutor: directHelperExecutor
        )
      }
    } catch ProductionCoreDeviceHelperExecutorError.timedOut {
      return try dynamicClassicMountTimeoutFailure(groupID: groupID)
    }
    guard mount["outcome"]?.stringValue == "succeeded" else {
      return .standard(result: mount)
    }
    guard let mountValue = mount["value"]?.objectValue,
      case .bool(true)? = mountValue["mounted"],
      case .bool(true)? = mountValue["servicesReady"]
    else { return .failed(code: "preparationFailed") }
    progress.publish(.ready)
    return try classicPreparationSuccess(
      assetDisposition: assetDisposition,
      capabilityIDs: capabilityIDs,
      connectionEpoch: connectionEpoch,
      disposition: .ready,
      groupID: groupID,
      mountDisposition: .mounted,
      preparationAttemptID: preparationAttemptID,
      provenance: mountValue["provenance"]?.stringValue ?? "approved"
                    )
                }

  static func dynamicCatalogFailure(
    _ error: DynamicDeveloperImageCatalogStoreError,
    groupID: String
  ) throws -> ProductionRuntimeBackendDisposition {
    let code: String
    switch error {
    case .candidateIncompatible:
      code = "developerImageCandidateIncompatible"
    case .catalogMismatch, .sourceRejected:
      code = "developerImageCatalogMismatch"
    case .catalogUnavailable, .networkUnavailable:
      code = "developerImageCatalogUnavailable"
    }
                return .failedWithDetails(
      code: code,
                    details: try developerSupportDetails(
                        groupID: groupID,
        phase: "resolvingDeveloperSupport"
                    )
                )
            }

  static func dynamicPersonalizationTimeoutFailure(
    groupID: String
  ) throws -> ProductionRuntimeBackendDisposition {
    .failedWithDetails(
      code: "preparationTimeout",
      details: try developerSupportDetails(
        groupID: groupID,
        phase: "personalizing",
        retryStage: "personalizationTSS"
      )
    )
  }

  static func dynamicClassicMountTimeoutFailure(
    groupID: String
  ) throws -> ProductionRuntimeBackendDisposition {
    .failedWithDetails(
      code: "preparationTimeout",
      details: try developerSupportDetails(
        groupID: groupID,
        phase: "mounting",
        retryStage: "classicMount"
      )
    )
  }

  /// A dynamic catalog authorizes the asset identity, while the Xcode reader
  /// merely supplies local bytes. An Xcode content mismatch therefore falls
  /// through to the approved remote archive; storage and integrity failures
  /// remain observable rather than being silently accepted.
  static func acquireDynamicAssetForPreparation(
    _ reference: DynamicDeveloperImageAssetReference,
    assetCache: DynamicDeveloperImageAssetCache,
    willAcquireRemote: () -> Void = {},
    xcodeFilesProvider:
      @escaping @Sendable (
        DynamicDeveloperImageAssetReference
      ) -> [String: Data]? = { reference in
        ProductionSelectedXcodeSnapshot.captureDynamicAssetFiles(
          for: reference
                )
      }
  ) throws -> (
    disposition: PreparationAssetDisposition,
    lease: DynamicDeveloperImageAssetLease
  ) {
    if let lease = try assetCache.openVerified(reference) {
      return (.cacheHit, lease)
    }
    if let files = xcodeFilesProvider(reference) {
      do {
        let lease = try assetCache.importVerifiedContent(
          reference,
          files: files
                )
        return (.xcodeHit, lease)
      } catch DynamicDeveloperImageAssetCacheError.contentManifestMismatch {
        // A selected Xcode that does not supply this exact catalog
        // asset is not a failure of the catalog; use the approved
        // remote archive next.
      }
    }
    willAcquireRemote()
    return (.downloaded, try assetCache.acquireRemote(reference))
  }

  private static func dynamicAssetAcquisitionFailure(
    _ error: DynamicDeveloperImageAssetCacheError,
    groupID: String
  ) throws -> ProductionRuntimeBackendDisposition {
    let code: String
    switch error {
    case .archiveIntegrityFailed, .contentManifestMismatch:
      code = "developerImageIntegrityFailed"
    case .cacheCapacityExceeded:
      code = "developerImageCacheCapacityExceeded"
    case .sourceRejected:
      code = "developerImageDownloadFailed"
            }
            return .failedWithDetails(
      code: code,
                details: try developerSupportDetails(
                    groupID: groupID,
        phase: "validating",
        retryStage: "acquisition"
                )
            )
        }

    private static func executeModernPreparation(
        request: RuntimeRequestEnvelope,
        actionID: CanonicalUUID,
        preparationAttemptID: CanonicalUUID,
        capabilityIDs: [String],
        groupID: String,
        coordinator: ProductionRuntimeDeviceCoordinator,
        device: ProductionRuntimeDeviceObservation,
        connectionEpoch: UInt64,
        helperExecutor: ProductionCoreDeviceHelperExecutor,
        developerImageCatalog: DeveloperImageCatalogV1?,
        developerImageStore: DeveloperImageAssetStore?,
        remoteDeveloperImageCatalog: ControlledRemoteDeveloperImageCatalog?,
        progress: ProductionPreparationProgressPublisher,
    selectedXcodeSnapshotProvider:
      @Sendable (
            DeveloperImageCatalogEntryV1
        ) -> SelectedXcodeSnapshot?
    ) throws -> ProductionRuntimeBackendDisposition {
        // Mounted device support is a device fact, not an asset reference. It
        // must be checked before catalog/cache/Xcode/remote source resolution.
        progress.publish(.queryingMountedImage)
        let query = try executeMountedPersonalizedQuery(
            actionID: actionID,
            device: device,
            connectionEpoch: connectionEpoch,
            helperExecutor: helperExecutor
        )
        guard query["outcome"]?.stringValue == "succeeded" else {
            return .standard(result: query)
        }
        guard let queryValue = query["value"]?.objectValue,
              case .bool(let mounted)? = queryValue["mounted"]
        else {
            return .failed(code: "preparationFailed")
        }
        if mounted {
            return try modernPreparationSuccess(
                assetDisposition: .mountedOnly,
                capabilityIDs: capabilityIDs,
                connectionEpoch: connectionEpoch,
                disposition: .alreadyReady,
                groupID: groupID,
                mountDisposition: .alreadyMounted,
                preparationAttemptID: nil,
                provenance: queryValue["provenance"]?.stringValue
                    ?? "mountedUnknownUnverified",
                actionID: actionID,
                device: device,
                helperExecutor: helperExecutor,
                progress: progress
            )
        }
        progress.publish(.resolvingDeveloperSupport)
        guard let developerImageCatalog else {
            return .failedWithDetails(
                code: "developerImageCatalogMismatch",
                details: try developerSupportDetails(
                    groupID: groupID,
                    phase: "resolvingDeveloperSupport"
                )
            )
        }
        guard let developerImageStore else {
            return .failedWithDetails(
                code: "developerSupportUnavailable",
                details: try developerSupportDetails(
                    groupID: groupID,
                    phase: "resolvingDeveloperSupport"
                )
            )
        }
        do {
            _ = try developerImageStore.createOrValidateCatalog(developerImageCatalog)
        } catch let error as DeveloperImageAssetStoreError {
            return try developerImageStoreFailure(
                error,
                groupID: groupID,
                phase: "validating"
            )
        }
    guard
      let osMajor = UInt64(
            device.facts.productVersion.split(separator: ".").first ?? ""
      )
    else {
            return .failedWithDetails(
                code: "developerImageCatalogMismatch",
                details: try developerSupportDetails(
                    groupID: groupID,
                    phase: "resolvingDeveloperSupport"
                )
            )
        }
        var effectiveCatalog = developerImageCatalog
        var entry = DeveloperImageCompatibility.exactEntry(
            in: effectiveCatalog,
            osMajor: osMajor,
            buildID: device.facts.buildVersion
        )
        if entry == nil {
            do {
        let remote =
          remoteDeveloperImageCatalog
                    ?? ControlledRemoteDeveloperImageCatalog()
                if let catalog = try remote.matchingCatalog(
                    assetStore: developerImageStore,
                    osMajor: osMajor,
                    buildID: device.facts.buildVersion,
                    validateCatalog: { try coordinator.validateDeveloperImageCatalog($0) }
                ) {
                    effectiveCatalog = catalog
                    entry = DeveloperImageCompatibility.exactEntry(
                        in: catalog,
                        osMajor: osMajor,
                        buildID: device.facts.buildVersion
                    )
                }
            } catch let error as ControlledRemoteDeveloperImageCatalogError {
                return try controlledRemoteCatalogFailure(
                    error,
                    groupID: groupID,
                    phase: "resolvingDeveloperSupport"
                )
            }
        }
        guard let entry, entry.imageKind == .personalized else {
            return .failedWithDetails(
                code: "developerImageCatalogMismatch",
                details: try developerSupportDetails(
                    groupID: groupID,
                    phase: "resolvingDeveloperSupport"
                )
            )
        }

        let assetDisposition: PreparationAssetDisposition
        do {
            if try developerImageStore.openVerifiedAsset(
                catalog: effectiveCatalog,
                entryID: entry.entryID
            ) != nil {
                assetDisposition = .cacheHit
            } else if let selectedXcode = selectedXcodeSnapshotProvider(entry),
                      try developerImageStore.publishSelectedXcode(
                        catalog: effectiveCatalog,
                        entryID: entry.entryID,
                        snapshot: selectedXcode
                      ) != nil,
                      try developerImageStore.openVerifiedAsset(
                        catalog: effectiveCatalog,
                        entryID: entry.entryID
                      ) != nil
            {
                assetDisposition = .xcodeHit
            } else if !entry.sourceURLs.isEmpty {
        let remote =
          remoteDeveloperImageCatalog
                    ?? ControlledRemoteDeveloperImageCatalog()
                progress.publish(
                    .downloading,
                    completedBytes: 0,
                    totalBytes: entry.archiveSize,
                    sourceKind: .approvedRemote
                )
                _ = try remote.acquire(
                    catalog: effectiveCatalog,
                    entryID: entry.entryID,
                    assetStore: developerImageStore
                )
        guard
          try developerImageStore.openVerifiedAsset(
                    catalog: effectiveCatalog,
                    entryID: entry.entryID
          ) != nil
        else {
                    return try controlledRemoteCatalogFailure(
                        .archiveIntegrityFailed,
                        groupID: groupID,
                        phase: "validating"
                    )
                }
                progress.publish(
                    .validating,
                    completedBytes: entry.archiveSize,
                    totalBytes: entry.archiveSize,
                    sourceKind: .approvedRemote
                )
                assetDisposition = .downloaded
            } else {
                return .failedWithDetails(
                    code: "developerSupportUnavailable",
                    details: try developerSupportDetails(
                        groupID: groupID,
                        phase: "resolvingDeveloperSupport",
                        retryStage: "acquisition"
                    )
                )
            }
        } catch let error as ControlledRemoteDeveloperImageCatalogError {
            return try controlledRemoteCatalogFailure(
                error,
                groupID: groupID,
                phase: "resolvingDeveloperSupport"
            )
        } catch let error as DeveloperImageAssetStoreError {
            return try developerImageStoreFailure(
                error,
                groupID: groupID,
                phase: "validating"
            )
        }

        progress.publish(.personalizing)
        let tss = try executePersonalizedHelperOperation(
            .requestTSS,
            routeID: "coredevice.developerSupport.requestTSS",
            actionID: actionID,
            preparationAttemptID: preparationAttemptID,
            catalog: effectiveCatalog,
            entryID: entry.entryID,
            device: device,
            connectionEpoch: connectionEpoch,
            helperExecutor: helperExecutor
        )
        guard tss["outcome"]?.stringValue == "succeeded" else {
            return .standard(result: tss)
        }
        progress.publish(.mounting)
        let mount = try executePersonalizedHelperOperation(
            .mount,
            routeID: "coredevice.developerSupport.mount",
            actionID: actionID,
            preparationAttemptID: preparationAttemptID,
            catalog: effectiveCatalog,
            entryID: entry.entryID,
            device: device,
            connectionEpoch: connectionEpoch,
            helperExecutor: helperExecutor
        )
        guard mount["outcome"]?.stringValue == "succeeded" else {
            return .standard(result: mount)
        }
        guard let mountValue = mount["value"]?.objectValue,
              case .bool(true)? = mountValue["mounted"],
              case .bool(true)? = mountValue["mountCommitted"]
        else {
            return .failed(code: "preparationFailed")
        }
        return try modernPreparationSuccess(
            assetDisposition: assetDisposition,
            capabilityIDs: capabilityIDs,
            connectionEpoch: connectionEpoch,
            disposition: .ready,
            groupID: groupID,
            mountDisposition: .mounted,
            preparationAttemptID: preparationAttemptID,
            provenance: mountValue["provenance"]?.stringValue ?? "approved",
            actionID: actionID,
            device: device,
            helperExecutor: helperExecutor,
            progress: progress
        )
    }

    /// A prior successful preparation only permits this fresh Runtime to ask
    /// the device again. The receipt alone never makes a capability ready.
    private static func restoreCurrentModernPreparationReadinessIfEligible(
        actionID: CanonicalUUID,
        coordinator: ProductionRuntimeDeviceCoordinator,
        device: ProductionRuntimeDeviceObservation,
        groupID: String,
        helperExecutor: ProductionCoreDeviceHelperExecutor,
        snapshot: ProductionRuntimeDeviceSnapshot
    ) -> PreparationReadinessRecoveryResult {
        guard let osMajor = UInt64(
                  device.facts.productVersion.split(separator: ".").first ?? ""
              ),
              let route = try? coordinator.developerSupportRoute(osMajor: osMajor),
              route.route == .personalized
        else {
            return .mountedStateCheckFailed
        }

        do {
            let query = try executeMountedPersonalizedQuery(
                actionID: actionID,
                device: device,
                connectionEpoch: snapshot.connectionEpoch,
                helperExecutor: helperExecutor
            )
            guard query["outcome"]?.stringValue == "succeeded" else {
                return .mountedStateCheckFailed
            }
            guard case .bool(true)? = query["value"]?.objectValue?["mounted"] else {
                return .notMounted
            }
            let warm = try helperExecutor.warmGeneration(
                requestID: CanonicalUUID(value: UUID()),
                actionID: actionID,
                preparationAttemptID: CanonicalUUID(value: UUID()),
                preparationGroupID: groupID,
                device: device,
                connectionEpoch: snapshot.connectionEpoch
            )
            guard warm["outcome"]?.stringValue == "succeeded",
                  let warmValue = warm["value"]?.objectValue,
                  warmValue["executorGeneration"]?.numberValue
                    .flatMap({ try? $0.requireUInt64() }) != nil
            else {
                return .serviceWarmupFailed
            }
            let current = try coordinator.commandAdmissionSnapshot()
            guard current.connectionEpoch == snapshot.connectionEpoch,
                  current.device == device
            else {
                return .staleConnection
            }
            _ = try coordinator.markPreparationReady(
                groupID: groupID,
                connectionEpoch: current.connectionEpoch
            )
            developerSupportLogger.notice(
                "stage=rehydrateCurrentGeneration outcome=succeeded preparationGroupID=\(groupID, privacy: .public)"
            )
            return coordinator.isPreparationReady(
                groupID: groupID,
                snapshot: try coordinator.commandAdmissionSnapshot()
            ) ? .ready : .staleConnection
        } catch ProductionRuntimeDeviceCoordinatorError.stalePreparationState {
            return .staleConnection
        } catch ProductionCoreDeviceHelperExecutorError.timedOut {
            return .serviceWarmupFailed
        } catch ProductionCoreDeviceHelperExecutorError.helperUnavailableBeforeRequest {
            return .serviceWarmupFailed
        } catch {
            developerSupportLogger.notice(
                "stage=rehydrateCurrentGeneration outcome=failed preparationGroupID=\(groupID, privacy: .public)"
            )
            return .mountedStateCheckFailed
        }
    }

    /// A classic receipt permits only a fresh, catalog-bound check of the
    /// currently mounted image and its service surface. It does not bypass a
    /// mount, catalog, or probe failure.
    private static func restoreCurrentClassicPreparationReadinessIfEligible(
        actionID: CanonicalUUID,
        coordinator: ProductionRuntimeDeviceCoordinator,
        dynamicDeveloperImageCatalogStore: DynamicDeveloperImageCatalogStore?,
        device: ProductionRuntimeDeviceObservation,
        groupID: String,
        directHelperExecutor: ProductionCoreDeviceHelperExecutor?,
        snapshot: ProductionRuntimeDeviceSnapshot
    ) -> PreparationReadinessRecoveryResult {
        guard let dynamicDeveloperImageCatalogStore,
              let directHelperExecutor,
              let osMajor = UInt64(
                  device.facts.productVersion.split(separator: ".").first ?? ""
              ),
              let route = try? coordinator.developerSupportRoute(osMajor: osMajor),
              route.route == .classic
        else {
            return .mountedStateCheckFailed
        }

        do {
            let catalogSnapshot = try dynamicDeveloperImageCatalogStore.snapshot()
            guard let asset = DynamicDeveloperImageCatalog.classicDDI(
                in: catalogSnapshot.catalog,
                iosVersion: device.facts.productVersion
            ) else {
                return .serviceWarmupFailed
            }
            let query = try directHelperExecutor.executeOneShot(
                requestID: CanonicalUUID(value: UUID()),
                actionID: actionID,
                parentActionID: nil,
                routeID: "legacy.developerSupport.queryMounted",
                backendPayload: ["operation": .string("queryMounted")],
                device: device,
                connectionEpoch: snapshot.connectionEpoch
            )
            guard query["outcome"]?.stringValue == "succeeded" else {
                return .mountedStateCheckFailed
            }
            guard case .bool(true)? = query["value"]?.objectValue?["mounted"] else {
                return .notMounted
            }
            let payload = try ClassicHelperRequestFactory.make(
                operation: .probeServices,
                snapshot: catalogSnapshot,
                asset: asset,
                connectionEpoch: snapshot.connectionEpoch,
                preparationAttemptID: CanonicalUUID(value: UUID())
            )
            let probe = try directHelperExecutor.executeOneShot(
                requestID: CanonicalUUID(value: UUID()),
                actionID: actionID,
                parentActionID: nil,
                routeID: "legacy.developerSupport.probeServices",
                backendPayload: classicHelperPayload(payload),
                device: device,
                connectionEpoch: snapshot.connectionEpoch
            )
            guard probe["outcome"]?.stringValue == "succeeded" else {
                return .serviceWarmupFailed
            }
            let current = try coordinator.commandAdmissionSnapshot()
            guard current.connectionEpoch == snapshot.connectionEpoch,
                  current.device == device
            else {
                return .staleConnection
            }
            _ = try coordinator.markPreparationReady(
                groupID: groupID,
                connectionEpoch: current.connectionEpoch
            )
            developerSupportLogger.notice(
                "stage=rehydrateCurrentClassicReadiness outcome=succeeded preparationGroupID=\(groupID, privacy: .public)"
            )
            return coordinator.isPreparationReady(
                groupID: groupID,
                snapshot: try coordinator.commandAdmissionSnapshot()
            ) ? .ready : .staleConnection
        } catch ProductionRuntimeDeviceCoordinatorError.stalePreparationState {
            return .staleConnection
        } catch ProductionCoreDeviceHelperExecutorError.timedOut {
            return .serviceWarmupFailed
        } catch ProductionCoreDeviceHelperExecutorError.helperUnavailableBeforeRequest {
            return .serviceWarmupFailed
        } catch {
            developerSupportLogger.notice(
                "stage=rehydrateCurrentClassicReadiness outcome=failed preparationGroupID=\(groupID, privacy: .public)"
            )
            return .mountedStateCheckFailed
        }
    }

    private static func recordModernPreparationRehydrationEligibility(
        developerImageStore: DeveloperImageAssetStore?,
        device: ProductionRuntimeDeviceObservation,
        groupID: String
    ) -> Bool {
        recordPreparationRehydrationEligibility(
            developerImageStore: developerImageStore,
            device: device,
            groupID: groupID
        )
    }

    private static func recordClassicPreparationRehydrationEligibility(
        developerImageStore: DeveloperImageAssetStore?,
        device: ProductionRuntimeDeviceObservation,
        groupID: String
    ) -> Bool {
        recordPreparationRehydrationEligibility(
            developerImageStore: developerImageStore,
            device: device,
            groupID: groupID
        )
    }

    private static func recordPreparationRehydrationEligibility(
        developerImageStore: DeveloperImageAssetStore?,
        device: ProductionRuntimeDeviceObservation,
        groupID: String
    ) -> Bool {
        guard let developerImageStore else {
            // Persistence is optional in test/minimal assemblies; readiness is
            // still valid for the current Runtime and connection epoch.
            return true
        }
        guard let receipt = preparationRehydrationEligibility(
            device: device,
            groupID: groupID
        ) else {
            return false
        }
        do {
            try developerImageStore.recordPreparationRehydrationEligibility(
                receipt
            )
            return true
        } catch {
            developerSupportLogger.error(
                "stage=recordRehydrationEligibility outcome=failed preparationGroupID=\(groupID, privacy: .public)"
            )
            return false
        }
    }

    private static func preparationRehydrationEligibility(
        device: ProductionRuntimeDeviceObservation,
        groupID: String
    ) -> DeveloperSupportRehydrationEligibilityReceipt? {
    guard
      let canonicalUDID = try? CanonicalUDID(
            canonicalString: device.facts.uniqueDeviceID
      )
    else {
            return nil
        }
        return DeveloperSupportRehydrationEligibilityReceipt(
            buildVersion: device.facts.buildVersion,
            preparationGroupID: groupID,
            productType: device.facts.productType,
            productVersion: device.facts.productVersion,
            targetIdentityHash: canonicalUDID.domainSeparatedHash
        )
    }

    private static func executeMountedPersonalizedQuery(
        actionID: CanonicalUUID,
        device: ProductionRuntimeDeviceObservation,
        connectionEpoch: UInt64,
        helperExecutor: ProductionCoreDeviceHelperExecutor
    ) throws -> RepositoryJSONObject {
        try helperExecutor.executeOneShot(
            requestID: CanonicalUUID(value: UUID()),
            actionID: actionID,
            parentActionID: nil,
            routeID: "coredevice.developerSupport.queryMounted",
            backendPayload: ["operation": .string("queryMounted")],
            device: device,
            connectionEpoch: connectionEpoch
        )
    }

  private static func executeMountedClassicQuery(
    request: RuntimeRequestEnvelope,
    actionID: CanonicalUUID,
    device: ProductionRuntimeDeviceObservation,
    connectionEpoch: UInt64,
    directHelperExecutor: ProductionCoreDeviceHelperExecutor
  ) throws -> RepositoryJSONObject {
    try directHelperExecutor.executeOneShot(
      requestID: request.requestID,
      actionID: actionID,
      parentActionID: nil,
      routeID: "legacy.developerSupport.queryMounted",
      backendPayload: ["operation": .string("queryMounted")],
      device: device,
      connectionEpoch: connectionEpoch
    )
  }

  private static func executePersonalizedHelperOperation(
    _ operation: PersonalizedDeveloperSupportOperation,
    routeID: String,
    actionID: CanonicalUUID,
    preparationAttemptID: CanonicalUUID,
    snapshot: DynamicDeveloperImageCatalogSnapshot,
    selection: DynamicDeveloperImageSelection,
    device: ProductionRuntimeDeviceObservation,
    connectionEpoch: UInt64,
    helperExecutor: ProductionCoreDeviceHelperExecutor
  ) throws -> RepositoryJSONObject {
    let payload = try PersonalizedHelperRequestFactory.make(
      operation: operation,
      snapshot: snapshot,
      selection: selection,
      connectionEpoch: connectionEpoch,
      preparationAttemptID: preparationAttemptID
    )
    return try helperExecutor.executeOneShot(
      requestID: CanonicalUUID(value: UUID()),
      actionID: actionID,
      parentActionID: nil,
      routeID: routeID,
      backendPayload: personalizedHelperPayload(payload),
      device: device,
      connectionEpoch: connectionEpoch
    )
  }

    private static func executePersonalizedHelperOperation(
        _ operation: PersonalizedDeveloperSupportOperation,
        routeID: String,
        actionID: CanonicalUUID,
        preparationAttemptID: CanonicalUUID,
        catalog: DeveloperImageCatalogV1,
        entryID: String,
        device: ProductionRuntimeDeviceObservation,
        connectionEpoch: UInt64,
        helperExecutor: ProductionCoreDeviceHelperExecutor
    ) throws -> RepositoryJSONObject {
        let payload = try PersonalizedHelperRequestFactory.make(
            operation: operation,
            catalog: catalog,
            entryID: entryID,
            connectionEpoch: connectionEpoch,
            preparationAttemptID: preparationAttemptID
        )
        return try helperExecutor.executeOneShot(
            requestID: CanonicalUUID(value: UUID()),
            actionID: actionID,
            parentActionID: nil,
            routeID: routeID,
            backendPayload: personalizedHelperPayload(payload),
            device: device,
            connectionEpoch: connectionEpoch
        )
    }

    private static func personalizedHelperPayload(
        _ payload: PersonalizedHelperBackendPayload
    ) -> [String: HelperWireJSONValue] {
        [
      "assetContentManifestSHA256": .string(
        payload.assetContentManifestSHA256
      ),
      "catalogCanonicalSHA256": .string(
        payload.catalogCanonicalSHA256
      ),
            "catalogRevision": .string(payload.catalogRevision),
            "deviceContext": .object([
                "connectionEpoch": .unsignedInteger(
                    payload.deviceContext.connectionEpoch
        )
            ]),
            "fileRoles": .array(payload.fileRoles.map { .string($0) }),
            "operation": .string(payload.operation.rawValue),
            "preparationAttemptID": .string(
                payload.preparationAttemptID.canonicalString
            ),
            "preparationGroupID": .string(payload.preparationGroupID),
        ]
    }

    private static func modernPreparationSuccess(
        assetDisposition: PreparationAssetDisposition,
        capabilityIDs: [String],
        connectionEpoch: UInt64,
        disposition: PreparationResultDisposition,
        groupID: String,
        mountDisposition: PreparationMountDisposition,
        preparationAttemptID: CanonicalUUID?,
        provenance: String,
        actionID: CanonicalUUID,
        device: ProductionRuntimeDeviceObservation,
        helperExecutor: ProductionCoreDeviceHelperExecutor,
        progress: ProductionPreparationProgressPublisher
    ) throws -> ProductionRuntimeBackendDisposition {
        let warm = try awaitModernWarmReadiness(
            actionID: actionID,
            preparationAttemptID: preparationAttemptID,
            preparationGroupID: groupID,
            device: device,
            connectionEpoch: connectionEpoch,
            helperExecutor: helperExecutor,
            progress: progress
        )
        guard warm["outcome"]?.stringValue == "succeeded" else {
            return .standard(result: warm)
        }
        guard let helperValue = warm["value"]?.objectValue,
              let executorGeneration = helperValue["executorGeneration"]?
                .numberValue.flatMap({ try? $0.requireUInt64() })
        else {
            return .failed(code: "preparationFailed")
        }
        progress.publish(.probingServices)
        _ = try PreparationResultV1(
            assetDisposition: assetDisposition,
            capabilityIDs: capabilityIDs,
            connectionEpoch: connectionEpoch,
            disposition: disposition,
            executorGeneration: executorGeneration,
            mountDisposition: mountDisposition,
            preparationAttemptID: preparationAttemptID,
            preparationGroupID: groupID,
            provenance: provenance,
            serviceDisposition: .ready
        )
        var members: [(String, RepositoryJSONValue)] = [
            ("assetDisposition", .string(assetDisposition.rawValue)),
            ("capabilityIDs", .array(capabilityIDs.map { .string($0) })),
            ("connectionEpoch", .number(.uint64(connectionEpoch))),
            ("disposition", .string(disposition.rawValue)),
            ("executorGeneration", .number(.uint64(executorGeneration))),
            ("mountDisposition", .string(mountDisposition.rawValue)),
            ("preparationGroupID", .string(groupID)),
            ("provenance", .string(provenance)),
            ("serviceDisposition", .string("ready")),
        ]
        if let preparationAttemptID {
      members.append(
        (
                "preparationAttemptID",
                .string(preparationAttemptID.canonicalString)
            ))
        }
        progress.publish(.ready)
        return .succeeded(value: try object(members))
    }

    private static let modernWarmReadinessTimeout: TimeInterval = 5 * 60
    private static let modernWarmReadinessRetryInterval: TimeInterval = 1

    // MountImage is a committed device mutation. Retry only the actual
    // RequiredFacets warm-up while CoreDevice publishes its service surface.
    private static func awaitModernWarmReadiness(
        actionID: CanonicalUUID,
        preparationAttemptID: CanonicalUUID?,
        preparationGroupID: String,
        device: ProductionRuntimeDeviceObservation,
        connectionEpoch: UInt64,
        helperExecutor: ProductionCoreDeviceHelperExecutor,
        progress: ProductionPreparationProgressPublisher
    ) throws -> RepositoryJSONObject {
        let deadline = Date().addingTimeInterval(modernWarmReadinessTimeout)
        while true {
            progress.publish(.startingDeviceServices)
            let warm = try helperExecutor.warmGeneration(
                requestID: CanonicalUUID(value: UUID()),
                actionID: actionID,
                preparationAttemptID: preparationAttemptID
                    ?? CanonicalUUID(value: UUID()),
                preparationGroupID: preparationGroupID,
                device: device,
                connectionEpoch: connectionEpoch
            )
            guard warm["outcome"]?.stringValue != "succeeded",
                  isRetryableModernWarmFailure(warm),
                  Date() < deadline
            else {
                return warm
            }
      Thread.sleep(
        forTimeInterval: min(
                modernWarmReadinessRetryInterval,
                max(0, deadline.timeIntervalSinceNow)
            ))
        }
    }

    private static func isRetryableModernWarmFailure(
        _ result: RepositoryJSONObject
    ) -> Bool {
        result["outcome"]?.stringValue == "failed"
            && result["error"]?.objectValue?["code"]?.stringValue
                == "developerServicesUnavailable"
    }

    private static func executeClassicPreparation(
        request: RuntimeRequestEnvelope,
        actionID: CanonicalUUID,
        preparationAttemptID: CanonicalUUID,
        capabilityIDs: [String],
        groupID: String,
        device: ProductionRuntimeDeviceObservation,
        connectionEpoch: UInt64,
        directHelperExecutor: ProductionCoreDeviceHelperExecutor,
        developerImageCatalog: DeveloperImageCatalogV1?,
        developerImageStore: DeveloperImageAssetStore?,
        progress: ProductionPreparationProgressPublisher,
    selectedXcodeSnapshotProvider:
      @Sendable (
            DeveloperImageCatalogEntryV1
        ) -> SelectedXcodeSnapshot?
    ) throws -> ProductionRuntimeBackendDisposition {
        progress.publish(.resolvingDeveloperSupport)
        guard let developerImageCatalog else {
            return .failedWithDetails(
                code: "developerImageCatalogMismatch",
                details: try developerSupportDetails(
                    groupID: groupID,
                    phase: "resolvingDeveloperSupport"
                )
            )
        }
        guard let developerImageStore else {
            return .failedWithDetails(
                code: "developerSupportUnavailable",
                details: try developerSupportDetails(
                    groupID: groupID,
                    phase: "resolvingDeveloperSupport"
                )
            )
        }
        do {
            _ = try developerImageStore.createOrValidateCatalog(
                developerImageCatalog
            )
        } catch let error as DeveloperImageAssetStoreError {
            return try developerImageStoreFailure(
                error,
                groupID: groupID,
                phase: "validating"
            )
        }
    guard
      let osMajor = UInt64(
            device.facts.productVersion.split(separator: ".").first ?? ""
      ),
      let entry = DeveloperImageCompatibility.exactEntry(
            in: developerImageCatalog,
            osMajor: osMajor,
            buildID: device.facts.buildVersion
      ), entry.imageKind == .classic
    else {
            return .failedWithDetails(
                code: "developerImageCatalogMismatch",
                details: try developerSupportDetails(
                    groupID: groupID,
                    phase: "resolvingDeveloperSupport"
                )
            )
        }

        progress.publish(.queryingMountedImage)
        let query = try executeClassicHelperOperation(
            .queryMounted,
            routeID: "legacy.developerSupport.queryMounted",
            request: request,
            actionID: actionID,
            preparationAttemptID: preparationAttemptID,
            catalog: developerImageCatalog,
            entryID: entry.entryID,
            device: device,
            connectionEpoch: connectionEpoch,
            directHelperExecutor: directHelperExecutor
        )
        guard query["outcome"]?.stringValue == "succeeded" else {
            return .standard(result: query)
        }
        guard let queryValue = query["value"]?.objectValue,
              case .bool(let mounted)? = queryValue["mounted"]
        else {
            return .failed(code: "preparationFailed")
        }

        if mounted {
      let provenance =
        queryValue["provenance"]?.stringValue
                ?? "mountedUnknownUnverified"
            progress.publish(.probingServices)
            let probe = try executeClassicHelperOperation(
                .probeServices,
                routeID: "legacy.developerSupport.probeServices",
                request: request,
                actionID: actionID,
                preparationAttemptID: preparationAttemptID,
                catalog: developerImageCatalog,
                entryID: entry.entryID,
                device: device,
                connectionEpoch: connectionEpoch,
                directHelperExecutor: directHelperExecutor
            )
            guard probe["outcome"]?.stringValue == "succeeded" else {
                return .standard(result: probe)
            }
            progress.publish(.ready)
            return try classicPreparationSuccess(
                assetDisposition: .mountedOnly,
                capabilityIDs: capabilityIDs,
                connectionEpoch: connectionEpoch,
                disposition: .alreadyReady,
                groupID: groupID,
                mountDisposition: .alreadyMounted,
                preparationAttemptID: nil,
                provenance: provenance
            )
        }

        let assetLease: DeveloperImageAssetLease
        let assetDisposition: PreparationAssetDisposition
        do {
            if let cachedLease = try developerImageStore.openVerifiedAsset(
                catalog: developerImageCatalog,
                entryID: entry.entryID
            ) {
                assetLease = cachedLease
                assetDisposition = .cacheHit
            } else if let selectedXcode = selectedXcodeSnapshotProvider(entry),
                      try developerImageStore.publishSelectedXcode(
                        catalog: developerImageCatalog,
                        entryID: entry.entryID,
                        snapshot: selectedXcode
                      ) != nil,
        let selectedXcodeLease =
          try developerImageStore
                        .openVerifiedAsset(
                            catalog: developerImageCatalog,
                            entryID: entry.entryID
                        )
            {
                assetLease = selectedXcodeLease
                assetDisposition = .xcodeHit
            } else {
                return .failedWithDetails(
                    code: "developerSupportUnavailable",
                    details: try developerSupportDetails(
                        groupID: groupID,
                        phase: "resolvingDeveloperSupport",
                        retryStage: "acquisition"
                    )
                )
            }
        } catch let error as DeveloperImageAssetStoreError {
            return try developerImageStoreFailure(
                error,
                groupID: groupID,
                phase: "validating"
            )
        }
        progress.publish(.mounting)
        let mount = try withExtendedLifetime(assetLease) {
            try executeClassicHelperOperation(
                .mount,
                routeID: "legacy.developerSupport.mount",
                request: request,
                actionID: actionID,
                preparationAttemptID: preparationAttemptID,
                catalog: developerImageCatalog,
                entryID: entry.entryID,
                device: device,
                connectionEpoch: connectionEpoch,
                directHelperExecutor: directHelperExecutor
            )
        }
        guard mount["outcome"]?.stringValue == "succeeded" else {
            return .standard(result: mount)
        }
        guard let mountValue = mount["value"]?.objectValue,
              case .bool(true)? = mountValue["mounted"],
              case .bool(true)? = mountValue["servicesReady"]
        else {
            return .failed(code: "preparationFailed")
        }
        progress.publish(.probingServices)
        progress.publish(.ready)
        return try classicPreparationSuccess(
            assetDisposition: assetDisposition,
            capabilityIDs: capabilityIDs,
            connectionEpoch: connectionEpoch,
            disposition: .ready,
            groupID: groupID,
            mountDisposition: .mounted,
            preparationAttemptID: preparationAttemptID,
            provenance: mountValue["provenance"]?.stringValue ?? "approved"
        )
    }

  private static func executeClassicHelperOperation(
    _ operation: ClassicDeveloperSupportOperation,
    routeID: String,
    request: RuntimeRequestEnvelope,
    actionID: CanonicalUUID,
    preparationAttemptID: CanonicalUUID,
    snapshot: DynamicDeveloperImageCatalogSnapshot,
    asset: DynamicDeveloperImageAssetReference,
    device: ProductionRuntimeDeviceObservation,
    connectionEpoch: UInt64,
    directHelperExecutor: ProductionCoreDeviceHelperExecutor
  ) throws -> RepositoryJSONObject {
    let payload = try ClassicHelperRequestFactory.make(
      operation: operation,
      snapshot: snapshot,
      asset: asset,
      connectionEpoch: connectionEpoch,
      preparationAttemptID: preparationAttemptID
    )
    return try directHelperExecutor.executeOneShot(
      requestID: request.requestID,
      actionID: actionID,
      parentActionID: nil,
      routeID: routeID,
      backendPayload: classicHelperPayload(payload),
      device: device,
      connectionEpoch: connectionEpoch
    )
  }

    private static func executeClassicHelperOperation(
        _ operation: ClassicDeveloperSupportOperation,
        routeID: String,
        request: RuntimeRequestEnvelope,
        actionID: CanonicalUUID,
        preparationAttemptID: CanonicalUUID,
        catalog: DeveloperImageCatalogV1,
        entryID: String,
        device: ProductionRuntimeDeviceObservation,
        connectionEpoch: UInt64,
        directHelperExecutor: ProductionCoreDeviceHelperExecutor
    ) throws -> RepositoryJSONObject {
        let payload = try ClassicHelperRequestFactory.make(
            operation: operation,
            catalog: catalog,
            entryID: entryID,
            connectionEpoch: connectionEpoch,
            preparationAttemptID: preparationAttemptID
        )
        return try directHelperExecutor.executeOneShot(
            requestID: request.requestID,
            actionID: actionID,
            parentActionID: nil,
            routeID: routeID,
            backendPayload: classicHelperPayload(payload),
            device: device,
            connectionEpoch: connectionEpoch
        )
    }

    private static func classicHelperPayload(
        _ payload: ClassicHelperBackendPayload
    ) -> [String: HelperWireJSONValue] {
        [
      "assetContentManifestSHA256": .string(
        payload.assetContentManifestSHA256
      ),
      "catalogCanonicalSHA256": .string(
        payload.catalogCanonicalSHA256
      ),
            "catalogRevision": .string(payload.catalogRevision),
            "deviceContext": .object([
                "connectionEpoch": .unsignedInteger(
                    payload.deviceContext.connectionEpoch
        )
            ]),
            "fileRoles": .array(payload.fileRoles.map { .string($0) }),
            "operation": .string(payload.operation.rawValue),
            "preparationAttemptID": .string(
                payload.preparationAttemptID.canonicalString
            ),
            "preparationGroupID": .string(payload.preparationGroupID),
        ]
    }

    private static func classicPreparationSuccess(
        assetDisposition: PreparationAssetDisposition,
        capabilityIDs: [String],
        connectionEpoch: UInt64,
        disposition: PreparationResultDisposition,
        groupID: String,
        mountDisposition: PreparationMountDisposition,
        preparationAttemptID: CanonicalUUID?,
        provenance: String
    ) throws -> ProductionRuntimeBackendDisposition {
        _ = try PreparationResultV1(
            assetDisposition: assetDisposition,
            capabilityIDs: capabilityIDs,
            connectionEpoch: connectionEpoch,
            disposition: disposition,
            mountDisposition: mountDisposition,
            preparationAttemptID: preparationAttemptID,
            preparationGroupID: groupID,
            provenance: provenance,
            serviceDisposition: .ready
        )
        var members: [(String, RepositoryJSONValue)] = [
            ("assetDisposition", .string(assetDisposition.rawValue)),
            ("capabilityIDs", .array(capabilityIDs.map { .string($0) })),
            ("connectionEpoch", .number(.uint64(connectionEpoch))),
            ("disposition", .string(disposition.rawValue)),
            ("mountDisposition", .string(mountDisposition.rawValue)),
            ("preparationGroupID", .string(groupID)),
            ("provenance", .string(provenance)),
            ("serviceDisposition", .string("ready")),
        ]
        if let preparationAttemptID {
      members.append(
        (
                "preparationAttemptID",
                .string(preparationAttemptID.canonicalString)
            ))
        }
        return .succeeded(value: try object(members))
    }

    private static func developerImageStoreFailure(
        _ error: DeveloperImageAssetStoreError,
        groupID: String,
        phase: String
    ) throws -> ProductionRuntimeBackendDisposition {
        let code: String
        switch error {
        case .capacityExceeded:
            code = "developerImageCacheCapacityExceeded"
        case .catalogMismatch, .invalidCatalogEntry(_):
            code = "developerImageCatalogMismatch"
        case .integrityMismatch(_), .invalidArchive(_), .invalidAssetKey,
             .invalidPartialState, .invalidPreparationRehydrationEligibility,
             .unsafeNode:
            code = "developerImageIntegrityFailed"
        case .lockUnavailable(_), .sourceUnavailable, .systemCall:
            code = "developerSupportUnavailable"
        }
        return .failedWithDetails(
            code: code,
            details: try developerSupportDetails(
                groupID: groupID,
                phase: phase
            )
        )
    }

    private static func controlledRemoteCatalogFailure(
        _ error: ControlledRemoteDeveloperImageCatalogError,
        groupID: String,
        phase: String
    ) throws -> ProductionRuntimeBackendDisposition {
        let code: String
        switch error {
        case .networkUnavailable:
            code = "developerImageDownloadFailed"
        case .archiveIntegrityFailed, .catalogRejected, .sourceRejected:
            code = "developerImageIntegrityFailed"
        }
        return .failedWithDetails(
            code: code,
            details: try developerSupportDetails(
                groupID: groupID,
                phase: phase,
                retryStage: "acquisition"
            )
        )
    }

    private static func developerSupportDetails(
        groupID: String,
        phase: String,
        retryStage: String? = nil
    ) throws -> RepositoryJSONObject {
        var members: [(String, RepositoryJSONValue)] = [
            ("phase", .string(phase)),
            ("preparationGroupID", .string(groupID)),
        ]
        if let retryStage {
            members.append(("retryStage", .string(retryStage)))
        }
        return try object(members)
    }

    private static func preparationOutcomeUnknownResult() throws
        -> RepositoryJSONObject
    {
        try object([
            ("commitState", .string("unknown")),
      (
        "error",
        .object(
          try object([
                ("code", .string("outcomeUnknown")),
            (
              "details",
              .object(
                try object([
                  ("reason", .string("terminalDeliveryUncertain"))
                ]))
            ),
          ]))
      ),
            ("outcome", .string("outcomeUnknown")),
        ])
    }

    private static func executeStreamClose(
        _ request: RuntimeRequestEnvelope,
        helperExecutor: ProductionCoreDeviceHelperExecutor,
        coordinateProjectionStore: ProductionRuntimeCoordinateProjectionStore
    ) throws -> ProductionRuntimeBackendDisposition {
        guard let sessionID = canonicalUUID(request.body["sessionID"]),
              let interactionID = canonicalUUID(request.body["interactionID"]),
              let reason = request.body["reason"]?.stringValue
        else {
            return .failed(code: "protocolViolation")
        }
        defer {
            coordinateProjectionStore.remove(
                sessionID: sessionID,
                interactionID: interactionID
            )
        }
        do {
            let closed = try helperExecutor.closeStream(
                sessionID: sessionID,
                interactionID: interactionID,
                reason: reason,
                cancel: request.operation == .streamCancel
            )
            var members: [(String, RepositoryJSONValue)] = [
                ("actionID", .string(closed.actionID.canonicalString)),
                ("cleanupDisposition", .string("acknowledged")),
                ("closingCause", .string(reason)),
                ("disposition", .string(closed.disposition)),
                ("interactionID", .string(interactionID.canonicalString)),
                ("sessionID", .string(sessionID.canonicalString)),
            ]
            if let sequence = closed.lastAcceptedSequence {
                members.append(("lastAcceptedSeq", .number(.uint64(sequence))))
            }
            return .succeeded(value: try object(members))
        } catch ProductionCoreDeviceHelperExecutorError.invalidRequest {
      return .succeeded(
        value: try object([
                ("cleanupDisposition", .string("notRequired")),
                ("disposition", .string("notFound")),
                ("interactionID", .string(interactionID.canonicalString)),
                ("sessionID", .string(sessionID.canonicalString)),
            ]))
        } catch {
            return .outcomeUnknown(code: "transportFailure")
        }
    }

    private static func isCoordinateCommand(_ commandID: String) -> Bool {
        commandID == "touch.tap"
            || commandID == "touch.drag"
            || commandID == "touch.swipe"
    }

    private static func logTouchPlanning(
        commandID: String,
        actionID: CanonicalUUID,
        outcome: String,
        routeID: String? = nil
    ) {
        guard isCoordinateCommand(commandID) else { return }
        let route = routeID ?? "none"
        touchRouteAuditLogger.notice(
            "stage=planning commandID=\(commandID, privacy: .public) actionID=\(actionID.canonicalString, privacy: .public) outcome=\(outcome, privacy: .public) routeID=\(route, privacy: .public)"
        )
    }

    private static func logTouchStage(
        _ stage: String,
        commandID: String,
        actionID: CanonicalUUID,
        connectionEpoch: UInt64? = nil,
        routeID: String? = nil,
        outcome: String? = nil,
        errorCode: String? = nil
    ) {
    guard
      ProcessInfo.processInfo.environment[
            "PULSEPHONE_RUNTIME_TOUCH_STAGE_TRACE"
      ] == "1", isCoordinateCommand(commandID)
    else {
            return
        }
        touchStageTraceLogger.notice(
            "stage=\(stage, privacy: .public) commandID=\(commandID, privacy: .public) actionID=\(actionID.canonicalString, privacy: .public) connectionEpoch=\(connectionEpoch.map(String.init) ?? "none", privacy: .public) routeID=\(routeID ?? "none", privacy: .public) outcome=\(outcome ?? "none", privacy: .public) errorCode=\(errorCode ?? "none", privacy: .public)"
        )
    }

    static func planCommandForExecution(
        commandID: String,
        rawArguments: [String: String],
        coordinator: ProductionRuntimeDeviceCoordinator,
        snapshot initialSnapshot: ProductionRuntimeDeviceSnapshot,
        refreshCoordinateGeometry: (
            ProductionRuntimeDeviceSnapshot
        ) throws -> ProductionRuntimeDeviceSnapshot
    ) throws -> (
        snapshot: ProductionRuntimeDeviceSnapshot,
        planning: PlanningResult
    ) {
        var snapshot = initialSnapshot
        var planning: PlanningResult
        do {
            planning = try coordinator.plan(
                commandID: commandID,
                rawArguments: rawArguments,
                snapshot: snapshot
            )
        } catch {
            throw ProductionRuntimeCommandPlanningError.invalidArgument
        }
        guard isCoordinateCommand(commandID) else {
            return (snapshot, planning)
        }
        let needsGeometryRefresh: Bool
        switch planning {
        case .planned:
            needsGeometryRefresh = true
        case .unknown(let reason):
            needsGeometryRefresh = reason == "displayGeometryUnavailable"
        case .awaitingPreparation, .notRuntimePlannable, .unavailable:
            needsGeometryRefresh = false
        }
        guard needsGeometryRefresh else {
            return (snapshot, planning)
        }
        do {
            snapshot = try refreshCoordinateGeometry(snapshot)
        } catch {
            touchRouteAuditLogger.error(
                "stage=geometryRefresh outcome=failed commandID=\(commandID, privacy: .public)"
            )
            throw ProductionRuntimeCommandPlanningError.geometryUnavailable
        }
        touchRouteAuditLogger.notice(
            "stage=geometryRefresh outcome=succeeded commandID=\(commandID, privacy: .public) geometryRevision=\(snapshot.geometryRevision, privacy: .public)"
        )
        do {
            planning = try coordinator.plan(
                commandID: commandID,
                rawArguments: rawArguments,
                snapshot: snapshot
            )
        } catch {
            throw ProductionRuntimeCommandPlanningError.invalidArgument
        }
        return (snapshot, planning)
    }

    static func admitPointerGeometry(
        requested: DisplayGeometryDTO,
        snapshot: ProductionRuntimeDeviceSnapshot,
        query: () throws -> DisplayGeometryDTO,
        update: (DisplayGeometryDTO) throws -> ProductionRuntimeDeviceSnapshot
    ) throws -> ProductionRuntimeDeviceSnapshot {
        if snapshot.geometry == requested {
            pointerLatencyLogger.notice(
                "stage=geometryAdmission source=cached connectionEpoch=\(requested.connectionEpoch, privacy: .public) geometryRevision=\(requested.geometryRevision, privacy: .public)"
            )
            return snapshot
        }
        let observed = try query()
        guard observed.connectionEpoch == requested.connectionEpoch,
              observed.logicalWidth == requested.logicalWidth,
              observed.logicalHeight == requested.logicalHeight,
              observed.orientation == requested.orientation
        else {
            throw ProductionRuntimeCoordinateProjectionError.staleGeometry
        }
        let updated = try update(requested)
        guard let accepted = updated.geometry,
              accepted.connectionEpoch == observed.connectionEpoch,
              accepted.logicalWidth == observed.logicalWidth,
              accepted.logicalHeight == observed.logicalHeight,
              accepted.orientation == observed.orientation
        else {
            throw ProductionRuntimeCoordinateProjectionError.staleGeometry
        }
        pointerLatencyLogger.notice(
            "stage=geometryAdmission source=refreshed connectionEpoch=\(accepted.connectionEpoch, privacy: .public) requestedRevision=\(requested.geometryRevision, privacy: .public) acceptedRevision=\(accepted.geometryRevision, privacy: .public)"
        )
        return updated
    }

    private static func synchronizeCoordinateGeometry(
        coordinator: ProductionRuntimeDeviceCoordinator,
        helperExecutor: ProductionCoreDeviceHelperExecutor,
        device: ProductionRuntimeDeviceObservation,
        snapshot: ProductionRuntimeDeviceSnapshot
    ) throws -> ProductionRuntimeDeviceSnapshot {
        do {
            let observed = try queryDisplayGeometry(
                helperExecutor: helperExecutor,
                device: device,
                connectionEpoch: snapshot.connectionEpoch,
                requestedRevision: max(1, snapshot.geometryRevision)
            )
            let updated = try coordinator.synchronizeGeometry(
                connectionEpoch: snapshot.connectionEpoch,
                logicalWidth: observed.logicalWidth,
                logicalHeight: observed.logicalHeight,
                orientation: observed.orientation
            )
            guard updated.geometry != nil else {
                throw ProductionRuntimeCoordinateProjectionError.staleGeometry
            }
            return updated
        } catch {
            touchRouteAuditLogger.error(
                "stage=geometryRefresh outcome=failed reason=\(String(reflecting: error), privacy: .public)"
            )
            throw error
        }
    }

    static func recoverInvalidatedRotateGeometry(
        coordinator: ProductionRuntimeDeviceCoordinator,
        connectionEpoch: UInt64,
        query: (UInt64) throws -> DisplayGeometryDTO
    ) throws -> ProductionRuntimeDeviceSnapshot {
        let current = try coordinator.commandAdmissionSnapshot()
        guard current.connectionEpoch == connectionEpoch,
              current.geometry == nil
        else {
            return current
        }
        let observed = try query(max(1, current.geometryRevision))
        guard observed.connectionEpoch == connectionEpoch else {
            throw ProductionRuntimeCoordinateProjectionError.staleGeometry
        }
        let updated = try coordinator.synchronizeGeometry(
            connectionEpoch: connectionEpoch,
            logicalWidth: observed.logicalWidth,
            logicalHeight: observed.logicalHeight,
            orientation: observed.orientation
        )
        guard let accepted = updated.geometry,
              accepted.logicalWidth == observed.logicalWidth,
              accepted.logicalHeight == observed.logicalHeight,
              accepted.orientation == observed.orientation
        else {
            throw ProductionRuntimeCoordinateProjectionError.staleGeometry
        }
        pointerLatencyLogger.notice(
            "stage=rotateGeometryRecovery outcome=succeeded connectionEpoch=\(connectionEpoch, privacy: .public) geometryRevision=\(accepted.geometryRevision, privacy: .public) orientation=\(accepted.orientation.rawValue, privacy: .public)"
        )
        return updated
    }

    private static func queryDisplayGeometry(
        helperExecutor: ProductionCoreDeviceHelperExecutor,
        device: ProductionRuntimeDeviceObservation,
        connectionEpoch: UInt64,
        requestedRevision: UInt64
    ) throws -> DisplayGeometryDTO {
        let result = try helperExecutor.executeOneShot(
            requestID: CanonicalUUID(value: UUID()),
            actionID: CanonicalUUID(value: UUID()),
            parentActionID: nil,
            routeID: "coredevice.displayGeometry.query",
            backendPayload: [
        "commandID": .string("runtime.displayGeometry.query")
            ],
            device: device,
            connectionEpoch: connectionEpoch
        )
        let outcome = result["outcome"]?.stringValue ?? "missing"
    let routeID =
      result["value"]?.objectValue?["resolvedRouteID"]?.stringValue
            ?? "missing"
    let errorCode =
      result["error"]?.objectValue?["code"]?.stringValue
            ?? "none"
        touchRouteAuditLogger.notice(
            "stage=geometryQuery outcome=\(outcome, privacy: .public) routeID=\(routeID, privacy: .public) errorCode=\(errorCode, privacy: .public)"
        )
        guard result["outcome"]?.stringValue == "succeeded",
              let value = result["value"]?.objectValue,
              value["resolvedRouteID"]?.stringValue
                == "coredevice.displayGeometry.query",
              let width = value["logicalWidth"]?.numberValue.flatMap({
                  try? $0.requireUInt64()
              }),
              let height = value["logicalHeight"]?.numberValue.flatMap({
                  try? $0.requireUInt64()
              }),
              let orientationText = value["orientation"]?.stringValue,
              let orientation = DisplayOrientationDTO(rawValue: orientationText)
        else {
            throw ProductionRuntimeCoordinateProjectionError.staleGeometry
        }
        return try DisplayGeometryDTO(
            connectionEpoch: connectionEpoch,
            geometryRevision: requestedRevision,
            logicalHeight: height,
            logicalWidth: width,
            orientation: orientation
        )
    }

    static func helperBackendPayload(
        commandID: String,
        arguments: [String: String],
        snapshot: ProductionRuntimeDeviceSnapshot
    ) throws -> [String: HelperWireJSONValue]? {
        if commandID.hasPrefix("button.") {
            return ["commandID": .string(commandID)]
        }
        if commandID == "touch.tap" {
            guard let point = arguments["point"],
                  let visual = pointComponents(point),
                  let geometry = snapshot.geometry
            else { return nil }
            let projected = try ProductionRuntimeCoordinateProjection(
                geometry: geometry
            ).project(x: visual.0, y: visual.1, edge: "none")
            return [
                "commandID": .string(commandID),
                "frames": .array([
                    touchFrame(kind: "begin", x: projected.x, y: projected.y, elapsed: 0),
                    touchFrame(kind: "end", x: projected.x, y: projected.y, elapsed: 35),
                ]),
            ]
        }
        if commandID == "touch.drag" || commandID == "touch.swipe" {
            guard let geometry = snapshot.geometry else { return nil }
            let gesture = try LinearGesturePlanner().plan(
                commandID: commandID,
                rawArguments: arguments
            )
            let projection = ProductionRuntimeCoordinateProjection(
                geometry: geometry
            )
            return [
                "commandID": .string(commandID),
        "frames": .array(
          try gesture.frames.map {
                    let point = try projection.project(
                        x: $0.point.x,
                        y: $0.point.y,
                        edge: "none"
                    )
                    return touchFrame(
                        kind: $0.kind.rawValue,
                        x: point.x,
                        y: point.y,
                        elapsed: $0.elapsedMilliseconds
                    )
                }),
            ]
        }
        if commandID == "device.rotate" {
            guard let direction = arguments["direction"],
                  ["left", "right"].contains(direction),
                  let geometry = snapshot.geometry
            else { return nil }
            return [
                "commandID": .string(commandID),
                "connectionEpoch": .unsignedInteger(snapshot.connectionEpoch),
                "direction": .string(direction),
                "geometryRevision": .unsignedInteger(geometry.geometryRevision),
                "logicalHeight": .unsignedInteger(geometry.logicalHeight),
                "logicalWidth": .unsignedInteger(geometry.logicalWidth),
                "orientation": .string(geometry.orientation.rawValue),
            ]
        }
        if commandID == "gui.softwareKeyboard.toggle" {
            return ["commandID": .string(commandID)]
        }
        if commandID == "text.type", let text = arguments["text"] {
            return [
                "commandID": .string(commandID),
                "text": .string(text),
            ]
        }
        if commandID == "text.key",
      Set(arguments.keys)
        == Set([
               "command", "control", "key", "option", "repeat", "shift",
           ]),
           let key = arguments["key"],
           let repeatText = arguments["repeat"],
           let repeatCount = UInt64(repeatText),
           (1...TextKeyboardContract.maximumRepeatCount).contains(repeatCount)
        {
            var modifiers = [HelperWireJSONValue]()
            for modifier in TextKeyboardContract.modifierArgumentKeys {
                guard let raw = arguments[modifier],
                      let enabled = TextKeyboardContract.canonicalBoolean(raw)
                else { return nil }
                if enabled { modifiers.append(.string(modifier)) }
            }
            guard TextKeyboardContract.keys.contains(key) else { return nil }
            return [
                "commandID": .string(commandID),
                "key": .string(key),
                "modifiers": .array(modifiers),
                "repeat": .unsignedInteger(repeatCount),
            ]
        }
        if commandID == "text.cursor",
           Set(arguments.keys) == Set(["count", "move", "select"]),
           let move = arguments["move"],
           let countText = arguments["count"],
           let count = UInt64(countText),
           (1...TextKeyboardContract.maximumRepeatCount).contains(count),
           let selectText = arguments["select"],
           let select = TextKeyboardContract.canonicalBoolean(selectText),
           TextKeyboardContract.moves.contains(move)
        {
            return [
                "commandID": .string(commandID),
                "count": .unsignedInteger(count),
                "move": .string(move),
                "select": .bool(select),
            ]
        }
        if ["text.clear", "text.inputSource.next"].contains(commandID),
           arguments.isEmpty
        {
            return ["commandID": .string(commandID)]
        }
        if commandID == "app.launch", let bundleID = arguments["bundleID"] {
            return [
                "bundleID": .string(bundleID),
                "commandID": .string(commandID),
                "operation": .string("launch"),
            ]
        }
        if commandID == "app.install", let ipaPath = arguments["ipaPath"] {
            return [
                "ipaPath": .string(ipaPath),
                "operation": .string("install"),
            ]
        }
        if commandID == "app.uninstall", let bundleID = arguments["bundleID"] {
            return [
                "bundleID": .string(bundleID),
                "operation": .string("uninstall"),
            ]
        }
        if commandID == "app.list", arguments.isEmpty {
            return ["operation": .string("browse")]
        }
        return nil
    }

    static func validIPAPathForExecution(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              !path.utf8.contains(0),
              !path.contains("//"),
              !path.split(
                separator: "/",
                omittingEmptySubsequences: false
              ).contains(".."),
              (path as NSString).standardizingPath == path,
              (path as NSString).pathExtension.lowercased() == "ipa"
        else { return false }
        var metadata = stat()
        return lstat(path, &metadata) == 0
            && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && metadata.st_size > 0
    }

    static func pointerObservationPlan(
        commandID: String,
        arguments: [String: String],
        connectionEpoch: UInt64
    ) throws -> ProductionRuntimePointerObservationPlan? {
        if commandID == "touch.tap" {
            guard let point = arguments["point"],
                  let components = pointComponents(point)
            else { return nil }
            return ProductionRuntimePointerObservationPlan(
                connectionEpoch: connectionEpoch,
                frames: [
                    ProductionRuntimeScheduledPointerProjection(
                        delayMilliseconds: 0,
                        projection: RuntimePointerProjection(
                            edge: "none",
                            frameKind: .begin,
                            x: components.0,
                            y: components.1
                        )
                    ),
                    ProductionRuntimeScheduledPointerProjection(
                        delayMilliseconds: 35,
                        projection: RuntimePointerProjection(
                            edge: "none",
                            frameKind: .end,
                            x: components.0,
                            y: components.1
                        )
                    ),
                ]
            )
        }
        guard commandID == "touch.drag" || commandID == "touch.swipe" else {
            return nil
        }
        let gesture = try LinearGesturePlanner().plan(
            commandID: commandID,
            rawArguments: arguments
        )
        return ProductionRuntimePointerObservationPlan(
            connectionEpoch: connectionEpoch,
            frames: gesture.frames.map { frame in
                ProductionRuntimeScheduledPointerProjection(
                    delayMilliseconds: frame.elapsedMilliseconds,
                    projection: RuntimePointerProjection(
                        edge: "none",
                        frameKind: RuntimePointerFrameKind(
                            rawValue: frame.kind.rawValue
                        ) ?? .cancel,
                        x: frame.point.x,
                        y: frame.point.y
                    )
                )
            }
        )
    }

    static func publicPlanningFailureCode(_ reason: String) -> String {
        switch reason {
        case "displayGeometryUnavailable", "invalidCandidateGroupMapping",
             "liveNotAttached", "noCompatibleCandidate":
            return "capabilityUnavailable"
        default:
            return reason
        }
    }

    private static func planningFailure(
        commandID: String,
        reason: String,
        snapshot: ProductionRuntimeDeviceSnapshot,
        coordinator: ProductionRuntimeDeviceCoordinator
    ) throws -> ProductionRuntimeBackendDisposition {
        let code = publicPlanningFailureCode(reason)
        if let details = try coordinator.targetFailureDetails(
            commandID: commandID,
            code: code,
            snapshot: snapshot
        ) {
            return .failedWithDetails(code: code, details: details)
        }
        return .failed(code: code)
    }

    static func projectCommandResult(
        commandID: String,
        arguments: [String: String],
        helperResult: RepositoryJSONObject,
        coordinator: ProductionRuntimeDeviceCoordinator,
        connectionEpoch: UInt64,
        previousGeometry: DisplayGeometryDTO? = nil
    ) throws -> RepositoryJSONObject {
        if commandID == "app.list" {
            return try projectAppListResult(helperResult)
        }
        if commandID == "text.type",
           helperResult["commitState"]?.stringValue == "committed",
           helperResult["outcome"]?.stringValue == "failed",
           let error = helperResult["error"]?.objectValue,
           error["code"]?.stringValue == "backendFailed",
           error["details"]?.objectValue?["stage"]?.stringValue
            == "pasteboardReadBack"
        {
            return try textTypeReadBackFailureResult()
        }
        guard helperResult["outcome"]?.stringValue == "succeeded",
              let helperValue = helperResult["value"]?.objectValue
        else {
            return helperResult
        }
        let helperValueKeys = Set(helperValue.members.map(\.key))
        if commandID.hasPrefix("button.") {
            logButtonHelperTiming(commandID: commandID, helperValue: helperValue)
        }
        let value: RepositoryJSONObject
        if commandID.hasPrefix("button.") || commandID.hasPrefix("touch.") {
            value = try object([
        ("disposition", .string("acknowledged"))
            ])
        } else if commandID == "device.rotate" {
            guard let direction = arguments["direction"],
                  ["left", "right"].contains(direction),
                  let previousGeometry,
                  let revision = helperValue["geometryRevision"]?.numberValue
                    .flatMap({ try? $0.requireUInt64() }),
                  let logicalHeight = helperValue["logicalHeight"]?.numberValue
                    .flatMap({ try? $0.requireUInt64() }),
                  let logicalWidth = helperValue["logicalWidth"]?.numberValue
                    .flatMap({ try? $0.requireUInt64() }),
                  let orientationText = helperValue["orientation"]?.stringValue,
                  let orientation = DisplayOrientationDTO(rawValue: orientationText),
                  let requestedDirection = helperValue["requestedDirection"]?
                    .stringValue,
                  requestedDirection == direction,
                  let responseOrientationText = helperValue[
                    "rotateResponseOrientation"
                  ]?.stringValue,
                  let responseOrientation = DisplayOrientationDTO(
                    rawValue: responseOrientationText
                  ),
                  let previousOrientationText = helperValue[
                    "previousDisplayOrientation"
                  ]?.stringValue,
                  let previousOrientation = DisplayOrientationDTO(
                    rawValue: previousOrientationText
                  ),
                  previousOrientation == previousGeometry.orientation,
                  let currentOrientationText = helperValue[
                    "currentDisplayOrientation"
                  ]?.stringValue,
                  let currentOrientation = DisplayOrientationDTO(
                    rawValue: currentOrientationText
                  ),
                  currentOrientation == orientation,
                  case .bool(let displayOrientationChanged)? = helperValue[
                    "displayOrientationChanged"
                  ],
                  displayOrientationChanged
                    == (currentOrientation != previousGeometry.orientation),
                  case .bool(let visibleOrientationConfirmed)? = helperValue[
                    "visibleOrientationConfirmed"
                  ],
                  visibleOrientationConfirmed
                    == (currentOrientation == responseOrientation
                        && displayOrientationChanged),
                  previousGeometry.connectionEpoch == connectionEpoch,
                  revision > previousGeometry.geometryRevision
            else {
                return try outcomeUnknownResult(code: "outcomeUnknown")
            }
            let updated = try coordinator.updateGeometry(
                connectionEpoch: connectionEpoch,
                geometryRevision: revision,
                logicalWidth: logicalWidth,
                logicalHeight: logicalHeight,
                orientation: orientation
            )
            guard updated.geometryRevision == revision,
                  updated.geometry?.orientation == orientation
            else {
                return try outcomeUnknownResult(code: "outcomeUnknown")
            }
            var members: [(String, RepositoryJSONValue)] = [
                ("currentDisplayOrientation", .string(currentOrientation.rawValue)),
                ("direction", .string(direction)),
                ("displayOrientationChanged", .bool(displayOrientationChanged)),
                ("geometryRevision", .number(.uint64(revision))),
                ("logicalHeight", .number(.uint64(logicalHeight))),
                ("logicalWidth", .number(.uint64(logicalWidth))),
                ("orientation", .string(orientation.rawValue)),
                ("outcomeKnown", .bool(visibleOrientationConfirmed)),
                ("previousDisplayOrientation", .string(previousOrientation.rawValue)),
                ("requestedDirection", .string(requestedDirection)),
                ("rotateResponseOrientation", .string(responseOrientation.rawValue)),
                ("visibleOrientationConfirmed", .bool(visibleOrientationConfirmed)),
            ]
            if let count = helperValue["geometrySampleCount"]?.numberValue
                .flatMap({ try? $0.requireUInt64() })
            {
                members.append(("geometrySampleCount", .number(.uint64(count))))
            }
            if let window = helperValue["geometrySampleWindowMilliseconds"]?
                .numberValue.flatMap({ try? $0.requireUInt64() })
            {
        members.append(
          (
                    "geometrySampleWindowMilliseconds",
                    .number(.uint64(window))
                ))
            }
            if let reason = helperValue["geometryConfirmationReason"]?.stringValue {
                members.append(("geometryConfirmationReason", .string(reason)))
            }
            value = try object(members)
        } else if commandID == "gui.softwareKeyboard.toggle" {
            guard helperValue["disposition"]?.stringValue == "acknowledged",
                  case .bool(true)? = helperValue["stateUnknown"]
            else {
                return try outcomeUnknownResult(code: "outcomeUnknown")
            }
            value = try object([
        ("stateUnknown", .bool(true))
            ])
        } else if commandID == "text.type", let text = arguments["text"] {
            guard helperValue["disposition"]?.stringValue == "pasteDispatched" else {
                return try outcomeUnknownResult(code: "outcomeUnknown")
            }
            value = try object([
                ("disposition", .string("pasteDispatched")),
                ("textByteCount", .number(.uint64(UInt64(text.utf8.count)))),
                ("textRedacted", .bool(true)),
            ])
        } else if commandID == "text.key",
      Set(arguments.keys)
        == Set([
                      "command", "control", "key", "option", "repeat", "shift",
                  ]),
                  let key = arguments["key"],
                  TextKeyboardContract.keys.contains(key),
                  let repeatText = arguments["repeat"],
                  let repeatCount = UInt64(repeatText),
                  (1...TextKeyboardContract.maximumRepeatCount).contains(repeatCount),
                  helperValueKeys == Set(["disposition", "resolvedRouteID"]),
                  helperValue["disposition"]?.stringValue == "keyDispatched",
                  helperValue["resolvedRouteID"]?.stringValue
                    == "coredevice.keyboardMacro"
        {
            var modifiers = [RepositoryJSONValue]()
            for modifier in TextKeyboardContract.modifierArgumentKeys {
                guard let raw = arguments[modifier],
                      let enabled = TextKeyboardContract.canonicalBoolean(raw)
                else { return try outcomeUnknownResult(code: "outcomeUnknown") }
                if enabled { modifiers.append(.string(modifier)) }
            }
            value = try object([
                ("disposition", .string("keyDispatched")),
                ("key", .string(key)),
                ("modifiers", .array(modifiers)),
                ("repeatCount", .number(.uint64(repeatCount))),
            ])
        } else if commandID == "text.cursor",
                  Set(arguments.keys) == Set(["count", "move", "select"]),
                  let move = arguments["move"],
                  TextKeyboardContract.moves.contains(move),
                  let countText = arguments["count"],
                  let count = UInt64(countText),
                  (1...TextKeyboardContract.maximumRepeatCount).contains(count),
                  let selectText = arguments["select"],
                  let select = TextKeyboardContract.canonicalBoolean(selectText),
                  helperValueKeys == Set(["disposition", "resolvedRouteID"]),
                  helperValue["disposition"]?.stringValue
                    == "cursorMoveDispatched",
                  helperValue["resolvedRouteID"]?.stringValue
                    == "coredevice.keyboardMacro"
        {
            value = try object([
                ("count", .number(.uint64(count))),
                ("disposition", .string("cursorMoveDispatched")),
                ("move", .string(move)),
                ("select", .bool(select)),
            ])
        } else if commandID == "text.clear",
                  arguments.isEmpty,
                  helperValueKeys == Set(["disposition", "resolvedRouteID"]),
                  helperValue["disposition"]?.stringValue == "clearDispatched",
                  helperValue["resolvedRouteID"]?.stringValue
                    == "coredevice.keyboardMacro"
        {
            value = try object([
        ("disposition", .string("clearDispatched"))
            ])
        } else if commandID == "text.inputSource.next",
                  arguments.isEmpty,
                  helperValueKeys == Set(["disposition", "resolvedRouteID"]),
                  helperValue["disposition"]?.stringValue
                    == "inputSourceCycleDispatched",
                  helperValue["resolvedRouteID"]?.stringValue
                    == "coredevice.keyboardMacro"
        {
            value = try object([
        ("disposition", .string("inputSourceCycleDispatched"))
            ])
        } else if [
            "text.clear", "text.cursor", "text.inputSource.next", "text.key",
        ].contains(commandID) {
            return try outcomeUnknownResult(code: "outcomeUnknown")
        } else if commandID == "app.launch", let bundleID = arguments["bundleID"] {
            value = try object([
                ("bundleID", .string(bundleID)),
                ("disposition", .string("launchRequested")),
            ])
        } else {
            return helperResult
        }
        return try object([
            ("commitState", helperResult["commitState"] ?? .string("committed")),
            ("outcome", .string("succeeded")),
            ("value", .object(value)),
        ])
    }

    private static func textTypeReadBackFailureResult() throws
        -> RepositoryJSONObject
    {
        try object([
            ("commitState", .string("committed")),
      (
        "error",
        .object(
          try object([
                ("code", .string("backendFailed")),
            (
              "details",
              .object(
                try object([
                    ("commitState", .string("committed")),
                    ("stage", .string("pasteboardReadBack")),
                ]))
            ),
          ]))
      ),
            ("outcome", .string("failed")),
        ])
    }

    static func projectAppListResult(
        _ helperResult: RepositoryJSONObject
    ) throws -> RepositoryJSONObject {
        let invalid = try appListFailureResult(
            code: "backendFailed",
            stage: "resultNormalize"
        )
        guard helperResult["commitState"]?.stringValue == "notCommitted",
              let outcome = helperResult["outcome"]?.stringValue
        else { return invalid }

        if outcome == "failed" {
            guard let error = helperResult["error"]?.objectValue,
                  let code = error["code"]?.stringValue,
                  [
                      "backendFailed", "deviceDisconnected", "deviceLocked",
                      "deviceNotTrusted", "executionTimeout", "transportFailure",
                  ].contains(code),
                  let details = error["details"]?.objectValue,
                  details["commitState"]?.stringValue == "notCommitted",
                  let stage = details["stage"]?.stringValue,
                  [
                      "browseDeadline", "browseReceive", "browseSend",
                      "browseValidate", "directDispatcher", "helperStartup",
                      "resultNormalize", "serviceOpen",
                  ].contains(stage)
            else { return invalid }
            return try appListFailureResult(code: code, stage: stage)
        }

        guard outcome == "succeeded",
              let helperValue = helperResult["value"]?.objectValue,
              Set(helperValue.members.map(\.key)) == ["apps", "truncated"],
              case .bool(false)? = helperValue["truncated"],
              let helperApps = helperValue["apps"]?.arrayValue
        else { return invalid }

        var normalizedApps = [RepositoryJSONValue]()
        var previousBundleID: String?
        for helperAppValue in helperApps {
            guard let helperApp = helperAppValue.objectValue,
                  let bundleID = helperApp["bundleID"]?.stringValue,
                  validAppListBundleID(bundleID),
                  previousBundleID.map({
                      $0.utf8.lexicographicallyPrecedes(bundleID.utf8)
                  }) ?? true,
                  let applicationType = helperApp["applicationType"]?.stringValue,
                  ["system", "unknown", "user"].contains(applicationType)
            else { return invalid }
            let keys = Set(helperApp.members.map(\.key))
      guard
        keys.isSubset(of: [
                "applicationType", "bundleID", "displayName", "version",
            ]),
            keys.contains("applicationType"),
            keys.contains("bundleID")
            else { return invalid }

            var members: [(String, RepositoryJSONValue)] = [
                ("applicationType", .string(applicationType)),
                ("bundleID", .string(bundleID)),
            ]
            for key in ["displayName", "version"] {
                if helperApp[key] != nil {
                    guard let value = helperApp[key]?.stringValue, !value.isEmpty
                    else { return invalid }
                    members.append((key, .string(value)))
                }
            }
            normalizedApps.append(.object(try object(members)))
            previousBundleID = bundleID
        }

        let value = try object([
            ("apps", .array(normalizedApps)),
            ("truncated", .bool(false)),
        ])
        guard RepositoryCanonicalJSON.encodeDocument(value).count <= 256 * 1_024
        else { return invalid }
        return try object([
            ("commitState", .string("notCommitted")),
            ("outcome", .string("succeeded")),
            ("value", .object(value)),
        ])
    }

    private static func validAppListBundleID(_ value: String) -> Bool {
        1...255 ~= value.utf8.count
    }

    private static func logButtonHelperTiming(
        commandID: String,
        helperValue: RepositoryJSONObject
    ) {
        guard let timing = helperValue["_pulsephoneInternalTiming"]?.objectValue,
              let serviceOpen = timing["serviceOpenMicroseconds"]?.numberValue
                .flatMap({ try? $0.requireUInt64() }),
              let sequence = timing["buttonSequenceMicroseconds"]?.numberValue
                .flatMap({ try? $0.requireUInt64() }),
              let serviceClose = timing["serviceCloseMicroseconds"]?.numberValue
                .flatMap({ try? $0.requireUInt64() }),
              let total = timing["totalMicroseconds"]?.numberValue
                .flatMap({ try? $0.requireUInt64() })
        else { return }
        toolbarLatencyLogger.notice(
            "stage=helper commandID=\(commandID, privacy: .public) serviceOpenUs=\(serviceOpen, privacy: .public) sequenceUs=\(sequence, privacy: .public) serviceCloseUs=\(serviceClose, privacy: .public) totalUs=\(total, privacy: .public)"
        )
    }

    private static func elapsedMicroseconds(
        _ start: UInt64,
        _ end: UInt64
    ) -> UInt64 {
        guard end >= start else { return 0 }
        return (end - start) / 1_000
    }

    private static func outcomeUnknownResult(
        code: String
    ) throws -> RepositoryJSONObject {
        try object([
            ("commitState", .string("committed")),
      (
        "error",
        .object(
          try object([
            ("code", .string(code))
          ]))
      ),
            ("outcome", .string("outcomeUnknown")),
        ])
    }

    private static func touchFrame(
        kind: String,
        x: UInt16,
        y: UInt16,
        elapsed: UInt64
    ) -> HelperWireJSONValue {
        .object([
            "elapsedMs": .unsignedInteger(elapsed),
            "kind": .string(kind),
            "x": .unsignedInteger(UInt64(x)),
            "y": .unsignedInteger(UInt64(y)),
        ])
    }

    private static func pointComponents(_ value: String) -> (String, String)? {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    private static func stringArguments(
        _ object: RepositoryJSONObject
    ) -> [String: String]? {
        var result = [String: String]()
        for member in object.members {
            guard let value = member.value.stringValue else { return nil }
            result[member.key] = value
        }
        return result
    }

    private static func canonicalUUID(
        _ value: RepositoryJSONValue?
    ) -> CanonicalUUID? {
        guard let raw = value?.stringValue else { return nil }
        return try? CanonicalUUID(raw)
    }

    private static func optionalCanonicalUUID(
        _ value: RepositoryJSONValue?
    ) -> CanonicalUUID? {
        canonicalUUID(value)
    }

    private static func helperObject(
        _ values: [String: String]
    ) throws -> [String: HelperWireJSONValue] {
        Dictionary(uniqueKeysWithValues: values.map { ($0.key, .string($0.value)) })
    }

    private static func appendGeometry(
        _ geometry: DisplayGeometryDTO,
        to members: inout [(String, RepositoryJSONValue)]
    ) {
        members.append(contentsOf: [
            ("geometryRevision", .number(.uint64(geometry.geometryRevision))),
            ("logicalHeight", .number(.uint64(geometry.logicalHeight))),
            ("logicalWidth", .number(.uint64(geometry.logicalWidth))),
            ("orientation", .string(geometry.orientation.rawValue)),
        ])
    }

    private static func object(
        _ members: [(String, RepositoryJSONValue)]
    ) throws -> RepositoryJSONObject {
    try RepositoryJSONObject(
      members: members.map {
            RepositoryJSONMember(key: $0.0, value: $0.1)
        })
    }
}

enum ProductionRuntimePeerLiveValidationError: Error, Equatable, Sendable {
    case activationConflict
    case notAttached
    case ownerConflict
    case staleConnectionEpoch
    case targetMismatch
}

enum ProductionRuntimeCaptureActivationValidation: Equatable, Sendable {
    case duplicate
    case new
}

struct ProductionRuntimePeerLiveState: Equatable, Sendable {
    private(set) var canonicalUDID: CanonicalUDID?
    private(set) var captureActivationID: CanonicalUUID?
    private(set) var connectionAvailable = false
    private(set) var connectionEpoch: UInt64?
    private(set) var liveOwnerID: CanonicalUUID?
    private(set) var subscriptionID: CanonicalUUID?

    var isAttached: Bool { liveOwnerID != nil }

    mutating func attach(
        canonicalUDID: CanonicalUDID,
        connectionEpoch: UInt64,
        liveOwnerID: CanonicalUUID,
        subscriptionID: CanonicalUUID
    ) -> Bool {
        guard !isAttached else { return false }
        self.canonicalUDID = canonicalUDID
        self.connectionEpoch = connectionEpoch
        self.liveOwnerID = liveOwnerID
        self.subscriptionID = subscriptionID
        connectionAvailable = true
        captureActivationID = nil
        return true
    }

    func validateCaptureReady(
        canonicalUDID: CanonicalUDID,
        connectionEpoch: UInt64,
        liveOwnerID: CanonicalUUID,
        subscriptionID: CanonicalUUID,
        captureActivationID: CanonicalUUID
    ) throws -> ProductionRuntimeCaptureActivationValidation {
        guard isAttached else {
            throw ProductionRuntimePeerLiveValidationError.notAttached
        }
        guard self.canonicalUDID == canonicalUDID else {
            throw ProductionRuntimePeerLiveValidationError.targetMismatch
        }
        guard connectionAvailable,
              self.connectionEpoch == connectionEpoch
        else {
            throw ProductionRuntimePeerLiveValidationError.staleConnectionEpoch
        }
        guard self.liveOwnerID == liveOwnerID,
              self.subscriptionID == subscriptionID
        else {
            throw ProductionRuntimePeerLiveValidationError.ownerConflict
        }
        guard let current = self.captureActivationID else { return .new }
        guard current == captureActivationID else {
            throw ProductionRuntimePeerLiveValidationError.activationConflict
        }
        return .duplicate
    }

    mutating func commitCaptureActivation(_ captureActivationID: CanonicalUUID) {
        self.captureActivationID = captureActivationID
    }

    mutating func invalidateForDisconnect(connectionEpoch: UInt64) -> Bool {
        guard isAttached,
              connectionAvailable,
              self.connectionEpoch == connectionEpoch
        else {
            return false
        }
        connectionAvailable = false
        captureActivationID = nil
        return true
    }

    mutating func replaceConnectionEpoch(_ connectionEpoch: UInt64) -> Bool {
        guard isAttached,
              !connectionAvailable,
              let current = self.connectionEpoch,
              connectionEpoch > current
        else {
            return false
        }
        self.connectionEpoch = connectionEpoch
        connectionAvailable = true
        captureActivationID = nil
        return true
    }

    mutating func detach(
        canonicalUDID: CanonicalUDID,
        liveOwnerID: CanonicalUUID,
        subscriptionID: CanonicalUUID
    ) throws {
        guard isAttached else {
            throw ProductionRuntimePeerLiveValidationError.notAttached
        }
        guard self.canonicalUDID == canonicalUDID else {
            throw ProductionRuntimePeerLiveValidationError.targetMismatch
        }
        guard self.liveOwnerID == liveOwnerID,
              self.subscriptionID == subscriptionID
        else {
            throw ProductionRuntimePeerLiveValidationError.ownerConflict
        }
        self = ProductionRuntimePeerLiveState()
    }
}

final class ProductionRuntimePeerContext: @unchecked Sendable {
    let clientInstanceID: CanonicalUUID
    let connection: RuntimeConnection
    let connectionID: CanonicalUUID
    let descriptor: Int32
    let normal: Bool

    private let liveLock = NSLock()
    private var liveState = ProductionRuntimePeerLiveState()
    private let outboundLock = NSLock()

    init(
        clientInstanceID: CanonicalUUID,
        connection: RuntimeConnection,
        connectionID: CanonicalUUID,
        descriptor: Int32,
        normal: Bool
    ) {
        self.clientInstanceID = clientInstanceID
        self.connection = connection
        self.connectionID = connectionID
        self.descriptor = descriptor
        self.normal = normal
    }

    func withLiveState<T>(
        _ body: (inout ProductionRuntimePeerLiveState) throws -> T
    ) rethrows -> T {
        liveLock.lock()
        defer { liveLock.unlock() }
        return try body(&liveState)
    }

    var liveSnapshot: ProductionRuntimePeerLiveState {
        liveLock.withLock { liveState }
    }

    func withOutbound<T>(
        _ body: (RuntimeConnection, Int32) throws -> T
    ) rethrows -> T {
        outboundLock.lock()
        defer { outboundLock.unlock() }
        return try body(connection, descriptor)
    }
}

public final class ProductionRuntimeServer: @unchecked Sendable {
    public static let maximumConcurrentConnections = 64
    public static let connectionTimeoutSeconds = 60
    public static let runtimeBuildID = "pulsephone.runtime.v1"
    public static let runtimeCompatibilityID = "runtime.compat.v4"
    public static let executionCatalogHash =
    "494f0e80a087941a7651163bbdedd3e567559de57f1cdb88da7020ce296d76cf"

    private let canonicalUDID: CanonicalUDID
    private let connectionTimeoutSeconds: Int
    private let operationBackend: ProductionRuntimeOperationBackend
    private let observationBroker: ProductionRuntimeObservationBroker
    private let compatibility: RuntimeCompatibilityIdentity
    private let runtimeEpoch: UInt64
    private let runtimeRegistry = RuntimeOutstandingRegistry()
    private let stateLock = NSLock()
    private static let reconnectLogger = Logger(
        subsystem: "com.pulsephone.PulsePhoneRuntime",
        category: "usb-reconnect"
    )
    private static let reconnectProbeInitialDelay: DispatchTimeInterval =
        .milliseconds(250)
    private static let reconnectProbeInterval: DispatchTimeInterval =
        .seconds(1)
    private static let resynchronizePresenceDelay: DispatchTimeInterval =
        .seconds(2)
    private static let reattachSettlingNanoseconds: UInt64 = 2_000_000_000
    private enum ReconnectProbeMode {
        case attachOnly
        case detachedEventConfirmation
        case resynchronizePresenceCheck
        case resynchronizeDetachConfirmation
    }
    private enum ConnectionInventoryResult {
        case connected
        case disconnected
        case indeterminate
    }
    private let reconnectProbeQueue = DispatchQueue(
        label: "com.pulsephone.runtime.usb-reconnect-probe",
        qos: .utility
    )
    private var listener: RuntimeListener?
    private var activePeers = Set<Int32>()
    private var peerContexts = [Int32: ProductionRuntimePeerContext]()
    private var reconnectProbeGeneration: UInt64 = 0
    // Accessed only on reconnectProbeQueue.
    private var reattachSettlingConnectionEpoch: UInt64?
    private var reattachSettlingDeadlineNanoseconds: UInt64 = 0
    private var stopping = false
    private var usbMonitor: (any ProductionUSBDeviceMonitoring)?

    public init(
        canonicalUDID: CanonicalUDID,
        compatibility: RuntimeCompatibilityIdentity,
        runtimeEpoch: UInt64,
        operationBackend: ProductionRuntimeOperationBackend,
        connectionTimeoutSeconds: Int = ProductionRuntimeServer
            .connectionTimeoutSeconds
    ) {
        let observationBroker = try! ProductionRuntimeObservationBroker()
        self.canonicalUDID = canonicalUDID
        self.connectionTimeoutSeconds = connectionTimeoutSeconds
        self.compatibility = compatibility
        self.runtimeEpoch = runtimeEpoch
        self.operationBackend = operationBackend
        self.observationBroker = observationBroker
        self.usbMonitor = nil
        self.operationBackend.installPointerObservationHandler {
            [weak observationBroker] clientInstanceID, interactionID, plan in
            observationBroker?.publishAccepted(
                clientInstanceID: clientInstanceID,
                interactionID: interactionID,
                plan: plan
            )
        }
    }

    public static func bundled(
        canonicalUDID: CanonicalUDID
    ) throws -> ProductionRuntimeServer {
        let runtimeEpoch = UInt64.random(in: 1...UInt64.max)
        let backend = try ProductionRuntimeOperationBackend.bundled(
            canonicalUDID: canonicalUDID,
            runtimeEpoch: runtimeEpoch
        )
        let server = ProductionRuntimeServer(
            canonicalUDID: canonicalUDID,
            compatibility: try RuntimeCompatibilityIdentity(
                runtimeCompatibilityID: runtimeCompatibilityID,
        executionCatalogHash: executionCatalogHash
            ),
            runtimeEpoch: runtimeEpoch,
            operationBackend: backend
        )
        server.usbMonitor = ProductionUSBDeviceMonitor(
            canonicalUDID: canonicalUDID
        )
        return server
    }

    public static func testing(
        canonicalUDID: CanonicalUDID,
        runtimeEpoch: UInt64 = 1,
        operationBackend: ProductionRuntimeOperationBackend? = nil,
        connectionTimeoutSeconds: Int = ProductionRuntimeServer
            .connectionTimeoutSeconds
    ) throws -> ProductionRuntimeServer {
        ProductionRuntimeServer(
            canonicalUDID: canonicalUDID,
            compatibility: try RuntimeCompatibilityIdentity(
                runtimeCompatibilityID: runtimeCompatibilityID,
        executionCatalogHash: executionCatalogHash
            ),
            runtimeEpoch: runtimeEpoch,
            operationBackend: try operationBackend
                ?? .bundled(
                    canonicalUDID: canonicalUDID,
                    runtimeEpoch: runtimeEpoch
                ),
            connectionTimeoutSeconds: connectionTimeoutSeconds
        )
    }

  /// Fixture-only overload. Dynamic catalog snapshots are per preparation
  /// job and must not re-enter the Runtime compatibility handshake.
  public static func testing(
    canonicalUDID: CanonicalUDID,
    developerImageCatalogRevision _: String,
    developerImageCatalogHash _: String,
    runtimeEpoch: UInt64 = 1,
    operationBackend: ProductionRuntimeOperationBackend? = nil,
    connectionTimeoutSeconds: Int = ProductionRuntimeServer
      .connectionTimeoutSeconds
  ) throws -> ProductionRuntimeServer {
    try testing(
      canonicalUDID: canonicalUDID,
      runtimeEpoch: runtimeEpoch,
      operationBackend: operationBackend,
      connectionTimeoutSeconds: connectionTimeoutSeconds
    )
  }

    public func run(readiness: ReadinessFD? = nil) throws {
        let runtimeLock = try RuntimeLock.acquireForRuntimeStartup(
            for: canonicalUDID
        )
        let helperManifest = try makeHelperManifestStore()
        try helperManifest.publish([])
        operationBackend.bind(
            runtimeLock: runtimeLock,
            manifestStore: helperManifest
        )
        usbMonitor?.start { [weak self] event in
            self?.handleUSBMonitorEvent(event)
        }
        defer {
            usbMonitor?.stop()
            operationBackend.shutdown()
            removeHelperManifestIfOwned(helperManifest)
        }
        let bound = try RuntimeListener.bind(
            for: canonicalUDID,
            whileHolding: runtimeLock,
            onWatchFailure: { [weak self] _ in self?.requestStop() }
        )
        stateLock.lock()
        listener = bound
        stateLock.unlock()
        defer {
            try? bound.shutdownExpected()
            removeBoundSocketIfPresent(
                path: bound.socketPath,
                device: bound.socketIdentity.device,
                inode: bound.socketIdentity.inode
            )
            stateLock.lock()
            listener = nil
            stateLock.unlock()
        }
        try readiness?.publishReady(
            runtimeEpoch: CanonicalUUID(value: UUID()),
            pid: getpid()
        )
        try bound.withUnsafeListeningSocket { descriptor in
            while !isStopping {
                let peer = Darwin.accept(descriptor, nil, nil)
                if peer >= 0 {
                    do {
                        try configure(peer: peer)
                        guard reserve(peer: peer) else {
                            _ = Darwin.close(peer)
                            continue
                        }
                    } catch {
                        _ = Darwin.close(peer)
                        continue
                    }
                    DispatchQueue.global(qos: .userInitiated).async {
                        defer {
                            self.release(peer: peer)
                            _ = Darwin.close(peer)
                        }
                        try? self.serve(peer: peer)
                    }
                    continue
                }
                if errno == EINTR { continue }
                if isStopping { break }
                throw ProductionRuntimeServerError.acceptFailed(errno: errno)
            }
        }
    }

    public func requestStop() {
        stateLock.lock()
        guard !stopping else {
            stateLock.unlock()
            return
        }
        stopping = true
        advanceReconnectProbeGenerationLocked()
        let active = listener
        let peers = Array(activePeers)
        stateLock.unlock()
        for peer in peers {
            _ = Darwin.shutdown(peer, SHUT_RDWR)
        }
        try? active?.shutdownExpected()
    }

    private var isStopping: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopping
    }

    private func reserve(peer: Int32) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stopping,
              activePeers.count < Self.maximumConcurrentConnections
        else {
            return false
        }
        activePeers.insert(peer)
        return true
    }

    private func release(peer: Int32) {
        stateLock.lock()
        activePeers.remove(peer)
        peerContexts.removeValue(forKey: peer)
        stateLock.unlock()
    }

    private func register(_ context: ProductionRuntimePeerContext) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stopping, activePeers.contains(context.descriptor) else {
            return false
        }
        peerContexts[context.descriptor] = context
        return true
    }

    func installUSBMonitorForTesting(
        _ monitor: (any ProductionUSBDeviceMonitoring)?
    ) {
        stateLock.withLock { usbMonitor = monitor }
    }

    var observationSubscriberCountForTesting: Int {
        observationBroker.subscriberCount
    }

    private var currentPeerContexts: [ProductionRuntimePeerContext] {
        stateLock.withLock { Array(peerContexts.values) }
    }

    private func handleUSBMonitorEvent(
        _ event: ProductionUSBDeviceMonitorEvent
    ) {
        reconnectProbeQueue.async { [weak self] in
            self?.processUSBMonitorEvent(event)
        }
    }

    private func processUSBMonitorEvent(
        _ event: ProductionUSBDeviceMonitorEvent
    ) {
        guard stateLock.withLock({ !stopping }) else { return }
        switch event {
        case .detached:
            if let connectionEpoch = settlingConnectionEpoch() {
                Self.reconnectLogger.notice(
                    "stage=detachDeferred connectionEpoch=\(connectionEpoch, privacy: .public) reason=reattachSettling"
                )
                schedulePersistentReconnectProbe(
                    after: Self.resynchronizePresenceDelay,
                    mode: .resynchronizePresenceCheck
                )
                return
            }
            switch reconcileConnectionInventory(allowDetachment: true) {
            case .connected:
                cancelReconnectProbe()
            case .disconnected:
                schedulePersistentReconnectProbe(
                    after: Self.reconnectProbeInitialDelay,
                    mode: .attachOnly
                )
            case .indeterminate:
                schedulePersistentReconnectProbe(
                    after: Self.reconnectProbeInitialDelay,
                    mode: .detachedEventConfirmation
                )
            }
        case .attached:
            handleAttachOnlyResult(
                reconcileConnectionInventory(allowDetachment: false)
            )
        case .resynchronize:
            let result = reconcileConnectionInventory(allowDetachment: false)
            if operationBackend.hasConnectedDevice {
                schedulePersistentReconnectProbe(
                    after: Self.resynchronizePresenceDelay,
                    mode: .resynchronizePresenceCheck
                )
            } else {
                handleAttachOnlyResult(result)
            }
        }
    }

    @discardableResult
    private func reconcileConnectionInventory(
        allowDetachment: Bool
    ) -> ConnectionInventoryResult {
        do {
      guard
        let transition =
          try operationBackend
                .refreshConnectionTransition(allowDetachment: allowDetachment)
            else { return .connected }
            switch transition.kind {
            case .unchanged:
                break
            case .detached(let previousConnectionEpoch):
                try handleConfirmedDetach(
                    previousConnectionEpoch: previousConnectionEpoch,
                    snapshot: transition.snapshot
                )
            case .attached:
                try handleConfirmedAttach(snapshot: transition.snapshot)
            }
            return transition.snapshot.device == nil
                ? .disconnected
                : .connected
        } catch {
            Self.reconnectLogger.error(
                "stage=inventoryRefresh outcome=failed allowDetachment=\(allowDetachment, privacy: .public)"
            )
            return .indeterminate
        }
    }

    private func handleAttachOnlyResult(
        _ result: ConnectionInventoryResult
    ) {
        switch result {
        case .connected:
            if settlingConnectionEpoch() != nil {
                schedulePersistentReconnectProbe(
                    after: Self.resynchronizePresenceDelay,
                    mode: .resynchronizePresenceCheck
                )
            } else {
                cancelReconnectProbe()
            }
        case .disconnected, .indeterminate:
            schedulePersistentReconnectProbe(
                after: Self.reconnectProbeInitialDelay,
                mode: .attachOnly
            )
        }
    }

    private func schedulePersistentReconnectProbe(
        after delay: DispatchTimeInterval,
        mode: ReconnectProbeMode
    ) {
        guard operationBackend.hasPersistentLiveDemand else {
            cancelReconnectProbe()
            return
        }
        scheduleReconnectProbe(after: delay, mode: mode)
    }

    private func scheduleReconnectProbe(
        after delay: DispatchTimeInterval,
        mode: ReconnectProbeMode
    ) {
        let generation = stateLock.withLock { () -> UInt64? in
            guard !stopping else { return nil }
            advanceReconnectProbeGenerationLocked()
            return reconnectProbeGeneration
        }
        guard let generation else { return }
        reconnectProbeQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.runReconnectProbe(generation: generation, mode: mode)
        }
    }

    private func runReconnectProbe(
        generation: UInt64,
        mode: ReconnectProbeMode
    ) {
        let isCurrent = stateLock.withLock {
            !stopping && reconnectProbeGeneration == generation
        }
        guard isCurrent else { return }
        switch mode {
        case .attachOnly:
            switch reconcileConnectionInventory(allowDetachment: false) {
            case .connected:
                cancelReconnectProbe()
            case .disconnected, .indeterminate:
                schedulePersistentReconnectProbe(
                    after: Self.reconnectProbeInterval,
                    mode: .attachOnly
                )
            }
        case .detachedEventConfirmation:
            switch reconcileConnectionInventory(allowDetachment: true) {
            case .connected:
                cancelReconnectProbe()
            case .disconnected:
                schedulePersistentReconnectProbe(
                    after: Self.reconnectProbeInterval,
                    mode: .attachOnly
                )
            case .indeterminate:
                schedulePersistentReconnectProbe(
                    after: Self.reconnectProbeInterval,
                    mode: .detachedEventConfirmation
                )
            }
        case .resynchronizePresenceCheck:
            runResynchronizePresenceCheck(confirmingDetach: false)
        case .resynchronizeDetachConfirmation:
            runResynchronizePresenceCheck(confirmingDetach: true)
        }
    }

    private func runResynchronizePresenceCheck(
        confirmingDetach: Bool
    ) {
        do {
            guard let present = try operationBackend.probeConnectionPresence()
            else {
                cancelReconnectProbe()
                return
            }
            if present {
                handleAttachOnlyResult(
                    reconcileConnectionInventory(allowDetachment: false)
                )
            } else if confirmingDetach {
                handleConfirmedDisconnectionProbe()
            } else {
                schedulePersistentReconnectProbe(
                    after: Self.reconnectProbeInterval,
                    mode: .resynchronizeDetachConfirmation
                )
            }
        } catch {
            schedulePersistentReconnectProbe(
                after: Self.reconnectProbeInterval,
                mode: confirmingDetach
                    ? .resynchronizeDetachConfirmation
                    : .resynchronizePresenceCheck
            )
        }
    }

    private func handleConfirmedDisconnectionProbe() {
        do {
            guard let transition = try operationBackend.confirmDisconnected()
            else {
                cancelReconnectProbe()
                return
            }
            switch transition.kind {
            case .unchanged:
                break
            case .detached(let previousConnectionEpoch):
                try handleConfirmedDetach(
                    previousConnectionEpoch: previousConnectionEpoch,
                    snapshot: transition.snapshot
                )
            case .attached:
                try handleConfirmedAttach(snapshot: transition.snapshot)
            }
            if transition.snapshot.device == nil {
                schedulePersistentReconnectProbe(
                    after: Self.reconnectProbeInterval,
                    mode: .attachOnly
                )
            } else {
                cancelReconnectProbe()
            }
        } catch {
            schedulePersistentReconnectProbe(
                after: Self.reconnectProbeInterval,
                mode: .resynchronizeDetachConfirmation
            )
        }
    }

    private func cancelReconnectProbe() {
        stateLock.withLock {
            advanceReconnectProbeGenerationLocked()
        }
    }

    private func advanceReconnectProbeGenerationLocked() {
    reconnectProbeGeneration =
      reconnectProbeGeneration == UInt64.max
            ? 1
            : reconnectProbeGeneration + 1
    }

    private func settlingConnectionEpoch() -> UInt64? {
        guard let connectionEpoch = reattachSettlingConnectionEpoch else {
            return nil
        }
    guard
      DispatchTime.now().uptimeNanoseconds
            < reattachSettlingDeadlineNanoseconds
        else {
            reattachSettlingConnectionEpoch = nil
            reattachSettlingDeadlineNanoseconds = 0
            return nil
        }
        return connectionEpoch
    }

    private func beginReattachSettling(connectionEpoch: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        let deadline = now.addingReportingOverflow(
            Self.reattachSettlingNanoseconds
        )
        reattachSettlingConnectionEpoch = connectionEpoch
    reattachSettlingDeadlineNanoseconds =
      deadline.overflow
            ? UInt64.max
            : deadline.partialValue
    }

    private func endReattachSettling() {
        reattachSettlingConnectionEpoch = nil
        reattachSettlingDeadlineNanoseconds = 0
    }

    private func scheduleReconnectProbeIfNeeded(
        snapshot: ProductionRuntimeDeviceSnapshot?
    ) {
        if snapshot?.device == nil, operationBackend.hasPersistentLiveDemand {
            scheduleReconnectProbe(
                after: Self.reconnectProbeInitialDelay,
                mode: .attachOnly
            )
        } else {
            cancelReconnectProbe()
        }
    }

    private func handleConfirmedDetach(
        previousConnectionEpoch: UInt64,
        snapshot: ProductionRuntimeDeviceSnapshot
    ) throws {
        endReattachSettling()
        Self.reconnectLogger.notice(
            "stage=detached connectionEpoch=\(previousConnectionEpoch, privacy: .public) stateRevision=\(snapshot.stateRevision, privacy: .public)"
        )
        observationBroker.invalidateProjections(
            connectionEpoch: previousConnectionEpoch
        )
        for context in currentPeerContexts where context.normal {
            let subscriptionID = context.withLiveState { state -> CanonicalUUID? in
                let subscriptionID = state.subscriptionID
                return state.invalidateForDisconnect(
                    connectionEpoch: previousConnectionEpoch
                ) ? subscriptionID : nil
            }
      guard
        sendReconnectControl(
                to: context,
                frames: try reconnectFrames(
                    context: context,
                    disconnectedEpoch: previousConnectionEpoch,
                    snapshot: snapshot
                ),
                resetSubscriptionID: subscriptionID
        )
      else { continue }
        }
        operationBackend.retireLiveGeneration(
            connectionEpoch: previousConnectionEpoch
        )
    }

    private func handleConfirmedAttach(
        snapshot: ProductionRuntimeDeviceSnapshot
    ) throws {
        beginReattachSettling(connectionEpoch: snapshot.connectionEpoch)
        Self.reconnectLogger.notice(
            "stage=attached connectionEpoch=\(snapshot.connectionEpoch, privacy: .public) stateRevision=\(snapshot.stateRevision, privacy: .public)"
        )
        for context in currentPeerContexts where context.normal {
            _ = context.withLiveState { state in
                state.replaceConnectionEpoch(snapshot.connectionEpoch)
            }
            _ = sendReconnectControl(
                to: context,
        frames: [
          try availabilityInvalidatedFrame(
                    context: context,
                    stateRevision: snapshot.stateRevision
          )
        ]
            )
        }
    }

    private func reconnectFrames(
        context: ProductionRuntimePeerContext,
        disconnectedEpoch: UInt64,
        snapshot: ProductionRuntimeDeviceSnapshot
    ) throws -> [RuntimeWireFrame] {
        [
            try deviceDisconnectedFrame(
                context: context,
                connectionEpoch: disconnectedEpoch,
                stateRevision: snapshot.stateRevision
            ),
            try availabilityInvalidatedFrame(
                context: context,
                stateRevision: snapshot.stateRevision
            ),
        ]
    }

    private func deviceDisconnectedFrame(
        context: ProductionRuntimePeerContext,
        connectionEpoch: UInt64,
        stateRevision: UInt64
    ) throws -> RuntimeWireFrame {
    runtimeEventFrame(
      try object([
            ("connectionEpoch", .number(.uint64(connectionEpoch))),
            ("connectionID", .string(context.connectionID.canonicalString)),
            ("eventKind", .string("deviceDisconnected")),
            ("schemaVersion", .number(.uint64(1))),
            ("stateRevision", .number(.uint64(stateRevision))),
        ]))
    }

    private func availabilityInvalidatedFrame(
        context: ProductionRuntimePeerContext,
        stateRevision: UInt64
    ) throws -> RuntimeWireFrame {
    runtimeEventFrame(
      try object([
        (
          "affectedRevisionKinds",
          .array([
                .string("capability"),
                .string("condition"),
                .string("facts"),
                .string("geometry"),
                .string("state"),
          ])
        ),
            ("connectionID", .string(context.connectionID.canonicalString)),
            ("eventKind", .string("availabilityInvalidated")),
            ("schemaVersion", .number(.uint64(1))),
            ("stateRevision", .number(.uint64(stateRevision))),
        ]))
    }

    private func runtimeEventFrame(
        _ payload: RepositoryJSONObject
    ) -> RuntimeWireFrame {
        RuntimeWireFrame(
            messageType: .runtimeEvent,
            payload: RepositoryCanonicalJSON.encodeDocument(payload)
        )
    }

    private func observationResetFrame(
        subscriptionID: CanonicalUUID,
        nextSequence: UInt64,
        reason: String
    ) throws -> RuntimeWireFrame {
        RuntimeWireFrame(
            messageType: .observationStreamReset,
      payload: RepositoryCanonicalJSON.encodeDocument(
        try object([
                ("nextSequence", .number(.uint64(nextSequence))),
                ("reason", .string(reason)),
                ("schemaVersion", .number(.uint64(1))),
                ("subscriptionID", .string(subscriptionID.canonicalString)),
            ]))
        )
    }

    private func sendReconnectControl(
        to context: ProductionRuntimePeerContext,
        frames: [RuntimeWireFrame],
        resetSubscriptionID: CanonicalUUID? = nil
    ) -> Bool {
        do {
            try context.withOutbound { connection, descriptor in
                var outboundFrames = frames
                if let resetSubscriptionID,
                   let reset = observationBroker.resetForControl(
                       subscriptionID: resetSubscriptionID,
                       reason: "projectionInvalidated"
                   )
                {
                    outboundFrames.append(
                        try ProductionRuntimeObservationBroker.resetFrame(reset)
                    )
                }
                for frame in outboundFrames {
          guard
            try connection.enqueueUnassociatedReliable(frame)
                        == .enqueued
                    else {
                        throw ProductionRuntimeServerError.invalidFrame
                    }
                }
                try drain(connection: connection, to: descriptor)
            }
            return true
        } catch {
            _ = Darwin.shutdown(context.descriptor, SHUT_RDWR)
            Self.reconnectLogger.error(
                "stage=peerDelivery outcome=closed connectionID=\(context.connectionID.canonicalString, privacy: .public)"
            )
            return false
        }
    }

    private func configure(peer: Int32) throws {
        guard fcntl(peer, F_SETFD, FD_CLOEXEC) == 0 else {
            throw ProductionRuntimeServerError.transportFailure(errno: errno)
        }
        var noSignal: Int32 = 1
        var timeout = timeval(tv_sec: connectionTimeoutSeconds, tv_usec: 0)
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
    guard
      setsockopt(
            peer,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0,
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize) == 0,
        setsockopt(peer, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize) == 0
        else {
            throw ProductionRuntimeServerError.transportFailure(errno: errno)
        }
    }

    private func setLiveReceiveTimeout(
        attached: Bool,
        on peer: Int32
    ) throws {
        var timeout = timeval(
            tv_sec: attached ? 0 : connectionTimeoutSeconds,
            tv_usec: 0
        )
    guard
      setsockopt(
            peer,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
      ) == 0
    else {
            throw ProductionRuntimeServerError.transportFailure(errno: errno)
        }
    }

    private func removeBoundSocketIfPresent(
        path: String,
        device: UInt64,
        inode: UInt64
    ) {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else { return }
        guard metadata.st_uid == geteuid(),
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              UInt64(metadata.st_dev) == device,
              UInt64(metadata.st_ino) == inode
        else {
            return
        }
        _ = unlink(path)
    }

    private func makeHelperManifestStore() throws -> HelperManifestStore {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, pointer, Int32(size))
        }
        guard result == Int32(size),
              info.pbi_pid == UInt32(getpid()),
              info.pbi_start_tvusec < 1_000_000
        else {
            throw ProductionRuntimeServerError.processIdentityUnavailable
        }
        return try HelperManifestStore(
            canonicalUDID: canonicalUDID,
            runtimeEpoch: runtimeEpoch,
            runtimePID: getpid(),
            runtimeProcessStartIdentity: HelperProcessStartIdentity(
                seconds: info.pbi_start_tvsec,
                microseconds: info.pbi_start_tvusec
            )
        )
    }

    private func removeHelperManifestIfOwned(_ store: HelperManifestStore) {
        guard (try? store.load()) != nil else { return }
        var before = stat()
        guard lstat(store.path, &before) == 0,
              before.st_uid == geteuid(),
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else { return }
        guard (try? store.load()) != nil else { return }
        var after = stat()
        guard lstat(store.path, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino
        else { return }
        _ = unlink(store.path)
    }

    private func serve(peer: Int32) throws {
        let connectionID = CanonicalUUID(value: UUID())
    let handshake = RuntimeHandshakeServer(
      context: RuntimeHandshakeContext(
            expectedPeerUserID: geteuid(),
            runtimeBuildID: Self.runtimeBuildID,
            compatibility: compatibility,
            canonicalUDID: canonicalUDID,
            runtimeEpoch: runtimeEpoch,
            connectionEpoch: nil,
            quiescing: isStopping,
            connectionIDFactory: { connectionID }
        ))
        let hello = try readFrame(from: peer)
        let helloEnvelope = try RuntimeHandshakeCodec.decodeHello(hello)
        let state: RuntimeHandshakeConnectionState
        switch handshake.receiveHello(frameBytes: hello, peerSocket: peer) {
        case .close:
            return
        case .respond(let bytes, let next):
            try writeAll(bytes, to: peer)
            state = next
        }
        let connection = try RuntimeConnection.accepted(
            state: state,
            canonicalUDID: canonicalUDID,
            runtimeRegistry: runtimeRegistry,
            bootstrapStartedAt: state == .bootstrapOnly
                ? SystemMonotonicClock().now()
                : nil
        )
        let context = ProductionRuntimePeerContext(
            clientInstanceID: helloEnvelope.clientInstanceID,
            connection: connection,
            connectionID: connectionID,
            descriptor: peer,
            normal: state == .normal
        )
        guard register(context) else { return }
        defer {
            let liveState = context.liveSnapshot
            if let subscriptionID = liveState.subscriptionID {
                observationBroker.stop(subscriptionID: subscriptionID)
            }
            if liveState.isAttached {
                _ = try? operationBackend.deviceCoordinator?.setLiveAttached(false)
                if let connectionEpoch = liveState.connectionEpoch {
                    operationBackend.retireLiveGeneration(
                        connectionEpoch: connectionEpoch
                    )
                }
            }
        }
        while !isStopping {
            let bytes: [UInt8]
            do {
                bytes = try readFrame(from: peer)
            } catch ProductionRuntimeServerError.closedFrame {
                return
            }
            for message in try connection.receive(
                bytes,
                now: SystemMonotonicClock().now()
            ) {
                switch message {
                case .bootstrap(let request):
                    let response = try bootstrapResponse(request)
                    try context.withOutbound { _, descriptor in
                        try writeAll(
                            BootstrapControlCodec.encodeResponse(response),
                            to: descriptor
                        )
                    }
                    if request.operation == .retireIfIdle, response.ok {
                        requestStop()
                    }
                    return
                case .streamFrame(let frame):
                    try operationBackend.handleStreamFrame(
                        frame,
                        clientInstanceID: context.clientInstanceID
                    )
                case .request(let request):
                    if request.operation == .runtimeRecordLocalAction {
                        continue
                    }
                    let preparationProgress = preparationProgressHandler(
                        requestID: request.requestID,
                        context: context
                    )
          let response:
            (
                        artifact: (
                            descriptor: Int32,
                            artifactID: CanonicalUUID,
                            sizeBytes: UInt64,
                            binding: ArtifactFDContentBinding
                        )?,
                        frame: RuntimeWireFrame,
                        stopAfterResponse: Bool
                    )
                    let previousLiveState = context.liveSnapshot
                    if Self.usesPeerLiveState(request.operation) {
                        response = try context.withLiveState { liveState in
                            try responseFrame(
                                request,
                                clientInstanceID: context.clientInstanceID,
                                liveState: &liveState,
                                elementCancellation: nil,
                                preparationProgress: preparationProgress
                            )
                        }
                    } else {
                        var unusedLiveState = ProductionRuntimePeerLiveState()
                        response = try responseFrameMonitoringElementOwner(
                            request,
                            clientInstanceID: context.clientInstanceID,
                            liveState: &unusedLiveState,
                            peer: peer,
                            preparationProgress: preparationProgress
                        )
                    }
                    var liveTimeoutUpdate: Bool?
                    if request.operation == .runtimeAttachLive,
                       responseSucceeded(response.frame)
                    {
                        if Self.requestsPointerProjection(request),
                           let subscriptionID = context.liveSnapshot.subscriptionID
                        {
                            try observationBroker.attach(
                                clientInstanceID: context.clientInstanceID,
                                subscriptionID: subscriptionID,
                                context: context
                            )
                        }
                        liveTimeoutUpdate = true
                    } else if request.operation == .runtimeDetachLive,
                              responseSucceeded(response.frame)
                    {
                        if let subscriptionID = previousLiveState.subscriptionID {
                            observationBroker.stop(
                                subscriptionID: subscriptionID
                            )
                        }
                        liveTimeoutUpdate = false
                    }
                    try context.withOutbound { connection, descriptor in
                        if let artifact = response.artifact {
                            defer { _ = Darwin.close(artifact.descriptor) }
                            try writeArtifact(
                                artifact,
                                requestID: request.requestID,
                                to: descriptor
                            )
                        }
            guard
              try connection.enqueueTerminalResponse(
                            response.frame,
                            now: SystemMonotonicClock().now()
              ) == .enqueued
            else {
                            throw ProductionRuntimeServerError.invalidFrame
                        }
                        try drain(connection: connection, to: descriptor)
                    }
                    if let liveTimeoutUpdate {
                        try setLiveReceiveTimeout(
                            attached: liveTimeoutUpdate,
                            on: peer
                        )
                    }
                    if response.stopAfterResponse {
                        requestStop()
                        return
                    }
                }
            }
        }
    }

    private static func usesPeerLiveState(
        _ operation: RuntimeOperationID
    ) -> Bool {
        operation == .runtimeAttachLive
            || operation == .runtimeDetachLive
            || operation == .runtimeMarkLiveCaptureReady
    }

    private static func requestsPointerProjection(
        _ request: RuntimeRequestEnvelope
    ) -> Bool {
        request.body["observationTopics"]?.arrayValue?.contains {
            $0.stringValue == "pointerProjection"
        } == true
    }

    private func responseSucceeded(_ frame: RuntimeWireFrame) -> Bool {
    guard
      let envelope = try? RepositoryCanonicalJSON.parseDocument(
            frame.payload,
            maximumByteCount: 256 * 1_024
        ),
        let result = envelope["payload"]?.objectValue?["result"]?.objectValue
        else { return false }
        return result["outcome"]?.stringValue == "succeeded"
    }

    private func preparationProgressHandler(
        requestID: CanonicalUUID,
        context: ProductionRuntimePeerContext
    ) -> ProductionRuntimeOperationBackend.PreparationProgressHandler {
        { [weak self, weak context] progress in
            guard let self, let context else { return }
            self.sendPreparationProgress(
                progress,
                requestID: requestID,
                context: context
            )
        }
    }

    private func sendPreparationProgress(
        _ progress: PreparationProgressV1,
        requestID: CanonicalUUID,
        context: ProductionRuntimePeerContext
    ) {
    guard
      let frame = try? preparationProgressFrame(
            progress,
            requestID: requestID
      )
    else { return }
        do {
            try context.withOutbound { connection, descriptor in
        guard
          try connection.enqueueAssociated(
                    frame,
                    requestID: requestID,
                    kind: .progress,
                    now: SystemMonotonicClock().now()
          ) == .enqueued
        else {
                    throw ProductionRuntimeServerError.invalidFrame
                }
                try drain(connection: connection, to: descriptor)
            }
        } catch {
            _ = Darwin.shutdown(context.descriptor, SHUT_RDWR)
        }
    }

    private func preparationProgressFrame(
        _ progress: PreparationProgressV1,
        requestID: CanonicalUUID
    ) throws -> RuntimeWireFrame {
        var progressMembers: [(String, RepositoryJSONValue)] = [
            ("phase", .string(progress.phase.rawValue)),
            ("phaseSequence", .number(.uint64(progress.phaseSequence))),
            (
                "preparationAttemptID",
                .string(progress.preparationAttemptID.canonicalString)
            ),
            ("preparationGroupID", .string(progress.preparationGroupID)),
            ("stateRevision", .number(.uint64(progress.stateRevision))),
        ]
        if let completedBytes = progress.completedBytes {
      progressMembers.append(
        (
                "completedBytes", .number(.uint64(completedBytes))
            ))
        }
        if let totalBytes = progress.totalBytes {
      progressMembers.append(
        (
                "totalBytes", .number(.uint64(totalBytes))
            ))
        }
        if let retryAfterMs = progress.retryAfterMs {
      progressMembers.append(
        (
                "retryAfterMs", .number(.uint64(retryAfterMs))
            ))
        }
        if let sharedAcquisition = progress.sharedAcquisition {
      progressMembers.append(
        (
                "sharedAcquisition", .bool(sharedAcquisition)
            ))
        }
        if let sourceKind = progress.sourceKind {
            progressMembers.append(("sourceKind", .string(sourceKind.rawValue)))
        }
        let envelope = try object([
            ("payload", .object(try object(progressMembers))),
            (
                "preparationAttemptID",
                .string(progress.preparationAttemptID.canonicalString)
            ),
            ("progressKind", .string("preparation")),
            ("requestID", .string(requestID.canonicalString)),
            ("schemaVersion", .number(.uint64(1))),
        ])
        return RuntimeWireFrame(
            messageType: .progress,
            payload: RepositoryCanonicalJSON.encodeDocument(envelope)
        )
    }

    private func responseFrame(
        _ request: RuntimeRequestEnvelope,
        clientInstanceID: CanonicalUUID,
        liveState: inout ProductionRuntimePeerLiveState,
        elementCancellation: ProductionElementSnapshotCancellation?,
        preparationProgress: ProductionRuntimeOperationBackend
            .PreparationProgressHandler?
    ) throws -> (
        artifact: (
            descriptor: Int32,
            artifactID: CanonicalUUID,
            sizeBytes: UInt64,
            binding: ArtifactFDContentBinding
        )?,
        frame: RuntimeWireFrame,
        stopAfterResponse: Bool
    ) {
        let result: RepositoryJSONObject
    var artifact:
      (
            descriptor: Int32,
            artifactID: CanonicalUUID,
            sizeBytes: UInt64,
            binding: ArtifactFDContentBinding
        )?
        var stopAfterResponse = false
        switch request.operation {
        case .runtimeHealth:
            result = try succeeded(value: runtimeHealth())
        case .runtimeRuntimeStatus:
            result = try succeeded(value: runtimeStatus())
        case .runtimeStopIfIdle:
            if operationBackend.recordingSnapshot()?.hasActiveTrace == true {
                result = try failed(code: "controlBusy")
                break
            }
      result = try succeeded(
        value: try object([
                ("disposition", .string("stopping")),
                ("forceStopSupported", .bool(false)),
                ("runtimeEpoch", .number(.uint64(runtimeEpoch))),
                ("stateRevision", .number(.uint64(1))),
            ]))
            stopAfterResponse = true
        case .runtimeAttachLive:
            guard !liveState.isAttached else {
                result = try failed(code: "liveAlreadyOpen")
                break
            }
            let snapshot = try operationBackend.deviceCoordinator?.refresh()
            let connectionEpoch = snapshot?.connectionEpoch ?? 1
            let liveOwnerID = CanonicalUUID(value: UUID())
            let subscriptionID = CanonicalUUID(value: UUID())
      guard
        liveState.attach(
                canonicalUDID: canonicalUDID,
                connectionEpoch: connectionEpoch,
                liveOwnerID: liveOwnerID,
                subscriptionID: subscriptionID
        )
      else {
                result = try failed(code: "liveOwnerConflict")
                break
            }
            do {
                let attachedSnapshot = try operationBackend.deviceCoordinator?
                    .setLiveAttached(true)
                scheduleReconnectProbeIfNeeded(snapshot: attachedSnapshot)
        result = try succeeded(
          value: try object([
                    ("connectionEpoch", .number(.uint64(connectionEpoch))),
                    ("liveOwnerID", .string(liveOwnerID.canonicalString)),
            (
              "stateRevision",
              .number(
                .uint64(
                        attachedSnapshot?.stateRevision ?? 1
                ))
            ),
                    ("subscriptionID", .string(subscriptionID.canonicalString)),
                ]))
            } catch {
                liveState = ProductionRuntimePeerLiveState()
                throw error
            }
        case .runtimeDetachLive:
            guard let targetText = request.body["canonicalUDID"]?.stringValue,
                  let target = try? CanonicalUDID(canonicalString: targetText),
                  let ownerText = request.body["liveOwnerID"]?.stringValue,
                  let owner = try? CanonicalUUID(ownerText),
                  let subscriptionText = request.body["subscriptionID"]?.stringValue,
                  let subscription = try? CanonicalUUID(subscriptionText)
            else {
                result = try failed(code: "protocolViolation")
                break
            }
            do {
                var detachedState = liveState
                try detachedState.detach(
                    canonicalUDID: target,
                    liveOwnerID: owner,
                    subscriptionID: subscription
                )
                _ = try operationBackend.deviceCoordinator?.setLiveAttached(false)
                if let connectionEpoch = liveState.connectionEpoch {
                    operationBackend.retireLiveGeneration(
                        connectionEpoch: connectionEpoch
                    )
                }
                liveState = detachedState
                result = try succeeded(value: try object([("detached", .bool(true))]))
            } catch {
                result = try failed(code: "protocolViolation")
            }
        case .runtimeMarkLiveCaptureReady:
            guard let targetText = request.body["canonicalUDID"]?.stringValue,
                  let target = try? CanonicalUDID(canonicalString: targetText),
                  let epoch = request.body["connectionEpoch"]?.numberValue
                    .flatMap({ try? $0.requireUInt64() }),
                  let ownerText = request.body["liveOwnerID"]?.stringValue,
                  let owner = try? CanonicalUUID(ownerText),
                  let subscriptionText = request.body["subscriptionID"]?.stringValue,
                  let subscription = try? CanonicalUUID(subscriptionText),
                  let activationText = request.body["captureActivationID"]?.stringValue,
                  let activation = try? CanonicalUUID(activationText)
            else {
                result = try failed(code: "protocolViolation")
                break
            }
            do {
                let validation = try liveState.validateCaptureReady(
                    canonicalUDID: target,
                    connectionEpoch: epoch,
                    liveOwnerID: owner,
                    subscriptionID: subscription,
                    captureActivationID: activation
                )
                if validation == .duplicate {
                    result = try standardResult(
                        operationBackend.refreshDuplicateCaptureReady(
                            connectionEpoch: epoch
                        )
                    )
                    break
                }
                let backend = try operationBackend.markLiveCaptureReady(
                    connectionEpoch: epoch,
                    captureActivationID: activation
                )
                if case .succeeded = backend {
                    liveState.commitCaptureActivation(activation)
                }
                result = try standardResult(backend)
            } catch ProductionRuntimePeerLiveValidationError.staleConnectionEpoch {
                result = try failed(code: "deviceDisconnected")
            } catch ProductionRuntimePeerLiveValidationError.notAttached,
        ProductionRuntimePeerLiveValidationError.ownerConflict
      {
                result = try failed(code: "liveOwnerConflict")
            } catch {
                result = try failed(code: "protocolViolation")
            }
        case .commandSubmit, .runtimeCancelOwnedPendingWork,
             .runtimeClearActionLogs, .runtimeGetAvailabilitySnapshot,
             .runtimePrepareCapabilities, .runtimeStartDiagnostics,
             .runtimeStartReplayTrace, .runtimeStopDiagnostics,
             .runtimeStopReplayTrace, .streamCancel, .streamClose,
             .streamOpen:
            let backend = try operationBackend.handle(
                request,
                clientInstanceID: clientInstanceID,
                elementCancellation: elementCancellation,
                preparationProgress: preparationProgress
            )
            switch backend {
            case .artifact(
                let descriptor,
                let artifactID,
                let sizeBytes,
                let binding,
                let value
            ):
                artifact = (descriptor, artifactID, sizeBytes, binding)
                result = try succeeded(value: value)
            default:
                result = try standardResult(backend)
            }
        case .runtimeRecordLocalAction:
            throw ProductionRuntimeServerError.invalidFrame
        }
        var payloadMembers: [(String, RepositoryJSONValue)] = [
            ("operation", .string(request.operation.rawValue)),
            ("result", .object(result)),
        ]
        if let actionID = request.body["actionID"]?.stringValue {
            payloadMembers.append(("actionID", .string(actionID)))
        }
        let payload = try object(payloadMembers)
        let envelope = try object([
            ("payload", .object(payload)),
            ("requestID", .string(request.requestID.canonicalString)),
            ("schemaVersion", .number(.uint64(1))),
        ])
        return (
            artifact,
            RuntimeWireFrame(
                messageType: .response,
                payload: RepositoryCanonicalJSON.encodeDocument(envelope)
            ),
            stopAfterResponse
        )
    }

    private func responseFrameMonitoringElementOwner(
        _ request: RuntimeRequestEnvelope,
        clientInstanceID: CanonicalUUID,
        liveState: inout ProductionRuntimePeerLiveState,
        peer: Int32,
        preparationProgress: ProductionRuntimeOperationBackend
            .PreparationProgressHandler?
    ) throws -> (
        artifact: (
            descriptor: Int32,
            artifactID: CanonicalUUID,
            sizeBytes: UInt64,
            binding: ArtifactFDContentBinding
        )?,
        frame: RuntimeWireFrame,
        stopAfterResponse: Bool
    ) {
        guard request.operation == .commandSubmit,
              request.body["commandID"]?.stringValue == "element.snapshot"
        else {
            return try responseFrame(
                request,
                clientInstanceID: clientInstanceID,
                liveState: &liveState,
                elementCancellation: nil,
                preparationProgress: preparationProgress
            )
        }
        let cancellation = ProductionElementSnapshotCancellation()
        let monitor = ProductionElementOwnerDisconnectMonitor(
            descriptor: peer,
            cancellation: cancellation
        )
        defer { monitor.stop() }
        return try responseFrame(
            request,
            clientInstanceID: clientInstanceID,
            liveState: &liveState,
            elementCancellation: cancellation,
            preparationProgress: preparationProgress
        )
    }

    private func runtimeHealth() throws -> RepositoryJSONObject {
        try object([
            ("canonicalUDID", .string(canonicalUDID.rawValue)),
            ("pid", .number(.uint64(UInt64(getpid())))),
            ("runtimeEpoch", .number(.uint64(runtimeEpoch))),
            ("runtimeState", .string(isStopping ? "quiescing" : "ready")),
            ("stateRevision", .number(.uint64(1))),
        ])
    }

    private func runtimeStatus() throws -> RepositoryJSONObject {
        let empty = try object([])
        let snapshot = try operationBackend.deviceCoordinator?.refresh()
        let executor = operationBackend.executorDiagnosticSnapshot()
        let recording = operationBackend.recordingSnapshot()
        let executorSummary = try ProductionRuntimeOperationBackend.executorSummary(
            executor
        )
        let diagnosticsSummary = try recordingSummary(
            activeID: recording?.activeDiagnosticsSessionID,
            activePath: recording?.activeDiagnosticsPath,
            idKey: "diagnosticsSessionID"
        )
        let traceSummary = try recordingSummary(
            activeID: recording?.activeTraceID,
            activePath: recording?.activeTracePath,
            idKey: "traceID"
        )
        let stopBlockers = try recordingStopBlockers(recording)
        return try object([
            ("assetAcquisitionSummaries", .array([])),
            ("canonicalUDID", .string(canonicalUDID.rawValue)),
            ("capabilitySummary", .object(empty)),
            ("connected", .bool(snapshot?.device?.condition.connected == true)),
      (
        "connectionEpoch",
        .number(
          .uint64(
                snapshot?.connectionEpoch ?? 0
          ))
      ),
            ("diagnosticsSummary", .object(diagnosticsSummary)),
            ("executorSummary", .object(executorSummary)),
            ("inhibitorRevision", .number(.uint64(recording?.revision ?? 0))),
            ("omittedAssetAcquisitionCount", .number(.uint64(0))),
            ("omittedPreparationCount", .number(.uint64(0))),
            ("operationSummary", .object(empty)),
            ("otherOmittedCounts", .object(empty)),
            ("pid", .number(.uint64(UInt64(getpid())))),
            ("preparationSummaries", .array([])),
            ("queueSummary", .object(empty)),
            ("runtimeEpoch", .number(.uint64(runtimeEpoch))),
            ("runtimeState", .string(isStopping ? "stopping" : "ready")),
      (
        "stateRevision",
        .number(
          .uint64(
            max(
                1,
                snapshot?.stateRevision ?? 0,
                recording?.revision ?? 0
            )))
      ),
            ("stopBlockers", .array(stopBlockers)),
            ("streamSummary", .object(empty)),
            ("traceSummary", .object(traceSummary)),
            ("truncated", .bool(false)),
        ])
    }

    private func recordingSummary(
        activeID: CanonicalUUID?,
        activePath: String?,
        idKey: String
    ) throws -> RepositoryJSONObject {
        var members: [(String, RepositoryJSONValue)] = [
      ("active", .bool(activeID != nil))
        ]
        if let activeID {
            members.append((idKey, .string(activeID.canonicalString)))
        }
        if let activePath {
            members.append(("absolutePath", .string(activePath)))
        }
        return try object(members)
    }

    private func recordingStopBlockers(
        _ snapshot: ProductionRuntimeRecordingSnapshot?
    ) throws -> [RepositoryJSONValue] {
        guard snapshot?.hasActiveTrace == true else { return [] }
    return [
      .object(
        try object([
            ("commandID", .string("trace.start")),
            ("count", .number(.uint64(1))),
            ("kind", .string("activeTrace")),
            ("retryWhen", .string("traceStopped")),
            ("state", .string("active")),
        ]))
    ]
    }

    private func bootstrapResponse(
        _ request: BootstrapRequest
    ) throws -> BootstrapResponse {
        if request.operation == .retireIfIdle {
            guard operationBackend.recordingSnapshot()?.hasActiveTrace != true else {
                return BootstrapResponse(
                    requestID: request.requestID,
                    operation: request.operation,
                    error: try BootstrapErrorPayload(
                        code: "incompatibleRuntimeBusy",
                        details: try object([])
                    )
                )
            }
            return BootstrapResponse(
                requestID: request.requestID,
                operation: request.operation,
                result: try object([
                    ("canonicalUDID", .string(canonicalUDID.rawValue)),
                    ("disposition", .string("retiring")),
                    ("runtimeEpoch", .number(.uint64(runtimeEpoch))),
                ])
            )
        }
        if request.operation == .stopReplayTraceAndFinalize {
            do {
                let stopped = try operationBackend.stopReplayTraceForBootstrap()
                guard stopped.completeness == .complete else {
                    return BootstrapResponse(
                        requestID: request.requestID,
                        operation: request.operation,
                        error: try BootstrapErrorPayload(
                            code: "traceWriteFailed",
                            details: try object([])
                        )
                    )
                }
                return BootstrapResponse(
                    requestID: request.requestID,
                    operation: request.operation,
                    result: try object([
                        ("absolutePath", .string(stopped.absolutePath)),
                        ("completeness", .string("complete")),
                        ("traceID", .string(stopped.traceID.canonicalString)),
                    ])
                )
            } catch ProductionRuntimeRecordingError.noActiveTrace {
                return BootstrapResponse(
                    requestID: request.requestID,
                    operation: request.operation,
                    error: try BootstrapErrorPayload(
                        code: "noActiveTrace",
                        details: try object([])
                    )
                )
            } catch {
                return BootstrapResponse(
                    requestID: request.requestID,
                    operation: request.operation,
                    error: try BootstrapErrorPayload(
                        code: "traceWriteFailed",
                        details: try object([])
                    )
                )
            }
        }
        guard request.operation == .probeRuntimeLite else {
            return BootstrapResponse(
                requestID: request.requestID,
                operation: request.operation,
                error: try BootstrapErrorPayload(
                    code: "unsupportedBootstrapOperation",
                    details: try object([])
                )
            )
        }
        return BootstrapResponse(
            requestID: request.requestID,
            operation: request.operation,
            result: try object([
                (
                    "blockersSummary",
          .array(
            operationBackend.recordingSnapshot()?.hasActiveTrace == true
                        ? [.string("activeTrace")]
                        : [])
                ),
                ("canonicalUDID", .string(canonicalUDID.rawValue)),
                (
                    "executionCatalogHash",
                    .string(compatibility.executionCatalogHash)
                ),
                ("pid", .number(.uint64(UInt64(getpid())))),
                ("quiescing", .bool(isStopping)),
                ("runtimeBuildID", .string(Self.runtimeBuildID)),
                (
                    "runtimeCompatibilityID",
                    .string(compatibility.runtimeCompatibilityID)
                ),
                ("runtimeEpoch", .number(.uint64(runtimeEpoch))),
            ])
        )
    }

    private func succeeded(
        value: RepositoryJSONObject
    ) throws -> RepositoryJSONObject {
        try object([
            ("commitState", .string("notCommitted")),
            ("outcome", .string("succeeded")),
            ("value", .object(value)),
        ])
    }

    private func failed(
        code: String,
        details: RepositoryJSONObject? = nil
    ) throws -> RepositoryJSONObject {
        let error = try object([
            ("code", .string(code)),
            ("details", .object(try details ?? object([]))),
        ])
        return try object([
            ("commitState", .string("notCommitted")),
            ("error", .object(error)),
            ("outcome", .string("failed")),
        ])
    }

    private func standardResult(
        _ disposition: ProductionRuntimeBackendDisposition
    ) throws -> RepositoryJSONObject {
        switch disposition {
        case .artifact:
            throw ProductionRuntimeServerError.invalidFrame
        case .failed(let code):
            return try failed(code: code)
        case .failedWithDetails(let code, let details):
            return try failed(code: code, details: details)
        case .outcomeUnknown(let code):
            let error = try object([
                ("code", .string(code)),
                ("details", .object(try object([]))),
            ])
            return try object([
                ("commitState", .string("unknown")),
                ("error", .object(error)),
                ("outcome", .string("outcomeUnknown")),
            ])
        case .standard(let result):
            return result
        case .succeeded(let value):
            return try succeeded(value: value)
        }
    }

    private func writeArtifact(
        _ artifact: (
            descriptor: Int32,
            artifactID: CanonicalUUID,
            sizeBytes: UInt64,
            binding: ArtifactFDContentBinding
        ),
        requestID: CanonicalUUID,
        to descriptor: Int32
    ) throws {
        let element = artifact.binding.elementAnnotation
        let payload = try object([
            ("artifactID", .string(artifact.artifactID.canonicalString)),
            (
                "captureSHA256",
                element.map { .string($0.captureSHA256) } ?? .null
            ),
            ("contentType", .string("image/png")),
            (
                "pixelHeight",
                element.map { .number(.uint64($0.pixelHeight)) } ?? .null
            ),
            (
                "pixelWidth",
                element.map { .number(.uint64($0.pixelWidth)) } ?? .null
            ),
            ("purpose", .string(artifact.binding.purpose.rawValue)),
            ("requestID", .string(requestID.canonicalString)),
            ("schemaVersion", .number(.uint64(1))),
            ("sizeBytes", .number(.uint64(artifact.sizeBytes))),
            (
                "snapshotGeneration",
                element.map { .number(.uint64($0.snapshotGeneration)) } ?? .null
            ),
        ])
    let bytes = try RuntimeWireFrameCodec.encode(
      RuntimeWireFrame(
            messageType: .artifactFD,
            payload: RepositoryCanonicalJSON.encodeDocument(payload)
        ))
        let header = Array(bytes.prefix(RuntimeWireFrame.headerByteCount))
        try sendDescriptor(
            artifact.descriptor,
            withHeader: header,
            to: descriptor
        )
        try writeAll(
            Array(bytes.dropFirst(RuntimeWireFrame.headerByteCount)),
            to: descriptor
        )
    }

    private func sendDescriptor(
        _ transferred: Int32,
        withHeader header: [UInt8],
        to descriptor: Int32
    ) throws {
        let alignment = MemoryLayout<UInt32>.alignment
        let headerSize = Self.aligned(MemoryLayout<cmsghdr>.size, to: alignment)
    let controlSize =
      headerSize
      + Self.aligned(
            MemoryLayout<Int32>.size,
            to: alignment
        )
        var control = [UInt8](repeating: 0, count: controlSize)
        var mutableHeader = header
        let sent = mutableHeader.withUnsafeMutableBytes { headerBuffer in
            control.withUnsafeMutableBytes { controlBuffer in
                let messageHeader = controlBuffer.baseAddress!
                    .assumingMemoryBound(to: cmsghdr.self)
                messageHeader.pointee.cmsg_len = socklen_t(
                    headerSize + MemoryLayout<Int32>.size
                )
                messageHeader.pointee.cmsg_level = SOL_SOCKET
                messageHeader.pointee.cmsg_type = SCM_RIGHTS
                controlBuffer.storeBytes(
                    of: transferred,
                    toByteOffset: headerSize,
                    as: Int32.self
                )
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
                    return Darwin.sendmsg(descriptor, &message, 0)
                }
            }
        }
        guard sent == header.count else {
            throw ProductionRuntimeServerError.transportFailure(errno: errno)
        }
    }

    private static func aligned(_ value: Int, to alignment: Int) -> Int {
        (value + alignment - 1) & ~(alignment - 1)
    }

    private func drain(
        connection: RuntimeConnection,
        to descriptor: Int32
    ) throws {
        while connection.writer.queuedFrameCount > 0 {
            _ = try connection.writer.drainNext(
                now: SystemMonotonicClock().now()
            ) { remaining in
                let result = remaining.withUnsafeBytes { buffer in
                    Darwin.write(descriptor, buffer.baseAddress, remaining.count)
                }
                if result > 0 { return result }
                if result == -1, errno == EINTR { return 0 }
                throw ProductionRuntimeServerError.transportFailure(errno: errno)
            }
        }
    }

    private func readFrame(from descriptor: Int32) throws -> [UInt8] {
        let header = try readExact(RuntimeWireFrame.headerByteCount, from: descriptor)
        let payloadLength = Int(
            (UInt32(header[12]) << 24)
                | (UInt32(header[13]) << 16)
                | (UInt32(header[14]) << 8)
                | UInt32(header[15])
        )
        guard payloadLength <= 1 * 1_024 * 1_024 else {
            throw ProductionRuntimeServerError.invalidFrame
        }
        return header + (try readExact(payloadLength, from: descriptor))
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
                throw ProductionRuntimeServerError.closedFrame
            } else if errno == EINTR {
                continue
            } else {
                throw ProductionRuntimeServerError.transportFailure(errno: errno)
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
                throw ProductionRuntimeServerError.transportFailure(errno: errno)
            }
        }
    }

    private func object(
        _ members: [(String, RepositoryJSONValue)]
    ) throws -> RepositoryJSONObject {
    try RepositoryJSONObject(
      members: members.map {
            RepositoryJSONMember(key: $0.0, value: $0.1)
        })
    }
}
