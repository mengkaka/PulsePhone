import AppKit
import AVFoundation
import Darwin
import Dispatch
import Foundation
import OSLog
import PulsePhoneClientCore
import PulsePhoneHostPaths
import PulsePhoneMedia
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions
import UniformTypeIdentifiers

struct ProductionGUIHostWindowCloseLifecycle: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case open
        case stoppingOwnedResources
        case readyToClose
        case closed
    }

    private(set) var phase: Phase = .open

    var acceptsWork: Bool { phase == .open }

    mutating func requestClose() -> Bool {
        guard phase == .open else { return false }
        phase = .stoppingOwnedResources
        return true
    }

    mutating func ownedResourcesStopped() -> Bool {
        guard phase == .stoppingOwnedResources else { return false }
        phase = .readyToClose
        return true
    }

    mutating func windowClosed() {
        phase = .closed
    }
}

private enum ProductionBoundVideoStopPresentation {
    case clear(reason: LiveWindowPlaceholderReason)
    case freezeIfAvailable(reason: LiveWindowPlaceholderReason)
}

public final class ProductionGUIHostWindowController:
    NSObject,
    NSWindowDelegate,
    NSToolbarDelegate,
    @unchecked Sendable
{
    public typealias WindowClosed = @Sendable (CanonicalUDID, String) -> Void
    typealias RuntimeSessionFactory = @Sendable (CanonicalUDID) throws
        -> any ProductionGUIHostRuntimeSession
    typealias IPASelectionPresenter = @MainActor (
        NSWindow,
        @escaping @MainActor (String?) -> Void
    ) -> Void
    typealias ScreenshotSavePresenter = @MainActor (
        NSWindow,
        @escaping @MainActor (String?) -> Void
    ) -> Void
    typealias SourceTargetSnapshotProvider =
        ProductionLiveSourceResolver.TargetSnapshotProvider

    private let applicationIsActive: (() -> Bool)?
    private let catalog: ProductionAVFoundationVideoSourceCatalog
    private let captureCoordinator: ProductionSourceCaptureCoordinator
    private let callbackLock = NSLock()
    private let keyboardEventTap: any ProductionKeyboardEventTapControlling
    private let ipaSelectionPresenter: IPASelectionPresenter
    private let mappingCoordinator: ProductionVideoSourceMappingCoordinator
    private let productVersion: PulsePhoneProductVersion?
    private let screenshotDeviceBackend: any GUIScreenshotDeviceBackend
    private let screenshotOutputWriter: any GUIScreenshotOutputWriting
    private let screenshotSavePresenter: ScreenshotSavePresenter
    private let runtimeQueue = DispatchQueue(
        label: "com.pulsephone.gui.runtime",
        qos: .userInitiated
    )
    private let runtimeRetryDelaysNanoseconds: [UInt64]
    private let runtimeSessionFactory: RuntimeSessionFactory
    private let sourceTargetSnapshotProvider: SourceTargetSnapshotProvider
    private let toolbarRepositoryRoot: URL?
    private let presentsWindows: Bool
    private let windowIsKey: ((NSWindow) -> Bool)?
    private static let moreToolbarCommandID = "gui.more"
    private static let toolbarLatencyLogger = Logger(
        subsystem: "com.pulsephone.PulsePhone",
        category: "toolbar-latency"
    )
    private static let pointerLatencyLogger = Logger(
        subsystem: "com.pulsephone.PulsePhone",
        category: "pointer-latency"
    )
    private static let screenshotLogger = Logger(
        subsystem: "com.pulsephone.PulsePhone",
        category: "screenshot"
    )
    private static let windowGeometryLogger = Logger(
        subsystem: "com.pulsephone.PulsePhone",
        category: "window-geometry"
    )
    private static let videoLatencyLogger = Logger(
        subsystem: "com.pulsephone.PulsePhone",
        category: "video-latency"
    )
    private static let audioPreviewLogger = Logger(
        subsystem: "com.pulsephone.PulsePhone",
        category: "audio-preview"
    )
    private static let liveResizeSettlementDelays: [DispatchTimeInterval] = [
        .milliseconds(0),
        .milliseconds(16),
        .milliseconds(34),
        .milliseconds(66),
        .milliseconds(100),
        .milliseconds(100),
        .milliseconds(100),
    ]
    private static let liveResizeSettlementMinimumAttempt = 3
    private static let liveResizeSettlementRequiredExactObservations = 2
    private var windowClosed: WindowClosed?
    @MainActor private var latestInventory: VideoSourceInventory?
    @MainActor private var keyboardCaptureWindowID: String?
    @MainActor private var keyboardEventTapFaulted = false
    @MainActor private var liveOwnerRegistry = LiveOwnerRegistry()
    @MainActor private var monitoring = false
    @MainActor private var windows = [String: ProductionGUIHostWindowState]()
    @MainActor private lazy var sourceResolver = ProductionLiveSourceResolver(
        catalog: catalog,
        captureCoordinator: captureCoordinator,
        mappingCoordinator: mappingCoordinator,
        productVersion: productVersion,
        presentsWindows: presentsWindows,
        targetSnapshotProvider: sourceTargetSnapshotProvider,
        inventoryRefresh: { [weak self] inventory in
            self?.apply(inventory)
        },
        firstHandoff: { [weak self] target, ownerID, handoff in
            self?.createWindowOnMain(
                for: target,
                ownerID: ownerID,
                targetFacts: handoff.targetFacts,
                sourceHandoff: handoff
            )
        },
        firstBlindHandoff: { [weak self] target, ownerID, targetFacts in
            self?.createWindowOnMain(
                for: target,
                ownerID: ownerID,
                targetFacts: targetFacts,
                sourceHandoff: nil
            )
        },
        existingHandoff: { [weak self] target, ownerID, handoff in
            self?.applySourceReassignment(
                target: target,
                ownerID: ownerID,
                handoff: handoff
            )
        },
        existingSourceRetained: { [weak self] target, ownerID in
            guard let state = self?.windows[ownerID],
                  state.canonicalUDID == target
            else { return }
            state.window.makeKeyAndOrderFront(nil)
        },
        ownerCancelled: { [weak self] target, ownerID in
            self?.callbackLock.withLock { self?.windowClosed }?(target, ownerID)
        },
        fenceTargets: { [weak self] targets in
            self?.fenceSourceReassignment(targets: targets)
        },
        activeBindingsProvider: { [weak self] in
            self?.windows.values.compactMap { state in
                guard state.videoSession != nil,
                      let descriptor = state.confirmedDescriptor
                else { return nil }
                return ProductionLiveSourceActiveBinding(
                    descriptor: descriptor,
                    target: state.canonicalUDID
                )
            } ?? []
        }
    )

    public init(
        catalog: ProductionAVFoundationVideoSourceCatalog =
            ProductionAVFoundationVideoSourceCatalog()
    ) {
        self.applicationIsActive = nil
        self.catalog = catalog
        self.captureCoordinator = ProductionSourceCaptureCoordinator(catalog: catalog)
        self.ipaSelectionPresenter = Self.presentIPASelection
        self.keyboardEventTap = ProductionKeyboardEventTap()
        self.mappingCoordinator = ProductionVideoSourceMappingCoordinator()
        self.productVersion = PulsePhoneProductVersion(bundle: .main)
        self.screenshotDeviceBackend = ProductionGUIScreenshotDeviceBackend()
        self.screenshotOutputWriter = AtomicGUIScreenshotOutputWriter(
            fileSystem: ProductionAtomicOutputFileSystem()
        )
        self.screenshotSavePresenter = Self.presentScreenshotSave
        self.runtimeSessionFactory = { target in
            try RuntimeClient.bundled(role: .gui).openLiveSession(
                canonicalUDID: target,
                activation: .ensureRunning
            )
        }
        self.sourceTargetSnapshotProvider = Self.productionSourceTargetSnapshot
        self.runtimeRetryDelaysNanoseconds = [
            250_000_000,
            1_000_000_000,
            2_000_000_000,
            5_000_000_000,
        ]
        self.toolbarRepositoryRoot = Bundle.main.resourceURL
        self.presentsWindows = true
        self.windowIsKey = nil
        super.init()
        installApplicationObservers()
    }

    init(
        catalog: ProductionAVFoundationVideoSourceCatalog,
        keyboardEventTap: any ProductionKeyboardEventTapControlling =
            ProductionKeyboardEventTap(),
        mappingCoordinator: ProductionVideoSourceMappingCoordinator =
            ProductionVideoSourceMappingCoordinator(),
        productVersion: PulsePhoneProductVersion? = nil,
        captureCoordinator: ProductionSourceCaptureCoordinator? = nil,
        ipaSelectionPresenter: @escaping IPASelectionPresenter =
            ProductionGUIHostWindowController.presentIPASelection,
        runtimeSessionFactory: @escaping RuntimeSessionFactory,
        screenshotDeviceBackend: any GUIScreenshotDeviceBackend =
            ProductionGUIScreenshotDeviceBackend(),
        screenshotOutputWriter: any GUIScreenshotOutputWriting =
            AtomicGUIScreenshotOutputWriter(
                fileSystem: ProductionAtomicOutputFileSystem()
            ),
        screenshotSavePresenter: @escaping ScreenshotSavePresenter =
            ProductionGUIHostWindowController.presentScreenshotSave,
        sourceTargetSnapshotProvider: @escaping SourceTargetSnapshotProvider =
            ProductionGUIHostWindowController.productionSourceTargetSnapshot,
        runtimeRetryDelaysNanoseconds: [UInt64] = [],
        toolbarRepositoryRoot: URL? = Bundle.main.resourceURL,
        presentsWindows: Bool = false,
        applicationIsActive: (() -> Bool)? = nil,
        windowIsKey: ((NSWindow) -> Bool)? = nil
    ) {
        self.applicationIsActive = applicationIsActive
        self.catalog = catalog
        self.captureCoordinator = captureCoordinator
            ?? ProductionSourceCaptureCoordinator(catalog: catalog)
        self.keyboardEventTap = keyboardEventTap
        self.ipaSelectionPresenter = ipaSelectionPresenter
        self.mappingCoordinator = mappingCoordinator
        self.productVersion = productVersion
        self.runtimeSessionFactory = runtimeSessionFactory
        self.screenshotDeviceBackend = screenshotDeviceBackend
        self.screenshotOutputWriter = screenshotOutputWriter
        self.screenshotSavePresenter = screenshotSavePresenter
        self.sourceTargetSnapshotProvider = sourceTargetSnapshotProvider
        self.runtimeRetryDelaysNanoseconds = runtimeRetryDelaysNanoseconds
        self.toolbarRepositoryRoot = toolbarRepositoryRoot
        self.presentsWindows = presentsWindows
        self.windowIsKey = windowIsKey
        super.init()
        installApplicationObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        keyboardEventTap.invalidate()
    }

    private func installApplicationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.keyboardEventTapFaulted = false
                self.windows.values.forEach {
                    self.reevaluateKeyboardCapture(in: $0)
                }
            }
        }
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.windows.values.forEach {
                    self.reevaluateKeyboardCapture(in: $0)
                }
            }
        }
    }

    public func setWindowClosedHandler(_ handler: @escaping WindowClosed) {
        callbackLock.withLock { windowClosed = handler }
    }

    @MainActor
    public func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        catalog.startMonitoring { [weak self] inventory in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.apply(inventory)
                }
            }
        }
    }

    @MainActor
    public func stopMonitoring() {
        guard monitoring else { return }
        monitoring = false
        catalog.stopMonitoring()
        for state in windows.values {
            stopAutomaticProbe(state)
            stopPreview(state)
            stopBoundVideo(
                state,
                presentation: .clear(reason: .awaitingBinding),
                invalidateCoordinateAuthority: true
            )
        }
    }

    @MainActor
    func shutdownForApplicationTermination(
        completion: @escaping @MainActor () -> Void
    ) {
        if monitoring {
            monitoring = false
            catalog.stopMonitoring()
        }
        let states = Array(windows.values)
        keyboardCaptureWindowID = nil
        keyboardEventTap.setCaptureActive(false)
        keyboardEventTap.invalidate()
        windows.removeAll()
        guard !states.isEmpty else {
            completion()
            return
        }
        var remaining = states.count
        for state in states {
            stopAutomaticProbe(state)
            stopPreview(state)
            stopBoundVideo(
                state,
                presentation: .clear(reason: .awaitingBinding),
                invalidateCoordinateAuthority: true
            )
            closeRuntime(state) { [weak self] in
                self?.callbackLock.withLock { self?.windowClosed }?(
                    state.canonicalUDID,
                    state.windowID
                )
                remaining -= 1
                if remaining == 0 { completion() }
            }
        }
    }

    public func createWindow(for canonicalUDID: CanonicalUDID) -> String? {
        let create = {
            MainActor.assumeIsolated {
                self.createWindowOnMain(
                    for: canonicalUDID,
                    ownerID: nil,
                    targetFacts: nil,
                    sourceHandoff: nil
                )
            }
        }
        return Thread.isMainThread
            ? create()
            : DispatchQueue.main.sync(execute: create)
    }

    public func openOwner(
        for canonicalUDID: CanonicalUDID,
        policy: GUIHostSourceSelectionPolicy
    ) -> String? {
        let open = {
            MainActor.assumeIsolated {
                self.startMonitoring()
                let ownerID = "appkit-\(UUID().uuidString.lowercased())"
                self.sourceResolver.openFirstOwner(
                    target: canonicalUDID,
                    ownerID: ownerID,
                    policy: policy
                )
                return ownerID
            }
        }
        return Thread.isMainThread
            ? open()
            : DispatchQueue.main.sync(execute: open)
    }

    public func activateOwner(
        for canonicalUDID: CanonicalUDID,
        ownerID: String,
        policy: GUIHostSourceSelectionPolicy
    ) {
        let activate = {
            MainActor.assumeIsolated {
                if policy == .forceChooser {
                    self.sourceResolver.openForExistingLive(
                        target: canonicalUDID,
                        ownerID: ownerID
                    )
                    return
                }
                if let state = self.windows[ownerID] {
                    state.window.makeKeyAndOrderFront(nil)
                } else {
                    self.sourceResolver.focusOwner(target: canonicalUDID)
                }
            }
        }
        if Thread.isMainThread {
            activate()
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if policy == .forceChooser {
                    self.sourceResolver.openForExistingLive(
                        target: canonicalUDID,
                        ownerID: ownerID
                    )
                } else if let state = self.windows[ownerID] {
                    state.window.makeKeyAndOrderFront(nil)
                } else {
                    self.sourceResolver.focusOwner(target: canonicalUDID)
                }
            }
        }
    }

    @MainActor
    @discardableResult
    private func createWindowOnMain(
        for canonicalUDID: CanonicalUDID,
        ownerID: String?,
        targetFacts: ProductionLiveSourceTargetFacts?,
        sourceHandoff: ProductionLiveSourceHandoff?
    ) -> String {
        startMonitoring()
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        let identifier = ownerID
            ?? "appkit-\(UUID().uuidString.lowercased())"
        let visibleFrame = (NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_024, height: 768))
        let identity = try! IdentityPlaceholder(
            deviceName: targetFacts?.name ?? "iPhone",
            canonicalUDID: canonicalUDID
        )
        var liveModel = try! LiveWindowModel(
            identityPlaceholder: identity,
            screenVisibleFrame: Self.liveRect(visibleFrame)
        )
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: liveModel.reservation.contentSize.width,
                height: liveModel.reservation.contentSize.height
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PulsePhone"
        window.titleVisibility = .hidden
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.delegate = self
        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        let videoView = NSView(frame: content.bounds)
        videoView.identifier = ProductionGUIHostViewIdentifier.videoCanvas
        videoView.wantsLayer = true
        videoView.layer?.backgroundColor = NSColor.black.cgColor
        let interactionView = ProductionGUIHostInteractionView(frame: content.bounds)
        interactionView.identifier = ProductionGUIHostViewIdentifier
            .interactionCanvas
        let availabilityOverlay = ProductionGUIHostAvailabilityOverlayView(
            frame: content.bounds
        )
        let canvasHost = ProductionGUIHostCanvasHost(
            frame: content.bounds,
            aspectRatio: CGFloat(liveModel.reservation.canvasAspectRatio.value),
            videoView: videoView,
            interactionView: interactionView,
            availabilityOverlay: availabilityOverlay
        )
        canvasHost.translatesAutoresizingMaskIntoConstraints = false
        let placeholder = NSTextField(
            labelWithString: "\(identity.primaryText)\n\(identity.secondaryText)"
        )
        placeholder.alignment = .center
        placeholder.lineBreakMode = .byTruncatingMiddle
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.textColor = .secondaryLabelColor
        placeholder.isHidden = true
        videoView.addSubview(placeholder)
        let sourcePicker = NSPopUpButton(frame: .zero, pullsDown: false)
        sourcePicker.translatesAutoresizingMaskIntoConstraints = false
        sourcePicker.controlSize = .small
        sourcePicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sourcePicker.addItem(withTitle: "No video sources")
        sourcePicker.isEnabled = false
        sourcePicker.identifier = NSUserInterfaceItemIdentifier(identifier)
        sourcePicker.target = self
        sourcePicker.action = #selector(sourceSelectionChanged(_:))
        let previewButton = NSButton(
            image: NSImage(
                systemSymbolName: "play.rectangle",
                accessibilityDescription: "Preview source"
            ) ?? NSImage(),
            target: self,
            action: #selector(previewSource(_:))
        )
        previewButton.bezelStyle = .texturedRounded
        previewButton.controlSize = .small
        previewButton.identifier = NSUserInterfaceItemIdentifier(identifier)
        previewButton.toolTip = "Preview source"
        previewButton.isEnabled = false
        let confirmButton = NSButton(
            image: NSImage(
                systemSymbolName: "checkmark.circle",
                accessibilityDescription: "Use source"
            ) ?? NSImage(),
            target: self,
            action: #selector(confirmSource(_:))
        )
        confirmButton.bezelStyle = .texturedRounded
        confirmButton.controlSize = .small
        confirmButton.identifier = NSUserInterfaceItemIdentifier(identifier)
        confirmButton.toolTip = "Use source"
        confirmButton.isEnabled = false
        let changeMappingButton = NSButton(
            image: NSImage(
                systemSymbolName: "rectangle.on.rectangle",
                accessibilityDescription: "更换视频源"
            ) ?? NSImage(),
            target: self,
            action: #selector(changeSourceMapping(_:))
        )
        changeMappingButton.bezelStyle = .texturedRounded
        changeMappingButton.controlSize = .small
        changeMappingButton.identifier = NSUserInterfaceItemIdentifier(identifier)
        changeMappingButton.toolTip = "更换视频源"
        changeMappingButton.isEnabled = false
        let clearMappingButton = NSButton(
            image: NSImage(
                systemSymbolName: "trash",
                accessibilityDescription: "Clear source mapping"
            ) ?? NSImage(),
            target: self,
            action: #selector(clearSourceMapping(_:))
        )
        clearMappingButton.bezelStyle = .texturedRounded
        clearMappingButton.controlSize = .small
        clearMappingButton.identifier = NSUserInterfaceItemIdentifier(identifier)
        clearMappingButton.toolTip = "Clear source mapping"
        clearMappingButton.isEnabled = false
        let progressIndicator = NSProgressIndicator()
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.style = .spinning
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.isHidden = true
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let sourceSummaryLabel = NSTextField(labelWithString: "No video source")
        sourceSummaryLabel.identifier = ProductionGUIHostViewIdentifier.sourceSummary
        sourceSummaryLabel.lineBreakMode = .byTruncatingMiddle
        sourceSummaryLabel.textColor = .secondaryLabelColor
        sourceSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        sourceSummaryLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        let controls = NSStackView(views: [
            sourceSummaryLabel, changeMappingButton, progressIndicator, statusLabel,
        ])
        controls.alignment = .centerY
        controls.orientation = .horizontal
        controls.spacing = 3
        controls.translatesAutoresizingMaskIntoConstraints = false
        let controlsHorizontalInset: CGFloat = 6
        let sourceButtonWidth: CGFloat = 28
        let progressIndicatorWidth: CGFloat = 16
        let controlBackground = NSVisualEffectView(frame: .zero)
        controlBackground.blendingMode = .withinWindow
        controlBackground.material = .hudWindow
        controlBackground.state = .active
        controlBackground.identifier = ProductionGUIHostViewIdentifier
            .sourceControls
        controlBackground.translatesAutoresizingMaskIntoConstraints = false
        controlBackground.addSubview(controls)
        content.addSubview(canvasHost)
        content.addSubview(controlBackground)
        NSLayoutConstraint.activate([
            canvasHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvasHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvasHost.topAnchor.constraint(equalTo: content.topAnchor),
            canvasHost.bottomAnchor.constraint(
                equalTo: controlBackground.topAnchor
            ),
            placeholder.centerXAnchor.constraint(equalTo: videoView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: videoView.centerYAnchor),
            placeholder.leadingAnchor.constraint(
                greaterThanOrEqualTo: videoView.leadingAnchor,
                constant: 24
            ),
            placeholder.trailingAnchor.constraint(
                lessThanOrEqualTo: videoView.trailingAnchor,
                constant: -24
            ),
            controlBackground.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            controlBackground.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            controlBackground.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            controlBackground.heightAnchor.constraint(
                equalToConstant: liveModel.reservation.sourceControlsHeight
            ),
            controls.leadingAnchor.constraint(
                equalTo: controlBackground.leadingAnchor,
                constant: controlsHorizontalInset
            ),
            controls.trailingAnchor.constraint(
                equalTo: controlBackground.trailingAnchor,
                constant: -controlsHorizontalInset
            ),
            controls.centerYAnchor.constraint(equalTo: controlBackground.centerYAnchor),
            changeMappingButton.widthAnchor.constraint(equalToConstant: sourceButtonWidth),
            changeMappingButton.heightAnchor.constraint(equalToConstant: 26),
            progressIndicator.widthAnchor.constraint(
                equalToConstant: progressIndicatorWidth
            ),
            progressIndicator.heightAnchor.constraint(equalToConstant: 16),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 120),
        ])
        let sourceControlsMinimumContentWidth = ProductionSourceControlsSizing
            .minimumContentWidth(
                horizontalInset: controlsHorizontalInset,
                spacing: controls.spacing,
                arrangedSubviewCount: controls.arrangedSubviews.count,
                noncompressibleWidths: [
                    sourceButtonWidth,
                    progressIndicatorWidth,
                ]
            )
        try! liveModel.updateActualMinimumContentWidth(
            Double(sourceControlsMinimumContentWidth)
        )
        let controller = NSViewController()
        controller.view = content
        window.contentViewController = controller
        window.contentMinSize = ProductionLiveWindowSizing.minimumContentSize(
            canvasAspectRatio: CGFloat(
                liveModel.reservation.canvasAspectRatio.value
            ),
            sourceControlsHeight: CGFloat(
                liveModel.reservation.sourceControlsHeight
            ),
            maximumFrameSize: visibleFrame.size,
            frameChromeHeight: max(
                0,
                window.frame.height
                    - (window.contentView?.bounds.height ?? 0)
            ),
            minimumContentWidth: sourceControlsMinimumContentWidth
        )
        window.setFrame(
            Self.windowFrame(for: liveModel.reservation, window: window),
            display: false
        )
        if presentsWindows {
            window.makeKeyAndOrderFront(nil)
        }
        let state = ProductionGUIHostWindowState(
            availabilityOverlay: availabilityOverlay,
            canonicalUDID: canonicalUDID,
            canvasHost: canvasHost,
            changeMappingButton: changeMappingButton,
            clearMappingButton: clearMappingButton,
            confirmButton: confirmButton,
            interactionView: interactionView,
            liveModel: liveModel,
            placeholder: placeholder,
            previewButton: previewButton,
            progressIndicator: progressIndicator,
            sourcePicker: sourcePicker,
            sourceControlsContent: controls,
            sourceControlsMinimumContentWidth: Double(
                sourceControlsMinimumContentWidth
            ),
            sourceSummaryLabel: sourceSummaryLabel,
            statusLabel: statusLabel,
            videoView: videoView,
            windowID: identifier,
            window: window
        )
        windows[identifier] = state
        refreshAvailabilityOverlay(in: state)
        setStatus("Connecting controls", busy: true, in: state)
        bindInteractionHandlers(to: state)
        precondition(
            sourceHandoff == nil
                || sourceHandoff?.targetFacts.canonicalUDID == canonicalUDID
        )
        loadSourceMapping(for: state)
        startRuntimeSession(for: state)
        if let latestInventory {
            apply(latestInventory, to: state)
        }
        return identifier
    }

    @MainActor
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let identifier = sender.identifier?.rawValue,
              let state = windows[identifier]
        else { return true }
        switch state.closeLifecycle.phase {
        case .readyToClose:
            return true
        case .open:
            reevaluateKeyboardCapture(in: state, enabled: false)
            let beginNow = state.closeLifecycle.requestClose()
            prepareControlsForClose(state)
            if beginNow { beginWindowClose(state) }
            return false
        case .stoppingOwnedResources, .closed:
            return false
        }
    }

    @MainActor
    func applyRuntimeGeometry(
        _ geometry: DisplayGeometryDTO,
        toWindow identifier: String
    ) throws {
        guard let state = windows[identifier], state.closeLifecycle.acceptsWork else {
            return
        }
        let update = try state.liveModel.updateRuntimeGeometry(geometry)
        if state.liveModel.coordinateInputEnabled {
            state.pointerLastFailure = nil
        }
        state.geometryRevision = max(state.geometryRevision, geometry.geometryRevision)
        if update.requiresInteractionCancellation,
           let cancellation = try state.pointerController.geometryDidChange(to: geometry)
        {
            appendPointerCancellation(cancellation, in: state)
        }
        if update.requiresInteractionCancellation {
            state.observationOverlay = InputObservationOverlay()
        }
        state.interactionView.geometry = geometry
        applyWindowReservation(state)
    }

    @MainActor
    public func windowWillStartLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let identifier = window.identifier?.rawValue,
              let state = windows[identifier],
              state.closeLifecycle.acceptsWork,
              state.liveModel.windowState == .windowed
        else { return }
        clearPendingLiveResize(in: state)
        cancelLiveResizeVideoTransition(in: state)
        state.liveResizeStartFrame = window.frame
        state.liveResizeTransaction = makeLiveResizeTransaction(
            in: state,
            window: window,
            referenceFrame: window.frame
        )
        state.pendingLiveResizePresentation = nil
        state.awaitingLiveResizePresentation = false
        state.liveResizeFramesWithheld = false
        state.videoSession?.beginLiveResize(
            frozenPresentation: state.liveModel.samplePresentation
        )
        Self.windowGeometryLogger.notice(
            "stage=windowWillStartLiveResize width=\(window.frame.width, privacy: .public) height=\(window.frame.height, privacy: .public)"
        )
    }

    @MainActor
    public func windowWillResize(
        _ sender: NSWindow,
        to frameSize: NSSize
    ) -> NSSize {
        guard let identifier = sender.identifier?.rawValue,
              let state = windows[identifier],
              state.closeLifecycle.acceptsWork
        else { return frameSize }
        guard state.liveModel.windowState == .windowed else { return frameSize }
        let referenceFrame = state.liveResizeStartFrame ?? sender.frame
        state.liveResizeStartFrame = referenceFrame
        var transaction = state.liveResizeTransaction
            ?? makeLiveResizeTransaction(
                in: state,
                window: sender,
                referenceFrame: referenceFrame
            )
        if transaction.driver == nil {
            transaction.driver = ProductionLiveWindowSizing.liveResizeDriver(
                proposedFrameSize: frameSize,
                referenceFrameSize: transaction.referenceFrame.size,
                sourceControlsHeight: transaction.sourceControlsHeight,
                frameChromeHeight: transaction.frameChromeHeight
            )
        }
        state.liveResizeTransaction = transaction
        state.settlingLiveResizeSequence = nil
        state.liveResizeSettlementAttempt = 0
        state.liveResizeSettlementExactObservations = 0
        let expectedFrameSize = constrainedLiveResizeFrameSize(
            in: state,
            window: sender,
            proposedFrameSize: frameSize,
            transaction: transaction
        )
        state.liveResizeSequence &+= 1
        state.pendingLiveResize = ProductionPendingLiveResize(
            referenceFrame: transaction.referenceFrame,
            expectedFrameSize: expectedFrameSize,
            sequence: state.liveResizeSequence,
            source: .windowWillResize
        )
        Self.windowGeometryLogger.debug(
            "stage=windowWillResize sequence=\(state.liveResizeSequence, privacy: .public) driver=\(transaction.driver?.rawValue ?? "pending", privacy: .public) proposedWidth=\(frameSize.width, privacy: .public) proposedHeight=\(frameSize.height, privacy: .public) expectedWidth=\(expectedFrameSize.width, privacy: .public) expectedHeight=\(expectedFrameSize.height, privacy: .public)"
        )
        return expectedFrameSize
    }

    @MainActor
    public func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let identifier = window.identifier?.rawValue,
              let state = windows[identifier],
              state.closeLifecycle.acceptsWork
        else { return }
        updateToolbarButtons(in: state)
        synthesizePendingLiveResizeIfNeeded(in: state)
        reconcilePendingLiveResize(in: state)
        if state.liveResizeTransaction == nil {
            schedulePendingLiveResizeReconciliation(in: state)
        }
    }

    @MainActor
    public func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let identifier = window.identifier?.rawValue,
              let state = windows[identifier],
              state.closeLifecycle.acceptsWork
        else { return }
        guard state.liveModel.windowState == .windowed else { return }
        var synthesizedPending = false
        if state.pendingLiveResize == nil {
            let referenceFrame = state.liveResizeTransaction?.referenceFrame
                ?? state.liveResizeStartFrame
                ?? window.frame
            state.liveResizeSequence &+= 1
            state.pendingLiveResize = ProductionPendingLiveResize(
                referenceFrame: referenceFrame,
                expectedFrameSize: constrainedLiveResizeFrameSize(
                    in: state,
                    window: window,
                    proposedFrameSize: window.frame.size,
                    comparisonFrameSize: referenceFrame.size,
                    transaction: state.liveResizeTransaction
                ),
                sequence: state.liveResizeSequence,
                source: .windowDidResizeFallback
            )
            synthesizedPending = true
        }
        guard let pending = state.pendingLiveResize else { return }
        reconcilePendingLiveResize(in: state)
        recordCurrentUserCanvasSize(in: state)
        state.liveResizeTransaction = nil
        state.settlingLiveResizeSequence = pending.sequence
        state.liveResizeSettlementAttempt = 0
        state.liveResizeSettlementExactObservations = 0
        Self.windowGeometryLogger.notice(
            "stage=windowDidEndLiveResize sequence=\(pending.sequence, privacy: .public) synthesized=\(synthesizedPending, privacy: .public) inLiveResize=\(window.inLiveResize, privacy: .public) actualWidth=\(window.frame.width, privacy: .public) actualHeight=\(window.frame.height, privacy: .public) expectedWidth=\(pending.expectedFrameSize.width, privacy: .public) expectedHeight=\(pending.expectedFrameSize.height, privacy: .public)"
        )
        if finishLiveResizeVideoTransition(in: state) {
            return
        }
        scheduleLiveResizeSettlement(
            in: state,
            sequence: pending.sequence,
            attempt: 0
        )
    }

    @MainActor
    public func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let identifier = window.identifier?.rawValue,
              let state = windows[identifier],
              state.closeLifecycle.acceptsWork,
              let visibleFrame = window.screen?.visibleFrame
        else { return }
        try? state.liveModel.updateScreenVisibleFrame(Self.liveRect(visibleFrame))
        applyWindowReservation(state)
    }

    @MainActor
    public func windowWillEnterFullScreen(_ notification: Notification) {
        guard let state = state(from: notification) else { return }
        clearPendingLiveResize(in: state)
        cancelLiveResizeVideoTransition(in: state)
        _ = state.liveModel.windowWillEnterFullscreen()
    }

    @MainActor
    public func windowDidEnterFullScreen(_ notification: Notification) {
        guard let state = state(from: notification) else { return }
        _ = state.liveModel.windowDidEnterFullscreen()
        applyWindowReservation(state)
    }

    @MainActor
    public func windowWillExitFullScreen(_ notification: Notification) {
        guard let state = state(from: notification) else { return }
        clearPendingLiveResize(in: state)
        cancelLiveResizeVideoTransition(in: state)
        _ = state.liveModel.windowWillExitFullscreen()
    }

    @MainActor
    public func windowDidExitFullScreen(_ notification: Notification) {
        guard let state = state(from: notification) else { return }
        guard state.liveModel.windowDidExitFullscreen() else { return }
        applyWindowReservation(state)
    }

    @MainActor
    public func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let identifier = window.identifier?.rawValue,
              let state = windows[identifier]
        else { return }
        reevaluateKeyboardCapture(in: state)
    }

    @MainActor
    public func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let identifier = window.identifier?.rawValue,
              let state = windows[identifier]
        else { return }
        reevaluateKeyboardCapture(in: state)
    }

    @MainActor
    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let identifier = window.identifier?.rawValue,
              let state = windows[identifier]
        else { return }
        let completedTwoPhaseClose = state.closeLifecycle.phase == .readyToClose
        state.closeLifecycle.windowClosed()
        guard !completedTwoPhaseClose else {
            retainThroughWindowCloseTransaction(state, identifier: identifier)
            return
        }
        // Programmatic AppKit close can bypass windowShouldClose. Let the
        // current notification and transform transaction unwind first.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dropKeyboardCaptureForClose(state)
                self.stopAutomaticProbe(state)
                self.stopPreview(state)
                self.stopBoundVideo(
                    state,
                    presentation: .clear(reason: .awaitingBinding),
                    invalidateCoordinateAuthority: true
                )
                self.closeRuntime(state) { [weak self] in
                    self?.finishWindowClose(state, identifier: identifier)
                }
            }
        }
    }

    @MainActor
    private func retainThroughWindowCloseTransaction(
        _ state: ProductionGUIHostWindowState,
        identifier: String
    ) {
        // windowWillClose is sent before AppKit finishes the close transaction.
        // Keep the state as the window's strong owner until that event unwinds.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.finishWindowClose(state, identifier: identifier)
            }
        }
    }

    @MainActor
    private func finishWindowClose(
        _ state: ProductionGUIHostWindowState,
        identifier: String
    ) {
        guard windows[identifier] === state else { return }
        state.window.delegate = nil
        windows.removeValue(forKey: identifier)
        notifyWindowClosed(state, identifier: identifier)
    }

    @MainActor
    private func prepareControlsForClose(_ state: ProductionGUIHostWindowState) {
        clearPendingLiveResize(in: state)
        state.window.standardWindowButton(.closeButton)?.isEnabled = false
        state.sourcePicker.isEnabled = false
        state.previewButton.isEnabled = false
        state.confirmButton.isEnabled = false
        state.changeMappingButton.isEnabled = false
        state.clearMappingButton.isEnabled = false
        state.toolbarButtons.values.forEach { $0.isEnabled = false }
        setStatus("Closing", busy: true, in: state)
    }

    @MainActor
    private func beginWindowClose(_ state: ProductionGUIHostWindowState) {
        guard state.closeLifecycle.phase == .stoppingOwnedResources else { return }
        captureCoordinator.cancelHandoff(
            target: state.canonicalUDID,
            ownerID: state.windowID
        )
        stopAutomaticProbe(state)
        stopPreview(state)
        stopBoundVideo(
            state,
            presentation: .clear(reason: .awaitingBinding),
            invalidateCoordinateAuthority: true
        )
        closeRuntime(state) { [weak self, weak window = state.window] in
            guard let self,
                  let current = self.windows[state.windowID],
                  current === state,
                  state.closeLifecycle.ownedResourcesStopped()
            else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    window?.close()
                }
            }
        }
    }

    private func notifyWindowClosed(
        _ state: ProductionGUIHostWindowState,
        identifier: String
    ) {
        callbackLock.withLock { windowClosed }?(
            state.canonicalUDID,
            identifier
        )
    }

    @MainActor
    private func startRuntimeSession(
        for state: ProductionGUIHostWindowState,
        attempt: Int = 0
    ) {
        let identifier = state.windowID
        let target = state.canonicalUDID
        let factory = runtimeSessionFactory
        runtimeQueue.async { [weak self] in
            guard let self else { return }
            var attemptedSession: (any ProductionGUIHostRuntimeSession)?
            do {
                let session = try factory(target)
                attemptedSession = session
                _ = try session.prepareCapabilities()
                _ = try session.attach(observationTopics: [
                    "availability", "capability", "deviceCondition", "geometry",
                    "pointerProjection", "preparation", "runtimeState",
                ])
                let clientInstanceID = session.clientInstanceID
                session.setRuntimeEventHandler { [weak self] event in
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            self?.handleRuntimeEvent(
                                event,
                                clientInstanceID: clientInstanceID,
                                windowID: identifier
                            )
                        }
                    }
                }
                session.setRuntimeObservationHandler { [weak self] observation in
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            self?.handleRuntimeObservation(
                                observation,
                                clientInstanceID: clientInstanceID,
                                windowID: identifier
                            )
                        }
                    }
                }
                session.setObservationResetHandler { [weak self] reset in
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            self?.handleObservationReset(
                                reset,
                                clientInstanceID: clientInstanceID,
                                windowID: identifier
                            )
                        }
                    }
                }
                session.setTransportFailureHandler { [weak self] failure in
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            self?.handleRuntimeTransportFailure(
                                failure,
                                clientInstanceID: clientInstanceID,
                                windowID: identifier
                            )
                        }
                    }
                }
                let availability = try session.availability()
                guard let currentAttachment = session.currentAttachment else {
                    throw RuntimeClientError.invalidResponse
                }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.applyRuntimeSession(
                            session,
                            attachment: currentAttachment,
                            availability: availability,
                            toWindow: identifier
                        )
                    }
                }
            } catch {
                try? attemptedSession?.close()
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self,
                              let state = self.windows[identifier],
                              state.closeLifecycle.acceptsWork,
                              state.runtimeSession == nil
                        else { return }
                        if attempt < self.runtimeRetryDelaysNanoseconds.count {
                            self.setStatus(
                                "Reconnecting controls",
                                busy: true,
                                in: state
                            )
                            let delay = self.runtimeRetryDelaysNanoseconds[attempt]
                            DispatchQueue.main.asyncAfter(
                                deadline: .now() + .nanoseconds(Int(delay))
                            ) { [weak self] in
                                MainActor.assumeIsolated {
                                    guard let self,
                                          let current = self.windows[identifier],
                                          current === state,
                                          current.closeLifecycle.acceptsWork,
                                          current.runtimeSession == nil
                                    else { return }
                                    self.startRuntimeSession(
                                        for: current,
                                        attempt: attempt + 1
                                    )
                                }
                            }
                            return
                        }
                        state.liveModel.setControlUnavailable(reason: "runtimeUnavailable")
                        state.confirmButton.isEnabled = false
                        self.setStatus(
                            "Controls unavailable",
                            busy: false,
                            in: state
                        )
                    }
                }
            }
        }
    }

    @MainActor
    private func applyRuntimeSession(
        _ session: any ProductionGUIHostRuntimeSession,
        attachment: LiveAttachment,
        availability: RepositoryJSONObject,
        toWindow identifier: String
    ) {
        guard let state = windows[identifier],
              state.closeLifecycle.acceptsWork
        else {
            runtimeQueue.async { try? session.close() }
            return
        }
        let disposition = state.ownerCoordinator.attach(
            attachment: attachment,
            clientInstanceID: session.clientInstanceID,
            windowID: identifier,
            registry: &liveOwnerRegistry
        )
        if case .conflict = disposition {
            runtimeQueue.async { try? session.close() }
            return
        }
        if state.captureReadyConnectionEpoch != attachment.connectionEpoch {
            resetCaptureActivation(in: state)
        }
        state.runtimeSession = session
        state.captureGenerationTransitionInFlight = false
        state.pointerLastFailure = nil
        try? state.liveModel.setControlAvailable(
            connectionEpoch: attachment.connectionEpoch
        )
        applyToolbarAvailability(availability, in: state)
        setStatus(nil, busy: false, in: state)
        updateSourceControls(state)
        if let activationID = state.captureReadyActivationID,
           Self.captureReadyActivationCanResume(
               activationConnectionEpoch: state.captureReadyConnectionEpoch,
               attachment: attachment
           )
        {
            beginCaptureReadyTransition(
                activationID: activationID,
                session: session,
                state: state
            )
        }
        maybeStartCachedBinding(in: state)
    }

    @MainActor
    private func handleRuntimeEvent(
        _ event: RepositoryJSONObject,
        clientInstanceID: CanonicalUUID,
        windowID: String
    ) {
        guard let state = windows[windowID],
              state.closeLifecycle.acceptsWork,
              let session = state.runtimeSession,
              session.clientInstanceID == clientInstanceID,
              let kind = event["eventKind"]?.stringValue
        else { return }
        switch kind {
        case "deviceDisconnected":
            resetCaptureActivation(in: state)
            state.ownerCoordinator.invalidateOwnedStreamsForReconnect()
            state.pointerStream = nil
            state.keyboardStream = nil
            state.keyboardPendingFrames.removeAll()
            state.keyboardInteractionID = nil
            state.keyboardRuntimeCapabilityReady = false
            resetPointerInteractions(in: state)
            state.interactionView.clearPointerOverlay()
            stopBoundVideo(
                state,
                presentation: .freezeIfAvailable(reason: .deviceDetached),
                invalidateCoordinateAuthority: true
            )
            state.liveModel.setControlUnavailable(reason: "deviceDisconnected")
            state.toolbarButtons.values.forEach { $0.isEnabled = false }
            setStatus("Device disconnected", busy: false, in: state)
        case "availabilityInvalidated":
            guard let replacement = session.currentAttachment else { return }
            if state.captureReadyConnectionEpoch != replacement.connectionEpoch {
                resetCaptureActivation(in: state)
            }
            do {
                try state.ownerCoordinator.replaceAttachmentAfterReconnect(
                    replacement,
                    clientInstanceID: clientInstanceID,
                    windowID: windowID,
                    registry: &liveOwnerRegistry
                )
                try state.liveModel.setControlAvailable(
                    connectionEpoch: replacement.connectionEpoch
                )
                state.pointerLastFailure = nil
            } catch {
                return
            }
            setStatus("Restoring controls", busy: true, in: state)
            updateSourceControls(state)
            maybeStartCachedBinding(in: state)
            runtimeQueue.async { [weak self] in
                let availability = try? session.availability()
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self,
                              let current = self.windows[windowID],
                              current.runtimeSession === session,
                              current.runtimeSession?.currentAttachment
                                == replacement,
                              let availability
                        else { return }
                        self.applyToolbarAvailability(availability, in: current)
                        self.setStatus(nil, busy: false, in: current)
                        self.maybeStartCachedBinding(in: current)
                    }
                }
            }
        default:
            break
        }
    }

    @MainActor
    private func handleObservationReset(
        _ reset: ObservationStreamReset,
        clientInstanceID: CanonicalUUID,
        windowID: String
    ) {
        guard let state = windows[windowID],
              state.runtimeSession?.clientInstanceID == clientInstanceID
        else { return }
        state.observationOverlay.applyReset(reset)
        state.interactionView.clearPointerOverlay()
    }

    @MainActor
    private func handleRuntimeObservation(
        _ observation: RuntimeObservation,
        clientInstanceID: CanonicalUUID,
        windowID: String
    ) {
        guard let state = windows[windowID],
              state.closeLifecycle.acceptsWork,
              let session = state.runtimeSession,
              session.clientInstanceID == clientInstanceID,
              session.currentAttachment?.subscriptionID
                == observation.subscriptionID,
              state.liveModel.runtimeGeometry != nil
        else { return }
        let disposition = state.observationOverlay.receive(
            observation: observation
        )
        switch disposition {
        case .ignoredStale, .deduplicatedEcho:
            return
        case .resetForSequenceGap:
            state.interactionView.clearPointerOverlay()
        case .insertedRuntimeEcho:
            break
        }
        guard state.interactionView.showPointerOverlay(
            projection: observation.presentationPayload
        ) else {
            state.observationOverlay.remove(
                clientInstanceID: observation.clientInstanceID,
                interactionID: observation.interactionID
            )
            return
        }
        if observation.presentationPayload.frameKind == .end
            || observation.presentationPayload.frameKind == .cancel
        {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                [weak self] in
                MainActor.assumeIsolated {
                    self?.windows[windowID]?.observationOverlay.remove(
                        clientInstanceID: observation.clientInstanceID,
                        interactionID: observation.interactionID
                    )
                }
            }
        }
    }

    @MainActor
    private func handleRuntimeTransportFailure(
        _ failure: RuntimeClientError,
        clientInstanceID: CanonicalUUID,
        windowID: String
    ) {
        guard let state = windows[windowID],
              state.closeLifecycle.acceptsWork,
              let session = state.runtimeSession,
              session.clientInstanceID == clientInstanceID
        else { return }
        if let ownership = state.ownerCoordinator.currentAttachment {
            _ = try? liveOwnerRegistry.detach(ownership)
        }
        state.runtimeSession = nil
        resetCaptureActivation(in: state)
        state.ownerCoordinator = LiveOwnerCoordinator()
        resetPointerInteractions(in: state)
        stopBoundVideo(
            state,
            presentation: .freezeIfAvailable(reason: .sourceUnavailable),
            invalidateCoordinateAuthority: true
        )
        state.liveModel.setControlUnavailable(reason: "runtimeUnavailable")
        setStatus(
            "Reconnecting controls: \(Self.runtimeClientErrorCode(failure))",
            busy: true,
            in: state
        )
        runtimeQueue.async { try? session.close() }
        startRuntimeSession(for: state)
    }

    @MainActor
    private func refreshToolbarAvailability(
        in state: ProductionGUIHostWindowState
    ) {
        guard let session = state.runtimeSession else { return }
        let identifier = state.windowID
        runtimeQueue.async { [weak self] in
            let availability = try? session.availability()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          let state = self.windows[identifier],
                          let availability
                    else { return }
                    self.applyToolbarAvailability(availability, in: state)
                }
            }
        }
    }

    @MainActor
    private func applyToolbarAvailability(
        _ availability: RepositoryJSONObject,
        in state: ProductionGUIHostWindowState
    ) {
        state.liveModel.setPointerCapabilityAvailable(
            ProductionGUIHostToolbarProjection.commandIsAvailable(
                "gui.pointer.interaction",
                availability: availability
            )
        )
        refreshAvailabilityOverlay(in: state)
        state.keyboardRuntimeCapabilityReady =
            ProductionGUIHostToolbarProjection.commandIsAvailable(
                "gui.keyboard.interaction",
                availability: availability
            )
        reevaluateKeyboardCapture(in: state)
        guard let root = toolbarRepositoryRoot,
              var toolbar = try? ProductionGUIHostToolbarProjection.make(
                  availability: availability,
                  repositoryRoot: root
              ),
              state.toolbarModel == nil
                || state.toolbarModel?.commandIDs == toolbar.commandIDs
        else { return }
        if !state.keyboardRuntimeCapabilityReady {
            try? toolbar.setLocalPresentation(
                commandID: "gui.keyboardCapture.toggle",
                presentation: .disabled(reason: "deviceKeyboardUnavailable")
            )
        }
        try? toolbar.setLocalToggle(
            commandID: "gui.keyboardCapture.toggle",
            selected: state.keyboardController.isEnabled
        )
        try? toolbar.setLocalToggle(
            commandID: "gui.previewAudioMute.toggle",
            selected: state.audioPreview.isMacOutputEnabled
        )
        state.toolbarModel = toolbar
        installToolbar(on: state)
    }

    @MainActor
    private func dropKeyboardCaptureForClose(
        _ state: ProductionGUIHostWindowState
    ) {
        let transition = state.keyboardController.updateContext(
            enabled: false,
            keyWindow: false,
            firstResponder: false,
            eventTapAvailable: false,
            runtimeCapabilityReady: false
        )
        if case .releaseAllRequired(let reason) = transition {
            releaseKeyboardInteraction(in: state, reason: reason)
        }
        state.keyboardPendingFrames.removeAll()
        state.keyboardInteractionID = nil
        state.keyboardShortCloseToken = nil
        updateKeyboardEventTapRoute()
    }

    @MainActor
    private func closeRuntime(
        _ state: ProductionGUIHostWindowState,
        completion: @escaping @MainActor () -> Void
    ) {
        dropKeyboardCaptureForClose(state)
        resetPointerInteractions(in: state)
        guard let session = state.runtimeSession else {
            completion()
            return
        }
        let attachment = session.currentAttachment
        let now = SystemMonotonicClock().now().nanoseconds
        _ = try? state.ownerCoordinator.beginClose(atNanoseconds: now)
        let pointer = state.pointerStream
        let keyboard = state.keyboardStream
        state.pointerStream = nil
        state.keyboardStream = nil
        state.runtimeSession = nil
        runtimeQueue.async { [weak self] in
            if let pointer {
                _ = try? session.cancelStream(pointer, reason: "ownerLost")
            }
            if let keyboard {
                _ = try? session.cancelStream(keyboard, reason: "ownerLost")
            }
            let detached = try? session.detach()
            try? session.close()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else {
                        completion()
                        return
                    }
                    var clock = SystemMonotonicClock().now().nanoseconds
                    if let pointer {
                        _ = try? state.ownerCoordinator.completeOwnedStreamCleanup(
                            pointer.sessionID,
                            atNanoseconds: clock
                        )
                        clock &+= 1
                    }
                    if let keyboard {
                        _ = try? state.ownerCoordinator.completeOwnedStreamCleanup(
                            keyboard.sessionID,
                            atNanoseconds: clock
                        )
                        clock &+= 1
                    }
                    if let detached {
                        _ = try? state.ownerCoordinator.completeDetach(
                            detached,
                            registry: &self.liveOwnerRegistry,
                            atNanoseconds: clock
                        )
                        clock &+= 1
                        _ = try? state.ownerCoordinator.completeConnectionClose(
                            atNanoseconds: clock
                        )
                    } else if let attachment {
                        // Closing the transport revokes the server-side owner even
                        // when its detach acknowledgement cannot be delivered.
                        _ = try? self.liveOwnerRegistry.detach(attachment)
                    }
                    completion()
                }
            }
        }
    }

    @MainActor
    private func bindInteractionHandlers(to state: ProductionGUIHostWindowState) {
        let identifier = state.windowID
        state.interactionView.pointerBegan = { [weak self] point, rect in
            self?.pointerBegan(in: identifier, point: point, visibleRect: rect)
                ?? false
        }
        state.interactionView.pointerMoved = { [weak self] point, rect in
            self?.pointerMoved(in: identifier, point: point, visibleRect: rect)
                ?? false
        }
        state.interactionView.pointerEnded = { [weak self] point, rect in
            self?.pointerEnded(in: identifier, point: point, visibleRect: rect)
                ?? false
        }
        state.interactionView.keyEvent = { [weak self] event, kind, pressed in
            self?.handleKeyEvent(
                in: identifier,
                event: event,
                kind: kind,
                pressed: pressed
            ) ?? false
        }
        state.interactionView.firstResponderChanged = { [weak self] _ in
            guard let self,
                  let state = self.windows[identifier]
            else { return }
            self.reevaluateKeyboardCapture(in: state)
        }
    }

    @MainActor
    private func pointerBegan(
        in identifier: String,
        point: PointerViewPoint,
        visibleRect: PointerVisibleImageRect
    ) -> Bool {
        let acceptedAt = SystemMonotonicClock().now().nanoseconds
        guard let state = windows[identifier], state.closeLifecycle.acceptsWork else {
            return false
        }
        guard !state.captureGenerationTransitionInFlight else {
            recordPointerFailure(
                .init(stage: .admission, code: "capabilityPreparing"),
                in: state,
                reset: false
            )
            return false
        }
        guard !state.liveResizeFramesWithheld,
              !state.awaitingLiveResizePresentation
        else {
            recordPointerFailure(
                .init(stage: .admission, code: "capabilityPreparing"),
                in: state,
                reset: false
            )
            return false
        }
        guard !state.pointerGestureInProgress else {
            recordPointerFailure(
                .init(stage: .admission, code: "gestureAlreadyActive"),
                in: state,
                reset: false
            )
            return false
        }
        guard state.pointerInteractionQueue.count < 32 else {
            recordPointerFailure(
                .init(stage: .admission, code: "interactionBackpressure"),
                in: state,
                reset: false
            )
            return false
        }
        guard let geometry = ProductionLiveGeometryProjection
            .coordinateAdmissionGeometry(
                liveModel: state.liveModel,
                videoBinding: state.videoSession?.bindingIdentity,
                videoBindingInFlight: state.videoBindingInFlight
            )
        else {
            recordPointerFailure(
                .init(
                    stage: .admission,
                    code: state.videoBindingInFlight
                        ? "capabilityPreparing"
                        : "geometryUnavailable"
                ),
                in: state,
                reset: false
            )
            return false
        }
        do {
            let frame = try state.pointerController.begin(
                at: point,
                visibleImageRect: visibleRect,
                geometry: geometry
            )
            let interactionID = CanonicalUUID(value: UUID())
            state.pointerGestureInProgress = true
            state.pointerInteractionQueue.append(ProductionQueuedPointerInteraction(
                interactionID: interactionID,
                startedAtNanoseconds: acceptedAt,
                pendingFrames: [(frame, frame.sequence)]
            ))
            Self.pointerLatencyLogger.notice(
                "stage=p0 interactionID=\(interactionID.canonicalString, privacy: .public) acceptedMonotonicNs=\(acceptedAt, privacy: .public)"
            )
            showOptimisticPointer(frame, interactionID: interactionID, in: state)
            drivePointerQueue(in: state)
            return true
        } catch {
            recordPointerFailure(
                .init(stage: .admission, code: "invalidFrameOrder"),
                in: state,
                reset: true
            )
            return false
        }
    }

    @MainActor
    private func pointerMoved(
        in identifier: String,
        point: PointerViewPoint,
        visibleRect: PointerVisibleImageRect
    ) -> Bool {
        guard let state = windows[identifier], state.closeLifecycle.acceptsWork else {
            return false
        }
        guard state.pointerGestureInProgress else { return false }
        do {
            let frame = try state.pointerController.move(
                to: point,
                visibleImageRect: visibleRect
            )
            appendPointerFrame(frame, in: state)
            return true
        } catch {
            recordPointerFailure(
                .init(stage: .admission, code: "invalidFrameOrder"),
                in: state,
                reset: true
            )
            return false
        }
    }

    @MainActor
    private func pointerEnded(
        in identifier: String,
        point: PointerViewPoint,
        visibleRect: PointerVisibleImageRect
    ) -> Bool {
        guard let state = windows[identifier], state.closeLifecycle.acceptsWork else {
            return false
        }
        guard state.pointerGestureInProgress else { return false }
        do {
            let frame = try state.pointerController.end(
                at: point,
                visibleImageRect: visibleRect
            )
            appendPointerFrame(frame, in: state)
            state.pointerGestureInProgress = false
            state.pointerController = PointerInteractionController()
            return true
        } catch {
            recordPointerFailure(
                .init(stage: .admission, code: "invalidFrameOrder"),
                in: state,
                reset: true
            )
            return false
        }
    }

    @MainActor
    private func appendPointerFrame(
        _ frame: PointerInteractionFrame,
        in state: ProductionGUIHostWindowState
    ) {
        guard state.closeLifecycle.acceptsWork,
              !state.pointerInteractionQueue.isEmpty
        else { return }
        let index = state.pointerInteractionQueue.index(before:
            state.pointerInteractionQueue.endIndex)
        state.pointerInteractionQueue[index].pendingFrames.append((frame, frame.sequence))
        let interactionID = state.pointerInteractionQueue[index].interactionID
        showOptimisticPointer(frame, interactionID: interactionID, in: state)
        drivePointerQueue(in: state)
    }

    @MainActor
    private func showOptimisticPointer(
        _ frame: PointerInteractionFrame,
        interactionID: CanonicalUUID,
        in state: ProductionGUIHostWindowState
    ) {
        guard let clientInstanceID = state.runtimeSession?.clientInstanceID else {
            return
        }
        state.observationOverlay.showOptimistic(
            clientInstanceID: clientInstanceID,
            interactionID: interactionID,
            projection: RuntimePointerProjection(
                edge: frame.edge.rawValue,
                frameKind: RuntimePointerFrameKind(
                    rawValue: frame.kind.rawValue
                ) ?? .cancel,
                x: frame.point.x,
                y: frame.point.y
            )
        )
        if frame.kind == .end || frame.kind == .cancel {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak state] in
                state?.observationOverlay.remove(
                    clientInstanceID: clientInstanceID,
                    interactionID: interactionID
                )
            }
        }
    }

    @MainActor
    private func drivePointerQueue(in state: ProductionGUIHostWindowState) {
        guard state.closeLifecycle.acceptsWork,
              !state.captureGenerationTransitionInFlight,
              !state.pointerInteractionQueue.isEmpty
        else { return }
        if let stream = state.pointerStream {
            guard !state.pointerStreamClosing else { return }
            flushPointerFrames(in: state, stream: stream)
        } else if !state.pointerStreamOpening {
            openPointerStream(in: state)
        }
    }

    @MainActor
    private func openPointerStream(in state: ProductionGUIHostWindowState) {
        guard let session = state.runtimeSession,
              let geometry = state.liveModel.runtimeGeometry,
              let interaction = state.pointerInteractionQueue.first,
              let assertion = interaction.geometryAssertion
        else { return }
        guard assertion.expectedConnectionEpoch == geometry.connectionEpoch,
              assertion.expectedGeometryRevision == geometry.geometryRevision
        else {
            state.pointerInteractionQueue.removeFirst()
            if state.pointerInteractionQueue.isEmpty,
               state.pointerGestureInProgress
            {
                resetPointerInteractions(in: state)
            }
            recordPointerFailure(
                .init(stage: .admission, code: "geometryChanged"),
                in: state,
                reset: false
            )
            drivePointerQueue(in: state)
            return
        }
        state.pointerStreamOpening = true
        let identifier = state.windowID
        let interactionID = interaction.interactionID
        let gestureStartedAt = interaction.startedAtNanoseconds
        runtimeQueue.async { [weak self] in
            let stream: ProductionRuntimeLiveStream?
            let failure: ProductionPointerInteractionFailure?
            do {
                stream = try session.openStream(
                    commandID: "gui.pointer.interaction",
                    rawArguments: [
                        "geometryRevision": String(geometry.geometryRevision),
                        "logicalHeight": String(geometry.logicalHeight),
                        "logicalWidth": String(geometry.logicalWidth),
                        "orientation": geometry.orientation.rawValue,
                    ],
                    actionID: CanonicalUUID(value: UUID()),
                    interactionID: interactionID
                )
                failure = nil
            } catch {
                stream = nil
                failure = ProductionPointerInteractionFailure(
                    stage: .streamOpen,
                    code: Self.runtimeClientErrorCode(error)
                )
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          let state = self.windows[identifier],
                          state.closeLifecycle.acceptsWork,
                          state.pointerInteractionQueue.first?.interactionID
                            == interactionID
                    else {
                        if let stream { self?.runtimeQueue.async {
                            _ = try? session.cancelStream(stream, reason: "ownerLost")
                        } }
                        return
                    }
                    state.pointerStreamOpening = false
                    guard let stream else {
                        state.pointerInteractionQueue.removeFirst()
                        if state.pointerInteractionQueue.isEmpty,
                           state.pointerGestureInProgress
                        {
                            self.resetPointerInteractions(in: state)
                        }
                        self.recordPointerFailure(
                            failure ?? .init(
                                stage: .streamOpen,
                                code: "outcomeUnknown"
                            ),
                            in: state,
                            reset: false
                        )
                        self.drivePointerQueue(in: state)
                        return
                    }
                    if let acceptedGeometry = stream.acceptedGeometry,
                       !self.adoptAcceptedPointerGeometry(
                        acceptedGeometry,
                        expected: geometry,
                        interactionID: interactionID,
                        in: state
                       )
                    {
                        state.pointerInteractionQueue.removeFirst()
                        if state.pointerInteractionQueue.isEmpty,
                           state.pointerGestureInProgress
                        {
                            self.resetPointerInteractions(in: state)
                        }
                        self.runtimeQueue.async {
                            _ = try? session.cancelStream(
                                stream,
                                reason: "geometryInvalidated"
                            )
                        }
                        self.recordPointerFailure(
                            .init(stage: .streamOpen, code: "capabilityUnavailable"),
                            in: state,
                            reset: false
                        )
                        self.drivePointerQueue(in: state)
                        return
                    }
                    state.pointerStream = stream
                    try? state.ownerCoordinator.registerOwnedStream(stream.sessionID)
                    let openedAt = SystemMonotonicClock().now().nanoseconds
                    Self.pointerLatencyLogger.notice(
                        "stage=p1 sessionID=\(stream.sessionID.canonicalString, privacy: .public) interactionID=\(stream.interactionID.canonicalString, privacy: .public) openedMonotonicNs=\(openedAt, privacy: .public) p1MinusP0Us=\(Self.elapsedMicroseconds(gestureStartedAt, openedAt), privacy: .public) executorGeneration=\(stream.executorGeneration, privacy: .public)"
                    )
                    self.flushPointerFrames(in: state, stream: stream)
                }
            }
        }
    }

    @MainActor
    private func adoptAcceptedPointerGeometry(
        _ accepted: DisplayGeometryDTO,
        expected: DisplayGeometryDTO,
        interactionID: CanonicalUUID,
        in state: ProductionGUIHostWindowState
    ) -> Bool {
        guard state.liveModel.runtimeGeometry == expected,
              state.pointerInteractionQueue.first?.interactionID == interactionID,
              accepted.connectionEpoch == expected.connectionEpoch,
              accepted.logicalWidth == expected.logicalWidth,
              accepted.logicalHeight == expected.logicalHeight,
              accepted.orientation == expected.orientation,
              accepted.geometryRevision >= expected.geometryRevision
        else { return false }
        guard accepted != expected else { return true }

        var interactions = state.pointerInteractionQueue
        var controller = state.pointerController
        var liveModel = state.liveModel
        for index in interactions.indices {
            guard interactions[index].adoptGeometryRevision(
                from: expected,
                to: accepted
            ) else { return false }
        }
        guard controller.adoptGeometryRevision(from: expected, to: accepted),
              (try? liveModel.updateRuntimeGeometry(accepted)) != nil,
              state.videoSession?.rebindGeometry(accepted) != false
        else { return false }

        state.pointerInteractionQueue = interactions
        state.pointerController = controller
        state.liveModel = liveModel
        state.geometryRevision = max(
            state.geometryRevision,
            accepted.geometryRevision
        )
        state.interactionView.geometry = accepted
        state.observationOverlay = InputObservationOverlay()
        Self.pointerLatencyLogger.notice(
            "stage=geometryAdopted interactionID=\(interactionID.canonicalString, privacy: .public) previousRevision=\(expected.geometryRevision, privacy: .public) acceptedRevision=\(accepted.geometryRevision, privacy: .public)"
        )
        return true
    }

    @MainActor
    private func flushPointerFrames(
        in state: ProductionGUIHostWindowState,
        stream: ProductionRuntimeLiveStream
    ) {
        guard let session = state.runtimeSession,
              let interaction = state.pointerInteractionQueue.first,
              interaction.interactionID == stream.interactionID,
              !interaction.pendingFrames.isEmpty
        else { return }
        let pending = interaction.pendingFrames
        state.pointerInteractionQueue[0].pendingFrames.removeAll(keepingCapacity: true)
        let terminal = ProductionPointerStreamTerminalDisposition.resolve(pending)
        if terminal != .keepOpen {
            state.pointerStreamClosing = true
        }
        let identifier = state.windowID
        runtimeQueue.async { [weak self] in
            var failure: ProductionPointerInteractionFailure?
            var sessionRecoveryRequired = false
            var attachmentToRelease: LiveAttachment?
            for item in pending {
                do {
                    let payload = try ProductionGUIHostFramePayload.pointer(item.frame)
                    try session.sendFrame(
                        stream: stream,
                        sequence: item.sequence,
                        frameKind: item.frame.kind.rawValue,
                        payload: payload,
                        clientSubmittedMonotonicNanoseconds:
                            SystemMonotonicClock().now().nanoseconds
                    )
                } catch {
                    failure = ProductionPointerInteractionFailure(
                        stage: error is RuntimeClientError
                            || error is ProductionRuntimeLiveSessionError
                            ? .frameSend
                            : .frameEncode,
                        code: Self.runtimeClientErrorCode(error)
                    )
                    break
                }
            }
            if failure != nil {
                do {
                    _ = try session.cancelStream(stream, reason: "clientInterrupted")
                } catch {
                    failure = ProductionPointerInteractionFailure(
                        stage: .streamCancel,
                        code: Self.runtimeClientErrorCode(error)
                    )
                    sessionRecoveryRequired = true
                }
            } else {
                switch terminal {
                case .cancel:
                    do {
                        _ = try session.cancelStream(
                            stream,
                            reason: "geometryInvalidated"
                        )
                    } catch {
                        failure = ProductionPointerInteractionFailure(
                            stage: .streamCancel,
                            code: Self.runtimeClientErrorCode(error)
                        )
                        sessionRecoveryRequired = true
                    }
                case .close(let expectedLastSequence):
                    do {
                        _ = try session.closeStream(
                            stream,
                            expectedLastSequence: expectedLastSequence,
                            reason: "completed"
                        )
                    } catch {
                        failure = ProductionPointerInteractionFailure(
                            stage: .streamClose,
                            code: Self.runtimeClientErrorCode(error)
                        )
                        do {
                            _ = try session.cancelStream(stream, reason: "ownerLost")
                        } catch {
                            failure = ProductionPointerInteractionFailure(
                                stage: .streamCancel,
                                code: Self.runtimeClientErrorCode(error)
                            )
                            sessionRecoveryRequired = true
                        }
                    }
                case .keepOpen:
                    return
                }
            }
            if sessionRecoveryRequired {
                attachmentToRelease = session.currentAttachment
                try? session.close()
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          let current = self.windows[identifier],
                          current === state,
                          current.pointerStream?.sessionID == stream.sessionID,
                          current.pointerInteractionQueue.first?.interactionID
                            == stream.interactionID
                    else { return }
                    current.pointerStream = nil
                    current.pointerStreamClosing = false
                    current.pointerInteractionQueue.removeFirst()
                    if failure != nil,
                       terminal == .keepOpen,
                       current.pointerInteractionQueue.isEmpty
                    {
                        self.resetPointerInteractions(in: current)
                    }
                    try? current.ownerCoordinator.completeOwnedStream(
                        stream.sessionID
                    )
                    if let failure {
                        self.recordPointerFailure(failure, in: current, reset: false)
                    } else if current.pointerLastFailure != nil {
                        current.pointerLastFailure = nil
                        self.setStatus(nil, busy: false, in: current)
                    }
                    if sessionRecoveryRequired,
                       current.runtimeSession === session,
                       current.closeLifecycle.acceptsWork
                    {
                        if let attachmentToRelease {
                            _ = try? self.liveOwnerRegistry.detach(
                                attachmentToRelease
                            )
                        }
                        current.ownerCoordinator = LiveOwnerCoordinator()
                        current.runtimeSession = nil
                        self.resetPointerInteractions(in: current)
                        current.liveModel.setControlUnavailable(
                            reason: "runtimeUnavailable"
                        )
                        self.startRuntimeSession(for: current)
                    } else {
                        self.drivePointerQueue(in: current)
                    }
                }
            }
        }
    }

    @MainActor
    private func recordPointerFailure(
        _ failure: ProductionPointerInteractionFailure,
        in state: ProductionGUIHostWindowState,
        reset: Bool
    ) {
        state.pointerLastFailure = failure
        state.interactionView.clearPointerOverlay()
        if reset {
            resetPointerInteractions(in: state)
        }
        Self.pointerLatencyLogger.error(
            "stage=failure failureStage=\(failure.stage.rawValue, privacy: .public) code=\(failure.code, privacy: .public)"
        )
        setStatus(
            "Pointer unavailable: \(failure.stage.rawValue)/\(failure.code)",
            busy: false,
            in: state
        )
    }

    @MainActor
    private func resetPointerInteractions(in state: ProductionGUIHostWindowState) {
        state.pointerInteractionQueue.removeAll()
        state.pointerStreamClosing = false
        state.pointerStreamOpening = false
        state.pointerGestureInProgress = false
        state.pointerController = PointerInteractionController()
    }

    @MainActor
    private func appendPointerCancellation(
        _ frame: PointerInteractionFrame,
        in state: ProductionGUIHostWindowState
    ) {
        appendPointerFrame(frame, in: state)
        state.pointerGestureInProgress = false
        state.pointerController = PointerInteractionController()
    }

    @MainActor
    private func handleKeyEvent(
        in identifier: String,
        event: NSEvent,
        kind: KeyboardCaptureEventKind,
        pressed: Bool
    ) -> Bool {
        guard let state = windows[identifier],
              state.closeLifecycle.acceptsWork,
              let key = ProductionKeyboardHIDUsage.key(for: event)
        else { return false }
        return handleCapturedKeyEvent(
            ProductionKeyboardCapturedEvent(
                isPressed: pressed,
                key: key,
                kind: kind
            ),
            in: state
        )
    }

    @MainActor
    private func handleEventTapMessage(
        _ message: ProductionKeyboardEventTapMessage
    ) {
        switch message {
        case .disabled:
            keyboardEventTapFaulted = true
            keyboardEventTap.setCaptureActive(false)
            keyboardEventTap.invalidate()
            windows.values.forEach { reevaluateKeyboardCapture(in: $0) }
        case .event(let event):
            guard let identifier = keyboardCaptureWindowID,
                  let state = windows[identifier]
            else { return }
            _ = handleCapturedKeyEvent(event, in: state)
        }
    }

    @MainActor
    private func handleCapturedKeyEvent(
        _ event: ProductionKeyboardCapturedEvent,
        in state: ProductionGUIHostWindowState
    ) -> Bool {
        guard state.closeLifecycle.acceptsWork else { return false }
        let result = state.keyboardController.handle(KeyboardCaptureEvent(
            kind: event.kind,
            key: event.key,
            isPressed: event.isPressed
        ))
        while let frame = state.keyboardController.dequeueFrame() {
            enqueueKeyboard(frame, in: state)
        }
        if case .releaseAllRequired(let reason) = result.disposition {
            releaseKeyboardInteraction(in: state, reason: reason)
        }
        return result.consumed
    }

    @MainActor
    private func reevaluateKeyboardCapture(
        in state: ProductionGUIHostWindowState,
        enabled desiredEnabled: Bool? = nil,
        requestAuthorization: Bool = false
    ) {
        guard state.closeLifecycle.acceptsWork else { return }
        let enabled = desiredEnabled ?? state.keyboardController.isEnabled
        if requestAuthorization,
           enabled,
           keyboardEventTap.authorizationStatus != .authorized
        {
            keyboardEventTapFaulted = false
            _ = keyboardEventTap.requestAuthorization()
        }
        let keyWindow = (applicationIsActive?() ?? NSApplication.shared.isActive)
            && (windowIsKey?(state.window) ?? state.window.isKeyWindow)
        let firstResponder = state.window.firstResponder === state.interactionView
        let prerequisitesReady = enabled
            && keyWindow
            && firstResponder
            && state.keyboardRuntimeCapabilityReady
        if prerequisitesReady,
           keyboardEventTap.authorizationStatus == .authorized,
           !keyboardEventTapFaulted,
           !keyboardEventTap.isInstalled
        {
            _ = keyboardEventTap.install { [weak self] message in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.handleEventTapMessage(message)
                    }
                }
            }
        }
        let eventTapAvailable = keyboardEventTap.authorizationStatus == .authorized
            && keyboardEventTap.isInstalled
            && !keyboardEventTapFaulted
        let transition = state.keyboardController.updateContext(
            enabled: enabled,
            keyWindow: keyWindow,
            firstResponder: firstResponder,
            eventTapAvailable: eventTapAvailable,
            runtimeCapabilityReady: state.keyboardRuntimeCapabilityReady
        )
        if case .releaseAllRequired(let reason) = transition {
            releaseKeyboardInteraction(in: state, reason: reason)
        }
        updateKeyboardEventTapRoute()
        applyKeyboardCapturePresentation(to: state)
        if !windows.values.contains(where: { $0.keyboardController.isEnabled }) {
            keyboardEventTap.invalidate()
            keyboardEventTapFaulted = false
        }
    }

    @MainActor
    private func updateKeyboardEventTapRoute() {
        let active = windows.values.filter {
            $0.keyboardController.isCaptureActive
        }
        guard active.count == 1 else {
            keyboardCaptureWindowID = nil
            keyboardEventTap.setCaptureActive(false)
            return
        }
        keyboardCaptureWindowID = active[0].windowID
        keyboardEventTap.setCaptureActive(true)
    }

    @MainActor
    private func applyKeyboardCapturePresentation(
        to state: ProductionGUIHostWindowState
    ) {
        let commandID = "gui.keyboardCapture.toggle"
        let enabled = state.keyboardController.isEnabled
        let active = state.keyboardController.isCaptureActive
        try? state.toolbarModel?.setLocalToggle(
            commandID: commandID,
            selected: enabled
        )
        guard let button = state.toolbarButtons[commandID] else { return }
        button.state = enabled ? .on : .off
        if !state.keyboardRuntimeCapabilityReady {
            button.contentTintColor = enabled ? .systemOrange : nil
            button.toolTip = "Keyboard Capture unavailable: device keyboard not ready"
        } else if active {
            button.contentTintColor = .controlAccentColor
            button.toolTip = "Keyboard Capture active"
        } else if enabled {
            button.contentTintColor = .systemOrange
            switch keyboardEventTap.authorizationStatus {
            case .authorized where keyboardEventTapFaulted:
                button.toolTip = "Keyboard Capture unavailable: Event Tap disabled"
            case .authorized where !state.keyboardRuntimeCapabilityReady:
                button.toolTip = "Keyboard Capture unavailable: device keyboard not ready"
            case .authorized:
                button.toolTip = "Keyboard Capture enabled: focus the live canvas"
            case .denied:
                button.toolTip = "Keyboard Capture unavailable: Input Monitoring denied"
            case .notDetermined:
                button.toolTip = "Keyboard Capture unavailable: Input Monitoring required"
            case .restricted:
                button.toolTip = "Keyboard Capture unavailable: Input Monitoring restricted"
            }
        } else {
            button.contentTintColor = nil
            button.toolTip = "Keyboard Capture"
        }
        state.toolbarItems[commandID]?.toolTip = button.toolTip
    }

    @MainActor
    private func enqueueKeyboard(
        _ frame: KeyboardCaptureFrame,
        in state: ProductionGUIHostWindowState
    ) {
        guard state.closeLifecycle.acceptsWork,
              state.keyboardController.isCaptureActive
        else { return }
        guard state.keyboardPendingFrames.count
                < KeyboardCaptureController.maximumPendingFrames
        else {
            _ = state.keyboardController.streamFailed(.backpressure)
            releaseKeyboardInteraction(in: state, reason: .backpressure)
            return
        }
        state.keyboardShortCloseToken = nil
        state.keyboardPressedKeysEmpty = frame.pressedKeys.isEmpty
        state.keyboardPendingFrames.append((frame, frame.sequence))
        let interactionID: CanonicalUUID
        if let current = state.keyboardInteractionID {
            interactionID = current
        } else {
            interactionID = CanonicalUUID(value: UUID())
            state.keyboardInteractionID = interactionID
        }
        if let stream = state.keyboardStream, !state.keyboardStreamClosing {
            flushKeyboardFrames(in: state, stream: stream)
        } else if !state.keyboardStreamOpening && !state.keyboardStreamClosing {
            openKeyboardStream(in: state, interactionID: interactionID)
        }
    }

    @MainActor
    private func openKeyboardStream(
        in state: ProductionGUIHostWindowState,
        interactionID: CanonicalUUID
    ) {
        guard let session = state.runtimeSession,
              state.keyboardController.isCaptureActive,
              state.keyboardInteractionID == interactionID
        else { return }
        state.keyboardStreamOpening = true
        let identifier = state.windowID
        runtimeQueue.async { [weak self] in
            let stream: ProductionRuntimeLiveStream?
            do {
                stream = try session.openStream(
                    commandID: "gui.keyboard.interaction",
                    rawArguments: [:],
                    actionID: CanonicalUUID(value: UUID()),
                    interactionID: interactionID
                )
            } catch {
                stream = nil
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          let state = self.windows[identifier],
                          state.closeLifecycle.acceptsWork
                    else {
                        if let stream { self?.runtimeQueue.async {
                            _ = try? session.cancelStream(stream, reason: "ownerLost")
                        } }
                        return
                    }
                    state.keyboardStreamOpening = false
                    guard state.keyboardInteractionID == interactionID,
                          state.keyboardController.isCaptureActive
                    else {
                        if let stream { self.runtimeQueue.async {
                            _ = try? session.cancelStream(stream, reason: "ownerLost")
                        } }
                        return
                    }
                    guard let stream else {
                        state.keyboardPendingFrames.removeAll()
                        state.keyboardInteractionID = nil
                        _ = state.keyboardController.streamOpenFailed()
                        _ = state.keyboardController.recoverAfterCleanup()
                        self.updateKeyboardEventTapRoute()
                        self.applyKeyboardCapturePresentation(to: state)
                        self.setStatus("Keyboard stream unavailable", busy: false, in: state)
                        self.refreshToolbarAvailability(in: state)
                        return
                    }
                    state.keyboardStream = stream
                    try? state.ownerCoordinator.registerOwnedStream(stream.sessionID)
                    self.flushKeyboardFrames(in: state, stream: stream)
                }
            }
        }
    }

    @MainActor
    private func flushKeyboardFrames(
        in state: ProductionGUIHostWindowState,
        stream: ProductionRuntimeLiveStream
    ) {
        guard let session = state.runtimeSession,
              !state.keyboardPendingFrames.isEmpty
        else { return }
        let pending = state.keyboardPendingFrames
        state.keyboardPendingFrames.removeAll(keepingCapacity: true)
        let identifier = state.windowID
        runtimeQueue.async { [weak self] in
            var deliveryFailed = false
            for item in pending {
                guard let payload = try? ProductionGUIHostFramePayload.keyboard(
                    item.frame
                ) else { continue }
                do {
                    try session.sendFrame(
                        stream: stream,
                        sequence: item.sequence,
                        frameKind: "pressedSet",
                        payload: payload,
                        clientSubmittedMonotonicNanoseconds:
                            SystemMonotonicClock().now().nanoseconds
                    )
                } catch {
                    deliveryFailed = true
                    break
                }
            }
            if deliveryFailed {
                _ = try? session.cancelStream(stream, reason: "transportFailure")
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          let current = self.windows[identifier],
                          current === state,
                          current.keyboardStream?.sessionID == stream.sessionID
                    else { return }
                    if deliveryFailed {
                        current.keyboardStream = nil
                        current.keyboardInteractionID = nil
                        current.keyboardPendingFrames.removeAll()
                        current.keyboardPressedKeysEmpty = true
                        current.keyboardShortCloseToken = nil
                        _ = current.keyboardController.streamFailed(.transportFailure)
                        try? current.ownerCoordinator.completeOwnedStream(
                            stream.sessionID
                        )
                        _ = current.keyboardController.recoverAfterCleanup()
                        self.updateKeyboardEventTapRoute()
                        self.applyKeyboardCapturePresentation(to: current)
                        self.setStatus(
                            "Keyboard transport unavailable",
                            busy: false,
                            in: current
                        )
                        self.refreshToolbarAvailability(in: current)
                    } else if current.keyboardPressedKeysEmpty,
                              current.keyboardPendingFrames.isEmpty,
                              let lastSequence = pending.last?.sequence
                    {
                        self.scheduleKeyboardShortClose(
                            in: current,
                            stream: stream,
                            expectedLastSequence: lastSequence
                        )
                    }
                }
            }
        }
    }

    @MainActor
    private func scheduleKeyboardShortClose(
        in state: ProductionGUIHostWindowState,
        stream: ProductionRuntimeLiveStream,
        expectedLastSequence: UInt64
    ) {
        let token = UUID()
        state.keyboardShortCloseToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) {
            [weak self, weak state] in
            MainActor.assumeIsolated {
                guard let self,
                      let state,
                      state.keyboardShortCloseToken == token,
                      state.keyboardStream?.sessionID == stream.sessionID,
                      state.keyboardPressedKeysEmpty,
                      state.keyboardPendingFrames.isEmpty,
                      (try? state.keyboardController.completeShortInteraction()) != nil
                else { return }
                state.keyboardShortCloseToken = nil
                state.keyboardStream = nil
                state.keyboardStreamClosing = true
                state.keyboardInteractionID = nil
                let session = state.runtimeSession
                self.runtimeQueue.async { [weak self] in
                    var closed = false
                    if let session {
                        closed = (try? session.closeStream(
                            stream,
                            expectedLastSequence: expectedLastSequence,
                            reason: "allReleased"
                        )) != nil
                        if !closed {
                            _ = try? session.cancelStream(
                                stream,
                                reason: "transportFailure"
                            )
                        }
                    }
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self,
                                  let current = self.windows[state.windowID],
                                  current === state
                            else { return }
                            current.keyboardStreamClosing = false
                            try? current.ownerCoordinator.completeOwnedStream(
                                stream.sessionID
                            )
                            if !closed {
                                _ = current.keyboardController.streamFailed(
                                    .transportFailure
                                )
                                current.keyboardPendingFrames.removeAll()
                                current.keyboardInteractionID = nil
                                current.keyboardPressedKeysEmpty = true
                                _ = current.keyboardController.recoverAfterCleanup()
                            }
                            if current.keyboardController.isCaptureActive,
                               !current.keyboardPendingFrames.isEmpty,
                               let interactionID = current.keyboardInteractionID
                            {
                                self.openKeyboardStream(
                                    in: current,
                                    interactionID: interactionID
                                )
                            }
                            self.updateKeyboardEventTapRoute()
                            self.applyKeyboardCapturePresentation(to: current)
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func releaseKeyboardInteraction(
        in state: ProductionGUIHostWindowState,
        reason: KeyboardCaptureCleanupReason
    ) {
        state.keyboardShortCloseToken = nil
        state.keyboardPendingFrames.removeAll()
        state.keyboardInteractionID = nil
        state.keyboardPressedKeysEmpty = true
        guard let stream = state.keyboardStream,
              let session = state.runtimeSession
        else {
            updateKeyboardEventTapRoute()
            applyKeyboardCapturePresentation(to: state)
            return
        }
        state.keyboardStream = nil
        state.keyboardStreamClosing = true
        let identifier = state.windowID
        runtimeQueue.async { [weak self] in
            _ = try? session.cancelStream(stream, reason: reason.rawValue)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          let current = self.windows[identifier],
                          current === state
                    else { return }
                    current.keyboardStreamClosing = false
                    try? current.ownerCoordinator.completeOwnedStream(
                        stream.sessionID
                    )
                    _ = current.keyboardController.recoverAfterCleanup()
                    self.updateKeyboardEventTapRoute()
                    self.applyKeyboardCapturePresentation(to: current)
                }
            }
        }
    }

    @MainActor
    private func installToolbar(on state: ProductionGUIHostWindowState) {
        guard state.toolbarModel != nil else { return }
        if state.window.toolbar != nil {
            updateToolbarButtons(in: state)
            return
        }
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier(
            "pulsephone.live.\(state.windowID)"
        ))
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .small
        toolbar.allowsUserCustomization = false
        state.window.toolbarStyle = .unifiedCompact
        state.window.toolbar = toolbar
        applyWindowReservation(state)
    }

    @MainActor
    private func updateToolbarButtons(in state: ProductionGUIHostWindowState) {
        guard let toolbar = state.toolbarModel else { return }
        synchronizeToolbarItems(in: state)
        for slot in toolbar.slots {
            let enabled = Self.toolbarEnabled(
                slot.presentation,
                commandID: slot.commandID
            )
                && (!state.captureGenerationTransitionInFlight
                    || slot.commandID == "gui.previewAudioMute.toggle")
            let toolTip = Self.toolbarToolTip(slot)
            if let item = state.toolbarItems[slot.commandID] {
                item.isEnabled = enabled
                item.toolTip = toolTip
                item.menuFormRepresentation?.isEnabled = enabled
                item.menuFormRepresentation?.toolTip = toolTip
            }
            if let button = state.toolbarButtons[slot.commandID] {
                button.isEnabled = enabled
                button.state = slot.selected == true ? .on : .off
                button.toolTip = toolTip
            }
        }
        updateMoreToolbarButton(in: state)
        state.window.toolbar?.validateVisibleItems()
        applyKeyboardCapturePresentation(to: state)
    }

    @MainActor
    private func synchronizeToolbarItems(in state: ProductionGUIHostWindowState) {
        guard let toolbar = state.window.toolbar else { return }
        let identifiers = toolbarItemIdentifiers(for: state)
        guard identifiers != state.toolbarItemIdentifiers else { return }

        for index in toolbar.items.indices.reversed() {
            toolbar.removeItem(at: index)
        }
        state.toolbarItems.removeAll()
        state.toolbarButtons.removeAll()
        for (index, identifier) in identifiers.enumerated() {
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
        }
        state.toolbarItemIdentifiers = identifiers
    }

    @MainActor
    private func updateMoreToolbarButton(in state: ProductionGUIHostWindowState) {
        guard let button = state.toolbarButtons[Self.moreToolbarCommandID] else {
            return
        }
        let hasPopoverActions = !Self.morePopoverSlots(in: state).isEmpty
        button.isEnabled = hasPopoverActions
        button.toolTip = hasPopoverActions ? "More Controls" : "More Controls unavailable"
        state.toolbarItems[Self.moreToolbarCommandID]?.isEnabled = hasPopoverActions
        state.toolbarItems[Self.moreToolbarCommandID]?.toolTip = button.toolTip
    }

    public func toolbarAllowedItemIdentifiers(
        _ toolbar: NSToolbar
    ) -> [NSToolbarItem.Identifier] {
        MainActor.assumeIsolated {
            guard let state = toolbarState(toolbar) else { return [] }
            return toolbarItemIdentifiers(for: state)
        }
    }

    public func toolbarDefaultItemIdentifiers(
        _ toolbar: NSToolbar
    ) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        MainActor.assumeIsolated {
            guard let state = toolbarState(toolbar),
                  let commandID = Self.commandID(from: itemIdentifier),
                  commandID == Self.moreToolbarCommandID
                    || Self.topToolbarSlots(in: state).contains(where: {
                        $0.commandID == commandID
                    })
            else { return nil }
            if commandID == Self.moreToolbarCommandID {
                return moreToolbarItem(itemIdentifier: itemIdentifier, state: state)
            }
            guard let slot = state.toolbarModel?.slots.first(where: {
                $0.commandID == commandID
            }) else { return nil }
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let button: NSButton
            if commandID == "app.install" {
                let installButton = ProductionIPAInstallButton(
                    image: Self.toolbarImage(commandID),
                    target: self,
                    action: #selector(toolbarAction(_:))
                )
                installButton.acceptedDrop = { [weak self, weak state] parameter in
                    guard let self, let state, state.closeLifecycle.acceptsWork else {
                        return
                    }
                    self.submitAcceptedIPA(parameter, in: state)
                }
                installButton.invalidDrop = { [weak self, weak state] in
                    guard let self, let state, state.closeLifecycle.acceptsWork else {
                        return
                    }
                    self.setStatus("invalidIPAPath", busy: false, in: state)
                }
                button = installButton
            } else {
                button = NSButton(
                    image: Self.toolbarImage(commandID),
                    target: self,
                    action: #selector(toolbarAction(_:))
                )
            }
            button.identifier = NSUserInterfaceItemIdentifier(itemIdentifier.rawValue)
            button.bezelStyle = .texturedRounded
            button.imagePosition = .imageOnly
            button.toolTip = Self.toolbarToolTip(slot)
            button.setButtonType(slot.controlKind == .checkedToggle
                ? .toggle
                : .momentaryPushIn)
            button.state = slot.selected == true ? .on : .off
            button.isEnabled = Self.toolbarEnabled(
                slot.presentation,
                commandID: commandID
            )
                && (!state.captureGenerationTransitionInFlight
                    || commandID == "gui.previewAudioMute.toggle")
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
            item.label = Self.toolbarLabel(commandID)
            item.toolTip = button.toolTip
            item.visibilityPriority = Self.toolbarVisibilityPriority(commandID)
            item.menuFormRepresentation = toolbarMenuItem(
                commandID: commandID,
                windowID: state.windowID,
                slot: slot
            )
            item.view = button
            state.toolbarItems[commandID] = item
            state.toolbarButtons[commandID] = button
            return item
        }
    }

    @MainActor
    private func toolbarItemIdentifiers(
        for state: ProductionGUIHostWindowState
    ) -> [NSToolbarItem.Identifier] {
        guard state.toolbarModel != nil else { return [] }
        let visibleSlots = Self.topToolbarSlots(in: state)
        var identifiers = visibleSlots.map {
            toolbarIdentifier(windowID: state.windowID, commandID: $0.commandID)
        }
        identifiers.append(.flexibleSpace)
        identifiers.append(toolbarIdentifier(
            windowID: state.windowID,
            commandID: Self.moreToolbarCommandID
        ))
        return identifiers
    }

    @MainActor
    private func moreToolbarItem(
        itemIdentifier: NSToolbarItem.Identifier,
        state: ProductionGUIHostWindowState
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        let button = NSButton(
            image: NSImage(
                systemSymbolName: "ellipsis.circle",
                accessibilityDescription: "More Controls"
            ) ?? NSImage(),
            target: self,
            action: #selector(toolbarAction(_:))
        )
        button.identifier = NSUserInterfaceItemIdentifier(itemIdentifier.rawValue)
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.toolTip = "More Controls"
        button.setButtonType(.momentaryPushIn)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        item.label = "More Controls"
        item.toolTip = button.toolTip
        item.visibilityPriority = .high
        item.view = button
        state.toolbarItems[Self.moreToolbarCommandID] = item
        state.toolbarButtons[Self.moreToolbarCommandID] = button
        updateMoreToolbarButton(in: state)
        return item
    }

    @MainActor
    private func toolbarMenuItem(
        commandID: String,
        windowID: String,
        slot: LiveToolbarSlot
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: Self.toolbarLabel(commandID),
            action: #selector(toolbarMenuAction(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.image = Self.toolbarImage(commandID)
        item.representedObject = toolbarIdentifier(
            windowID: windowID,
            commandID: commandID
        ).rawValue
        item.isEnabled = Self.toolbarEnabled(
            slot.presentation,
            commandID: commandID
        )
        item.toolTip = Self.toolbarToolTip(slot)
        return item
    }

    @MainActor
    @objc private func toolbarAction(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let separator = raw.range(of: "::"),
              let state = windows[String(raw[..<separator.lowerBound])],
              state.closeLifecycle.acceptsWork
        else { return }
        let commandID = String(raw[separator.upperBound...])
        guard !state.captureGenerationTransitionInFlight
                || commandID == "gui.previewAudioMute.toggle"
                || commandID == Self.moreToolbarCommandID
        else { return }
        if commandID == Self.moreToolbarCommandID {
            showMoreToolbarPopover(from: sender, in: state)
            return
        }
        performToolbarCommand(commandID, sender: sender, in: state)
    }

    @MainActor
    @objc private func toolbarMenuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let separator = raw.range(of: "::"),
              let state = windows[String(raw[..<separator.lowerBound])],
              state.closeLifecycle.acceptsWork
        else { return }
        let commandID = String(raw[separator.upperBound...])
        guard !state.captureGenerationTransitionInFlight
                || commandID == "gui.previewAudioMute.toggle"
        else { return }
        performToolbarCommand(commandID, sender: nil, in: state)
    }

    @MainActor
    @objc private func morePopoverAction(_ sender: NSControl) {
        guard let raw = sender.identifier?.rawValue,
              let separator = raw.range(of: "::"),
              let state = windows[String(raw[..<separator.lowerBound])],
              state.closeLifecycle.acceptsWork
        else { return }
        state.morePopover?.performClose(sender)
        let commandID = String(raw[separator.upperBound...])
        guard !state.captureGenerationTransitionInFlight
                || commandID == "gui.previewAudioMute.toggle"
        else { return }
        performToolbarCommand(commandID, sender: nil, in: state)
    }

    @MainActor
    private func performToolbarCommand(
        _ commandID: String,
        sender: NSButton?,
        in state: ProductionGUIHostWindowState
    ) {
        switch commandID {
        case "gui.keyboardCapture.toggle":
            toggleKeyboardCapture(in: state)
        case "gui.previewAudioMute.toggle":
            Self.audioPreviewLogger.notice(
                "action=toggle videoSession=\(state.videoSession != nil, privacy: .public) available=\(state.videoSession?.audioAvailable == true, privacy: .public)"
            )
            if (try? state.audioPreview.toggleMacOutput()) != nil {
                state.videoSession?.setAudioMuted(
                    !state.audioPreview.isMacOutputEnabled
                )
                try? state.toolbarModel?.setLocalToggle(
                    commandID: commandID,
                    selected: state.audioPreview.isMacOutputEnabled
                )
                let updatedState: NSControl.StateValue = state.audioPreview.isMacOutputEnabled
                    ? .on
                    : .off
                sender?.state = updatedState
                state.toolbarButtons[commandID]?.state = updatedState
            }
        case "app.install":
            chooseIPAAndSubmit(in: state)
        case "device.rotate":
            submit(commandID, arguments: ["direction": "right"], in: state)
        case "screenshot.gui":
            beginScreenshot(in: state)
        case "gui.softwareKeyboard.toggle":
            submit(commandID, arguments: ["windowID": state.windowID], in: state)
            sender?.state = .off
        default:
            submit(commandID, arguments: [:], in: state)
        }
    }

    @MainActor
    private func showMoreToolbarPopover(
        from sender: NSButton,
        in state: ProductionGUIHostWindowState
    ) {
        let slots = Self.morePopoverSlots(in: state)
        guard !slots.isEmpty else { return }
        state.morePopover?.performClose(sender)

        let rowHeight: CGFloat = 32
        let versionFooterHeight: CGFloat = productVersion == nil ? 0 : 27
        let contentView = NSVisualEffectView(frame: NSRect(
            x: 0,
            y: 0,
            width: 212,
            height: CGFloat(16 + slots.count * Int(rowHeight) + max(0, slots.count - 1) * 4)
                + versionFooterHeight
        ))
        contentView.material = .headerView
        contentView.blendingMode = .withinWindow
        contentView.state = .active

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        for slot in slots {
            let row = ProductionMoreToolbarPopoverRow(
                image: Self.toolbarImage(slot.commandID),
                title: Self.toolbarLabel(slot.commandID),
                target: self,
                action: #selector(morePopoverAction(_:))
            )
            row.identifier = NSUserInterfaceItemIdentifier(
                toolbarIdentifier(
                    windowID: state.windowID,
                    commandID: slot.commandID
                ).rawValue
            )
            row.isSelected = slot.selected == true
            row.isEnabled = Self.toolbarEnabled(
                slot.presentation,
                commandID: slot.commandID
            )
            row.toolTip = Self.toolbarToolTip(slot)
            row.widthAnchor.constraint(equalToConstant: 196).isActive = true
            row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
            stack.addArrangedSubview(row)
        }
        if let productVersion {
            let separator = NSBox()
            separator.boxType = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            separator.widthAnchor.constraint(equalToConstant: 196).isActive = true
            separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
            stack.addArrangedSubview(separator)

            let versionLabel = Self.morePopoverVersionLabel(productVersion)
            versionLabel.widthAnchor.constraint(equalToConstant: 196).isActive = true
            versionLabel.heightAnchor.constraint(equalToConstant: 18).isActive = true
            stack.addArrangedSubview(versionLabel)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])

        let controller = NSViewController()
        controller.view = contentView
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = contentView.frame.size
        popover.contentViewController = controller
        state.morePopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @MainActor
    static func morePopoverVersionLabel(
        _ productVersion: PulsePhoneProductVersion
    ) -> NSTextField {
        let label = NSTextField(labelWithString: productVersion.displayText)
        label.identifier = NSUserInterfaceItemIdentifier(
            "pulsephone.product-version"
        )
        label.alignment = .center
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    @MainActor
    private func toggleKeyboardCapture(in state: ProductionGUIHostWindowState) {
        let enabled = !state.keyboardController.isEnabled
        if enabled {
            keyboardEventTapFaulted = false
            state.window.makeFirstResponder(state.interactionView)
        }
        reevaluateKeyboardCapture(
            in: state,
            enabled: enabled,
            requestAuthorization: enabled
        )
        updateToolbarButtons(in: state)
        applyKeyboardCapturePresentation(to: state)
        if enabled {
            DispatchQueue.main.async { [weak self, weak state] in
                guard let self,
                      let state,
                      state.closeLifecycle.acceptsWork,
                      state.keyboardController.isEnabled
                else { return }
                state.window.makeFirstResponder(state.interactionView)
                self.reevaluateKeyboardCapture(in: state)
            }
        }
    }

    @MainActor
    private func chooseIPAAndSubmit(in state: ProductionGUIHostWindowState) {
        setStatus("Choose an IPA", busy: false, in: state)
        ipaSelectionPresenter(state.window) { [weak self, weak state] path in
            guard let self, let state, state.closeLifecycle.acceptsWork else { return }
            self.handleIPASelection(path, in: state)
        }
    }

    @MainActor
    private static func presentIPASelection(
        for window: NSWindow,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
        panel.beginSheetModal(for: window) { response in
            completion(response == .OK ? panel.url?.path : nil)
        }
    }

    @MainActor
    private static func presentScreenshotSave(
        for window: NSWindow,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "PulsePhone Screenshot.png"
        panel.beginSheetModal(for: window) { response in
            completion(response == .OK ? panel.url?.path : nil)
        }
    }

    @MainActor
    private func handleIPASelection(
        _ path: String?,
        in state: ProductionGUIHostWindowState
    ) {
        do {
            let result = try ToolbarPicker.resolve(
                selectedPath: path,
                isRegularFile: path.map(Self.isRegularIPAFile) ?? false
            )
            switch result {
            case .cancelled:
                setStatus("Install cancelled", busy: false, in: state)
            case .accepted(let parameter):
                submitAcceptedIPA(parameter, in: state)
            }
        } catch {
            setStatus("invalidIPAPath", busy: false, in: state)
        }
    }

    @MainActor
    private func submitAcceptedIPA(
        _ parameter: ToolbarInstallParameter,
        in state: ProductionGUIHostWindowState
    ) {
        guard state.runtimeSession != nil else {
            setStatus("runtimeNotRunning", busy: false, in: state)
            return
        }
        submit(
            "app.install",
            arguments: ["ipaPath": parameter.absoluteIPAPath],
            in: state
        )
    }

    private static func isRegularIPAFile(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0
            && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && metadata.st_size > 0
    }

    @MainActor
    private func submit(
        _ commandID: String,
        arguments: [String: String],
        in state: ProductionGUIHostWindowState
    ) {
        guard let session = state.runtimeSession else {
            setStatus("runtimeNotRunning", busy: false, in: state)
            return
        }
        let identifier = state.windowID
        let actionID = CanonicalUUID(value: UUID())
        let clickedAt = DispatchTime.now().uptimeNanoseconds
        let visualProbeClickedAt = Self.visualProbeClickedAtNanoseconds()
        if commandID == "device.rotate" {
            state.pendingRotateActionIDs.insert(actionID)
        }
        Self.toolbarLatencyLogger.notice(
            "stage=clicked actionID=\(actionID.canonicalString, privacy: .public) commandID=\(commandID, privacy: .public)"
        )
        if commandID == "button.home" || commandID == "button.appSwitcher" {
            let outcome = state.videoSession?.beginVisualChangeProbe(
                actionID: actionID,
                commandID: commandID,
                clickedAtNanoseconds: visualProbeClickedAt
            ) ?? .noVideoSession
            Self.videoLatencyLogger.notice(
                "stage=probeArm actionID=\(actionID.canonicalString, privacy: .public) commandID=\(commandID, privacy: .public) outcome=\(outcome.rawValue, privacy: .public)"
            )
        }
        setStatus("Running \(Self.toolbarLabel(commandID))", busy: true, in: state)
        runtimeQueue.async { [weak self] in
            let submitStartedAt = DispatchTime.now().uptimeNanoseconds
            let result: RepositoryJSONObject?
            let clientErrorCode: String?
            do {
                result = try session.submit(
                    commandID: commandID,
                    rawArguments: arguments,
                    actionID: actionID
                )
                clientErrorCode = nil
            } catch {
                result = nil
                clientErrorCode = Self.runtimeClientErrorCode(error)
            }
            let terminalAt = DispatchTime.now().uptimeNanoseconds
            let diagnostic = Self.toolbarTerminalDiagnostic(
                result,
                clientErrorCode: clientErrorCode
            )
            Self.toolbarLatencyLogger.notice(
                "stage=terminal actionID=\(actionID.canonicalString, privacy: .public) commandID=\(commandID, privacy: .public) outcome=\(diagnostic.outcome, privacy: .public) errorCode=\(diagnostic.errorCode, privacy: .public) queueUs=\(Self.elapsedMicroseconds(clickedAt, submitStartedAt), privacy: .public) submitUs=\(Self.elapsedMicroseconds(submitStartedAt, terminalAt), privacy: .public)"
            )
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let state = self.windows[identifier] else { return }
                    let rotateGeometryReady = commandID == "device.rotate"
                        ? result.flatMap { self.applyRotateResult($0, in: state) }
                        : nil
                    if commandID == "device.rotate" {
                        state.pendingRotateActionIDs.remove(actionID)
                    }
                    if rotateGeometryReady == false {
                        self.setStatus(
                            "Controls awaiting geometry",
                            busy: false,
                            in: state
                        )
                    } else {
                        self.setStatus(
                            Self.resultStatus(result, commandID: commandID),
                            busy: false,
                            in: state
                        )
                    }
                    let presentedAt = DispatchTime.now().uptimeNanoseconds
                    Self.toolbarLatencyLogger.notice(
                        "stage=presented actionID=\(actionID.canonicalString, privacy: .public) commandID=\(commandID, privacy: .public) terminalToPresentationUs=\(Self.elapsedMicroseconds(terminalAt, presentedAt), privacy: .public) totalUs=\(Self.elapsedMicroseconds(clickedAt, presentedAt), privacy: .public)"
                    )
                }
            }
            guard Self.commandRequiresAvailabilityRefresh(
                commandID,
                result: result
            ) else { return }
            let availabilityStartedAt = DispatchTime.now().uptimeNanoseconds
            let availability = try? session.availability()
            let availabilityCompletedAt = DispatchTime.now().uptimeNanoseconds
            Self.toolbarLatencyLogger.notice(
                "stage=availability actionID=\(actionID.canonicalString, privacy: .public) commandID=\(commandID, privacy: .public) availabilityUs=\(Self.elapsedMicroseconds(availabilityStartedAt, availabilityCompletedAt), privacy: .public)"
            )
            guard let availability else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let state = self.windows[identifier] else { return }
                    self.applyToolbarAvailability(availability, in: state)
                }
            }
        }
    }

    static func commandRequiresAvailabilityRefresh(
        _ commandID: String,
        result: RepositoryJSONObject?
    ) -> Bool {
        guard result?["outcome"]?.stringValue == "succeeded" else { return true }
        return commandID == "button.lock"
    }

    static func toolbarTerminalDiagnostic(
        _ result: RepositoryJSONObject?,
        clientErrorCode: String? = nil
    ) -> (outcome: String, errorCode: String) {
        guard let result else {
            return ("clientError", clientErrorCode ?? "unknown")
        }
        let outcome = result["outcome"]?.stringValue ?? "invalidResponse"
        let errorCode = result["error"]?.objectValue?["code"]?.stringValue
            ?? "none"
        return (outcome, errorCode)
    }

    private static func runtimeClientErrorCode(_ error: Error) -> String {
        switch error {
        case RuntimeClientError.closedBeforeResponse: "closedBeforeResponse"
        case RuntimeClientError.incompatibleRuntime: "incompatibleRuntime"
        case RuntimeClientError.invalidBundledResources: "invalidBundledResources"
        case RuntimeClientError.invalidResponse: "invalidResponse"
        case RuntimeClientError.runtimeStopping: "runtimeStopping"
        case RuntimeClientError.socketUnavailable: "socketUnavailable"
        case RuntimeClientError.targetMismatch: "targetMismatch"
        case RuntimeClientError.transportFailure: "transportFailure"
        case ProductionRuntimeLiveSessionError.operationFailed(let code): code
        default: "unknown"
        }
    }

    private static func elapsedMicroseconds(_ start: UInt64, _ end: UInt64) -> UInt64 {
        guard end >= start else { return 0 }
        return (end - start) / 1_000
    }

    static func visualProbeClickedAtNanoseconds() -> UInt64 {
        SystemMonotonicClock().now().nanoseconds
    }

    @MainActor
    private func applyRotateResult(
        _ result: RepositoryJSONObject,
        in state: ProductionGUIHostWindowState
    ) -> Bool? {
        guard state.closeLifecycle.acceptsWork,
              let attachment = state.runtimeSession?.currentAttachment,
              let current = state.liveModel.runtimeGeometry,
              let geometry = ProductionLiveGeometryProjection.rotatedGeometry(
                  result: result,
                  current: current,
                  expectedConnectionEpoch: attachment.connectionEpoch
              )
        else { return nil }
        do {
            var updatedModel = state.liveModel
            var updatedController = state.pointerController
            let update = try updatedModel.updateRuntimeGeometry(geometry)
            let cancellation = try updatedController.geometryDidChange(to: geometry)
            guard state.videoSession?.rebindGeometry(geometry) != false else {
                resetPointerInteractions(in: state)
                state.interactionView.geometry = nil
                state.observationOverlay = InputObservationOverlay()
                return false
            }
            state.liveModel = updatedModel
            state.pointerController = updatedController
            state.geometryRevision = max(
                state.geometryRevision,
                geometry.geometryRevision
            )
            if update.requiresInteractionCancellation, let cancellation {
                appendPointerCancellation(cancellation, in: state)
            }
            if update.requiresInteractionCancellation {
                state.observationOverlay = InputObservationOverlay()
            }
            let geometryReady = state.liveModel.coordinateInputEnabled
            state.interactionView.geometry = geometryReady ? geometry : nil
            applyWindowReservation(state)
            return geometryReady
        } catch {
            resetPointerInteractions(in: state)
            state.interactionView.geometry = nil
            state.observationOverlay = InputObservationOverlay()
            return false
        }
    }

    @MainActor
    private func beginScreenshot(in state: ProductionGUIHostWindowState) {
        let rootActionID = CanonicalUUID(value: UUID())
        let logger: ProductionGUIScreenshotRootLogger?
        if let session = state.runtimeSession {
            logger = ProductionGUIScreenshotRootLogger(
                clientInstanceID: session.clientInstanceID
            ) { [runtimeQueue] body in
                runtimeQueue.async { try? session.recordLocalAction(body) }
            }
        } else {
            logger = nil
        }
        let flow = ProductionGUIScreenshotFlowBox(flow: ScreenshotAction(
            backend: screenshotDeviceBackend,
            outputWriter: screenshotOutputWriter,
            existingRuntimeRootLogger: logger
        ).begin(
            rootActionID: rootActionID,
            canonicalUDID: state.canonicalUDID
        ))
        Self.screenshotLogger.notice(
            "stage=clicked rootActionID=\(rootActionID.canonicalString, privacy: .public) commandID=screenshot.gui existingRuntime=\(state.runtimeSession != nil, privacy: .public)"
        )
        setStatus("Choose screenshot destination", busy: false, in: state)
        screenshotSavePresenter(state.window) { [weak self, weak state] path in
            guard let self else { return }
            guard let state, state.closeLifecycle.acceptsWork else {
                self.runtimeQueue.async { try? flow.cancel() }
                return
            }
            guard let path else {
                Self.screenshotLogger.notice(
                    "stage=cancelled rootActionID=\(rootActionID.canonicalString, privacy: .public) commandID=screenshot.gui"
                )
                self.setStatus("Screenshot cancelled", busy: false, in: state)
                self.runtimeQueue.async { try? flow.cancel() }
                return
            }
            let selectedAt = SystemMonotonicClock().now().nanoseconds
            let preview = state.videoSession?.latestScreenshotPreviewFrame()
            let binding = state.videoSession?.bindingIdentity
            let identifier = state.windowID
            let childActionID = CanonicalUUID(value: UUID())
            self.setStatus("Saving screenshot", busy: true, in: state)
            self.runtimeQueue.async { [weak self] in
                let result: ScreenshotSaveResult?
                let errorCode: String?
                do {
                    result = try flow.save(
                        absoluteOutputPath: path,
                        replaceExisting: true,
                        selectedAtNanoseconds: selectedAt,
                        previewFrame: preview,
                        currentBinding: binding,
                        childActionID: childActionID,
                        tempID: CanonicalUUID(value: UUID())
                    )
                    errorCode = nil
                } catch {
                    result = nil
                    errorCode = Self.screenshotErrorCode(error)
                }
                if let result {
                    Self.screenshotLogger.notice(
                        "stage=terminal rootActionID=\(rootActionID.canonicalString, privacy: .public) commandID=screenshot.gui outcome=succeeded source=\(result.source.rawValue, privacy: .public) childCreated=\(result.childActionID != nil, privacy: .public) byteLength=\(result.byteLength, privacy: .public) pathRedacted=true"
                    )
                } else {
                    Self.screenshotLogger.notice(
                        "stage=terminal rootActionID=\(rootActionID.canonicalString, privacy: .public) commandID=screenshot.gui outcome=failed errorCode=\(errorCode ?? "internalFailure", privacy: .public) pathRedacted=true"
                    )
                }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self,
                              let current = self.windows[identifier],
                              current.closeLifecycle.acceptsWork
                        else {
                            return
                        }
                        self.setStatus(
                            result == nil
                                ? errorCode ?? "internalFailure"
                                : "Screenshot saved",
                            busy: false,
                            in: current
                        )
                    }
                }
            }
        }
    }

    static func screenshotErrorCode(_ error: Error) -> String {
        if let device = error as? ProductionGUIScreenshotDeviceError {
            return device.errorCode
        }
        if let flow = error as? ScreenshotSaveFlowError {
            switch flow {
            case .invalidOutputPath: return "invalidOutputPath"
            case .rootChildIdentityCollision, .terminalAlreadyRecorded:
                return "internalFailure"
            }
        }
        if let output = error as? AtomicOutputFileError {
            switch output {
            case .invalidArtifact: return "unsupportedScreenshotFormat"
            case .localWriteFailed: return "localWriteFailed"
            case .outputExists: return "outputExists"
            case .timedOut: return "timedOut"
            }
        }
        if let runtime = error as? RuntimeClientError {
            switch runtime {
            case .closedBeforeResponse: return "transportFailure"
            case .incompatibleRuntime: return "incompatibleRuntime"
            case .interrupted: return "interrupted"
            case .invalidBundledResources, .invalidResponse: return "internalFailure"
            case .runtimeStopping: return "runtimeStopping"
            case .socketUnavailable: return "runtimeNotRunning"
            case .targetMismatch: return "internalFailure"
            case .transportFailure: return "transportFailure"
            }
        }
        if case ProductionRuntimeLiveSessionError.operationFailed(let code) = error {
            return code
        }
        return "internalFailure"
    }

    @MainActor
    private func setStatus(
        _ text: String?,
        busy: Bool,
        in state: ProductionGUIHostWindowState
    ) {
        if busy { state.progressIndicator.startAnimation(nil) }
        else { state.progressIndicator.stopAnimation(nil) }
        state.statusLabel.stringValue = text ?? ""
        state.statusLabel.isHidden = text == nil
        refreshAvailabilityOverlay(in: state)
    }

    @MainActor
    private func refreshAvailabilityOverlay(
        in state: ProductionGUIHostWindowState
    ) {
        state.availabilityOverlay.update(
            ProductionLiveAvailabilityOverlayPresentation(
                videoAvailability: state.liveModel.videoAvailability,
                pointerAvailability: state.liveModel.pointerAvailability,
                pointerFailure: state.pointerLastFailure
            ),
            identityMessage: state.identityPlaceholderVisible
                ? state.placeholder.stringValue
                : nil
        )
    }

    @MainActor
    private func showIdentityPlaceholder(
        _ reason: LiveWindowPlaceholderReason,
        in state: ProductionGUIHostWindowState,
        unlessFrozen: Bool
    ) {
        if unlessFrozen,
           case .frozen = state.liveModel.videoAvailability
        {
            refreshAvailabilityOverlay(in: state)
            return
        }
        state.liveModel.showIdentityPlaceholder(reason: reason)
        state.identityPlaceholderVisible = true
        refreshAvailabilityOverlay(in: state)
    }

    @MainActor
    private func toolbarState(_ toolbar: NSToolbar) -> ProductionGUIHostWindowState? {
        guard toolbar.identifier.hasPrefix("pulsephone.live.") else {
            return nil
        }
        let identifier = String(toolbar.identifier.dropFirst(
            "pulsephone.live.".count
        ))
        guard let state = windows[identifier],
              state.closeLifecycle.acceptsWork
        else { return nil }
        return state
    }

    @MainActor
    private func loadSourceMapping(for state: ProductionGUIHostWindowState) {
        let identifier = state.windowID
        state.mappingLoadResult = nil
        mappingCoordinator.load(target: state.canonicalUDID) { [weak self] result in
            guard let self,
                  let current = self.windows[identifier],
                  current === state,
                  current.closeLifecycle.acceptsWork
            else { return }
            current.mappingLoadResult = result
            self.applyMappingLayoutHint(result, in: current)
            self.updateSourceControls(current)
            self.maybeStartCachedBinding(in: current)
        }
    }

    @MainActor
    private func applyMappingLayoutHint(
        _ result: VideoSourceMappingLoadResult,
        in state: ProductionGUIHostWindowState
    ) {
        let previousReservationRevision = state.liveModel.reservationRevision
        let dimensions: (width: UInt64, height: UInt64)?
        if case .mapped(let record) = result {
            dimensions = record.initialCanvasDimensions
        } else {
            dimensions = nil
        }
        do {
            try state.liveModel.updatePlaceholderAspectRatioHint(
                width: dimensions?.width,
                height: dimensions?.height
            )
        } catch {
            try? state.liveModel.updatePlaceholderAspectRatioHint(
                width: nil,
                height: nil
            )
        }
        guard state.liveModel.reservationRevision != previousReservationRevision else {
            return
        }
        applyWindowReservation(state)
    }

    @MainActor
    private func maybeStartCachedBinding(
        in state: ProductionGUIHostWindowState
    ) {
        guard state.closeLifecycle.acceptsWork,
              !state.mappingChangeRequested,
              !state.mappingMutationInFlight,
              !state.videoBindingInFlight,
              state.videoSession == nil,
              state.previewCapture == nil,
              state.automaticProbeCapture == nil,
              case .mapped(let record)? = state.mappingLoadResult,
              let inventory = state.inventory,
              let attachment = state.runtimeSession?.currentAttachment
        else { return }
        let resolution: VideoSourceResolution
        do {
            resolution = try CachedVideoSourceMappingResolver.resolve(
                target: state.canonicalUDID,
                sourceID: record.sourceID,
                mappingProofID: VideoSourceMappingRecordV1.proofKind,
                sources: inventory.sources
            )
        } catch {
            showIdentityPlaceholder(
                .sourceUnavailable,
                in: state,
                unlessFrozen: true
            )
            updateSourceControls(state)
            return
        }
        switch resolution {
        case .unavailable:
            showIdentityPlaceholder(
                .sourceUnavailable,
                in: state,
                unlessFrozen: true
            )
            updateSourceControls(state)
        case .ambiguous:
            showIdentityPlaceholder(
                .ambiguousSource,
                in: state,
                unlessFrozen: true
            )
            updateSourceControls(state)
        case .mapped(let resolved):
            let descriptor = resolved.descriptor
            let attempt = ProductionVideoSourceMappingAttempt(
                connectionEpoch: attachment.connectionEpoch,
                sourceEpoch: descriptor.sourceEpoch,
                sourceID: descriptor.sourceID
            )
            guard state.automaticMappingAttempt != attempt else {
                updateSourceControls(state)
                return
            }
            startAutomaticProbe(
                descriptor: descriptor,
                attempt: attempt,
                mappingProofID: record.proofKind.rawValue,
                in: state
            )
        }
    }

    @MainActor
    private func startAutomaticProbe(
        descriptor: VideoSourceDescriptor,
        attempt: ProductionVideoSourceMappingAttempt,
        mappingProofID: String,
        in state: ProductionGUIHostWindowState
    ) {
        let identifier = state.windowID
        let token = UUID()
        let sink = ProductionVideoSourcePreviewSink { [weak self] in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          let current = self.windows[identifier],
                          current === state,
                          current.closeLifecycle.acceptsWork,
                          current.automaticProbeToken == token,
                          current.automaticProbeDescriptor == descriptor,
                          let frameFormat = current.automaticProbeSink?
                            .latestFrameFormat,
                          let captureLease = current.automaticProbeCapture,
                          let inventory = current.inventory,
                          inventory.sources.contains(descriptor),
                          let attachment = current.runtimeSession?.currentAttachment,
                          attachment.connectionEpoch == attempt.connectionEpoch
                    else { return }
                    self.takeAutomaticProbe(current)
                    guard let mapping = self.makeCurrentVideoMapping(
                        descriptor: descriptor,
                        frameFormat: frameFormat,
                        attachment: attachment,
                        mappingProofID: mappingProofID,
                        state: current
                    ) else {
                        self.updateSourceControls(current)
                        return
                    }
                    self.startBoundVideo(
                        mapping: mapping,
                        descriptor: descriptor,
                        captureLease: captureLease,
                        inventory: inventory,
                        state: current,
                        successStatus: nil
                    )
                }
            }
        }
        state.automaticMappingAttempt = attempt
        state.automaticProbeDescriptor = descriptor
        state.automaticProbeMappingProofID = mappingProofID
        state.automaticProbeSink = sink
        state.automaticProbeToken = token
        setStatus("Restoring video", busy: true, in: state)
        do {
            let capture = try captureCoordinator.acquire(
                sourceID: descriptor.sourceID,
                sourceEpoch: descriptor.sourceEpoch,
                role: .liveProbe,
                handoffTarget: state.canonicalUDID,
                handoffOwnerID: state.windowID,
                frameHandler: sink.receive,
                audioHandler: { _ in }
            )
            state.automaticProbeCapture = capture
            try capture.start()
            updateSourceControls(state)
        } catch {
            stopAutomaticProbe(state)
            setStatus("Choose a video source", busy: false, in: state)
            updateSourceControls(state)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      let current = self.windows[identifier],
                      current === state,
                      current.automaticProbeToken == token
                else { return }
                self.stopAutomaticProbe(current)
                self.showIdentityPlaceholder(
                    .sourceUnavailable,
                    in: current,
                    unlessFrozen: true
                )
                self.setStatus("Choose a video source", busy: false, in: current)
                self.updateSourceControls(current)
            }
        }
    }

    @MainActor
    private func stopAutomaticProbe(_ state: ProductionGUIHostWindowState) {
        state.automaticProbeCapture?.stop()
        state.automaticProbeSink?.stop()
        state.automaticProbeCapture = nil
        state.automaticProbeDescriptor = nil
        state.automaticProbeMappingProofID = nil
        state.automaticProbeSink = nil
        state.automaticProbeToken = nil
    }

    @MainActor
    private func takeAutomaticProbe(_ state: ProductionGUIHostWindowState) {
        state.automaticProbeSink?.stop()
        state.automaticProbeCapture = nil
        state.automaticProbeDescriptor = nil
        state.automaticProbeMappingProofID = nil
        state.automaticProbeSink = nil
        state.automaticProbeToken = nil
    }

    @MainActor
    private func updateSourceControls(_ state: ProductionGUIHostWindowState) {
        guard state.closeLifecycle.acceptsWork else { return }
        let hasSources = !(state.inventory?.sources.isEmpty ?? true)
        let hasSavedMapping: Bool
        if case .mapped? = state.mappingLoadResult {
            hasSavedMapping = true
        } else {
            hasSavedMapping = false
        }
        let cachedMappingBlocksManualSelection =
            cachedMappingBlocksManualSelection(in: state)
        let manualSelectionAvailable = state.mappingLoadResult != nil
            && !state.mappingMutationInFlight
            && !state.videoBindingInFlight
            && state.videoSession == nil
            && state.automaticProbeCapture == nil
            && !cachedMappingBlocksManualSelection
        state.sourcePicker.isEnabled = hasSources && manualSelectionAvailable
        state.previewButton.isEnabled = hasSources && manualSelectionAvailable
        state.confirmButton.isEnabled = manualSelectionAvailable
            && state.previewSink?.latestFrameFormat != nil
            && state.runtimeSession?.currentAttachment != nil
        state.changeMappingButton.isEnabled = !state.mappingMutationInFlight
            && !state.videoBindingInFlight
            && (state.videoSession != nil || hasSavedMapping)
        state.clearMappingButton.isEnabled = !state.mappingMutationInFlight
            && !state.videoBindingInFlight
            && hasSavedMapping
        let descriptor = state.confirmedDescriptor
            ?? state.automaticProbeDescriptor
            ?? state.previewDescriptor
        if let descriptor {
            state.sourceSummaryLabel.stringValue = Self.sourceTitle(descriptor)
        } else if case .mapped(let record)? = state.mappingLoadResult {
            state.sourceSummaryLabel.stringValue =
                "Source \(record.sourceID.prefix(8))...\(record.sourceID.suffix(8))"
        } else {
            state.sourceSummaryLabel.stringValue = "No video source"
        }
    }

    @MainActor
    private func cachedMappingBlocksManualSelection(
        in state: ProductionGUIHostWindowState
    ) -> Bool {
        guard !state.mappingChangeRequested,
              case .mapped(let record)? = state.mappingLoadResult
        else { return false }
        guard let inventory = state.inventory else { return true }
        guard case .mapped(let resolved)? = try?
            CachedVideoSourceMappingResolver.resolve(
                target: state.canonicalUDID,
                sourceID: record.sourceID,
                mappingProofID: VideoSourceMappingRecordV1.proofKind,
                sources: inventory.sources
            )
        else { return false }
        guard let attachment = state.runtimeSession?.currentAttachment else {
            return true
        }
        let attempt = ProductionVideoSourceMappingAttempt(
            connectionEpoch: attachment.connectionEpoch,
            sourceEpoch: resolved.descriptor.sourceEpoch,
            sourceID: resolved.descriptor.sourceID
        )
        return state.automaticMappingAttempt != attempt
            || state.automaticProbeCapture != nil
            || state.videoBindingInFlight
    }

    @MainActor
    private func apply(_ inventory: VideoSourceInventory) {
        latestInventory = inventory
        sourceResolver.apply(inventory)
        for state in windows.values {
            apply(inventory, to: state)
        }
    }

    @MainActor
    private func apply(
        _ inventory: VideoSourceInventory,
        to state: ProductionGUIHostWindowState
    ) {
        guard state.closeLifecycle.acceptsWork else { return }
        state.inventory = inventory
        let selectedID = state.confirmedDescriptor?.sourceID
            ?? state.previewDescriptor?.sourceID
            ?? state.automaticProbeDescriptor?.sourceID
            ?? (state.sourcePicker.selectedItem?.representedObject as? String)
        state.sourcePicker.removeAllItems()
        for source in inventory.sources {
            state.sourcePicker.addItem(withTitle: Self.sourceTitle(source))
            state.sourcePicker.lastItem?.representedObject = source.sourceID
        }
        if let selectedID,
           let index = inventory.sources.firstIndex(where: {
               $0.sourceID == selectedID
           })
        {
            state.sourcePicker.selectItem(at: index)
        }
        let hasSources = !inventory.sources.isEmpty
        if !hasSources {
            state.sourcePicker.addItem(withTitle: "No video sources")
        }

        if let automatic = state.automaticProbeDescriptor,
           !inventory.sources.contains(automatic)
        {
            stopAutomaticProbe(state)
        }
        if let preview = state.previewDescriptor,
           !inventory.sources.contains(preview)
        {
            stopPreview(state)
        }
        if let confirmed = state.confirmedDescriptor,
           !inventory.sources.contains(confirmed)
        {
            stopBoundVideo(
                state,
                presentation: .freezeIfAvailable(reason: .sourceUnavailable),
                invalidateCoordinateAuthority: false
            )
            state.confirmedDescriptor = nil
        }
        updateSourceControls(state)
        maybeStartCachedBinding(in: state)
    }

    @MainActor
    @objc private func sourceSelectionChanged(_ sender: NSPopUpButton) {
        guard let identifier = sender.identifier?.rawValue,
              let state = windows[identifier],
              state.closeLifecycle.acceptsWork
        else { return }
        stopPreview(state)
    }

    @MainActor
    @objc private func changeSourceMapping(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue,
              let state = windows[identifier],
              state.closeLifecycle.acceptsWork,
              !state.mappingMutationInFlight
        else { return }
        sourceResolver.openForExistingLive(
            target: state.canonicalUDID,
            ownerID: state.windowID
        )
    }

    @MainActor
    private func applySourceReassignment(
        target: CanonicalUDID,
        ownerID: String,
        handoff: ProductionLiveSourceHandoff
    ) {
        guard let state = windows[ownerID], state.canonicalUDID == target,
              state.closeLifecycle.acceptsWork,
              handoff.targetFacts.canonicalUDID == target
        else { return }
        stopAutomaticProbe(state)
        stopPreview(state)
        stopBoundVideo(
            state,
            presentation: .freezeIfAvailable(reason: .awaitingBinding),
            invalidateCoordinateAuthority: false
        )
        state.confirmedDescriptor = nil
        state.mappingChangeRequested = false
        state.mappingLoadResult = nil
        state.automaticMappingAttempt = nil
        state.videoStallRecoveryGate.reset()
        if let latestInventory { apply(latestInventory, to: state) }
        loadSourceMapping(for: state)
    }

    @MainActor
    private func fenceSourceReassignment(targets: [CanonicalUDID]) {
        let targetSet = Set(targets)
        for state in windows.values where targetSet.contains(state.canonicalUDID) {
            stopAutomaticProbe(state)
            stopPreview(state)
            stopBoundVideo(
                state,
                presentation: .freezeIfAvailable(reason: .sourceUnavailable),
                invalidateCoordinateAuthority: false
            )
            state.confirmedDescriptor = nil
            state.mappingLoadResult = .missing
            state.automaticMappingAttempt = nil
            setStatus("Video source reassigned", busy: false, in: state)
            updateSourceControls(state)
        }
    }

    private static func productionSourceTargetSnapshot(
        _ target: CanonicalUDID
    ) throws -> ProductionLiveSourceTargetSnapshot {
        guard let resources = Bundle.main.resourceURL else {
            throw LocalDeviceFactsProbeError.invalidExecutable
        }
        let helper = BundledHelperExecutableSet(
            resourcesURL: resources
        ).directExecutableURL
        let discovery = USBDeviceDiscovery(
            factsProvider: LocalDeviceFactsProbe(executablePath: helper.path)
        )
        let snapshot = try discovery.discover()
        guard let selected = snapshot.device(for: target) else {
            throw LocalDeviceQueryError.deviceNotFound(target)
        }
        func facts(_ device: USBDiscoveredDevice) -> ProductionLiveSourceTargetFacts {
            ProductionLiveSourceTargetFacts(
                canonicalUDID: device.canonicalUDID,
                name: device.facts.deviceName.isEmpty
                    ? "iPhone"
                    : device.facts.deviceName,
                osVersion: device.facts.productVersion
            )
        }
        return ProductionLiveSourceTargetSnapshot(
            connectedTargets: snapshot.devices.map(facts),
            target: facts(selected)
        )
    }

    @MainActor
    @objc private func clearSourceMapping(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue,
              let state = windows[identifier],
              state.closeLifecycle.acceptsWork,
              !state.mappingMutationInFlight,
              !state.videoBindingInFlight
        else { return }
        state.mappingChangeRequested = true
        state.mappingMutationInFlight = true
        state.automaticMappingAttempt = nil
        stopAutomaticProbe(state)
        stopPreview(state)
        stopBoundVideo(
            state,
            presentation: .clear(reason: .awaitingBinding),
            invalidateCoordinateAuthority: false
        )
        state.confirmedDescriptor = nil
        setStatus("Clearing source mapping", busy: true, in: state)
        updateSourceControls(state)
        mappingCoordinator.clear(target: state.canonicalUDID) { [weak self] result in
            guard let self,
                  let current = self.windows[identifier],
                  current === state,
                  current.closeLifecycle.acceptsWork
            else { return }
            current.mappingMutationInFlight = false
            switch result {
            case .cleared:
                current.mappingLoadResult = .missing
                self.setStatus("Choose a video source", busy: false, in: current)
            case .failed(let failure):
                current.mappingLoadResult = .unavailable(failure)
                self.setStatus("Source mapping unavailable", busy: false, in: current)
            }
            self.updateSourceControls(current)
        }
    }

    @MainActor
    @objc private func previewSource(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue,
              let state = windows[identifier],
              state.closeLifecycle.acceptsWork,
              let descriptor = selectedDescriptor(in: state)
        else { return }
        stopPreview(state)
        let sink = ProductionVideoSourcePreviewSink { [weak self] in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          let current = self.windows[identifier],
                          current.closeLifecycle.acceptsWork,
                          current.previewDescriptor == descriptor
                    else { return }
                    current.identityPlaceholderVisible = false
                    self.refreshAvailabilityOverlay(in: current)
                    self.updateSourceControls(current)
                }
            }
        }
        do {
            let capture = try captureCoordinator.acquire(
                sourceID: descriptor.sourceID,
                sourceEpoch: descriptor.sourceEpoch,
                role: .chooserPreview,
                frameHandler: sink.receive,
                audioHandler: { _ in }
            )
            state.previewDescriptor = descriptor
            state.previewSink = sink
            state.previewCapture = capture
            state.videoView.layer = sink.displayLayer
            updateSourceControls(state)
            try capture.start()
        } catch {
            stopPreview(state)
            updateSourceControls(state)
        }
    }

    @MainActor
    @objc private func confirmSource(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue,
              let state = windows[identifier],
              state.closeLifecycle.acceptsWork,
              !state.mappingMutationInFlight,
              !state.videoBindingInFlight,
              let inventory = state.inventory,
              let descriptor = state.previewDescriptor,
              let frameFormat = state.previewSink?.latestFrameFormat,
              let attachment = state.runtimeSession?.currentAttachment,
              inventory.sources.contains(descriptor)
        else { return }
        state.mappingMutationInFlight = true
        setStatus("Saving source mapping", busy: true, in: state)
        updateSourceControls(state)
        let initialCanvasWidth = min(frameFormat.width, frameFormat.height)
        let initialCanvasHeight = max(frameFormat.width, frameFormat.height)
        mappingCoordinator.replace(
            target: state.canonicalUDID,
            sourceID: descriptor.sourceID,
            initialCanvasWidth: initialCanvasWidth,
            initialCanvasHeight: initialCanvasHeight
        ) { [weak self] result in
            guard let self,
                  let current = self.windows[identifier],
                  current === state,
                  current.closeLifecycle.acceptsWork
            else { return }
            current.mappingMutationInFlight = false
            let successStatus: String?
            switch result {
            case .saved(let record):
                current.mappingLoadResult = .mapped(.currentV2(record))
                successStatus = nil
            case .failed(let failure):
                current.mappingLoadResult = .unavailable(failure)
                successStatus = "Source mapping not saved"
            }
            guard current.previewDescriptor == descriptor,
                  let currentFormat = current.previewSink?.latestFrameFormat,
                  currentFormat == frameFormat,
                  current.inventory?.sources.contains(descriptor) == true,
                  current.runtimeSession?.currentAttachment == attachment,
                  let currentInventory = current.inventory,
                  let mapping = self.makeCurrentVideoMapping(
                      descriptor: descriptor,
                      frameFormat: currentFormat,
                      attachment: attachment,
                      mappingProofID: VideoSourceMappingRecordV1.proofKind,
                      state: current
                  )
            else {
                self.updateSourceControls(current)
                return
            }
            current.mappingChangeRequested = false
            guard let captureLease = self.takePreview(current) else {
                self.updateSourceControls(current)
                return
            }
            self.startBoundVideo(
                mapping: mapping,
                descriptor: descriptor,
                captureLease: captureLease,
                inventory: currentInventory,
                state: current,
                successStatus: successStatus
            )
        }
    }

    @MainActor
    private func makeCurrentVideoMapping(
        descriptor: VideoSourceDescriptor,
        frameFormat: ProductionVideoSourcePreviewSink.FrameFormat,
        attachment: LiveAttachment,
        mappingProofID: String,
        state: ProductionGUIHostWindowState
    ) -> ProductionVideoSourceMapping? {
        do {
            let initial = try ProductionLiveGeometryProjection
                .initialVideoGeometry(
                    width: frameFormat.width,
                    height: frameFormat.height,
                    current: state.liveModel.runtimeGeometry,
                    expectedConnectionEpoch: attachment.connectionEpoch
                )
            if let current = state.liveModel.runtimeGeometry,
               current.connectionEpoch > attachment.connectionEpoch
            {
                return nil
            }
            if !initial.isAuthoritative {
                if let current = state.liveModel.runtimeGeometry {
                    try state.liveModel.clearRuntimeGeometry(
                        throughConnectionEpoch: current.connectionEpoch
                    )
                }
                if let cancellation = try? state.pointerController.cancel() {
                    appendPointerCancellation(cancellation, in: state)
                }
                state.interactionView.geometry = nil
                state.observationOverlay = InputObservationOverlay()
            } else {
                state.geometryRevision = initial.geometry.geometryRevision
                state.interactionView.geometry = initial.geometry
            }
            if case .frozen = state.liveModel.videoAvailability {
                // Keep the retained frame ratio until the new bound session
                // submits its own identity-valid presentation.
            } else {
                try state.liveModel.updateCaptureActiveFormat(
                    LiveCaptureActiveFormat(
                        sourceEpoch: descriptor.sourceEpoch,
                        width: frameFormat.width,
                        height: frameFormat.height
                    )
                )
            }
            applyWindowReservation(state)
            return ProductionVideoSourceMapping(
                connectionEpoch: attachment.connectionEpoch,
                geometry: initial.geometry,
                mappingProofID: mappingProofID,
                sourceEpoch: descriptor.sourceEpoch,
                sourceID: descriptor.sourceID
            )
        } catch {
            showIdentityPlaceholder(
                .sourceUnavailable,
                in: state,
                unlessFrozen: true
            )
            return nil
        }
    }

    @MainActor
    private func startBoundVideo(
        mapping: ProductionVideoSourceMapping,
        descriptor: VideoSourceDescriptor,
        captureLease: ProductionSourceCaptureLease,
        inventory: VideoSourceInventory,
        state: ProductionGUIHostWindowState,
        successStatus: String?
    ) {
        let identifier = state.windowID
        let token = UUID()
        state.videoBindingInFlight = true
        state.videoBindingToken = token
        if case .frozen = state.liveModel.videoAvailability {
            // The old display layer remains visible until replacement succeeds.
        } else {
            try? state.liveModel.clearCaptureActiveFormat(
                throughSourceEpoch: mapping.sourceEpoch
            )
        }
        state.automaticMappingAttempt = ProductionVideoSourceMappingAttempt(
            connectionEpoch: mapping.connectionEpoch,
            sourceEpoch: mapping.sourceEpoch,
            sourceID: mapping.sourceID
        )
        setStatus("Starting video", busy: true, in: state)
        updateSourceControls(state)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let session: ProductionBoundVideoSession?
            do {
                session = try ProductionBoundVideoSession.start(
                    target: state.canonicalUDID,
                    mapping: mapping,
                    captureLease: captureLease,
                    inventory: inventory,
                    captureReadyHandler: { [weak self] binding in
                        DispatchQueue.main.async { [weak self] in
                            MainActor.assumeIsolated {
                                self?.markBoundCaptureReady(
                                    binding: binding,
                                    mapping: mapping,
                                    videoBindingToken: token,
                                    windowID: identifier
                                )
                            }
                        }
                    },
                    presentationHandler: { [weak self] format in
                        DispatchQueue.main.async { [weak self] in
                            MainActor.assumeIsolated {
                                self?.applyVideoPresentation(
                                    format,
                                    mapping: mapping,
                                    videoBindingToken: token,
                                    windowID: identifier
                                )
                            }
                        }
                    },
                    displayGateHandler: { [weak self] withholding in
                        DispatchQueue.main.async { [weak self] in
                            MainActor.assumeIsolated {
                                self?.handleLiveResizeDisplayGate(
                                    withholding: withholding,
                                    videoBindingToken: token,
                                    windowID: identifier
                                )
                            }
                        }
                    },
                    stallHandler: { [weak self] binding in
                        DispatchQueue.main.async { [weak self] in
                            MainActor.assumeIsolated {
                                self?.handleBoundVideoStall(
                                    binding: binding,
                                    mapping: mapping,
                                    videoBindingToken: token,
                                    windowID: identifier
                                )
                            }
                        }
                    }
                )
            } catch {
                Self.videoLatencyLogger.error(
                    "stage=boundStart outcome=failed code=\(Self.boundVideoStartErrorCode(error), privacy: .public)"
                )
                session = nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let current = self.windows[identifier] else {
                        session?.stop()
                        return
                    }
                    guard current.closeLifecycle.acceptsWork,
                          current.videoBindingToken == token,
                          current.inventory?.sources.contains(descriptor) == true,
                          current.runtimeSession?.currentAttachment?.connectionEpoch
                            == mapping.connectionEpoch,
                          let session
                    else {
                        session?.stop()
                        if current.videoBindingToken == token {
                            current.videoBindingInFlight = false
                            current.videoBindingToken = nil
                            self.stopBoundVideo(
                                current,
                                presentation: .freezeIfAvailable(
                                    reason: .sourceUnavailable
                                ),
                                invalidateCoordinateAuthority: false
                            )
                            self.setStatus(
                                "Choose a video source",
                                busy: false,
                                in: current
                            )
                            self.updateSourceControls(current)
                        }
                        return
                    }
                    current.videoBindingInFlight = false
                    current.videoBindingToken = nil
                    current.boundVideoToken = token
                    current.confirmedDescriptor = descriptor
                    self.selectSource(descriptor, in: current)
                    current.videoSession = session
                    current.videoView.layer = session.displayLayer
                    current.identityPlaceholderVisible = false
                    self.setStatus(successStatus, busy: false, in: current)
                    self.updateSourceControls(current)
                    self.startAudioPreview(
                        mapping: mapping,
                        inventory: inventory,
                        state: current
                    )
                    if let activationID = current.captureReadyActivationID,
                       let runtimeSession = current.runtimeSession
                    {
                        self.beginCaptureReadyTransition(
                            activationID: activationID,
                            session: runtimeSession,
                            state: current
                        )
                    }
                }
            }
        }
    }

    @MainActor
    private func handleBoundVideoStall(
        binding: VideoBindingIdentity,
        mapping: ProductionVideoSourceMapping,
        videoBindingToken: UUID,
        windowID: String
    ) {
        guard let state = windows[windowID],
              state.closeLifecycle.acceptsWork,
              state.boundVideoToken == videoBindingToken,
              state.videoSession?.bindingIdentity == binding,
              Self.captureReadyBindingIsCurrent(
                binding,
                mapping: mapping,
                target: state.canonicalUDID
              ),
              state.runtimeSession?.currentAttachment?.connectionEpoch
                == mapping.connectionEpoch
        else { return }
        Self.videoLatencyLogger.error(
            "stage=captureLiveness outcome=stalled sourceEpoch=\(binding.sourceEpoch, privacy: .public)"
        )
        let attempt = ProductionVideoSourceMappingAttempt(
            connectionEpoch: mapping.connectionEpoch,
            sourceEpoch: mapping.sourceEpoch,
            sourceID: mapping.sourceID
        )
        let shouldReacquire = state.videoStallRecoveryGate.beginCleanReacquire(
            for: attempt
        )
        stopBoundVideo(
            state,
            presentation: .freezeIfAvailable(reason: .sourceUnavailable),
            invalidateCoordinateAuthority: false
        )
        guard shouldReacquire else {
            setStatus("Video unavailable", busy: false, in: state)
            return
        }
        state.automaticMappingAttempt = nil
        setStatus("Restoring video", busy: true, in: state)
        maybeStartCachedBinding(in: state)
    }

    @MainActor
    private func markBoundCaptureReady(
        binding: VideoBindingIdentity,
        mapping: ProductionVideoSourceMapping,
        videoBindingToken: UUID,
        windowID: String
    ) {
        guard let state = windows[windowID],
              state.closeLifecycle.acceptsWork,
              Self.captureReadyBindingIsCurrent(
                  binding,
                  mapping: mapping,
                  target: state.canonicalUDID
              ),
              Self.videoCallbackTokenIsCurrent(
                  videoBindingToken,
                  inFlightToken: state.videoBindingToken,
                  boundToken: state.boundVideoToken
              ),
              let session = state.runtimeSession,
              session.currentAttachment?.connectionEpoch == binding.connectionEpoch
        else { return }
        let activationID = Self.captureReadyActivationID(
            existing: state.captureReadyActivationID,
            activationConnectionEpoch: state.captureReadyConnectionEpoch,
            bindingConnectionEpoch: binding.connectionEpoch
        )
        state.captureReadyActivationID = activationID
        state.captureReadyConnectionEpoch = binding.connectionEpoch
        beginCaptureReadyTransition(
            activationID: activationID,
            session: session,
            state: state
        )
    }

    @MainActor
    private func beginCaptureReadyTransition(
        activationID: CanonicalUUID,
        session: any ProductionGUIHostRuntimeSession,
        state: ProductionGUIHostWindowState
    ) {
        guard state.runtimeSession === session,
              session.currentAttachment != nil
        else { return }
        if state.captureGenerationTransitionInFlight {
            state.captureGeometryRefreshPending = true
            return
        }
        state.captureGenerationTransitionInFlight = true
        if !state.captureReadyCommitted {
            state.keyboardRuntimeCapabilityReady = false
            state.liveModel.setPointerPreparing(reason: "captureTransition")
        }
        let windowID = state.windowID
        updateToolbarButtons(in: state)
        setStatus("Preparing controls", busy: true, in: state)
        runtimeQueue.async { [weak self] in
            var transition: ProductionRuntimeCaptureReadyTransition?
            var availability: RepositoryJSONObject?
            var failureCode: String?
            do {
                transition = try session.markLiveCaptureReady(
                    captureActivationID: activationID
                )
                availability = try session.availability()
                failureCode = nil
            } catch let error as ProductionRuntimeLiveSessionError {
                transition = nil
                availability = nil
                switch error {
                case .operationFailed(let code): failureCode = code
                }
            } catch let error as RuntimeClientError {
                transition = nil
                availability = nil
                failureCode = Self.runtimeClientErrorCode(error)
            } catch {
                transition = nil
                availability = nil
                failureCode = "invalidResponse"
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          let current = self.windows[windowID],
                          current.runtimeSession === session,
                          current.captureReadyActivationID == activationID,
                          current.closeLifecycle.acceptsWork
                    else { return }
                    current.captureGenerationTransitionInFlight = false
                    let refreshPending = current.captureGeometryRefreshPending
                    current.captureGeometryRefreshPending = false
                    if let geometry = transition?.geometry {
                        _ = self.adoptCaptureReadyGeometry(
                            geometry,
                            in: current
                        )
                    }
                    let geometryReady = current.liveModel.runtimeGeometry.map {
                        current.liveModel.samplePresentation?.aligns(with: $0)
                            == true
                            && current.videoSession?.bindingIdentity
                                .geometryRevision == $0.geometryRevision
                    } ?? false
                    current.liveModel.reconcilePointerAvailability()
                    if let availability {
                        current.captureReadyCommitted = true
                        self.applyToolbarAvailability(availability, in: current)
                        self.setStatus(
                            geometryReady ? nil : "Controls awaiting geometry",
                            busy: false,
                            in: current
                        )
                    } else {
                        self.updateToolbarButtons(in: current)
                        let status = Self.captureReadyFailureStatus(
                            pointerAvailability: current.liveModel
                                .pointerAvailability
                        )
                        Self.videoLatencyLogger.error(
                            "stage=captureReady outcome=failed code=\(failureCode ?? "unknown", privacy: .public)"
                        )
                        self.setStatus(status, busy: false, in: current)
                    }
                    if refreshPending, !geometryReady {
                        self.beginCaptureReadyTransition(
                            activationID: activationID,
                            session: session,
                            state: current
                        )
                    }
                }
            }
        }
    }

    @MainActor
    private func adoptCaptureReadyGeometry(
        _ geometry: DisplayGeometryDTO,
        in state: ProductionGUIHostWindowState
    ) -> Bool {
        guard let attachment = state.runtimeSession?.currentAttachment,
              let videoSession = state.videoSession,
              let adoption = ProductionCaptureReadyGeometryAdoption.prepare(
                  geometry: geometry,
                  attachmentConnectionEpoch: attachment.connectionEpoch,
                  captureReadyConnectionEpoch: state.captureReadyConnectionEpoch,
                  videoBinding: videoSession.bindingIdentity,
                  liveModel: state.liveModel,
                  pointerController: state.pointerController,
                  rebindVideo: { videoSession.rebindGeometry($0) }
              )
        else { return false }

        state.liveModel = adoption.liveModel
        state.pointerController = adoption.pointerController
        if state.liveModel.runtimeGeometry?.connectionEpoch
            == geometry.connectionEpoch
        {
            state.geometryRevision = geometry.geometryRevision
        }
        if adoption.geometryUpdate.requiresInteractionCancellation,
           let cancellation = adoption.cancellation
        {
            appendPointerCancellation(cancellation, in: state)
        }
        state.interactionView.geometry = geometry
        state.observationOverlay = InputObservationOverlay()
        applyWindowReservation(state)
        Self.pointerLatencyLogger.notice(
            "stage=captureGeometryAdopted connectionEpoch=\(geometry.connectionEpoch, privacy: .public) geometryRevision=\(geometry.geometryRevision, privacy: .public) orientation=\(geometry.orientation.rawValue, privacy: .public)"
        )
        return true
    }

    @MainActor
    private func applyVideoPresentation(
        _ format: LiveSamplePresentationFormat,
        mapping: ProductionVideoSourceMapping,
        videoBindingToken: UUID,
        windowID: String
    ) {
        guard let state = windows[windowID],
              state.closeLifecycle.acceptsWork,
              format.sourceEpoch == mapping.sourceEpoch,
              Self.videoCallbackTokenIsCurrent(
                  videoBindingToken,
                  inFlightToken: state.videoBindingToken,
                  boundToken: state.boundVideoToken
              ),
              let attachment = state.runtimeSession?.currentAttachment,
              attachment.connectionEpoch == mapping.connectionEpoch
        else { return }
        if state.liveResizeTransaction != nil {
            if state.liveModel.samplePresentation != format {
                state.pendingLiveResizePresentation =
                    ProductionPendingLiveResizePresentation(
                        format: format,
                        mapping: mapping,
                        videoBindingToken: videoBindingToken
                    )
                state.liveModel.setPointerPreparing(reason: "awaitingPresentation")
                refreshAvailabilityOverlay(in: state)
            }
            return
        }
        let completesDeferredLiveResize = state.awaitingLiveResizePresentation
        defer {
            if completesDeferredLiveResize,
               state.liveModel.samplePresentation == format
            {
                state.awaitingLiveResizePresentation = false
                state.liveResizeFramesWithheld = false
                state.videoSession?.endLiveResize()
                state.liveModel.reconcilePointerAvailability()
                refreshAvailabilityOverlay(in: state)
            }
        }
        let previous = state.liveModel.samplePresentation
        do {
            let presentationUpdate = try state.liveModel.updateSamplePresentation(
                format
            )
            guard previous != format else {
                applyWindowReservation(state)
                return
            }
            Self.videoLatencyLogger.notice(
                "stage=presentation sourceEpoch=\(format.sourceEpoch, privacy: .public) formatRevision=\(format.formatRevision, privacy: .public) width=\(format.dimensions.widthUnits, privacy: .public) height=\(format.dimensions.heightUnits, privacy: .public) orientation=\(format.orientation.rawValue, privacy: .public)"
            )
            let current = state.liveModel.runtimeGeometry
            let geometry: DisplayGeometryDTO
            switch ProductionLiveGeometryProjection.presentationGeometry(
                format: format,
                current: current
            ) {
            case .current(let value):
                geometry = value
            case .deferred:
                if presentationUpdate.requiresInteractionCancellation,
                   let cancellation = try? state.pointerController.cancel()
                {
                    appendPointerCancellation(cancellation, in: state)
                }
                state.observationOverlay = InputObservationOverlay()
                state.interactionView.geometry = nil
                applyWindowReservation(state)
                if state.pendingRotateActionIDs.isEmpty,
                   let activationID = state.captureReadyActivationID,
                   let session = state.runtimeSession
                {
                    beginCaptureReadyTransition(
                        activationID: activationID,
                        session: session,
                        state: state
                    )
                }
                return
            }
            if presentationUpdate.requiresInteractionCancellation,
               let cancellation = try state.pointerController.geometryDidChange(
                   to: geometry
               )
            {
                appendPointerCancellation(cancellation, in: state)
            }
            if presentationUpdate.requiresInteractionCancellation
                || current?.geometryRevision != geometry.geometryRevision
            {
                state.observationOverlay = InputObservationOverlay()
            }
            state.interactionView.geometry = geometry
            applyWindowReservation(state)
            if state.liveModel.coordinateInputEnabled,
               state.videoSession?.bindingIdentity.geometryRevision
                    == geometry.geometryRevision
            {
                setStatus(nil, busy: false, in: state)
            }
        } catch {
            setStatus("Controls awaiting geometry", busy: false, in: state)
        }
    }

    @MainActor
    private func handleLiveResizeDisplayGate(
        withholding: Bool,
        videoBindingToken: UUID,
        windowID: String
    ) {
        guard let state = windows[windowID],
              state.closeLifecycle.acceptsWork,
              Self.videoCallbackTokenIsCurrent(
                  videoBindingToken,
                  inFlightToken: state.videoBindingToken,
                  boundToken: state.boundVideoToken
              )
        else { return }
        if withholding {
            guard state.videoSession?.isWithholdingLiveResizeFrames == true,
                  state.liveResizeTransaction != nil
                    || state.awaitingLiveResizePresentation
            else { return }
            state.liveResizeFramesWithheld = true
            state.liveModel.setPointerPreparing(reason: "awaitingPresentation")
            if state.pointerGestureInProgress,
               let cancellation = try? state.pointerController.cancel()
            {
                appendPointerCancellation(cancellation, in: state)
            }
            state.observationOverlay = InputObservationOverlay()
        } else {
            guard state.videoSession?.isWithholdingLiveResizeFrames != true else {
                return
            }
            state.liveResizeFramesWithheld = false
            if !state.awaitingLiveResizePresentation {
                state.liveModel.reconcilePointerAvailability()
            }
        }
        refreshAvailabilityOverlay(in: state)
    }

    @MainActor
    private func finishLiveResizeVideoTransition(
        in state: ProductionGUIHostWindowState
    ) -> Bool {
        if let pending = state.pendingLiveResizePresentation {
            state.pendingLiveResizePresentation = nil
            state.awaitingLiveResizePresentation = false
            applyVideoPresentation(
                pending.format,
                mapping: pending.mapping,
                videoBindingToken: pending.videoBindingToken,
                windowID: state.windowID
            )
            guard state.liveModel.samplePresentation == pending.format else {
                state.awaitingLiveResizePresentation = true
                state.liveModel.setPointerPreparing(reason: "awaitingPresentation")
                refreshAvailabilityOverlay(in: state)
                return false
            }
            state.videoSession?.endLiveResize()
            state.liveResizeFramesWithheld = false
            state.liveModel.reconcilePointerAvailability()
            refreshAvailabilityOverlay(in: state)
            return true
        }
        if state.liveResizeFramesWithheld
            || state.videoSession?.isWithholdingLiveResizeFrames == true
        {
            state.awaitingLiveResizePresentation = true
            state.liveModel.setPointerPreparing(reason: "awaitingPresentation")
            refreshAvailabilityOverlay(in: state)
            return false
        }
        state.videoSession?.endLiveResize()
        state.liveResizeFramesWithheld = false
        state.awaitingLiveResizePresentation = false
        state.liveModel.reconcilePointerAvailability()
        refreshAvailabilityOverlay(in: state)
        return false
    }

    @MainActor
    private func cancelLiveResizeVideoTransition(
        in state: ProductionGUIHostWindowState
    ) {
        state.pendingLiveResizePresentation = nil
        state.awaitingLiveResizePresentation = false
        state.liveResizeFramesWithheld = false
        state.videoSession?.endLiveResize()
        state.liveModel.reconcilePointerAvailability()
    }

    static func captureReadyBindingIsCurrent(
        _ binding: VideoBindingIdentity,
        mapping: ProductionVideoSourceMapping,
        target: CanonicalUDID
    ) -> Bool {
        binding.canonicalUDID == target
            && binding.connectionEpoch == mapping.connectionEpoch
            && binding.geometryRevision == mapping.geometry.geometryRevision
            && binding.sourceEpoch == mapping.sourceEpoch
            && binding.sourceID == mapping.sourceID
    }

    static func boundVideoStartErrorCode(_ error: Error) -> String {
        switch error {
        case is SnapshotFrameError:
            return "snapshotFrameInvalid"
        case is VideoBindingError:
            return "videoBindingInvalid"
        case is AVFoundationVideoSourceError:
            return "captureSourceUnavailable"
        default:
            return "boundSessionStartFailed"
        }
    }

    static func captureReadyActivationCanResume(
        activationConnectionEpoch: UInt64?,
        attachment: LiveAttachment
    ) -> Bool {
        activationConnectionEpoch == attachment.connectionEpoch
    }

    static func captureReadyActivationID(
        existing: CanonicalUUID?,
        activationConnectionEpoch: UInt64?,
        bindingConnectionEpoch: UInt64,
        create: () -> CanonicalUUID = { CanonicalUUID(value: UUID()) }
    ) -> CanonicalUUID {
        if activationConnectionEpoch == bindingConnectionEpoch,
           let existing
        {
            return existing
        }
        return create()
    }

    static func captureReadyFailureStatus(
        pointerAvailability: LiveWindowPointerAvailability
    ) -> String? {
        switch pointerAvailability {
        case .available:
            nil
        case .preparing:
            "Controls awaiting geometry"
        case .unavailable:
            "Controls unavailable"
        }
    }

    static func videoCallbackTokenIsCurrent(
        _ token: UUID,
        inFlightToken: UUID?,
        boundToken: UUID?
    ) -> Bool {
        token == inFlightToken || token == boundToken
    }

    @MainActor
    private func selectedDescriptor(
        in state: ProductionGUIHostWindowState
    ) -> VideoSourceDescriptor? {
        guard let sourceID = state.sourcePicker.selectedItem?.representedObject
            as? String
        else { return nil }
        return state.inventory?.sources.first { $0.sourceID == sourceID }
    }

    @MainActor
    private func selectSource(
        _ descriptor: VideoSourceDescriptor,
        in state: ProductionGUIHostWindowState
    ) {
        guard let index = state.inventory?.sources.firstIndex(where: {
            $0.sourceID == descriptor.sourceID
        }) else { return }
        state.sourcePicker.selectItem(at: index)
    }

    @MainActor
    private func stopPreview(_ state: ProductionGUIHostWindowState) {
        state.previewCapture?.stop()
        state.previewSink?.stop()
        state.previewCapture = nil
        state.previewSink = nil
        state.previewDescriptor = nil
        state.confirmButton.isEnabled = false
        let retainsFrozenFrame = if case .frozen = state.liveModel.videoAvailability {
            true
        } else {
            false
        }
        if state.videoSession == nil, !retainsFrozenFrame {
            state.videoView.layer = CALayer()
            state.videoView.layer?.backgroundColor = NSColor.black.cgColor
            state.identityPlaceholderVisible = true
        }
        refreshAvailabilityOverlay(in: state)
        updateSourceControls(state)
    }

    @MainActor
    private func takePreview(
        _ state: ProductionGUIHostWindowState
    ) -> ProductionSourceCaptureLease? {
        let capture = state.previewCapture
        state.previewSink?.stop()
        state.previewCapture = nil
        state.previewSink = nil
        state.previewDescriptor = nil
        state.confirmButton.isEnabled = false
        return capture
    }

    @MainActor
    private func stopBoundVideo(
        _ state: ProductionGUIHostWindowState,
        presentation: ProductionBoundVideoStopPresentation,
        invalidateCoordinateAuthority: Bool
    ) {
        clearPendingLiveResize(in: state)
        cancelLiveResizeVideoTransition(in: state)
        state.videoBindingInFlight = false
        state.videoBindingToken = nil
        state.boundVideoToken = nil
        state.captureGenerationTransitionInFlight = false
        state.captureGeometryRefreshPending = false
        if invalidateCoordinateAuthority,
           let geometry = state.liveModel.runtimeGeometry
        {
            do {
                let invalidated = try DisplayGeometryDTO(
                    connectionEpoch: geometry.connectionEpoch,
                    geometryRevision: geometry.geometryRevision == UInt64.max
                        ? geometry.geometryRevision
                        : geometry.geometryRevision + 1,
                    logicalHeight: geometry.logicalHeight,
                    logicalWidth: geometry.logicalWidth,
                    orientation: geometry.orientation
                )
                if let cancellation = try state.pointerController.geometryDidChange(
                    to: invalidated
                ) {
                    appendPointerCancellation(cancellation, in: state)
                }
            } catch {}
            try? state.liveModel.clearRuntimeGeometry(
                throughConnectionEpoch: geometry.connectionEpoch
            )
        }
        if invalidateCoordinateAuthority {
            state.interactionView.geometry = nil
            state.observationOverlay = InputObservationOverlay()
            state.interactionView.clearPointerOverlay()
        }
        let session = state.videoSession
        session?.stop()
        state.videoSession = nil
        state.confirmedDescriptor = nil
        _ = state.audioPreview.deviceDetached(canonicalUDID: state.canonicalUDID)
        let reason: LiveWindowPlaceholderReason
        let wantsFrozenFrame: Bool
        switch presentation {
        case .clear(let value):
            reason = value
            wantsFrozenFrame = false
        case .freezeIfAvailable(let value):
            reason = value
            wantsFrozenFrame = true
        }
        let alreadyFrozen = if case .frozen = state.liveModel.videoAvailability {
            true
        } else {
            false
        }
        let retainsFrame = wantsFrozenFrame
            && (alreadyFrozen || (session != nil && state.liveModel.samplePresentation != nil))
            && state.liveModel.freezeVideo(unavailableReason: reason)
        if retainsFrame {
            state.identityPlaceholderVisible = false
        } else {
            session?.displayLayer.flushAndRemoveImage()
            if let sourceEpoch = state.liveModel.samplePresentation?.sourceEpoch {
                try? state.liveModel.clearCaptureActiveFormat(
                    throughSourceEpoch: sourceEpoch
                )
            }
            state.liveModel.showIdentityPlaceholder(reason: reason)
            state.videoView.layer = CALayer()
            state.videoView.layer?.backgroundColor = NSColor.black.cgColor
            state.identityPlaceholderVisible = true
        }
        applyWindowReservation(state)
        refreshAvailabilityOverlay(in: state)
        updateSourceControls(state)
    }

    @MainActor
    private func resetCaptureActivation(
        in state: ProductionGUIHostWindowState
    ) {
        state.captureReadyActivationID = nil
        state.captureReadyCommitted = false
        state.captureReadyConnectionEpoch = nil
        state.captureGenerationTransitionInFlight = false
        state.captureGeometryRefreshPending = false
    }

    @MainActor
    private func startAudioPreview(
        mapping: ProductionVideoSourceMapping,
        inventory: VideoSourceInventory,
        state: ProductionGUIHostWindowState
    ) {
        guard state.videoSession?.audioAvailable == true else {
            state.audioPreview.fail(reason: "audioSourceUnavailable")
            setStatus("Audio unavailable", busy: false, in: state)
            return
        }
        guard let claim = try? VideoSourceMappingClaim(
            sourceID: mapping.sourceID,
            sourceEpoch: mapping.sourceEpoch,
            canonicalUDID: state.canonicalUDID,
            mappingProofID: mapping.mappingProofID
        ),
        let resolution = try? inventory.resolve(
            target: state.canonicalUDID,
            claims: [claim]
        ) else { return }
        let authorization: GUIAuthorizationState = switch AVCaptureDevice
            .authorizationStatus(for: .audio)
        {
        case .authorized: .authorized
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
        do {
            try state.audioPreview.start(
                resolution: resolution,
                microphoneAuthorization: authorization
            )
            state.videoSession?.setAudioMuted(
                !state.audioPreview.isMacOutputEnabled
            )
        } catch {
            state.audioPreview.fail(reason: "audioPermissionUnavailable")
            setStatus("Audio unavailable", busy: false, in: state)
        }
    }

    @MainActor
    private func applyWindowReservation(_ state: ProductionGUIHostWindowState) {
        guard state.closeLifecycle.acceptsWork else { return }
        let reservation = state.liveModel.reservation
        if let transaction = state.liveResizeTransaction {
            state.canvasHost.updateAspectRatio(transaction.canvasAspectRatio)
            refreshAvailabilityOverlay(in: state)
            return
        }
        clearPendingLiveResize(in: state)
        state.canvasHost.updateAspectRatio(CGFloat(
            reservation.canvasAspectRatio.value
        ))
        refreshAvailabilityOverlay(in: state)
        guard state.liveModel.windowState == .windowed else { return }
        updateWindowContentMinimumSize(in: state)
        let revision = state.liveModel.reservationRevision
        if state.windowReservationRevision != revision {
            state.windowReservationRevision = revision
            state.windowReservationAttempts = 0
        }
        guard state.windowReservationAttempts < 2 else { return }
        state.windowReservationAttempts += 1
        state.window.setFrame(
            Self.windowFrame(for: reservation, window: state.window),
            display: true,
            animate: false
        )
        state.window.contentView?.layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self, weak state] in
            guard let self, let state,
                  state.closeLifecycle.acceptsWork,
                  state.liveModel.windowState == .windowed,
                  state.windowReservationRevision == revision
            else { return }
            self.reconcileActualMinimumWidth(state, revision: revision)
        }
    }

    @MainActor
    private func reconcileActualMinimumWidth(
        _ state: ProductionGUIHostWindowState,
        revision: UInt64
    ) {
        state.window.contentView?.layoutSubtreeIfNeeded()
        let desiredWidth = state.liveModel.reservation.contentSize.width
        let adoptedWidth = Double(state.window.contentView?.bounds.width ?? 0)
        if adoptedWidth > desiredWidth + 0.5 {
            Self.windowGeometryLogger.notice(
                "stage=adoptedContentWidth width=\(adoptedWidth, privacy: .public) desiredWidth=\(desiredWidth, privacy: .public)"
            )
        }
        let minimumWidth = state.sourceControlsMinimumContentWidth
        if minimumWidth > desiredWidth + 0.5 {
            Self.windowGeometryLogger.notice(
                "stage=minimumWidthOwner owner=sourceControls width=\(minimumWidth, privacy: .public) desiredWidth=\(desiredWidth, privacy: .public)"
            )
        }
        let previous = state.liveModel.actualMinimumContentWidth
        do {
            try state.liveModel.updateActualMinimumContentWidth(minimumWidth)
        } catch {
            Self.windowGeometryLogger.error(
                "outcome=failed stage=minimumWidthReconciliation revision=\(revision, privacy: .public)"
            )
            setStatus("Window geometry unavailable", busy: false, in: state)
            return
        }
        if state.windowReservationRevision == revision,
           state.windowReservationAttempts < 2,
           ProductionLiveWindowSizing.shouldRetryProgrammaticReservation(
               adoptedContentWidth: adoptedWidth,
               desiredContentWidth: desiredWidth,
               minimumContentWidthChanged: abs(
                   state.liveModel.actualMinimumContentWidth - previous
               ) > 0.5
           )
        {
            applyWindowReservation(state)
            return
        }
        verifyWindowedCanvasGeometry(state, revision: revision)
    }

    @MainActor
    private func constrainedLiveResizeFrameSize(
        in state: ProductionGUIHostWindowState,
        window: NSWindow,
        proposedFrameSize: NSSize,
        comparisonFrameSize: NSSize? = nil,
        transaction: ProductionLiveResizeTransaction? = nil
    ) -> NSSize {
        let proposedFrame = NSRect(origin: .zero, size: proposedFrameSize)
        let proposedContentSize = window.contentRect(
            forFrameRect: proposedFrame
        ).size
        let comparisonContentSize = comparisonFrameSize.map {
            window.contentRect(forFrameRect: NSRect(origin: .zero, size: $0)).size
        }
        let currentContentSize = comparisonContentSize
            ?? window.contentView?.bounds.size
            ?? proposedContentSize
        let visibleFrame = window.screen?.visibleFrame
            ?? state.window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(origin: .zero, size: proposedFrameSize)
        let frameChromeHeight = max(
            0,
            proposedFrameSize.height - proposedContentSize.height
        )
        let canvasAspectRatio = transaction?.canvasAspectRatio
            ?? CGFloat(state.liveModel.reservation.canvasAspectRatio.value)
        let sourceControlsHeight = transaction?.sourceControlsHeight
            ?? CGFloat(state.liveModel.reservation.sourceControlsHeight)
        let contentSize = ProductionLiveWindowSizing.constrainedContentSize(
            proposedContentSize: proposedContentSize,
            currentContentSize: currentContentSize,
            canvasAspectRatio: canvasAspectRatio,
            sourceControlsHeight: sourceControlsHeight,
            maximumFrameSize: visibleFrame.size,
            frameChromeHeight: transaction?.frameChromeHeight ?? frameChromeHeight,
            minimumContentWidth: CGFloat(
                state.liveModel.actualMinimumContentWidth
            ),
            resizeDriver: transaction?.driver
        )
        return window.frameRect(forContentRect: NSRect(
            origin: .zero,
            size: contentSize
        )).size
    }

    @MainActor
    private func updateWindowContentMinimumSize(
        in state: ProductionGUIHostWindowState
    ) {
        let window = state.window
        let reservation = state.liveModel.reservation
        let contentSize = window.contentView?.bounds.size
            ?? window.contentRect(forFrameRect: window.frame).size
        let visibleFrame = window.screen?.visibleFrame
            ?? Self.nsRect(reservation.screenVisibleFrame)
        window.contentMinSize = ProductionLiveWindowSizing.minimumContentSize(
            canvasAspectRatio: CGFloat(reservation.canvasAspectRatio.value),
            sourceControlsHeight: CGFloat(reservation.sourceControlsHeight),
            maximumFrameSize: visibleFrame.size,
            frameChromeHeight: max(0, window.frame.height - contentSize.height),
            minimumContentWidth: CGFloat(
                state.liveModel.actualMinimumContentWidth
            )
        )
    }

    @MainActor
    private func synthesizePendingLiveResizeIfNeeded(
        in state: ProductionGUIHostWindowState
    ) {
        guard state.liveModel.windowState == .windowed,
              !state.liveResizeReconciliationInFlight,
              let referenceFrame = state.liveResizeStartFrame
        else { return }
        let adoptedFrame = state.window.frame
        if let pending = state.pendingLiveResize {
            guard pending.source == .windowDidResizeFallback,
                  !frameMatchesPending(adoptedFrame, pending: pending)
            else { return }
        }
        var transaction = state.liveResizeTransaction
        if var currentTransaction = transaction,
           currentTransaction.driver == nil
        {
            currentTransaction.driver = ProductionLiveWindowSizing.liveResizeDriver(
                proposedFrameSize: adoptedFrame.size,
                referenceFrameSize: referenceFrame.size,
                sourceControlsHeight: currentTransaction.sourceControlsHeight,
                frameChromeHeight: currentTransaction.frameChromeHeight
            )
            transaction = currentTransaction
            state.liveResizeTransaction = currentTransaction
        }
        let comparisonFrameSize = state.pendingLiveResize?.expectedFrameSize
            ?? referenceFrame.size
        state.settlingLiveResizeSequence = nil
        state.liveResizeSettlementAttempt = 0
        state.liveResizeSettlementExactObservations = 0
        state.liveResizeSequence &+= 1
        let expectedFrameSize = constrainedLiveResizeFrameSize(
            in: state,
            window: state.window,
            proposedFrameSize: adoptedFrame.size,
            comparisonFrameSize: comparisonFrameSize,
            transaction: transaction
        )
        state.pendingLiveResize = ProductionPendingLiveResize(
            referenceFrame: referenceFrame,
            expectedFrameSize: expectedFrameSize,
            sequence: state.liveResizeSequence,
            source: .windowDidResizeFallback
        )
        Self.windowGeometryLogger.notice(
            "stage=windowDidResizeFallback sequence=\(state.liveResizeSequence, privacy: .public) adoptedWidth=\(adoptedFrame.width, privacy: .public) adoptedHeight=\(adoptedFrame.height, privacy: .public) expectedWidth=\(expectedFrameSize.width, privacy: .public) expectedHeight=\(expectedFrameSize.height, privacy: .public)"
        )
    }

    @MainActor
    private func schedulePendingLiveResizeReconciliation(
        in state: ProductionGUIHostWindowState
    ) {
        guard !state.liveResizeReconciliationInFlight,
              let sequence = state.pendingLiveResize?.sequence,
              state.scheduledLiveResizeSequence != sequence
        else { return }
        state.scheduledLiveResizeSequence = sequence
        DispatchQueue.main.async { [weak self, weak state] in
            guard let self, let state else { return }
            if state.scheduledLiveResizeSequence == sequence {
                state.scheduledLiveResizeSequence = nil
            }
            guard state.closeLifecycle.acceptsWork,
                  state.liveModel.windowState == .windowed,
                  state.pendingLiveResize?.sequence == sequence
            else { return }
            self.reconcilePendingLiveResize(in: state)
        }
    }

    @MainActor
    private func scheduleLiveResizeSettlement(
        in state: ProductionGUIHostWindowState,
        sequence: UInt64,
        attempt: Int
    ) {
        guard attempt < Self.liveResizeSettlementDelays.count else { return }
        let delay = Self.liveResizeSettlementDelays[attempt]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak state] in
            guard let self, let state,
                  state.closeLifecycle.acceptsWork,
                  state.liveModel.windowState == .windowed,
                  state.settlingLiveResizeSequence == sequence,
                  state.pendingLiveResize?.sequence == sequence
            else { return }
            self.settleLiveResize(
                in: state,
                sequence: sequence,
                attempt: attempt
            )
        }
    }

    @MainActor
    private func settleLiveResize(
        in state: ProductionGUIHostWindowState,
        sequence: UInt64,
        attempt: Int
    ) {
        guard let pending = state.pendingLiveResize,
              pending.sequence == sequence
        else { return }
        state.liveResizeSettlementAttempt = attempt
        let observedFrame = state.window.frame
        let observedExact = frameMatchesPending(observedFrame, pending: pending)
        Self.windowGeometryLogger.notice(
            "stage=liveResizeSettlement sequence=\(sequence, privacy: .public) attempt=\(attempt, privacy: .public) inLiveResize=\(state.window.inLiveResize, privacy: .public) actualWidth=\(observedFrame.width, privacy: .public) actualHeight=\(observedFrame.height, privacy: .public) expectedWidth=\(pending.expectedFrameSize.width, privacy: .public) expectedHeight=\(pending.expectedFrameSize.height, privacy: .public)"
        )

        if state.window.inLiveResize {
            state.liveResizeSettlementExactObservations = 0
            scheduleNextLiveResizeSettlement(
                in: state,
                sequence: sequence,
                attempt: attempt
            )
            return
        }

        reconcilePendingLiveResize(in: state)
        guard let currentPending = state.pendingLiveResize,
              currentPending.sequence == sequence
        else { return }
        let reconciledExact = frameMatchesPending(
            state.window.frame,
            pending: currentPending
        )
        if observedExact && reconciledExact {
            state.liveResizeSettlementExactObservations += 1
        } else {
            state.liveResizeSettlementExactObservations = 0
        }

        if attempt >= Self.liveResizeSettlementMinimumAttempt,
           state.liveResizeSettlementExactObservations
            >= Self.liveResizeSettlementRequiredExactObservations
        {
            completeLiveResizeSettlement(in: state, pending: currentPending)
            return
        }
        scheduleNextLiveResizeSettlement(
            in: state,
            sequence: sequence,
            attempt: attempt
        )
    }

    @MainActor
    private func scheduleNextLiveResizeSettlement(
        in state: ProductionGUIHostWindowState,
        sequence: UInt64,
        attempt: Int
    ) {
        let nextAttempt = attempt + 1
        guard nextAttempt < Self.liveResizeSettlementDelays.count else {
            Self.windowGeometryLogger.error(
                "outcome=failed stage=liveResizeSettlementExhausted sequence=\(sequence, privacy: .public) attempt=\(attempt, privacy: .public)"
            )
            clearPendingLiveResize(in: state)
            setStatus("Window geometry unavailable", busy: false, in: state)
            return
        }
        scheduleLiveResizeSettlement(
            in: state,
            sequence: sequence,
            attempt: nextAttempt
        )
    }

    @MainActor
    private func completeLiveResizeSettlement(
        in state: ProductionGUIHostWindowState,
        pending: ProductionPendingLiveResize
    ) {
        recordCurrentUserCanvasSize(in: state)
        clearPendingLiveResize(in: state)
        Self.windowGeometryLogger.notice(
            "outcome=succeeded stage=liveResizeSettlement sequence=\(pending.sequence, privacy: .public) width=\(state.window.frame.width, privacy: .public) height=\(state.window.frame.height, privacy: .public)"
        )
    }

    @MainActor
    private func recordCurrentUserCanvasSize(
        in state: ProductionGUIHostWindowState
    ) {
        state.window.contentView?.layoutSubtreeIfNeeded()
        state.canvasHost.layoutSubtreeIfNeeded()
        let canvasSize = state.interactionView.bounds.size
        try? state.liveModel.recordUserCanvasSize(LiveWindowSize(
            width: canvasSize.width,
            height: canvasSize.height
        ))
    }

    @MainActor
    private func reconcilePendingLiveResize(
        in state: ProductionGUIHostWindowState
    ) {
        guard state.liveModel.windowState == .windowed else {
            clearPendingLiveResize(in: state)
            return
        }
        guard !state.liveResizeReconciliationInFlight,
              let pending = state.pendingLiveResize
        else { return }
        let adoptedFrame = state.window.frame
        guard abs(adoptedFrame.width - pending.expectedFrameSize.width) > 0.5
                || abs(adoptedFrame.height - pending.expectedFrameSize.height) > 0.5
        else { return }

        let visibleFrame = state.window.screen?.visibleFrame
            ?? Self.nsRect(state.liveModel.reservation.screenVisibleFrame)
        let reconciledFrame = ProductionLiveWindowSizing.reconciledLiveResizeFrame(
            referenceFrame: pending.referenceFrame,
            adoptedFrame: adoptedFrame,
            expectedFrameSize: pending.expectedFrameSize,
            visibleFrame: visibleFrame
        )
        Self.windowGeometryLogger.notice(
            "outcome=reconciling stage=partialAxisAdoption sequence=\(pending.sequence, privacy: .public) adoptedWidth=\(adoptedFrame.width, privacy: .public) adoptedHeight=\(adoptedFrame.height, privacy: .public) expectedWidth=\(pending.expectedFrameSize.width, privacy: .public) expectedHeight=\(pending.expectedFrameSize.height, privacy: .public)"
        )
        state.liveResizeReconciliationInFlight = true
        defer { state.liveResizeReconciliationInFlight = false }
        state.window.setFrame(reconciledFrame, display: true, animate: false)
        state.window.contentView?.layoutSubtreeIfNeeded()
        state.canvasHost.layoutSubtreeIfNeeded()

        let finalFrame = state.window.frame
        guard abs(finalFrame.width - pending.expectedFrameSize.width) <= 0.5,
              abs(finalFrame.height - pending.expectedFrameSize.height) <= 0.5
        else {
            Self.windowGeometryLogger.error(
                "outcome=failed stage=partialAxisReconciliation adoptedWidth=\(finalFrame.width, privacy: .public) adoptedHeight=\(finalFrame.height, privacy: .public) expectedWidth=\(pending.expectedFrameSize.width, privacy: .public) expectedHeight=\(pending.expectedFrameSize.height, privacy: .public)"
            )
            clearPendingLiveResize(in: state)
            setStatus("Window geometry unavailable", busy: false, in: state)
            return
        }
        verifyWindowedCanvasGeometry(
            state,
            revision: state.liveModel.reservationRevision
        )
    }

    private func frameMatchesPending(
        _ frame: NSRect,
        pending: ProductionPendingLiveResize
    ) -> Bool {
        abs(frame.width - pending.expectedFrameSize.width) <= 0.5
            && abs(frame.height - pending.expectedFrameSize.height) <= 0.5
    }

    @MainActor
    private func clearPendingLiveResize(in state: ProductionGUIHostWindowState) {
        state.pendingLiveResize = nil
        state.scheduledLiveResizeSequence = nil
        state.settlingLiveResizeSequence = nil
        state.liveResizeStartFrame = nil
        state.liveResizeTransaction = nil
        state.liveResizeSettlementAttempt = 0
        state.liveResizeSettlementExactObservations = 0
    }

    @MainActor
    private func makeLiveResizeTransaction(
        in state: ProductionGUIHostWindowState,
        window: NSWindow,
        referenceFrame: NSRect
    ) -> ProductionLiveResizeTransaction {
        let contentSize = window.contentView?.bounds.size
            ?? window.contentRect(forFrameRect: referenceFrame).size
        return ProductionLiveResizeTransaction(
            referenceFrame: referenceFrame,
            canvasAspectRatio: CGFloat(
                state.liveModel.reservation.canvasAspectRatio.value
            ),
            sourceControlsHeight: CGFloat(
                state.liveModel.reservation.sourceControlsHeight
            ),
            frameChromeHeight: max(0, referenceFrame.height - contentSize.height)
        )
    }

    @MainActor
    private func verifyWindowedCanvasGeometry(
        _ state: ProductionGUIHostWindowState,
        revision: UInt64
    ) {
        state.window.contentView?.layoutSubtreeIfNeeded()
        state.canvasHost.layoutSubtreeIfNeeded()
        let bounds = state.canvasHost.bounds
        let videoFrame = state.videoView.frame
        let interactionFrame = state.interactionView.frame
        let ratio = CGFloat(state.liveModel.reservation.canvasAspectRatio.value)
        let exact = abs(bounds.minX - videoFrame.minX) <= 0.5
            && abs(bounds.minY - videoFrame.minY) <= 0.5
            && abs(bounds.width - videoFrame.width) <= 0.5
            && abs(bounds.height - videoFrame.height) <= 0.5
            && abs(bounds.minX - interactionFrame.minX) <= 0.5
            && abs(bounds.minY - interactionFrame.minY) <= 0.5
            && abs(bounds.width - interactionFrame.width) <= 0.5
            && abs(bounds.height - interactionFrame.height) <= 0.5
            && abs(bounds.width - bounds.height * ratio) <= 0.5
        if exact {
            Self.windowGeometryLogger.notice(
                "outcome=succeeded revision=\(revision, privacy: .public) width=\(bounds.width, privacy: .public) height=\(bounds.height, privacy: .public)"
            )
        } else {
            Self.windowGeometryLogger.error(
                "outcome=failed stage=adoptedCanvasMismatch revision=\(revision, privacy: .public) width=\(bounds.width, privacy: .public) height=\(bounds.height, privacy: .public)"
            )
            setStatus("Window geometry unavailable", busy: false, in: state)
        }
    }

    @MainActor
    private func state(
        from notification: Notification
    ) -> ProductionGUIHostWindowState? {
        guard let window = notification.object as? NSWindow,
              let identifier = window.identifier?.rawValue
        else { return nil }
        return windows[identifier]
    }

    private static func liveRect(_ rect: NSRect) -> LiveWindowRect {
        LiveWindowRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.width,
            height: rect.height
        )
    }

    private static func nsRect(_ rect: LiveWindowRect) -> NSRect {
        NSRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    @MainActor
    private static func windowFrame(
        for reservation: LiveWindowReservation,
        window: NSWindow
    ) -> NSRect {
        let visibleFrame = nsRect(reservation.screenVisibleFrame)
        let desiredContentSize = NSSize(
            width: reservation.contentSize.width,
            height: reservation.contentSize.height
        )
        let desiredFrameSize = window.frameRect(forContentRect: NSRect(
            origin: .zero,
            size: desiredContentSize
        )).size
        let maximumCanvasSize = NSSize(
            width: max(
                1,
                visibleFrame.width
                    - max(0, desiredFrameSize.width - desiredContentSize.width)
            ),
            height: max(
                1,
                visibleFrame.height
                    - max(0, desiredFrameSize.height - desiredContentSize.height)
                    - reservation.sourceControlsHeight
            )
        )
        let boundedContentSize = ProductionLiveWindowSizing.adoptableContentSize(
            preferredCanvasSize: NSSize(
                width: reservation.canvasSize.width,
                height: reservation.canvasSize.height
            ),
            canvasAspectRatio: CGFloat(reservation.canvasAspectRatio.value),
            sourceControlsHeight: reservation.sourceControlsHeight,
            maximumCanvasSize: maximumCanvasSize,
            minimumContentWidth: reservation.actualMinimumContentWidth,
            preferredPrimaryConstraint: .notExceedingPreferred
        )
        let boundedFrameSize = window.frameRect(forContentRect: NSRect(
            origin: .zero,
            size: boundedContentSize
        )).size
        return NSRect(
            x: visibleFrame.midX - boundedFrameSize.width / 2,
            y: visibleFrame.midY - boundedFrameSize.height / 2,
            width: boundedFrameSize.width,
            height: boundedFrameSize.height
        )
    }

    private func toolbarIdentifier(
        windowID: String,
        commandID: String
    ) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("\(windowID)::\(commandID)")
    }

    private static func commandID(
        from identifier: NSToolbarItem.Identifier
    ) -> String? {
        guard let separator = identifier.rawValue.range(of: "::") else {
            return nil
        }
        return String(identifier.rawValue[separator.upperBound...])
    }

    private static func toolbarEnabled(
        _ presentation: LiveToolbarPresentationState
    ) -> Bool {
        if case .enabled = presentation { return true }
        return false
    }

    private static func toolbarEnabled(
        _ presentation: LiveToolbarPresentationState,
        commandID: String
    ) -> Bool {
        commandID == "gui.previewAudioMute.toggle"
            || toolbarEnabled(presentation)
    }

    private static func toolbarVisibilityPriority(
        _ commandID: String
    ) -> NSToolbarItem.VisibilityPriority {
        switch commandID {
        case "button.home", "button.appSwitcher", "device.rotate":
            return .high
        default:
            return .low
        }
    }

    @MainActor
    private static func morePopoverSlots(
        in state: ProductionGUIHostWindowState
    ) -> [LiveToolbarSlot] {
        state.toolbarModel?.slots ?? []
    }

    @MainActor
    private static func topToolbarSlots(
        in state: ProductionGUIHostWindowState
    ) -> [LiveToolbarSlot] {
        guard let slots = state.toolbarModel?.slots else { return [] }
        let maximumVisible = topToolbarSlotCapacity(for: state.window)
        let highPrioritySlots = slots.filter {
            toolbarVisibilityPriority($0.commandID) == .high
        }
        let visibleCount = min(
            slots.count,
            max(highPrioritySlots.count, maximumVisible)
        )
        return Array(slots.prefix(visibleCount))
    }

    @MainActor
    private static func topToolbarSlotCapacity(for window: NSWindow) -> Int {
        let reservedChromeAndMoreWidth: CGFloat = 210
        let toolbarItemWidth: CGFloat = 36
        let availableWidth = max(0, window.frame.width - reservedChromeAndMoreWidth)
        return max(0, Int(floor(availableWidth / toolbarItemWidth)))
    }

    private static func toolbarToolTip(_ slot: LiveToolbarSlot) -> String {
        let label = toolbarLabel(slot.commandID)
        switch slot.presentation {
        case .enabled:
            return label
        case .disabled("deviceKeyboardUnavailable")
            where slot.commandID == "gui.keyboardCapture.toggle":
            return "Keyboard Capture unavailable: device keyboard not ready"
        case .disabled(let reason), .loading(let reason):
            return "\(label): \(reason)"
        }
    }

    static func resultStatus(
        _ result: RepositoryJSONObject?,
        commandID: String? = nil
    ) -> String? {
        guard let result else { return "Control failed" }
        switch result["outcome"]?.stringValue {
        case "succeeded":
            if commandID == "app.install",
               let bundleID = result["value"]?.objectValue?["bundleID"]?.stringValue
            {
                return "Installed \(bundleID)"
            }
            if let value = result["value"]?.objectValue,
               case .bool(false)? = value["visibleOrientationConfirmed"],
               let orientationText = value["currentDisplayOrientation"]?.stringValue,
               let orientation = DisplayOrientationDTO(rawValue: orientationText)
            {
                if case .bool(true)? = value["displayOrientationChanged"] {
                    return "Visible direction is \(orientationStatusText(orientation))"
                }
                return "No visible rotation; current direction is \(orientationStatusText(orientation))"
            }
            return nil
        case "failed":
            return result["error"]?.objectValue?["code"]?.stringValue
                ?? "Control failed"
        case "outcomeUnknown":
            return "Result unknown"
        default:
            return "Control failed"
        }
    }

    static func orientationStatusText(
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

    private static func toolbarLabel(_ commandID: String) -> String {
        switch commandID {
        case "button.home": "Home"
        case "button.appSwitcher": "App Switcher"
        case "button.lock": "Lock"
        case "button.volumeUp": "Volume Up"
        case "button.volumeDown": "Volume Down"
        case "button.mute": "Mute Device"
        case "device.rotate": "Rotate"
        case "screenshot.gui": "Screenshot"
        case "gui.keyboardCapture.toggle": "Keyboard Capture"
        case "gui.softwareKeyboard.toggle": "Software Keyboard"
        case "gui.previewAudioMute.toggle": "Preview Audio"
        case "app.install": "Install App"
        default: commandID
        }
    }

    private static func toolbarImage(_ commandID: String) -> NSImage {
        let symbol: String = switch commandID {
        case "button.home": "house"
        case "button.appSwitcher": "rectangle.3.group"
        case "button.lock": "lock"
        case "button.volumeUp": "speaker.plus"
        case "button.volumeDown": "speaker.minus"
        case "button.mute": "speaker.slash"
        case "device.rotate": "rotate.right"
        case "screenshot.gui": "camera"
        case "gui.keyboardCapture.toggle": "keyboard"
        case "gui.softwareKeyboard.toggle": "keyboard.badge.ellipsis"
        case "gui.previewAudioMute.toggle": "speaker.wave.2"
        case "app.install": "plus.app"
        default: "questionmark"
        }
        return NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: toolbarLabel(commandID)
        ) ?? NSImage()
    }

    private static func sourceTitle(_ source: VideoSourceDescriptor) -> String {
        let prefix = source.sourceID.prefix(8)
        let suffix = source.sourceID.suffix(8)
        let identifier = "\(prefix)...\(suffix)"
        guard source.hasActiveFormat else {
            return "\(source.displayName)  \(identifier)"
        }
        return "\(source.displayName)  \(source.activeFormatWidth)x\(source.activeFormatHeight)  \(identifier)"
    }
}

@MainActor
private final class ProductionMoreToolbarPopoverRow: NSControl {
    var isSelected = false {
        didSet { updateVisualState() }
    }

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { updateVisualState() }
    }
    private var isPressed = false {
        didSet { updateVisualState() }
    }

    init(
        image: NSImage,
        title: String,
        target: AnyObject?,
        action: Selector?
    ) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        iconView.image = image
        titleField.stringValue = title
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var isEnabled: Bool {
        didSet { updateVisualState() }
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { isPressed = false }
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), let action else { return }
        NSApp.sendAction(action, to: target, from: self)
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        iconView.contentTintColor = NSColor.labelColor
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 13)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(iconView)
        addSubview(titleField)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),
            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateVisualState()
    }

    private func updateVisualState() {
        let activeBackground: NSColor
        if isPressed {
            activeBackground = NSColor.controlAccentColor.withAlphaComponent(0.18)
        } else if isSelected {
            activeBackground = NSColor.controlAccentColor.withAlphaComponent(0.13)
        } else if isHovered && isEnabled {
            activeBackground = NSColor.labelColor.withAlphaComponent(0.07)
        } else {
            activeBackground = .clear
        }
        layer?.backgroundColor = activeBackground.cgColor
        alphaValue = isEnabled ? 1.0 : 0.45
        iconView.contentTintColor = isEnabled
            ? NSColor.labelColor
            : NSColor.disabledControlTextColor
        titleField.textColor = isEnabled
            ? NSColor.labelColor
            : NSColor.disabledControlTextColor
    }
}

@MainActor
private final class ProductionGUIHostWindowState {
    let availabilityOverlay: ProductionGUIHostAvailabilityOverlayView
    let canonicalUDID: CanonicalUDID
    let canvasHost: ProductionGUIHostCanvasHost
    let changeMappingButton: NSButton
    let clearMappingButton: NSButton
    let confirmButton: NSButton
    let interactionView: ProductionGUIHostInteractionView
    let placeholder: NSTextField
    let previewButton: NSButton
    let progressIndicator: NSProgressIndicator
    let sourcePicker: NSPopUpButton
    let sourceControlsContent: NSView
    let sourceControlsMinimumContentWidth: Double
    let sourceSummaryLabel: NSTextField
    let statusLabel: NSTextField
    let videoView: NSView
    let window: NSWindow
    let windowID: String
    var audioPreview: AudioPreview
    var automaticMappingAttempt: ProductionVideoSourceMappingAttempt?
    var automaticProbeCapture: ProductionSourceCaptureLease?
    var automaticProbeDescriptor: VideoSourceDescriptor?
    var automaticProbeMappingProofID: String?
    var automaticProbeSink: ProductionVideoSourcePreviewSink?
    var automaticProbeToken: UUID?
    var boundVideoToken: UUID?
    var videoStallRecoveryGate = ProductionVideoStallRecoveryGate()
    var captureGenerationTransitionInFlight = false
    var captureGeometryRefreshPending = false
    var captureReadyActivationID: CanonicalUUID?
    var captureReadyCommitted = false
    var captureReadyConnectionEpoch: UInt64?
    var confirmedDescriptor: VideoSourceDescriptor?
    var geometryRevision: UInt64 = 0
    var identityPlaceholderVisible = true
    var inventory: VideoSourceInventory?
    var keyboardController = KeyboardCaptureController()
    var keyboardInteractionID: CanonicalUUID?
    var keyboardPendingFrames = [(frame: KeyboardCaptureFrame, sequence: UInt64)]()
    var keyboardPressedKeysEmpty = true
    var keyboardRuntimeCapabilityReady = false
    var keyboardShortCloseToken: UUID?
    var keyboardStream: ProductionRuntimeLiveStream?
    var keyboardStreamClosing = false
    var keyboardStreamOpening = false
    var closeLifecycle = ProductionGUIHostWindowCloseLifecycle()
    var liveModel: LiveWindowModel
    var mappingChangeRequested = false
    var mappingLoadResult: VideoSourceMappingLoadResult?
    var mappingMutationInFlight = false
    var morePopover: NSPopover?
    var observationOverlay = InputObservationOverlay()
    var ownerCoordinator = LiveOwnerCoordinator()
    var pointerController = PointerInteractionController()
    var pointerGestureInProgress = false
    var pointerInteractionQueue = [ProductionQueuedPointerInteraction]()
    var pointerStream: ProductionRuntimeLiveStream?
    var pointerStreamClosing = false
    var pointerStreamOpening = false
    var pointerLastFailure: ProductionPointerInteractionFailure?
    var pendingRotateActionIDs = Set<CanonicalUUID>()
    var pendingLiveResize: ProductionPendingLiveResize?
    var pendingLiveResizePresentation: ProductionPendingLiveResizePresentation?
    var previewCapture: ProductionSourceCaptureLease?
    var previewDescriptor: VideoSourceDescriptor?
    var previewSink: ProductionVideoSourcePreviewSink?
    var runtimeSession: (any ProductionGUIHostRuntimeSession)?
    var toolbarButtons = [String: NSButton]()
    var toolbarItemIdentifiers = [NSToolbarItem.Identifier]()
    var toolbarItems = [String: NSToolbarItem]()
    var toolbarModel: LiveToolbar?
    var videoBindingInFlight = false
    var videoBindingToken: UUID?
    var videoSession: ProductionBoundVideoSession?
    var windowReservationAttempts = 0
    var windowReservationRevision: UInt64 = 0
    var liveResizeReconciliationInFlight = false
    var liveResizeFramesWithheld = false
    var liveResizeSequence: UInt64 = 0
    var liveResizeSettlementAttempt = 0
    var liveResizeSettlementExactObservations = 0
    var liveResizeStartFrame: NSRect?
    var liveResizeTransaction: ProductionLiveResizeTransaction?
    var awaitingLiveResizePresentation = false
    var scheduledLiveResizeSequence: UInt64?
    var settlingLiveResizeSequence: UInt64?

    init(
        availabilityOverlay: ProductionGUIHostAvailabilityOverlayView,
        canonicalUDID: CanonicalUDID,
        canvasHost: ProductionGUIHostCanvasHost,
        changeMappingButton: NSButton,
        clearMappingButton: NSButton,
        confirmButton: NSButton,
        interactionView: ProductionGUIHostInteractionView,
        liveModel: LiveWindowModel,
        placeholder: NSTextField,
        previewButton: NSButton,
        progressIndicator: NSProgressIndicator,
        sourcePicker: NSPopUpButton,
        sourceControlsContent: NSView,
        sourceControlsMinimumContentWidth: Double,
        sourceSummaryLabel: NSTextField,
        statusLabel: NSTextField,
        videoView: NSView,
        windowID: String,
        window: NSWindow
    ) {
        self.availabilityOverlay = availabilityOverlay
        self.canonicalUDID = canonicalUDID
        self.canvasHost = canvasHost
        self.changeMappingButton = changeMappingButton
        self.clearMappingButton = clearMappingButton
        self.confirmButton = confirmButton
        self.interactionView = interactionView
        self.liveModel = liveModel
        self.placeholder = placeholder
        self.previewButton = previewButton
        self.progressIndicator = progressIndicator
        self.sourcePicker = sourcePicker
        self.sourceControlsContent = sourceControlsContent
        self.sourceControlsMinimumContentWidth = sourceControlsMinimumContentWidth
        self.sourceSummaryLabel = sourceSummaryLabel
        self.statusLabel = statusLabel
        self.videoView = videoView
        self.windowID = windowID
        self.window = window
        self.audioPreview = try! AudioPreview(
            windowID: windowID,
            canonicalUDID: canonicalUDID
        )
    }
}

private struct ProductionPendingLiveResize {
    let referenceFrame: NSRect
    let expectedFrameSize: NSSize
    let sequence: UInt64
    let source: ProductionPendingLiveResizeSource
}

private struct ProductionLiveResizeTransaction {
    let referenceFrame: NSRect
    let canvasAspectRatio: CGFloat
    let sourceControlsHeight: CGFloat
    let frameChromeHeight: CGFloat
    var driver: ProductionLiveResizeDriver?

    init(
        referenceFrame: NSRect,
        canvasAspectRatio: CGFloat,
        sourceControlsHeight: CGFloat,
        frameChromeHeight: CGFloat
    ) {
        self.referenceFrame = referenceFrame
        self.canvasAspectRatio = canvasAspectRatio
        self.sourceControlsHeight = sourceControlsHeight
        self.frameChromeHeight = frameChromeHeight
        self.driver = nil
    }
}

private struct ProductionPendingLiveResizePresentation {
    let format: LiveSamplePresentationFormat
    let mapping: ProductionVideoSourceMapping
    let videoBindingToken: UUID
}

private enum ProductionPendingLiveResizeSource {
    case windowDidResizeFallback
    case windowWillResize
}

private final class ProductionVideoSourcePreviewSink: @unchecked Sendable {
    struct FrameFormat: Equatable, Sendable {
        let height: UInt64
        let width: UInt64
    }

    let displayLayer = AVSampleBufferDisplayLayer()

    private let firstFrame: @Sendable () -> Void
    private var frameFormat: FrameFormat?
    private var frames: UInt64 = 0
    private let lock = NSLock()
    private var stopped = false

    var frameCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    var latestFrameFormat: FrameFormat? {
        lock.lock()
        defer { lock.unlock() }
        return frameFormat
    }

    init(firstFrame: @escaping @Sendable () -> Void) {
        self.firstFrame = firstFrame
        displayLayer.videoGravity = .resizeAspect
    }

    func receive(_ sample: AVFoundationVideoFrameSample) {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        let isFirst = frames == 0
        if frames < UInt64.max { frames += 1 }
        frameFormat = FrameFormat(
            height: sample.activeFormatHeight,
            width: sample.activeFormatWidth
        )
        lock.unlock()
        if isFirst { firstFrame() }
        DispatchQueue.main.async { [self] in
            guard lock.withLock({ !stopped }) else { return }
            ProductionSampleBufferDisplay.enqueue(
                sample.sampleBuffer,
                on: displayLayer
            )
        }
    }

    @MainActor
    func stop() {
        lock.withLock {
            stopped = true
            frameFormat = nil
        }
        displayLayer.flushAndRemoveImage()
    }
}

public final class ProductionGUIHostServer: @unchecked Sendable {
    public static let maximumConcurrentConnections = 16
    public typealias WindowCreator = @Sendable (CanonicalUDID) -> String?
    private typealias OwnerOpener = @Sendable (
        CanonicalUDID,
        GUIHostSourceSelectionPolicy
    ) -> String?
    private typealias OwnerActivator = @Sendable (
        CanonicalUDID,
        String,
        GUIHostSourceSelectionPolicy
    ) -> Void

    private let endpoint: GUIHostEndpoint
    private let windowController: ProductionGUIHostWindowController?
    private let ownerActivator: OwnerActivator
    private let ownerOpener: OwnerOpener
    private let stateLock = NSLock()
    private var host: GUIHostProcess
    private var listener: Int32 = -1
    private var activePeers = Set<Int32>()
    private var stopping = false

    private struct BoundSocketIdentity {
        let device: UInt64
        let inode: UInt64
    }

    public init(
        canonicalAppPath: CanonicalAppPath,
        hostPaths: HostPathLayoutV1,
        windowCreator: WindowCreator? = nil
    ) throws {
        endpoint = try GUIHostEndpoint(
            canonicalAppPath: canonicalAppPath,
            hostPaths: hostPaths
        )
        host = GUIHostProcess(
            endpoint: endpoint,
            guiBuildID: "pulsephone.gui.v1",
            guiHostInstanceID: CanonicalUUID(value: UUID())
        )
        if let windowCreator {
            self.windowController = nil
            self.ownerOpener = { target, _ in windowCreator(target) }
            self.ownerActivator = { _, _, _ in }
        } else {
            let controller = ProductionGUIHostWindowController()
            self.windowController = controller
            self.ownerOpener = { target, policy in
                controller.openOwner(for: target, policy: policy)
            }
            self.ownerActivator = { target, ownerID, policy in
                controller.activateOwner(
                    for: target,
                    ownerID: ownerID,
                    policy: policy
                )
            }
            controller.setWindowClosedHandler { [weak self] target, windowID in
                guard let self else { return }
                self.stateLock.withLock {
                    try? self.host.closeWindow(
                        canonicalUDID: target,
                        windowID: windowID
                    )
                }
            }
        }
    }

    @MainActor
    public func runAppKit() throws {
        guard Thread.isMainThread else {
            throw GUIHostTransportError.invalidFrame
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        windowController?.startMonitoring()
        defer { windowController?.stopMonitoring() }
        let result = GUIHostServerResult()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.run()
            } catch {
                result.store(error)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let controller = self.windowController {
                        controller.shutdownForApplicationTermination {
                            application.terminate(nil)
                        }
                    } else {
                        application.terminate(nil)
                    }
                }
            }
        }
        application.run()
        if let error = result.error { throw error }
    }

    public func run() throws {
        _ = try POSIXHostPathSystem().openTemporaryBaseAnchor()
        let singletonLock = try acquireSingletonLock()
        defer { _ = Darwin.close(singletonLock) }
        let bound = try bind(path: endpoint.socketPath)
        let descriptor = bound.descriptor
        stateLock.lock()
        listener = descriptor
        stateLock.unlock()
        defer {
            stateLock.lock()
            let shouldClose = listener == descriptor
            listener = -1
            stateLock.unlock()
            if shouldClose { _ = Darwin.close(descriptor) }
            removeBoundSocketIfPresent(identity: bound.identity)
        }
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
            if isStopping { return }
            throw GUIHostTransportError.systemCall(errno)
        }
    }

    public func requestStop() {
        stateLock.lock()
        stopping = true
        let active = listener
        let peers = Array(activePeers)
        listener = -1
        stateLock.unlock()
        for peer in peers {
            _ = Darwin.shutdown(peer, SHUT_RDWR)
        }
        if active >= 0 { _ = Darwin.close(active) }
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
        stateLock.unlock()
    }

    private func acquireSingletonLock() throws -> Int32 {
        let path = endpoint.socketPath + ".lock"
        let descriptor = Darwin.open(
            path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw GUIHostTransportError.systemCall(errno)
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              fchmod(descriptor, 0o600) == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0
        else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw GUIHostTransportError.systemCall(code)
        }
        return descriptor
    }

    private func configure(peer: Int32) throws {
        var peerUserID: uid_t = 0
        var peerGroupID: gid_t = 0
        guard fcntl(peer, F_SETFD, FD_CLOEXEC) == 0,
              getpeereid(peer, &peerUserID, &peerGroupID) == 0,
              peerUserID == geteuid()
        else {
            throw GUIHostTransportError.systemCall(errno)
        }
        var noSignal: Int32 = 1
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(
            peer,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0,
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize) == 0,
        setsockopt(peer, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize) == 0
        else {
            throw GUIHostTransportError.systemCall(errno)
        }
    }

    private func serve(peer: Int32) throws {
        let connectionID = CanonicalUUID(value: UUID())
        stateLock.lock()
        do {
            try host.acceptConnection(connectionID: connectionID)
            stateLock.unlock()
        } catch {
            stateLock.unlock()
            throw error
        }
        defer {
            stateLock.lock()
            host.closeConnection(connectionID: connectionID)
            stateLock.unlock()
        }
        let hello = try GUIHostWireCodec.decodeHello(
            GUIHostWireCodec.read(from: peer)
        )
        stateLock.lock()
        let disposition: GUIHostHelloDisposition
        do {
            disposition = try host.receiveHello(
                connectionID: connectionID,
                hello: hello
            )
            stateLock.unlock()
        } catch {
            stateLock.unlock()
            throw error
        }
        guard case .accepted(let acknowledgement) = disposition else { return }
        try GUIHostWireCodec.write(
            try GUIHostWireCodec.helloAck(acknowledgement),
            to: peer
        )
        while !isStopping {
            let request: GUIHostOpenLiveRequest
            do {
                request = try GUIHostWireCodec.decodeOpenLive(
                    GUIHostWireCodec.read(from: peer)
                )
            } catch GUIHostTransportError.closed {
                return
            }
            let now = SystemMonotonicClock().now().nanoseconds
            stateLock.lock()
            let start: GUIHostOpenStart
            do {
                start = try host.beginOpenLive(
                    connectionID: connectionID,
                    request: request,
                    atMonotonicNanoseconds: now
                )
                stateLock.unlock()
            } catch {
                stateLock.unlock()
                throw error
            }
            let result: GUIHostOpenLiveResult
            switch start {
            case .terminal(let value):
                result = value
                if let target = value.canonicalUDID,
                   let ownerID = value.windowID,
                   value.errorCode == nil
                {
                    ownerActivator(
                        target,
                        ownerID,
                        request.sourceSelectionPolicy
                    )
                }
            case .pending(let token):
                stateLock.lock()
                do {
                    result = try host.completeOpenLive(
                        token: token,
                        windowID: ownerOpener(
                            request.canonicalUDID,
                            token.sourceSelectionPolicy
                        ),
                        atMonotonicNanoseconds: SystemMonotonicClock().now().nanoseconds
                    )
                    stateLock.unlock()
                } catch {
                    stateLock.unlock()
                    throw error
                }
            }
            try GUIHostWireCodec.write(
                try GUIHostWireCodec.openLiveResult(result),
                to: peer
            )
        }
    }

    private func bind(
        path: String
    ) throws -> (descriptor: Int32, identity: BoundSocketIdentity) {
        var metadata = stat()
        if lstat(path, &metadata) == 0 {
            guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
                  metadata.st_uid == geteuid()
            else { throw GUIHostTransportError.invalidFrame }
            guard unlink(path) == 0 else {
                throw GUIHostTransportError.systemCall(errno)
            }
        } else if errno != ENOENT {
            throw GUIHostTransportError.systemCall(errno)
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw GUIHostTransportError.systemCall(errno) }
        do {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            var address = try socketAddress(path: path)
            let length = socklen_t(address.sun_len)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, length)
                }
            }
            guard result == 0,
                  chmod(path, 0o600) == 0,
                  Darwin.listen(descriptor, 16) == 0
            else { throw GUIHostTransportError.systemCall(errno) }
            var metadata = stat()
            guard lstat(path, &metadata) == 0,
                  metadata.st_uid == geteuid(),
                  metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK)
            else {
                throw GUIHostTransportError.invalidFrame
            }
            return (
                descriptor,
                BoundSocketIdentity(
                    device: UInt64(metadata.st_dev),
                    inode: UInt64(metadata.st_ino)
                )
            )
        } catch {
            _ = Darwin.close(descriptor)
            _ = unlink(path)
            throw error
        }
    }

    private func removeBoundSocketIfPresent(identity: BoundSocketIdentity) {
        var metadata = stat()
        guard lstat(endpoint.socketPath, &metadata) == 0,
              metadata.st_uid == geteuid(),
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              UInt64(metadata.st_dev) == identity.device,
              UInt64(metadata.st_ino) == identity.inode
        else {
            return
        }
        _ = unlink(endpoint.socketPath)
    }

    private func socketAddress(path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        let offset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)!
        let length = offset + bytes.count + 1
        guard length <= MemoryLayout<sockaddr_un>.size,
              length <= Int(UInt8.max)
        else { throw GUIHostTransportError.invalidFrame }
        var address = sockaddr_un()
        address.sun_len = UInt8(length)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }
}

private final class GUIHostServerResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var error: Error? {
        lock.withLock { storedError }
    }

    func store(_ error: Error) {
        lock.withLock { storedError = error }
    }
}
