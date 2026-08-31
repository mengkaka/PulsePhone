import Darwin
import Foundation
import PulsePhoneClientCore
import PulsePhoneCommandPlanner
import PulsePhoneDeveloperImageAssets
import PulsePhoneHostPaths
import PulsePhoneLogging
import PulsePhoneSharedDefinitions
import PulsePhoneWire

public struct CLILiveOpenResult: Sendable {
    public let disposition: String
    public let liveOwnerID: String

    public init(disposition: String, liveOwnerID: String) {
        self.disposition = disposition
        self.liveOwnerID = liveOwnerID
    }
}

public enum CLIProductionBackendError: Error, Equatable, Sendable {
    case standard(
        code: String,
        message: String? = nil,
        details: [String: String]? = nil
    )
}

public struct PulsePhoneCLIProcess: Sendable {
    public typealias StaticSurfaceFactory = @Sendable () throws -> CLIStaticSurface
    public typealias ProductVersionFactory = @Sendable () throws
        -> PulsePhoneProductVersion
    public typealias SelfInstall = @Sendable () throws -> SelfInstallResult
    public typealias AgentSkillManagerFactory = @Sendable () throws
        -> any AgentSkillManaging
    public typealias ActionLogMaintenanceFactory = @Sendable () throws
        -> ProductionActionLogMaintenance
    public typealias DeveloperImageDiagnosticsFactory = @Sendable () throws
        -> DynamicDeveloperImageDiagnostics

    public typealias RuntimeRequest = @Sendable (
        RuntimeOperationID,
        CanonicalUDID,
        RepositoryJSONObject,
        RuntimeClientActivation,
        CanonicalUUID
    ) throws -> RepositoryJSONObject

    public typealias PreparationProgressOutput = @Sendable (
        PreparationProgressV1
    ) -> Void

    public typealias LiveOpen = @Sendable (
        CanonicalUDID,
        CanonicalUUID,
        Bool
    ) throws -> CLILiveOpenResult

    public typealias ScreenshotRequest = @Sendable (
        CanonicalUUID,
        CanonicalUUID,
        CanonicalUDID,
        String
    ) throws -> ScreenshotReceivedArtifact

    public typealias ElementSnapshotRequest = @Sendable (
        CanonicalUUID,
        CanonicalUUID,
        CanonicalUDID,
        String,
        String?
    ) throws -> RuntimeClientElementSnapshotResponse

    public typealias RuntimeStop = @Sendable (
        CanonicalUDID,
        CLIOutputMode
    ) throws -> CLITerminalOutput

    private let makeStaticSurface: StaticSurfaceFactory
    private let makeProductVersion: ProductVersionFactory
    private let selfInstall: SelfInstall
    private let makeAgentSkillManager: AgentSkillManagerFactory
    private let makeQueries: @Sendable () throws -> LocalDeviceQueries
    private let makeActionLogMaintenance: ActionLogMaintenanceFactory
    private let makeDeveloperImageDiagnostics: DeveloperImageDiagnosticsFactory
    private let runtimeRequest: RuntimeRequest
    private let preparationProgressOutput: PreparationProgressOutput
    private let productionRuntimeStop: RuntimeStop?
    private let elementSnapshotRequest: ElementSnapshotRequest
    private let screenshotRequest: ScreenshotRequest
    private let liveOpen: LiveOpen

    public init(
        makeStaticSurface: @escaping StaticSurfaceFactory = {
            try CLIStaticSurface.bundled()
        },
        makeProductVersion: @escaping ProductVersionFactory = {
            let appPath = try CanonicalAppPath.resolveCurrentExecutable()
            guard let bundle = Bundle(url: appPath.bundleURL),
                  let version = PulsePhoneProductVersion(bundle: bundle)
            else {
                throw CLIProductionBackendError.standard(code: "internalFailure")
            }
            return version
        },
        selfInstall: @escaping SelfInstall = {
            throw CLIProductionBackendError.standard(code: "internalFailure")
        },
        makeAgentSkillManager: @escaping AgentSkillManagerFactory = {
            throw CLIProductionBackendError.standard(code: "internalFailure")
        },
        makeQueries: @escaping @Sendable () throws -> LocalDeviceQueries,
        makeDeveloperImageDiagnostics: @escaping DeveloperImageDiagnosticsFactory = {
            let root = URL(fileURLWithPath: try POSIXHostPathSystem()
                .makeHostPathLayout().developerImageStoreDirectory)
            let catalogStore = try DynamicDeveloperImageCatalogStore(rootURL: root)
            let assetCache = try DynamicDeveloperImageAssetCache(rootURL: root)
            return DynamicDeveloperImageDiagnostics(
                catalogStore: catalogStore,
                assetCache: assetCache
            )
        },
        makeActionLogMaintenance: @escaping ActionLogMaintenanceFactory = {
            try ProductionActionLogMaintenance.bundled()
        },
        runtimeRequest: @escaping RuntimeRequest = { _, _, _, _, _ in
            throw CLIProductionBackendError.standard(code: "runtimeFailed")
        },
        preparationProgressOutput: @escaping PreparationProgressOutput = { _ in },
        runtimeStop: RuntimeStop? = nil,
        elementSnapshotRequest: @escaping ElementSnapshotRequest = { _, _, _, _, _ in
            throw CLIProductionBackendError.standard(code: "runtimeFailed")
        },
        screenshotRequest: @escaping ScreenshotRequest = { _, _, _, _ in
            throw CLIProductionBackendError.standard(code: "runtimeFailed")
        },
        liveOpen: @escaping LiveOpen = { _, _, _ in
            throw CLIProductionBackendError.standard(code: "guiHostUnavailable")
        }
    ) {
        self.makeStaticSurface = makeStaticSurface
        self.makeProductVersion = makeProductVersion
        self.selfInstall = selfInstall
        self.makeAgentSkillManager = makeAgentSkillManager
        self.makeQueries = makeQueries
        self.makeDeveloperImageDiagnostics = makeDeveloperImageDiagnostics
        self.makeActionLogMaintenance = makeActionLogMaintenance
        self.runtimeRequest = runtimeRequest
        self.preparationProgressOutput = preparationProgressOutput
        self.productionRuntimeStop = runtimeStop
        self.elementSnapshotRequest = elementSnapshotRequest
        self.screenshotRequest = screenshotRequest
        self.liveOpen = liveOpen
    }

    public static func bundled(
        preparationProgressOutput: @escaping PreparationProgressOutput = { _ in },
        liveOpen: @escaping LiveOpen = { _, _, _ in
            throw CLIProductionBackendError.standard(code: "guiHostUnavailable")
        }
    ) -> Self {
        Self(
            makeStaticSurface: { try CLIStaticSurface.bundled() },
            selfInstall: {
                do {
                    return try ProductionSelfInstaller().install()
                } catch let error as SelfInstallError {
                    throw CLIProductionBackendError.standard(
                        code: error.cliCode,
                        message: error.description
                    )
                }
            },
            makeAgentSkillManager: {
                ProductionAgentSkillManager()
            },
            makeQueries: {
                let appPath = try CanonicalAppPath.resolveCurrentExecutable()
                let helper = BundledHelperExecutableSet(
                    resourcesURL: appPath.resourcesURL
                ).directExecutableURL
                return LocalDeviceQueries(
                    discovery: USBDeviceDiscovery(
                        factsProvider: LocalDeviceFactsProbe(
                            executablePath: helper.path
                        )
                    )
                )
            },
            makeActionLogMaintenance: {
                do {
                    return try ProductionActionLogMaintenance.bundled()
                } catch {
                    throw CLIProductionBackendError.standard(code: "unsafeHostPath")
                }
            },
            runtimeRequest: { operation, target, body, activation, requestID in
                let commandTimeout = body["commandID"]?.stringValue.map {
                    RuntimeClient.commandRequestTimeoutSeconds($0)
                } ?? RuntimeClient.requestTimeoutSeconds
                let timeout: Int? = operation == .runtimePrepareCapabilities
                    && body["mode"]?.stringValue == "waitForTerminal"
                    ? nil
                    : commandTimeout
                return try RuntimeClient.bundled(role: .cli).request(
                    operation: operation,
                    canonicalUDID: target,
                    body: body,
                    activation: activation,
                    requestID: requestID,
                    timeoutSeconds: timeout,
                    onPreparationProgress: preparationProgressOutput
                ).result
            },
            runtimeStop: { target, outputMode in
                try RuntimeStopCommand(
                    backend: ProductionRuntimeStopBackend.bundled()
                ).run(
                    canonicalUDID: target,
                    outputMode: outputMode
                )
            },
            elementSnapshotRequest: {
                requestID, actionID, target, format, internalAnalyzers in
                let interruption = RuntimeClientElementSnapshotInterruption()
                let signalMonitor = ProductionElementSnapshotSIGINTMonitor(
                    interruption: interruption
                )
                defer { signalMonitor.stop() }
                return try RuntimeClient.bundled(role: .cli).requestElementSnapshot(
                    canonicalUDID: target,
                    body: try Self.makeObject([
                        ("actionID", .string(actionID.canonicalString)),
                        ("canonicalUDID", .string(target.rawValue)),
                        ("commandID", .string("element.snapshot")),
                        (
                            "normalizedArguments",
                            .object(try Self.elementSnapshotArguments(
                                format: format,
                                internalAnalyzers: internalAnalyzers
                            ))
                        ),
                    ]),
                    activation: .ensureRunning,
                    requestID: requestID,
                    expectsAnnotation: format != "json",
                    interruption: interruption,
                    timeoutSeconds: RuntimeClient.preparationRequestTimeoutSeconds,
                    onPreparationProgress: preparationProgressOutput
                )
            },
            screenshotRequest: { requestID, actionID, target, outputPath in
                let response = try RuntimeClient.bundled(role: .cli).requestScreenshot(
                    canonicalUDID: target,
                    body: try Self.makeObject([
                        ("actionID", .string(actionID.canonicalString)),
                        ("canonicalUDID", .string(target.rawValue)),
                        ("commandID", .string(ScreenshotCommand.commandID)),
                        ("normalizedArguments", .object(try Self.makeObject([
                            ("outputPath", .string(outputPath)),
                        ]))),
                    ]),
                    activation: .ensureRunning,
                    requestID: requestID,
                    timeoutSeconds: RuntimeClient.preparationRequestTimeoutSeconds,
                    onPreparationProgress: preparationProgressOutput
                )
                guard response.result["outcome"]?.stringValue == "succeeded",
                      let artifact = response.artifact
                else {
                    let error = response.result["error"]?.objectValue
                    let code = error?["code"]?.stringValue ?? "runtimeFailed"
                    throw CLIProductionBackendError.standard(
                        code: code,
                        details: Self.stringDetails(error?["details"]?.objectValue)
                    )
                }
                return artifact
            },
            liveOpen: liveOpen
        )
    }

    public func run(arguments: [String]) -> CLITerminalOutput {
        let mode = CLIArgumentPreflight.outputMode(in: arguments)
        let adapter = CLIOutputAdapter(mode: mode)
        do {
            let surface = try makeStaticSurface()
            let internalSelection = try Self.extractInternalAnalyzerSelection(
                from: arguments
            )
            if let help = try CLIArgumentPreflight.helpRequest(
                internalSelection.publicArguments,
                surface: surface
            ) {
                return CLITerminalOutput(
                    chunk: CLIOutputChunk(stdout: [try CLIHelpRenderer(
                        surface: surface
                    ).render(help)]),
                    exitCode: 0
                )
            }
            let invocation = try CLIArgumentPreflight.parse(
                internalSelection.publicArguments,
                surface: surface
            )
            let invocationAdapter = Self.outputAdapter(
                for: invocation,
                requested: adapter
            )
            do {
                return try dispatch(
                    invocation,
                    surface: surface,
                    adapter: invocationAdapter,
                    internalAnalyzers: internalSelection.canonicalValue
                )
            } catch {
                return mappedFailure(
                    error,
                    invocation: invocation,
                    adapter: invocationAdapter
                )
            }
        } catch let error as CLIArgumentPreflightError {
            let failure = Self.preflightArgumentFailure(error)
            return fallbackFailure(
                adapter: adapter,
                family: .argument,
                commandToken: nil,
                code: "invalidArgument",
                message: failure.message,
                details: failure.details
            )
        } catch {
            return fallbackFailure(
                adapter: adapter,
                family: .internal,
                commandToken: nil,
                code: "internalFailure",
                message: String(describing: error)
            )
        }
    }

    private func dispatch(
        _ invocation: CLIInvocation,
        surface: CLIStaticSurface,
        adapter: CLIOutputAdapter,
        internalAnalyzers: String?
    ) throws -> CLITerminalOutput {
        let parsed = try parseOptions(invocation)
        switch invocation.commandID {
        case "catalog.commands":
            return try adapter.success(
                commandID: "catalog.commands",
                target: .global,
                result: CLICommandListResultV2(surface: surface),
                human: CLIHelpRenderer(surface: surface).commandTable()
            )
        case "developerImage.list":
            do {
                let result = try makeDeveloperImageDiagnostics().list(
                    forceRefresh: parsed.flags.contains("--refresh")
                )
                return try adapter.success(
                    commandID: "developerImage.list",
                    target: .global,
                    result: result,
                    human: developerImageListHuman(result)
                )
            } catch {
                return mappedFailure(
                    error,
                    invocation: invocation,
                    adapter: adapter,
                    target: .global
                )
            }
        case "developerImage.check":
            let queries = try makeQueries()
            let info = try queries.deviceInfo(
                canonicalUDID: try parseTargetOnly(parsed)
            )
            do {
                let result = try makeDeveloperImageDiagnostics().check(
                    iosVersion: info.osVersion,
                    buildID: info.osBuild,
                    developerServicesReady: developerImageServicesReady(
                        target: info.canonicalUDID,
                        osVersion: info.osVersion
                    ),
                    forceRefresh: parsed.flags.contains("--refresh")
                )
                return try adapter.success(
                    commandID: "developerImage.check",
                    target: .device(info.canonicalUDID),
                    result: result,
                    human: developerImageCheckHuman(result)
                )
            } catch {
                return mappedFailure(
                    error,
                    invocation: invocation,
                    adapter: adapter,
                    target: .device(info.canonicalUDID)
                )
            }
        case "product.version":
            let version = try makeProductVersion()
            return try adapter.success(
                commandID: "product.version",
                target: .global,
                result: version,
                human: version.displayText
            )
        case "self.install":
            let result = try selfInstall()
            return try adapter.success(
                commandID: "self.install",
                target: .global,
                result: result,
                human: result.humanSummary
            )
        case "skill.install":
            let result = try makeAgentSkillManager().install(
                agents: parsed.repeatedValues["--agent"] ?? [],
                skillRoots: parsed.repeatedValues["--skill-root"] ?? [],
                force: parsed.flags.contains("--force")
            )
            return try adapter.success(
                commandID: "skill.install",
                target: .global,
                result: result,
                human: result.humanSummary
            )
        case "skill.status":
            let result = try makeAgentSkillManager().status(
                agents: parsed.repeatedValues["--agent"] ?? [],
                skillRoots: parsed.repeatedValues["--skill-root"] ?? []
            )
            return try adapter.success(
                commandID: "skill.status",
                target: .global,
                result: result,
                human: result.humanSummary
            )
        case "skill.uninstall":
            let result = try makeAgentSkillManager().uninstall(
                agents: parsed.repeatedValues["--agent"] ?? [],
                skillRoots: parsed.repeatedValues["--skill-root"] ?? [],
                force: parsed.flags.contains("--force")
            )
            return try adapter.success(
                commandID: "skill.uninstall",
                target: .global,
                result: result,
                human: result.humanSummary
            )
        case "device.list":
            let queries = try makeQueries()
            let result = try queries.devices()
            let human = try DevicesCommand(queries: queries).run(outputMode: .human)
            return try adapter.success(
                commandID: "device.list",
                target: .global,
                result: result,
                human: human
            )
        case "device.info":
            let target = try parseTargetOnly(parsed)
            let queries = try makeQueries()
            let result = try queries.deviceInfo(canonicalUDID: target)
            let human = try DeviceInfoCommand(queries: queries).run(
                canonicalUDID: target,
                outputMode: .human
            )
            return try adapter.success(
                commandID: "device.info",
                target: .device(result.canonicalUDID),
                result: result,
                human: human
            )
        case "device.status":
            let target = try parseTargetOnly(parsed)
            let queries = try makeQueries()
            let result = try queries.deviceStatus(canonicalUDID: target)
            let human = try DeviceStatusCommand(queries: queries).run(
                canonicalUDID: target,
                outputMode: .human
            )
            return try adapter.success(
                commandID: "device.status",
                target: .device(result.canonicalUDID),
                result: result,
                human: human
            )
        case "runtime.status.device", "runtime.status.global":
            return try runtimeStatus(parsed, adapter: adapter)
        case "device.prepare":
            return try directControl(
                commandID: "device.prepare",
                operation: .runtimePrepareCapabilities,
                parsed: parsed,
                activation: .ensureRunning,
                adapter: adapter
            )
        case "live.launch":
            let target = try resolveTarget(parsed)
            let requestID = CanonicalUUID(value: UUID())
            let preparation: RepositoryJSONObject
            do {
                preparation = try runtimeRequest(
                    .runtimePrepareCapabilities,
                    target,
                    try object([
                        ("canonicalUDID", .string(target.rawValue)),
                        ("mode", .string("startOnly")),
                    ]),
                    .ensureRunning,
                    requestID
                )
            } catch {
                return try backendFailure(
                    error,
                    commandID: "live.launch",
                    target: .device(target),
                    adapter: adapter
                )
            }
            guard preparation["outcome"]?.stringValue
                == StandardOutcome.succeeded.rawValue
            else {
                return try renderRuntimeResult(
                    preparation,
                    commandID: "live.launch",
                    target: .device(target),
                    adapter: adapter
                )
            }
            let result: CLILiveOpenResult
            do {
                result = try liveOpen(
                    target,
                    requestID,
                    parsed.flags.contains("--select-source")
                )
            } catch {
                return try backendFailure(
                    error,
                    commandID: "live.launch",
                    target: .device(target),
                    adapter: adapter
                )
            }
            let human: String
            switch result.disposition {
            case "alreadyOpen":
                human = "Live window already open"
            case "sourceSelectionOpened":
                human = "Source selection opened"
            default:
                human = "Live window opened"
            }
            return try adapter.success(
                commandID: "live.launch",
                target: .device(target),
                result: LiveLaunchResult(
                    disposition: result.disposition,
                    liveOwnerID: result.liveOwnerID
                ),
                human: human
            )
        case "touch.tap":
            let point = try required(parsed, "--x") + "," + required(parsed, "--y")
            return try submit(
                commandID: "touch.tap",
                schemaID: "normalizedPoint.v1",
                rawArguments: ["point": point],
                parsed: parsed,
                adapter: adapter
            )
        case "touch.drag", "touch.swipe":
            let commandID = invocation.commandID
            return try submit(
                commandID: commandID,
                schemaID: "linearGesture.v1",
                rawArguments: [
                    "durationMs": try required(parsed, "--duration"),
                    "from": try required(parsed, "--from"),
                    "to": try required(parsed, "--to"),
                ],
                parsed: parsed,
                adapter: adapter
            )
        case "device.rotate":
            return try submit(
                commandID: "device.rotate",
                schemaID: "rotateDirection.v2",
                rawArguments: ["direction": try required(parsed, "--direction")],
                parsed: parsed,
                adapter: adapter
            )
        case "text.type":
            return try submit(
                commandID: "text.type",
                schemaID: "utf8Text.v1",
                rawArguments: ["text": try required(parsed, "--text")],
                parsed: parsed,
                adapter: adapter
            )
        case "text.key":
            return try submit(
                commandID: "text.key",
                schemaID: "textKey.v1",
                rawArguments: [
                    "command": String(parsed.flags.contains("--command")),
                    "control": String(parsed.flags.contains("--control")),
                    "key": try required(parsed, "--key"),
                    "option": String(parsed.flags.contains("--option")),
                    "repeat": parsed.values["--repeat"] ?? "1",
                    "shift": String(parsed.flags.contains("--shift")),
                ],
                parsed: parsed,
                adapter: adapter
            )
        case "text.cursor":
            return try submit(
                commandID: "text.cursor",
                schemaID: "textCursor.v1",
                rawArguments: [
                    "count": parsed.values["--count"] ?? "1",
                    "move": try required(parsed, "--move"),
                    "select": String(parsed.flags.contains("--select")),
                ],
                parsed: parsed,
                adapter: adapter
            )
        case "text.clear", "text.inputSource.next":
            return try submit(
                commandID: invocation.commandID,
                schemaID: "optionalTarget.v1",
                rawArguments: [:],
                parsed: parsed,
                adapter: adapter
            )
        case "app.install":
            return try submit(
                commandID: "app.install",
                schemaID: "ipaPath.v1",
                rawArguments: [
                    "ipaPath": try absolutePath(required(parsed, "--path")),
                ],
                parsed: parsed,
                adapter: adapter
            )
        case "app.list":
            return try submit(
                commandID: "app.list",
                schemaID: "optionalTarget.v1",
                rawArguments: [:],
                parsed: parsed,
                adapter: adapter
            )
        case "app.launch", "app.uninstall":
            return try submit(
                commandID: invocation.commandID,
                schemaID: "bundleID.v1",
                rawArguments: [
                    "bundleID": try required(parsed, "--bundle-id"),
                ],
                parsed: parsed,
                adapter: adapter
            )
        case "button.appSwitcher", "button.home", "button.lock",
             "button.mute", "button.volumeDown", "button.volumeUp":
            return try submit(
                commandID: invocation.commandID,
                schemaID: "none.v1",
                rawArguments: [:],
                parsed: parsed,
                adapter: adapter
            )
        case "screenshot.cli":
            return try screenshot(parsed, adapter: adapter)
        case "element.snapshot":
            return try elementSnapshot(
                parsed,
                adapter: adapter,
                internalAnalyzers: internalAnalyzers
            )
        case "runtime.stop":
            return try runtimeStop(parsed, adapter: adapter)
        case "trace.start":
            return try directControl(
                commandID: "trace.start",
                operation: .runtimeStartReplayTrace,
                parsed: parsed,
                activation: .ensureRunning,
                adapter: adapter
            )
        case "trace.stop":
            return try directControl(
                commandID: "trace.stop",
                operation: .runtimeStopReplayTrace,
                parsed: parsed,
                activation: .existingOnly,
                adapter: adapter,
                absentCode: "noActiveTrace",
                allowDisconnectedExplicit: true
            )
        case "diagnostics.start":
            return try directControl(
                commandID: "diagnostics.start",
                operation: .runtimeStartDiagnostics,
                parsed: parsed,
                activation: .ensureRunning,
                adapter: adapter
            )
        case "diagnostics.stop":
            return try directControl(
                commandID: "diagnostics.stop",
                operation: .runtimeStopDiagnostics,
                parsed: parsed,
                activation: .existingOnly,
                adapter: adapter,
                absentCode: "noActiveDiagnostics",
                allowDisconnectedExplicit: true
            )
        case "logs.clear.all", "logs.clear.device":
            return try logsClear(parsed, adapter: adapter)
        case "logs.prune":
            return try logsPrune(adapter: adapter)
        default:
            throw CLIProcessError.invalidArguments
        }
    }

    private func submit(
        commandID: String,
        schemaID: String,
        rawArguments: [String: String],
        parsed: ParsedOptions,
        adapter: CLIOutputAdapter
    ) throws -> CLITerminalOutput {
        let target = try resolveTarget(parsed)
        let normalized = try ArgumentNormalizer.normalize(
            schemaID: schemaID,
            raw: rawArguments
        )
        let requestID = CanonicalUUID(value: UUID())
        let actionID = CanonicalUUID(value: UUID())
        let body = try object([
            ("actionID", .string(actionID.canonicalString)),
            ("canonicalUDID", .string(target.rawValue)),
            ("commandID", .string(commandID)),
            ("normalizedArguments", .object(try object(
                normalized.values.map { key, value in
                    (key, .string(Self.normalizedString(value)))
                }
            ))),
        ])
        let response: RepositoryJSONObject
        do {
            response = try runtimeRequest(
                .commandSubmit,
                target,
                body,
                .ensureRunning,
                requestID
            )
        } catch {
            return try backendFailure(
                error,
                commandID: commandID,
                target: .device(target),
                adapter: adapter
            )
        }
        return try renderRuntimeResult(
            response,
            commandID: commandID,
            target: .device(target),
            adapter: adapter
        )
    }

    private func screenshot(
        _ parsed: ParsedOptions,
        adapter: CLIOutputAdapter
    ) throws -> CLITerminalOutput {
        let target = try resolveTarget(parsed)
        let absoluteOutput = try absolutePath(required(parsed, "--output"))
        do {
            return try ScreenshotCommand(
                backend: ProductionCLIScreenshotBackend(
                    outputPath: absoluteOutput,
                    request: screenshotRequest
                ),
                fileSystem: ProductionAtomicOutputFileSystem()
            ).run(
                outputPath: absoluteOutput,
                currentDirectory: FileManager.default.currentDirectoryPath,
                force: parsed.flags.contains("--force"),
                requestID: CanonicalUUID(value: UUID()),
                actionID: CanonicalUUID(value: UUID()),
                tempID: CanonicalUUID(value: UUID()),
                canonicalUDID: target,
                outputMode: adapter.mode
            )
        } catch let error as CLIProductionBackendError {
            return try backendFailure(
                error,
                commandID: ScreenshotCommand.commandID,
                target: .device(target),
                adapter: adapter
            )
        } catch let error as RuntimeClientError {
            return try standardFailure(
                code: Self.runtimeErrorCode(error),
                commandID: ScreenshotCommand.commandID,
                target: .device(target),
                adapter: adapter
            )
        } catch let error as AtomicOutputFileError {
            let code: String = switch error {
            case .invalidArtifact: "artifactValidationFailed"
            case .localWriteFailed: "localWriteFailed"
            case .outputExists: "outputExists"
            case .timedOut: "timedOut"
            }
            return try standardFailure(
                code: code,
                commandID: ScreenshotCommand.commandID,
                target: .device(target),
                adapter: adapter
            )
        } catch is ScreenshotCommandError {
            return try standardFailure(
                code: "invalidOutputPath",
                commandID: ScreenshotCommand.commandID,
                target: .device(target),
                adapter: adapter
            )
        }
    }

    private func elementSnapshot(
        _ parsed: ParsedOptions,
        adapter: CLIOutputAdapter,
        internalAnalyzers: String?
    ) throws -> CLITerminalOutput {
        let format = parsed.values["--format"] ?? "json"
        guard ["annotated", "both", "json"].contains(format) else {
            throw CLIProcessError.invalidArguments
        }
        guard format != "annotated" || adapter.mode != .json else {
            throw CLIProcessError.invalidArguments
        }
        let target = try resolveTarget(parsed)
        let absoluteOutput: String?
        if let rawOutput = parsed.values["--output"] {
            do {
                absoluteOutput = try absolutePath(rawOutput)
            } catch {
                return try standardFailure(
                    code: "invalidOutputPath",
                    commandID: "element.snapshot",
                    target: .device(target),
                    adapter: adapter
                )
            }
        } else {
            absoluteOutput = nil
        }
        var rawArguments = [
            "force": String(parsed.flags.contains("--force")),
            "format": format,
        ]
        if let absoluteOutput { rawArguments["outputPath"] = absoluteOutput }
        let normalized: NormalizedArgumentsV1
        do {
            normalized = try ArgumentNormalizer.normalize(
                schemaID: "elementSnapshot.v1",
                raw: rawArguments
            )
        } catch ArgumentNormalizationError.invalid("outputPath"),
                ArgumentNormalizationError.tooLarge("outputPath") {
            return try standardFailure(
                code: "invalidOutputPath",
                commandID: "element.snapshot",
                target: .device(target),
                adapter: adapter
            )
        } catch ArgumentNormalizationError.missing("outputPath") {
            return try standardFailure(
                code: "invalidArgument",
                commandID: "element.snapshot",
                target: .device(target),
                adapter: adapter,
                message: "Invalid element snapshot arguments: format \(format) requires --output.",
                details: [
                    "argumentName": "--output",
                    "reason": "the selected annotation format requires an output path",
                ]
            )
        }
        guard let canonicalFormat = normalized.string("format") else {
            throw CLIProcessError.invalidArguments
        }
        let canonicalOutput = normalized.string("outputPath")
        let fileSystem = ProductionAtomicOutputFileSystem()
        let outputPlan: AtomicOutputFilePlan?
        if let canonicalOutput {
            do {
                outputPlan = try AtomicOutputFile.preflight(
                    absoluteOutputPath: canonicalOutput,
                    force: parsed.flags.contains("--force"),
                    fileSystem: fileSystem
                )
            } catch {
                return try elementAtomicOutputFailure(
                    error,
                    target: target,
                    adapter: adapter
                )
            }
        } else {
            outputPlan = nil
        }

        let response: RuntimeClientElementSnapshotResponse
        do {
            response = try elementSnapshotRequest(
                CanonicalUUID(value: UUID()),
                CanonicalUUID(value: UUID()),
                target,
                canonicalFormat,
                internalAnalyzers
            )
        } catch {
            return try backendFailure(
                error,
                commandID: "element.snapshot",
                target: .device(target),
                adapter: adapter
            )
        }
        guard response.result["outcome"]?.stringValue == "succeeded" else {
            return try renderRuntimeResult(
                response.result,
                commandID: "element.snapshot",
                target: .device(target),
                adapter: adapter
            )
        }
        let projectedResponse: RepositoryJSONObject
        let projectedTerminal: CLITerminalOutput?
        if canonicalFormat == "both", let canonicalOutput {
            projectedResponse = try Self.addingElementOutputPath(
                canonicalOutput,
                to: response.result
            )
            projectedTerminal = try renderRuntimeResult(
                projectedResponse,
                commandID: "element.snapshot",
                target: .device(target),
                adapter: adapter
            )
        } else {
            projectedResponse = response.result
            projectedTerminal = nil
        }
        if let outputPlan {
            guard let annotation = response.annotation else {
                return try standardFailure(
                    code: "artifactValidationFailed",
                    commandID: "element.snapshot",
                    target: .device(target),
                    adapter: adapter
                )
            }
            do {
                try AtomicOutputFile.write(
                    plan: outputPlan,
                    artifact: annotation.artifact,
                    tempID: CanonicalUUID(value: UUID()),
                    fileSystem: fileSystem
                )
            } catch {
                return try elementAtomicOutputFailure(
                    error,
                    target: target,
                    adapter: adapter
                )
            }
        }
        if canonicalFormat == "annotated" {
            return CLITerminalOutput(chunk: CLIOutputChunk(), exitCode: 0)
        }
        if let projectedTerminal { return projectedTerminal }
        return try renderRuntimeResult(
            projectedResponse,
            commandID: "element.snapshot",
            target: .device(target),
            adapter: adapter
        )
    }

    private func elementAtomicOutputFailure(
        _ error: Error,
        target: CanonicalUDID,
        adapter: CLIOutputAdapter
    ) throws -> CLITerminalOutput {
        let code: String
        switch error as? AtomicOutputFileError {
        case .invalidArtifact: code = "artifactValidationFailed"
        case .localWriteFailed: code = "localWriteFailed"
        case .outputExists: code = "outputExists"
        case .timedOut: code = "timedOut"
        case .none: code = "localWriteFailed"
        }
        return try standardFailure(
            code: code,
            commandID: "element.snapshot",
            target: .device(target),
            adapter: adapter
        )
    }

    private func directControl(
        commandID: String,
        operation: RuntimeOperationID,
        parsed: ParsedOptions,
        activation: RuntimeClientActivation,
        adapter: CLIOutputAdapter,
        absentCode: String? = nil,
        allowDisconnectedExplicit: Bool = false
    ) throws -> CLITerminalOutput {
        let target = try resolveTarget(
            parsed,
            allowDisconnectedExplicit: allowDisconnectedExplicit
        )
        var members: [(String, RepositoryJSONValue)] = [
            ("canonicalUDID", .string(target.rawValue)),
        ]
        if operation == .runtimePrepareCapabilities {
            members.append(("mode", .string("waitForTerminal")))
        }
        let body = try object(members)
        do {
            let response = try runtimeRequest(
                operation,
                target,
                body,
                activation,
                CanonicalUUID(value: UUID())
            )
            return try renderRuntimeResult(
                response,
                commandID: commandID,
                target: .device(target),
                adapter: adapter
            )
        } catch let RuntimeClientError.socketUnavailable(errno) {
            guard case .existingOnly = activation, let absentCode else {
                return try backendFailure(
                    RuntimeClientError.socketUnavailable(errno: errno),
                    commandID: commandID,
                    target: .device(target),
                    adapter: adapter
                )
            }
            return try standardFailure(
                code: absentCode,
                commandID: commandID,
                target: .device(target),
                adapter: adapter
            )
        } catch {
            return try backendFailure(
                error,
                commandID: commandID,
                target: .device(target),
                adapter: adapter
            )
        }
    }

    private func runtimeStatus(
        _ parsed: ParsedOptions,
        adapter: CLIOutputAdapter
    ) throws -> CLITerminalOutput {
        if let requested = parsed.values["--udid"] {
            let target = try CanonicalUDID(canonicalString: requested)
            let state = try runtimeStatusState(for: target)
            return try adapter.success(
                commandID: "runtime.status.device",
                target: .device(target),
                result: RuntimeStatusResult(
                    targets: [.init(canonicalUDID: target.rawValue, state: state)],
                    truncated: false
                ),
                human: "\(target.rawValue): \(state)"
            )
        }
        let devices = try makeQueries().devices().devices
        let targets = try devices.prefix(256).map { device in
            RuntimeStatusTarget(
                canonicalUDID: device.canonicalUDID.rawValue,
                state: try runtimeStatusState(for: device.canonicalUDID)
            )
        }
        return try adapter.success(
            commandID: "runtime.status.global",
            target: .global,
            result: RuntimeStatusResult(
                targets: targets,
                truncated: devices.count > 256
            ),
            human: targets.map { "\($0.canonicalUDID): \($0.state)" }
                .joined(separator: "\n")
        )
    }

    private func runtimeStatusState(for target: CanonicalUDID) throws -> String {
        do {
            let body = try object([
                ("canonicalUDID", .string(target.rawValue)),
            ])
            let response = try runtimeRequest(
                .runtimeRuntimeStatus,
                target,
                body,
                .existingOnly,
                CanonicalUUID(value: UUID())
            )
            guard response["outcome"]?.stringValue == StandardOutcome.succeeded.rawValue
            else {
                let code = response["error"]?.objectValue?["code"]?.stringValue
                    ?? "runtimeFailed"
                return "failed:\(code)"
            }
            return "full"
        } catch RuntimeClientError.socketUnavailable {
            return "notRunning"
        }
    }

    private func runtimeStop(
        _ parsed: ParsedOptions,
        adapter: CLIOutputAdapter
    ) throws -> CLITerminalOutput {
        let target = try resolveStopTarget(parsed)
        if let productionRuntimeStop {
            do {
                return try productionRuntimeStop(target, adapter.mode)
            } catch let error as RuntimeStopCommandError {
                let code: String
                switch error {
                case .runtimeBlocked:
                    code = "controlBusy"
                case .socketDidNotClose, .runtimeLockStillBusy:
                    code = "timedOut"
                case .generationBusy(.exiting):
                    code = "runtimeStopping"
                case .generationBusy:
                    code = "runtimeFailed"
                }
                return try standardFailure(
                    code: code,
                    commandID: "runtime.stop",
                    target: .device(target),
                    adapter: adapter,
                    message: String(describing: error)
                )
            } catch let error as ProductionRuntimeStopBackendError {
                let code: String
                switch error {
                case .runtimeRequestFailed(let requestCode):
                    code = requestCode
                case .invalidState:
                    code = "runtimeFailed"
                }
                return try standardFailure(
                    code: code,
                    commandID: "runtime.stop",
                    target: .device(target),
                    adapter: adapter,
                    message: String(describing: error)
                )
            } catch {
                return try backendFailure(
                    error,
                    commandID: "runtime.stop",
                    target: .device(target),
                    adapter: adapter
                )
            }
        }
        let body = try object([
            ("canonicalUDID", .string(target.rawValue)),
        ])
        do {
            let response = try runtimeRequest(
                .runtimeStopIfIdle,
                target,
                body,
                .existingOnly,
                CanonicalUUID(value: UUID())
            )
            guard response["outcome"]?.stringValue == StandardOutcome.succeeded.rawValue
            else {
                return try renderRuntimeResult(
                    response,
                    commandID: "runtime.stop",
                    target: .device(target),
                    adapter: adapter
                )
            }
            return try adapter.success(
                commandID: "runtime.stop",
                target: .device(target),
                result: RuntimeStopResult(
                    disposition: "stopped",
                    stoppedTargetCount: 1
                ),
                human: "Stopped"
            )
        } catch RuntimeClientError.socketUnavailable {
            return try adapter.success(
                commandID: "runtime.stop",
                target: .device(target),
                result: RuntimeStopResult(
                    disposition: "alreadyStopped",
                    stoppedTargetCount: 0
                ),
                human: "Already stopped"
            )
        } catch {
            return try backendFailure(
                error,
                commandID: "runtime.stop",
                target: .device(target),
                adapter: adapter
            )
        }
    }

    private func logsClear(
        _ parsed: ParsedOptions,
        adapter: CLIOutputAdapter
    ) throws -> CLITerminalOutput {
        guard !(parsed.flags.contains("--all") && parsed.values["--udid"] != nil) else {
            throw CLIProcessError.invalidArguments
        }
        guard !parsed.flags.contains("--all") else {
            return try logsClearAll(adapter: adapter)
        }
        let target = try resolveTarget(parsed, allowDisconnectedExplicit: true)
        let body = try object([
            ("canonicalUDID", .string(target.rawValue)),
        ])
        do {
            let response = try runtimeRequest(
                .runtimeClearActionLogs,
                target,
                body,
                .existingOnly,
                CanonicalUUID(value: UUID())
            )
            return try renderRuntimeResult(
                response,
                commandID: "logs.clear.device",
                target: .device(target),
                adapter: adapter
            )
        } catch RuntimeClientError.socketUnavailable {
            do {
                return try LogsClearCommand.runProductionDevice(
                    canonicalUDID: target,
                    maintenance: makeActionLogMaintenance(),
                    outputMode: adapter.mode
                )
            } catch {
                return try actionLogMaintenanceFailure(
                    error,
                    commandID: "logs.clear.device",
                    target: .device(target),
                    adapter: adapter
                )
            }
        } catch {
            return try backendFailure(
                error,
                commandID: "logs.clear.device",
                target: .device(target),
                adapter: adapter
            )
        }
    }

    private func logsPrune(
        adapter: CLIOutputAdapter
    ) throws -> CLITerminalOutput {
        do {
            return try LogsPruneCommand.runProduction(
                maintenance: makeActionLogMaintenance(),
                outputMode: adapter.mode
            )
        } catch {
            return try actionLogMaintenanceFailure(
                error,
                commandID: "logs.prune",
                target: .global,
                adapter: adapter
            )
        }
    }

    private func logsClearAll(
        adapter: CLIOutputAdapter
    ) throws -> CLITerminalOutput {
        let targets: [CanonicalUDID]
        do {
            targets = try LogsClearCommand.fixedTargetSnapshot(
                makeQueries().devices().devices.map(\.canonicalUDID)
            )
        } catch LogsClearError.targetLimitExceeded {
            return try standardFailure(
                code: "aggregateTargetLimitExceeded",
                commandID: "logs.clear.all",
                target: .global,
                adapter: adapter
            )
        }

        var runtimeFailed = 0
        var runtimeUnknown = 0
        for target in targets {
            let body = try object([
                ("canonicalUDID", .string(target.rawValue)),
            ])
            do {
                let response = try runtimeRequest(
                    .runtimeClearActionLogs,
                    target,
                    body,
                    .existingOnly,
                    CanonicalUUID(value: UUID())
                )
                switch response["outcome"]?.stringValue {
                case StandardOutcome.succeeded.rawValue:
                    break
                case StandardOutcome.outcomeUnknown.rawValue:
                    runtimeUnknown += 1
                default:
                    runtimeFailed += 1
                }
            } catch RuntimeClientError.socketUnavailable {
                continue
            } catch {
                runtimeFailed += 1
            }
        }

        let local: ActionLogMaintenanceResult
        do {
            local = try makeActionLogMaintenance().clearAll()
        } catch {
            return try actionLogMaintenanceFailure(
                error,
                commandID: "logs.clear.all",
                target: .global,
                adapter: adapter
            )
        }
        if runtimeUnknown > 0 {
            return try standardFailure(
                code: "outcomeUnknown",
                commandID: "logs.clear.all",
                target: .global,
                adapter: adapter,
                message: "Runtime outcomes unknown=\(runtimeUnknown); "
                    + LogsPruneCommand.humanSummary(local)
            )
        }
        if runtimeFailed > 0 {
            return try standardFailure(
                code: "partialFailure",
                commandID: "logs.clear.all",
                target: .global,
                adapter: adapter,
                message: "Runtime failures=\(runtimeFailed); "
                    + LogsPruneCommand.humanSummary(local)
            )
        }
        return try renderProductionLogMaintenance(
            commandID: "logs.clear.all",
            target: .global,
            result: local,
            outputMode: adapter.mode
        )
    }

    private func actionLogMaintenanceFailure(
        _ error: Error,
        commandID: String,
        target: CLIOutputTarget,
        adapter: CLIOutputAdapter
    ) throws -> CLITerminalOutput {
        if let error = error as? CLIProductionBackendError {
            return try backendFailure(
                error,
                commandID: commandID,
                target: target,
                adapter: adapter
            )
        }
        guard let maintenanceError = error as? ProductionActionLogMaintenanceError else {
            throw error
        }
        let code: String
        switch maintenanceError {
        case .maintenanceBusy:
            code = "resourceBusy"
        case .unsafeHostPath:
            code = "unsafeHostPath"
        case .systemCall:
            code = "localWriteFailed"
        }
        return try standardFailure(
            code: code,
            commandID: commandID,
            target: target,
            adapter: adapter
        )
    }

    private func renderRuntimeResult(
        _ response: RepositoryJSONObject,
        commandID: String,
        target: CLIOutputTarget,
        adapter: CLIOutputAdapter
    ) throws -> CLITerminalOutput {
        let outcome = response["outcome"]?.stringValue
        guard outcome == StandardOutcome.succeeded.rawValue else {
            let error = response["error"]?.objectValue
            let code = error?["code"]?.stringValue
                ?? (outcome == StandardOutcome.outcomeUnknown.rawValue
                    ? "outcomeUnknown"
                    : "runtimeFailed")
            return try standardFailure(
                code: code,
                commandID: commandID,
                target: target,
                adapter: adapter,
                details: Self.stringDetails(error?["details"]?.objectValue)
            )
        }
        let value: RepositoryJSONValue
        if let responseValue = response["value"] {
            value = responseValue
        } else {
            value = .object(try object([]))
        }
        if commandID == "app.list" {
            guard let result = AppListCommandResult(repositoryValue: value) else {
                return try standardFailure(
                    code: "backendFailed",
                    commandID: commandID,
                    target: target,
                    adapter: adapter,
                    details: ["stage": "resultNormalize"]
                )
            }
            return try adapter.success(
                commandID: commandID,
                target: target,
                result: result,
                human: result.humanTable
            )
        }
        let human: String
        if commandID == "device.rotate",
           case .object(let object) = value,
           let direction = object["direction"]?.stringValue
        {
            human = Self.rotateHumanStatus(value: object, fallbackDirection: direction)
        } else if commandID == "text.key" {
            human = "Key macro dispatched"
        } else if commandID == "text.cursor" {
            human = "Cursor macro dispatched"
        } else if commandID == "text.clear" {
            human = "Clear macro dispatched"
        } else if commandID == "text.inputSource.next" {
            human = "Input-source cycle dispatched"
        } else {
            human = "\(commandID) succeeded"
        }
        return try adapter.success(
            commandID: commandID,
            target: target,
            result: try JSONValue(value),
            human: human
        )
    }

    private static func rotateHumanStatus(
        value: RepositoryJSONObject,
        fallbackDirection: String
    ) -> String {
        guard let orientationText = value["currentDisplayOrientation"]?.stringValue,
              let orientation = DisplayOrientationDTO(rawValue: orientationText)
        else {
            return "Completed one \(fallbackDirection) quarter-turn"
        }
        if case .bool(true)? = value["visibleOrientationConfirmed"] {
            return "Rotated to \(orientationStatusText(orientation))"
        }
        if case .bool(true)? = value["displayOrientationChanged"] {
            return "Visible direction is \(orientationStatusText(orientation))"
        }
        return "No visible rotation; current direction is \(orientationStatusText(orientation))"
    }

    private static func orientationStatusText(
        _ orientation: DisplayOrientationDTO
    ) -> String {
        switch orientation {
        case .portrait:
            return "Portrait"
        case .portraitUpsideDown:
            return "Portrait Upside Down"
        case .landscapeLeft:
            return "Landscape Left"
        case .landscapeRight:
            return "Landscape Right"
        }
    }

    private func mappedFailure(
        _ error: Error,
        invocation: CLIInvocation,
        adapter: CLIOutputAdapter,
        target explicitTarget: CLIOutputTarget? = nil
    ) -> CLITerminalOutput {
        let commandID = invocation.commandID
        let target = explicitTarget ?? unresolvedTarget(invocation.arguments)
        do {
            switch error {
            case let error as CLIProductionBackendError:
                switch error {
                case .standard(let code, let message, let details):
                    return try standardFailure(
                        code: code,
                        commandID: commandID,
                        target: target,
                        adapter: adapter,
                        message: message,
                        details: details
                    )
                }
            case let error as RuntimeClientError:
                return try standardFailure(
                    code: Self.runtimeErrorCode(error),
                    commandID: commandID,
                    target: target,
                    adapter: adapter
                )
            case let error as AgentSkillError:
                return try standardFailure(
                    code: error.cliCode,
                    commandID: commandID,
                    target: target,
                    adapter: adapter,
                    message: error.description
                )
            case let error as SelfInstallError:
                return try standardFailure(
                    code: error.cliCode,
                    commandID: commandID,
                    target: target,
                    adapter: adapter,
                    message: error.description
                )
            case let error as DynamicDeveloperImageCatalogStoreError:
                return try standardFailure(
                    code: Self.developerImageCatalogErrorCode(error),
                    commandID: commandID,
                    target: target,
                    adapter: adapter
                )
            case LocalDeviceQueryError.noDeviceConnected:
                return try standardFailure(
                    code: "noDeviceConnected",
                    commandID: commandID,
                    target: target,
                    adapter: adapter
                )
            case LocalDeviceQueryError.deviceNotFound:
                return try standardFailure(
                    code: "deviceNotFound",
                    commandID: commandID,
                    target: target,
                    adapter: adapter
                )
            case let LocalDeviceFactsProbeError.remoteFailure(code):
                return try standardFailure(
                    code: code,
                    commandID: commandID,
                    target: target,
                    adapter: adapter
                )
            case LocalDeviceFactsProbeError.workTimeout:
                return try standardFailure(
                    code: "probeUnavailable",
                    commandID: commandID,
                    target: target,
                    adapter: adapter,
                    details: ["reason": "timeout"]
                )
            case is CanonicalUDIDError:
                return try standardFailure(
                    code: "invalidUDID",
                    commandID: commandID,
                    target: target,
                    adapter: adapter
                )
            case let error as ArgumentNormalizationError:
                let failure = Self.normalizationArgumentFailure(
                    error,
                    commandID: commandID
                )
                return try standardFailure(
                    code: failure.code,
                    commandID: commandID,
                    target: target,
                    adapter: adapter,
                    message: failure.message,
                    details: failure.details
                )
            case let error as CLIOptionParserError:
                let failure = Self.optionParserArgumentFailure(error)
                return try standardFailure(
                    code: "invalidArgument",
                    commandID: commandID,
                    target: target,
                    adapter: adapter,
                    message: failure.message,
                    details: failure.details
                )
            case CLIProcessError.invalidArguments:
                return try standardFailure(
                    code: "invalidArgument",
                    commandID: commandID,
                    target: target,
                    adapter: adapter,
                    message: "Invalid command arguments; run the command help and correct the reported option.",
                    details: [
                        "argumentName": "command arguments",
                        "reason": "command arguments do not satisfy the command contract",
                    ]
                )
            default:
                return try standardFailure(
                    code: "internalFailure",
                    commandID: commandID,
                    target: target,
                    adapter: adapter,
                    message: String(describing: error)
                )
            }
        } catch {
            return CLITerminalOutput(
                chunk: CLIOutputChunk(stderr: ["internalFailure"]),
                exitCode: ErrorFamily.internal.exitCode
            )
        }
    }

    private static func normalizationArgumentFailure(
        _ error: ArgumentNormalizationError,
        commandID: String
    ) -> ArgumentFailureProjection {
        let key: String
        let kind: ArgumentFailureKind
        switch error {
        case .unexpectedKeys:
            return ArgumentFailureProjection(
                code: "invalidArgument",
                message: "Unsupported command option; run the command help and remove the unknown or duplicate option.",
                details: [
                    "argumentName": "command options",
                    "reason": "the supplied option set does not match the command contract",
                ]
            )
        case .missing(let value):
            key = value
            kind = .missing
        case .invalid(let value):
            key = value
            kind = .invalid
        case .tooLarge(let value):
            key = value
            kind = .tooLarge
        }

        let argumentName = publicArgumentName(key: key, commandID: commandID)
        let baseKey = key.split(separator: ".", maxSplits: 1).first.map(String.init) ?? key
        let code: String
        if ["point", "from", "to"].contains(baseKey) {
            code = "invalidCoordinate"
        } else if baseKey == "durationMs" {
            code = "invalidDuration"
        } else if baseKey == "bundleID" {
            code = "invalidBundleID"
        } else if baseKey == "ipaPath" {
            code = "invalidIPAPath"
        } else if baseKey == "outputPath" {
            code = "invalidOutputPath"
        } else if kind == .tooLarge {
            code = "argumentTooLarge"
        } else {
            code = "invalidArgument"
        }

        let reason: String
        let suggestion: String?
        if ["point", "from", "to"].contains(baseKey) {
            switch kind {
            case .invalid:
                reason = "must be a finite ASCII decimal in the inclusive range [0, 1]; trailing zeros are allowed"
                suggestion = "Use a normalized decimal such as 0.4 or 0.40"
            case .missing:
                reason = "a required coordinate value is missing"
                suggestion = "Provide both coordinate components"
            case .tooLarge:
                reason = "exceeds the maximum size allowed by the command contract"
                suggestion = nil
            }
        } else {
            switch kind {
            case .invalid where baseKey == "durationMs":
                reason = "must be an integer in the inclusive range 1...30000 milliseconds"
                suggestion = "Use a whole number such as 300"
            case .missing:
                reason = "a required value is missing"
                suggestion = "Provide the option value shown by command help"
            case .tooLarge:
                reason = "exceeds the maximum size allowed by the command contract"
                suggestion = nil
            default:
                reason = "does not satisfy the command input contract"
                suggestion = "Use the value format shown by command help"
            }
        }

        let details = [
            "argumentName": argumentName,
            "reason": reason,
        ]
        let message = suggestion.map {
            "Invalid value for \(argumentName): \(reason). \($0)."
        } ?? "Invalid value for \(argumentName): \(reason)."
        return ArgumentFailureProjection(code: code, message: message, details: details)
    }

    private static func optionParserArgumentFailure(
        _ error: CLIOptionParserError
    ) -> ArgumentFailureProjection {
        let option: String
        let reason: String
        switch error {
        case .duplicateFlag(let value):
            option = value
            reason = "the option was supplied more than once"
        case .duplicateOrMissingValue(let value):
            option = value
            reason = "the option requires exactly one value and must not be repeated"
        case .missingRequiredOption(let value):
            option = value
            reason = "the required option is missing"
        case .unknownOption(let value):
            option = value
            reason = "the option is not supported by this command"
        }
        return ArgumentFailureProjection(
            code: "invalidArgument",
            message: "Invalid option \(option): \(reason). Run the command help for the accepted options.",
            details: ["argumentName": option, "reason": reason]
        )
    }

    private static func preflightArgumentFailure(
        _ error: CLIArgumentPreflightError
    ) -> ArgumentFailureProjection {
        let reason: String
        let message: String
        let argumentName: String
        switch error {
        case .duplicateJSONFlag:
            argumentName = "--json"
            reason = "the flag may be supplied at most once"
            message = "Invalid option --json: \(reason)."
        case .invalidInternalAnalyzers:
            argumentName = "analyzer selection"
            reason = "the analyzer selection is not supported"
            message = "Invalid analyzer selection; use the choices shown by command help."
        case .verboseUnsupported:
            argumentName = "--verbose"
            reason = "the option is not supported"
            message = "Invalid option --verbose: \(reason)."
        case .missingCommand:
            argumentName = "command"
            reason = "a command is required"
            message = "Missing command; run PulsePhone --help to list commands."
        case .unknownCommand(let value):
            argumentName = "command"
            reason = "the command is not supported"
            message = "Unknown command \(value); run PulsePhone --help to list commands."
        }
        return ArgumentFailureProjection(
            code: "invalidArgument",
            message: message,
            details: ["argumentName": argumentName, "reason": reason]
        )
    }

    private static func publicArgumentName(key: String, commandID: String) -> String {
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        let base = parts.first ?? key
        let component = parts.count == 2 ? parts[1] : nil
        switch base {
        case "point":
            if commandID == "touch.tap", let component { return "--\(component)" }
            return "--x/--y"
        case "from":
            return "--from"
        case "to":
            return "--to"
        case "durationMs":
            return "--duration"
        case "bundleID":
            return "--bundle-id"
        case "ipaPath":
            return "--path"
        case "outputPath":
            return "--output"
        default:
            return key.hasPrefix("--") ? key : "--\(key)"
        }
    }

    private func standardFailure(
        code: String,
        commandID: String?,
        target: CLIOutputTarget,
        adapter: CLIOutputAdapter,
        message: String? = nil,
        details: [String: String]? = nil
    ) throws -> CLITerminalOutput {
        let renderedMessage: String?
        if code == "capabilityPreparing",
           details?["remediation"] == "runDevicePrepare"
        {
            let reason = details?["reason"]
            switch reason {
            case "developerSupportNotMounted":
                renderedMessage = "Developer Support is not mounted on the target device. Run PulsePhone device prepare, then retry the command. The command was not executed."
            case "serviceWarmupFailed":
                renderedMessage = "Developer Support is mounted, but the required device service is unavailable. Run PulsePhone device prepare, then retry the command. The command was not executed."
            case "mountedStateCheckFailed", "connectionEpochChanged":
                renderedMessage = "Developer Support readiness could not be verified for the current device connection. Run PulsePhone device prepare, then retry the command. The command was not executed."
            default:
                renderedMessage = "Developer Support preparation is required. Run PulsePhone device prepare, then retry the command. The command was not executed."
            }
        } else {
            renderedMessage = message
        }
        guard let descriptor = GeneratedStandardErrorRegistry.descriptors.first(where: {
            $0.code.rawValue == code
        }) else {
            return try adapter.failure(
                family: .internal,
                commandID: commandID,
                target: target,
                error: CLIErrorPayload(
                    code: "internalFailure",
                    message: renderedMessage ?? "Unregistered error code: \(code)"
                )
            )
        }
        return try adapter.failure(
            family: descriptor.family,
            commandID: commandID,
            target: target,
            error: CLIErrorPayload(
                code: code,
                details: details,
                message: renderedMessage ?? descriptor.defaultMessage
            ),
            metadata: CLIOutputMetadata(
                runtimeMayContinue: ["runtimeMayContinue", "runtimeStateUnknown"]
                    .contains(descriptor.clientContinuationProjectionPolicy)
                    ? true
                    : nil
            )
        )
    }

    private static func stringDetails(
        _ object: RepositoryJSONObject?
    ) -> [String: String]? {
        guard let object else { return nil }
        var values = [String: String]()
        for member in object.members {
            guard let value = member.value.stringValue else { return nil }
            values[member.key] = value
        }
        return values.isEmpty ? nil : values
    }

    private func backendFailure(
        _ error: Error,
        commandID: String,
        target: CLIOutputTarget,
        adapter: CLIOutputAdapter
    ) throws -> CLITerminalOutput {
        if let error = error as? CLIProductionBackendError {
            switch error {
            case .standard(let code, let message, let details):
                return try standardFailure(
                    code: code,
                    commandID: commandID,
                    target: target,
                    adapter: adapter,
                    message: message,
                    details: details
                )
            }
        }
        if let error = error as? RuntimeClientError {
            return try standardFailure(
                code: Self.runtimeErrorCode(error),
                commandID: commandID,
                target: target,
                adapter: adapter
            )
        }
        throw error
    }

    private func developerImageServicesReady(
        target: CanonicalUDID,
        osVersion: String
    ) -> Bool {
        let requiredCommands: [String]
        if let major = UInt64(osVersion.split(separator: ".").first ?? ""), major >= 17 {
            requiredCommands = ["button.home", "text.key", "screenshot.cli"]
        } else {
            requiredCommands = ["app.launch", "screenshot.cli"]
        }
        guard let body = try? object([
            ("canonicalUDID", .string(target.rawValue)),
        ]), let response = try? runtimeRequest(
            .runtimeGetAvailabilitySnapshot,
            target,
            body,
            .existingOnly,
            CanonicalUUID(value: UUID())
        ), response["outcome"]?.stringValue == StandardOutcome.succeeded.rawValue,
          let commands = response["value"]?.objectValue?["commands"]?.arrayValue
        else { return false }
        let states: [String: String] = Dictionary(uniqueKeysWithValues: commands.compactMap { entry in
            guard let object = entry.objectValue,
              let commandID = object["commandID"]?.stringValue,
              let state = object["state"]?.stringValue
            else { return nil }
            return (commandID, state)
        })
        return requiredCommands.allSatisfy { states[$0] == "enabled" }
    }

    private func developerImageListHuman(
        _ result: DynamicDeveloperImageSupportListResult
    ) -> String {
        let prefix = "Catalog \(result.catalogRevision)"
        let records = result.records.map { record in
            let identity = record.buildID ?? record.iosVersion ?? "unmapped"
            return "\(record.route.rawValue) \(identity): \(record.mappingStatus.rawValue), \(record.selectedAssetID), \(record.state.rawValue)"
        }
        let candidate = "default personalized candidate: \(result.defaultCandidate.selectedAssetID), \(result.defaultCandidate.state.rawValue)"
        return ([prefix] + records + [candidate]).joined(separator: "\n")
    }

    private func developerImageCheckHuman(
        _ result: DynamicDeveloperImageCheckResult
    ) -> String {
        var lines = [
            "Status: \(result.status.rawValue)",
            "iOS: \(result.iosVersion) (\(result.buildID))",
        ]
        if let route = result.route { lines.append("Route: \(route.rawValue)") }
        if let asset = result.selectedAssetID { lines.append("Asset: \(asset)") }
        lines.append("Next: \(result.nextStep)")
        return lines.joined(separator: "\n")
    }

    private static func developerImageCatalogErrorCode(
        _ error: DynamicDeveloperImageCatalogStoreError
    ) -> String {
        switch error {
        case .candidateIncompatible:
            return "developerImageCandidateIncompatible"
        case .catalogMismatch, .sourceRejected:
            return "developerImageCatalogMismatch"
        case .catalogUnavailable, .networkUnavailable:
            return "developerImageCatalogUnavailable"
        }
    }

    private func resolveTarget(
        _ parsed: ParsedOptions,
        allowDisconnectedExplicit: Bool = false
    ) throws -> CanonicalUDID {
        if let requested = parsed.values["--udid"] {
            let target = try CanonicalUDID(canonicalString: requested)
            if allowDisconnectedExplicit {
                return target
            }
            return try makeQueries().deviceInfo(canonicalUDID: target).canonicalUDID
        }
        return try makeQueries().deviceInfo().canonicalUDID
    }

    private func resolveStopTarget(
        _ parsed: ParsedOptions
    ) throws -> CanonicalUDID {
        if let requested = parsed.values["--udid"] {
            return try CanonicalUDID(canonicalString: requested)
        }
        let clock = SystemMonotonicClock()
        let deadline = try clock.now().advanced(
            by: MonotonicDuration(nanoseconds: 10_000_000_000)
        )
        while true {
            do {
                return try makeQueries().deviceInfo().canonicalUDID
            } catch LocalDeviceFactsProbeError.remoteFailure(
                code: "deviceNotFound"
            ) {
                guard clock.now() < deadline else {
                    throw LocalDeviceFactsProbeError.remoteFailure(
                        code: "deviceNotFound"
                    )
                }
                usleep(100_000)
            }
        }
    }

    private func parseTargetOnly(_ parsed: ParsedOptions) throws -> CanonicalUDID? {
        return try parsed.values["--udid"].map(CanonicalUDID.init(canonicalString:))
    }

    private func parseOptions(
        _ invocation: CLIInvocation
    ) throws -> ParsedOptions {
        let options = Dictionary(
            uniqueKeysWithValues: invocation.options.map { ($0.spelling, $0) }
        )
        var parsedValues = [String: String]()
        var repeatedValues = [String: [String]]()
        var parsedFlags = Set<String>()
        var index = 0
        while index < invocation.arguments.count {
            let spelling = invocation.arguments[index]
            guard let option = options[spelling] else {
                throw CLIOptionParserError.unknownOption(spelling)
            }
            if option.valueName != nil {
                guard invocation.arguments.indices.contains(index + 1),
                      option.repeatable || repeatedValues[spelling] == nil else {
                    throw CLIOptionParserError.duplicateOrMissingValue(spelling)
                }
                let value = invocation.arguments[index + 1]
                repeatedValues[spelling, default: []].append(value)
                if parsedValues[spelling] == nil { parsedValues[spelling] = value }
                index += 2
            } else {
                guard parsedFlags.insert(spelling).inserted else {
                    throw CLIOptionParserError.duplicateFlag(spelling)
                }
                index += 1
            }
        }
        for option in invocation.options where option.required {
            let present = option.valueName == nil
                ? parsedFlags.contains(option.spelling)
                : parsedValues[option.spelling] != nil
            guard present else {
                throw CLIOptionParserError.missingRequiredOption(option.spelling)
            }
        }
        return ParsedOptions(
            values: parsedValues,
            repeatedValues: repeatedValues,
            flags: parsedFlags
        )
    }

    private func required(_ parsed: ParsedOptions, _ key: String) throws -> String {
        guard let value = parsed.values[key] else {
            throw CLIOptionParserError.missingRequiredOption(key)
        }
        return value
    }

    private func absolutePath(_ path: String) throws -> String {
        guard !path.isEmpty, !path.utf8.contains(0) else {
            throw CLIProcessError.invalidArguments
        }
        let raw = path.hasPrefix("/")
            ? path
            : FileManager.default.currentDirectoryPath + "/" + path
        let standardized = (raw as NSString).standardizingPath
        guard standardized.hasPrefix("/") else {
            throw CLIProcessError.invalidArguments
        }
        return standardized
    }

    private func unresolvedTarget(_ arguments: [String]) -> CLIOutputTarget {
        .unresolved(requestedUDID: requestedUDID(in: arguments))
    }

    private func requestedUDID(in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--udid"),
              arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return arguments[index + 1]
    }

    private func fallbackFailure(
        adapter: CLIOutputAdapter,
        family: ErrorFamily,
        commandToken: String?,
        code: String,
        message: String,
        details: [String: String]? = nil
    ) -> CLITerminalOutput {
        (try? adapter.failure(
            family: family,
            commandToken: commandToken,
            target: .unresolved(requestedUDID: nil),
            error: CLIErrorPayload(code: code, details: details, message: message)
        )) ?? CLITerminalOutput(
            chunk: CLIOutputChunk(stderr: [code]),
            exitCode: family.exitCode
        )
    }

    private func object(
        _ members: [(String, RepositoryJSONValue)]
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: members.map {
            RepositoryJSONMember(key: $0.0, value: $0.1)
        })
    }

    private static func makeObject(
        _ members: [(String, RepositoryJSONValue)]
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: members.map {
            RepositoryJSONMember(key: $0.0, value: $0.1)
        })
    }

    private static func elementSnapshotArguments(
        format: String,
        internalAnalyzers: String?
    ) throws -> RepositoryJSONObject {
        var members: [(String, RepositoryJSONValue)] = [
            ("format", .string(format)),
        ]
        if let internalAnalyzers {
            members.append((
                "internalAnalyzers",
                .string(internalAnalyzers)
            ))
        }
        return try makeObject(members)
    }

    private static func extractInternalAnalyzerSelection(
        from arguments: [String]
    ) throws -> (publicArguments: [String], canonicalValue: String?) {
        let option = "--internal-analyzers"
        let indices = arguments.indices.filter { arguments[$0] == option }
        guard !indices.isEmpty else { return (arguments, nil) }
        let commandArguments = arguments.filter { $0 != "--json" }
        guard indices.count == 1,
              commandArguments.count >= 2,
              commandArguments[0] == "element",
              commandArguments[1] == "snapshot",
              let index = indices.first,
              arguments.indices.contains(index + 1)
        else {
            throw CLIArgumentPreflightError.invalidInternalAnalyzers
        }
        let tokens = arguments[index + 1].split(
            separator: ",",
            omittingEmptySubsequences: false
        ).map(String.init)
        let allowed = Set(["apple", "omni", "vision"])
        guard !tokens.isEmpty,
              tokens.allSatisfy({ allowed.contains($0) })
        else {
            throw CLIArgumentPreflightError.invalidInternalAnalyzers
        }
        let selected = Set(tokens)
        let canonical = ["omni", "vision", "apple"]
            .filter(selected.contains)
            .joined(separator: ",")
        guard !canonical.isEmpty else {
            throw CLIArgumentPreflightError.invalidInternalAnalyzers
        }
        var publicArguments = arguments
        publicArguments.removeSubrange(index...(index + 1))
        return (publicArguments, canonical)
    }

    private static func normalizedString(_ value: NormalizedArgumentValue) -> String {
        switch value {
        case .point(let point): "\(point.x),\(point.y)"
        case .string(let value): value
        case .uint64(let value): String(value)
        }
    }

    private static func runtimeErrorCode(_ error: RuntimeClientError) -> String {
        switch error {
        case .incompatibleRuntime: "incompatibleRuntime"
        case .interrupted: "interrupted"
        case .runtimeStopping: "runtimeStopping"
        case .socketUnavailable: "runtimeNotRunning"
        case .transportFailure, .closedBeforeResponse: "transportFailure"
        case .invalidResponse, .targetMismatch: "protocolViolation"
        case .invalidBundledResources: "internalFailure"
        }
    }

    private static func outputAdapter(
        for invocation: CLIInvocation,
        requested: CLIOutputAdapter
    ) -> CLIOutputAdapter {
        guard invocation.commandID == "element.snapshot" else { return requested }
        let format: String
        if let index = invocation.arguments.firstIndex(of: "--format"),
           invocation.arguments.indices.contains(index + 1)
        {
            format = invocation.arguments[index + 1]
        } else {
            format = "json"
        }
        return format == "annotated"
            ? requested : CLIOutputAdapter(mode: .json)
    }

    private static func addingElementOutputPath(
        _ outputPath: String,
        to response: RepositoryJSONObject
    ) throws -> RepositoryJSONObject {
        guard let value = response["value"]?.objectValue,
              let annotation = value["annotation"]?.objectValue,
              annotation["outputPath"] == nil
        else {
            throw RuntimeClientError.invalidResponse
        }
        var annotationMembers = annotation.members
        annotationMembers.append(RepositoryJSONMember(
            key: "outputPath",
            value: .string(outputPath)
        ))
        let projectedAnnotation = try RepositoryJSONObject(
            members: annotationMembers
        )
        let projectedValue = try RepositoryJSONObject(members: value.members.map {
            $0.key == "annotation"
                ? RepositoryJSONMember(
                    key: "annotation",
                    value: .object(projectedAnnotation)
                )
                : $0
        })
        guard RepositoryCanonicalJSON.encodeDocument(projectedValue).count
                <= 256 * 1_024
        else {
            throw RuntimeClientError.invalidResponse
        }
        return try RepositoryJSONObject(members: response.members.map {
            $0.key == "value"
                ? RepositoryJSONMember(key: "value", value: .object(projectedValue))
                : $0
        })
    }

}

private struct ParsedOptions: Sendable {
    let values: [String: String]
    let repeatedValues: [String: [String]]
    let flags: Set<String>
}

private enum ArgumentFailureKind: Sendable {
    case invalid
    case missing
    case tooLarge
}

private struct ArgumentFailureProjection: Sendable {
    let code: String
    let message: String
    let details: [String: String]
}

private struct ProductionCLIScreenshotBackend: ScreenshotCommandBackend {
    let outputPath: String
    let request: PulsePhoneCLIProcess.ScreenshotRequest

    func requestDeviceScreenshot(
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID
    ) throws -> ScreenshotReceivedArtifact {
        try request(requestID, actionID, canonicalUDID, outputPath)
    }
}

private enum CLIOptionParserError: Error, Equatable, Sendable {
    case duplicateFlag(String)
    case duplicateOrMissingValue(String)
    case missingRequiredOption(String)
    case unknownOption(String)
}

private struct LiveLaunchResult: Encodable {
    let disposition: String
    let liveOwnerID: String
}

private struct RuntimeStatusTarget: Encodable {
    let canonicalUDID: String
    let state: String
}

private struct RuntimeStatusResult: Encodable {
    let targets: [RuntimeStatusTarget]
    let truncated: Bool
}

private struct RuntimeStopResult: Encodable {
    let disposition: String
    let stoppedTargetCount: Int
}

private indirect enum JSONValue: Encodable {
    case null
    case bool(Bool)
    case string(String)
    case decimal(Decimal)
    case int64(Int64)
    case uint64(UInt64)
    case array([JSONValue])
    case object([String: JSONValue])

    init(_ value: RepositoryJSONValue) throws {
        switch value {
        case .null: self = .null
        case .bool(let value): self = .bool(value)
        case .string(let value): self = .string(value)
        case .number(.decimal(let value)):
            guard let decimal = Decimal(
                string: value.canonicalString,
                locale: Locale(identifier: "en_US_POSIX")
            ) else { throw CLIProcessError.invalidArguments }
            self = .decimal(decimal)
        case .number(.int64(let value)): self = .int64(value)
        case .number(.uint64(let value)): self = .uint64(value)
        case .array(let values): self = .array(try values.map(Self.init))
        case .object(let object):
            self = .object(try Dictionary(uniqueKeysWithValues:
                object.members.map { ($0.key, try Self($0.value)) }
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .decimal(let value): try container.encode(value)
        case .int64(let value): try container.encode(value)
        case .uint64(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public enum CLIProcessError: Error, Equatable, Sendable {
    case helperUnavailable
    case invalidArguments
}
