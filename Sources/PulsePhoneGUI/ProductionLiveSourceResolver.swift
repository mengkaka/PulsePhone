import AppKit
import AVFoundation
import CoreImage
import Foundation
import PulsePhoneClientCore
import PulsePhoneHostPaths
import PulsePhoneMedia
import PulsePhoneSharedDefinitions

struct ProductionLiveSourceTargetFacts: Equatable, Sendable {
    let canonicalUDID: CanonicalUDID
    let name: String
    let osVersion: String
}

struct ProductionLiveSourceTargetSnapshot: Equatable, Sendable {
    let connectedTargets: [ProductionLiveSourceTargetFacts]
    let target: ProductionLiveSourceTargetFacts
}

struct ProductionLiveSourceHandoff: Equatable, Sendable {
    let targetFacts: ProductionLiveSourceTargetFacts
}

struct ProductionLiveSourceActiveBinding: Equatable, Sendable {
    let descriptor: VideoSourceDescriptor
    let target: CanonicalUDID
}

struct ProductionLiveSourceCaptureHandle: @unchecked Sendable {
    private let startCapture: @Sendable () throws -> Void
    private let stopCapture: @Sendable () -> Void
    private let transferCapture: @Sendable (CanonicalUDID, String) -> Bool

    init(
        start: @escaping @Sendable () throws -> Void,
        stop: @escaping @Sendable () -> Void,
        transferForHandoff: @escaping @Sendable (CanonicalUDID, String) -> Bool = {
            _, _ in false
        }
    ) {
        startCapture = start
        stopCapture = stop
        transferCapture = transferForHandoff
    }

    func start() throws { try startCapture() }
    func stop() { stopCapture() }
    func transferForHandoff(target: CanonicalUDID, ownerID: String) -> Bool {
        transferCapture(target, ownerID)
    }
}

@MainActor
final class ProductionLiveSourceResolver: NSObject, NSWindowDelegate {
    private static let videoAuthorizationUnavailableStatus =
        "无法预览视频源：摄像头权限不可用"
    private static let videoAuthorizationRequiredStatus =
        "无法预览视频源：需要摄像头权限"
    private static let videoAuthorizationRequestingStatus =
        "正在请求摄像头权限"
    private static let previewFreshnessNanoseconds: UInt64 = 1_000_000_000
    private static let defaultTargetSnapshotRetryDelaysNanoseconds: [UInt64] = [
        200_000_000,
        500_000_000,
        1_000_000_000,
    ]

    typealias CaptureFactory = @Sendable (
        String,
        UInt64,
        @escaping ProductionAVFoundationVideoSourceCatalog.FrameHandler
    ) throws -> ProductionLiveSourceCaptureHandle
    typealias CaptureStopCompletion = @MainActor @Sendable () -> Void
    typealias TargetSnapshotProvider = @Sendable (
        CanonicalUDID
    ) throws -> ProductionLiveSourceTargetSnapshot
    typealias FirstHandoff = @MainActor @Sendable (
        CanonicalUDID,
        String,
        ProductionLiveSourceHandoff
    ) -> Void
    typealias FirstBlindHandoff = @MainActor @Sendable (
        CanonicalUDID,
        String,
        ProductionLiveSourceTargetFacts
    ) -> Void
    typealias ExistingHandoff = @MainActor @Sendable (
        CanonicalUDID,
        String,
        ProductionLiveSourceHandoff
    ) -> Void
    typealias OwnerCancelled = @MainActor @Sendable (
        CanonicalUDID,
        String
    ) -> Void
    typealias FenceTargets = @MainActor @Sendable ([CanonicalUDID]) -> Void
    typealias InventoryRefresh = @MainActor @Sendable (
        VideoSourceInventory
    ) -> Void
    typealias OpenCameraSettings = @MainActor @Sendable () -> Void
    typealias ActiveBindingsProvider = @MainActor @Sendable () -> [
        ProductionLiveSourceActiveBinding
    ]
    typealias ExistingSourceRetained = @MainActor @Sendable (
        CanonicalUDID,
        String
    ) -> Void
    typealias VideoAuthorizationRequest = @Sendable (
        @escaping @Sendable (Bool) -> Void
    ) -> Void

    private enum ProbeKind {
        case cached
        case automatic
    }

    private let activeBindingsProvider: ActiveBindingsProvider
    private let captureFactory: CaptureFactory
    private let existingHandoff: ExistingHandoff
    private let existingSourceRetained: ExistingSourceRetained
    private let fenceTargets: FenceTargets
    private let firstBlindHandoff: FirstBlindHandoff
    private let firstHandoff: FirstHandoff
    private let inventoryRefresh: InventoryRefresh
    private let inventoryRefreshProvider: @Sendable () throws -> VideoSourceInventory
    private let mappingCoordinator: ProductionVideoSourceMappingCoordinator
    private let openCameraSettings: OpenCameraSettings
    private let ownerCancelled: OwnerCancelled
    private let productVersion: PulsePhoneProductVersion?
    private let presentsWindows: Bool
    private let probeTimeout: DispatchTimeInterval
    private let targetSnapshotProvider: TargetSnapshotProvider
    private let targetSnapshotQueue = DispatchQueue(
        label: "com.pulsephone.gui.target-snapshots",
        qos: .userInitiated
    )
    private let targetSnapshotRetryDelaysNanoseconds: [UInt64]
    private let thumbnailTimeout: DispatchTimeInterval
    private let thumbnailQueue = DispatchQueue(
        label: "com.pulsephone.gui.source-thumbnails",
        qos: .userInitiated
    )
    private var latestInventory: VideoSourceInventory?
    private var owners = [String: ProductionLiveSourceResolverState]()
    private var ownerIDByTarget = [CanonicalUDID: String]()
    private let videoAuthorizationStatus: @Sendable () -> AVAuthorizationStatus
    private let videoAuthorizationRequest: VideoAuthorizationRequest

    init(
        catalog: ProductionAVFoundationVideoSourceCatalog,
        captureCoordinator: ProductionSourceCaptureCoordinator? = nil,
        mappingCoordinator: ProductionVideoSourceMappingCoordinator,
        productVersion: PulsePhoneProductVersion? = nil,
        presentsWindows: Bool,
        targetSnapshotProvider: @escaping TargetSnapshotProvider,
        inventoryRefresh: @escaping InventoryRefresh,
        firstHandoff: @escaping FirstHandoff,
        firstBlindHandoff: @escaping FirstBlindHandoff,
        existingHandoff: @escaping ExistingHandoff,
        existingSourceRetained: @escaping ExistingSourceRetained = { _, _ in },
        ownerCancelled: @escaping OwnerCancelled,
        fenceTargets: @escaping FenceTargets,
        activeBindingsProvider: @escaping ActiveBindingsProvider = { [] },
        captureFactory: CaptureFactory? = nil,
        inventoryRefreshProvider: (@Sendable () throws -> VideoSourceInventory)? = nil,
        probeTimeout: DispatchTimeInterval = .seconds(2),
        thumbnailTimeout: DispatchTimeInterval = .seconds(2),
        targetSnapshotRetryDelaysNanoseconds: [UInt64] =
            ProductionLiveSourceResolver.defaultTargetSnapshotRetryDelaysNanoseconds,
        openCameraSettings: @escaping OpenCameraSettings = {
            NSWorkspace.shared.open(CameraSettingsAction.privacySettingsURL)
        },
        videoAuthorizationStatus: @escaping @Sendable () -> AVAuthorizationStatus = {
            AVCaptureDevice.authorizationStatus(for: .video)
        },
        videoAuthorizationRequest: @escaping VideoAuthorizationRequest = {
            completion in
            AVCaptureDevice.requestAccess(
                for: .video,
                completionHandler: completion
            )
        }
    ) {
        let captureCoordinator = captureCoordinator
            ?? ProductionSourceCaptureCoordinator(catalog: catalog)
        self.captureFactory = captureFactory ?? { sourceID, sourceEpoch, handler in
            let capture = try captureCoordinator.acquire(
                sourceID: sourceID,
                sourceEpoch: sourceEpoch,
                role: .resolverProbe,
                frameHandler: handler,
                // Keep the audio output configured across chooser-to-Live handoff.
                audioHandler: { _ in }
            )
            return ProductionLiveSourceCaptureHandle(
                start: capture.start,
                stop: capture.stop,
                transferForHandoff: capture.transferForHandoff
            )
        }
        self.activeBindingsProvider = activeBindingsProvider
        self.inventoryRefreshProvider = inventoryRefreshProvider ?? catalog.refresh
        self.mappingCoordinator = mappingCoordinator
        self.openCameraSettings = openCameraSettings
        self.productVersion = productVersion
        self.presentsWindows = presentsWindows
        self.targetSnapshotProvider = targetSnapshotProvider
        self.inventoryRefresh = inventoryRefresh
        self.firstHandoff = firstHandoff
        self.firstBlindHandoff = firstBlindHandoff
        self.existingHandoff = existingHandoff
        self.existingSourceRetained = existingSourceRetained
        self.ownerCancelled = ownerCancelled
        self.fenceTargets = fenceTargets
        self.probeTimeout = probeTimeout
        self.thumbnailTimeout = thumbnailTimeout
        self.targetSnapshotRetryDelaysNanoseconds =
            targetSnapshotRetryDelaysNanoseconds
        self.videoAuthorizationStatus = videoAuthorizationStatus
        self.videoAuthorizationRequest = videoAuthorizationRequest
        super.init()
    }

    func openFirstOwner(
        target: CanonicalUDID,
        ownerID: String,
        policy: GUIHostSourceSelectionPolicy
    ) {
        guard ownerIDByTarget[target] == nil else { return }
        let state = ProductionLiveSourceResolverState(
            canonicalUDID: target,
            existingLive: false,
            ownerID: ownerID,
            policy: policy,
            stableInventory: VideoSourceStableInventoryAccumulator(
                startedAtMonotonicNanoseconds: SystemMonotonicClock()
                    .now().nanoseconds
            )
        )
        owners[ownerID] = state
        ownerIDByTarget[target] = ownerID
        if let latestInventory { apply(latestInventory, to: state) }
        if policy == .forceChooser { showChooser(state) }
        loadTargetSnapshot(state)
        if policy == .automatic {
            scheduleStableObservation(state)
        }
    }

    func openForExistingLive(target: CanonicalUDID, ownerID: String) {
        if let existingID = ownerIDByTarget[target],
           let state = owners[existingID]
        {
            showChooser(state)
            state.window?.makeKeyAndOrderFront(nil)
            return
        }
        let state = ProductionLiveSourceResolverState(
            canonicalUDID: target,
            existingLive: true,
            ownerID: ownerID,
            policy: .forceChooser,
            stableInventory: VideoSourceStableInventoryAccumulator(
                startedAtMonotonicNanoseconds: SystemMonotonicClock()
                    .now().nanoseconds
            )
        )
        owners[ownerID] = state
        ownerIDByTarget[target] = ownerID
        if let latestInventory { apply(latestInventory, to: state) }
        showChooser(state)
        loadTargetSnapshot(state)
    }

    func focusOwner(target: CanonicalUDID) {
        guard let ownerID = ownerIDByTarget[target],
              let state = owners[ownerID]
        else { return }
        state.window?.makeKeyAndOrderFront(nil)
    }

    func apply(_ inventory: VideoSourceInventory) {
        latestInventory = inventory
        for state in owners.values { apply(inventory, to: state) }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let ownerID = window.identifier?.rawValue,
              let state = owners[ownerID],
              !state.handingOff
        else { return }
        cancel(state)
    }

    private func loadTargetSnapshot(_ state: ProductionLiveSourceResolverState) {
        let token = UUID()
        state.targetSnapshotToken = token
        state.claimsReady = false
        state.claimsFailureMessage = nil
        state.mappingRecords.removeAll()
        state.targetMapping = nil
        state.targetSnapshotAttemptsCompleted = 0
        state.targetSnapshotObservedFacts = false
        state.targetSnapshotResolved = false
        state.targetSnapshotCandidateTargets = nil
        state.targetSnapshotExpectedAttempts =
            targetSnapshotRetryDelaysNanoseconds.count + 1
        refreshConfirmAvailability(state)

        performTargetSnapshotAttempt(state, token: token, delayNanoseconds: 0)
    }

    private func performTargetSnapshotAttempt(
        _ state: ProductionLiveSourceResolverState,
        token: UUID,
        delayNanoseconds: UInt64
    ) {
        let ownerID = state.ownerID
        let provider = targetSnapshotProvider
        let now = DispatchTime.now().uptimeNanoseconds
        let addition = now.addingReportingOverflow(delayNanoseconds)
        let deadline = addition.overflow ? UInt64.max : addition.partialValue
        DispatchQueue.main.asyncAfter(
            deadline: DispatchTime(uptimeNanoseconds: deadline)
        ) { [weak self, weak state] in
            MainActor.assumeIsolated {
                guard let self, let state, self.isCurrent(state),
                      state.targetSnapshotToken == token,
                      !state.targetSnapshotResolved
                else { return }
                self.targetSnapshotQueue.async {
                    let snapshot = try? provider(state.canonicalUDID)
                    DispatchQueue.main.async { [weak self, weak state] in
                        MainActor.assumeIsolated {
                            guard let self, let state,
                                  self.owners[ownerID] === state,
                                  state.targetSnapshotToken == token,
                                  !state.targetSnapshotResolved
                            else { return }
                            guard let snapshot,
                                  self.valid(snapshot, for: state.canonicalUDID)
                            else {
                                self.targetSnapshotAttemptFailed(
                                    state,
                                    token: token
                                )
                                return
                            }
                            state.targetSnapshotObservedFacts = true
                            state.targetSnapshot = snapshot
                            self.updateTargetIdentity(state)
                            self.loadClaims(
                                for: state,
                                snapshot: snapshot,
                                token: token
                            )
                        }
                    }
                }
            }
        }
    }

    private func targetSnapshotAttemptFailed(
        _ state: ProductionLiveSourceResolverState,
        token: UUID,
        resetCandidate: Bool = true
    ) {
        guard isCurrent(state), state.targetSnapshotToken == token,
              !state.targetSnapshotResolved
        else { return }
        if resetCandidate {
            state.targetSnapshotCandidateTargets = nil
        }
        state.targetSnapshotAttemptsCompleted += 1
        guard state.targetSnapshotAttemptsCompleted
                < state.targetSnapshotExpectedAttempts
        else {
            state.claimsFailureMessage = state.targetSnapshotObservedFacts
                ? "无法验证视频源缓存，请刷新后重试"
                : "无法读取设备信息，请刷新后重试"
            updateTargetIdentity(state)
            showChooser(state)
            rebuildCandidates(state)
            refreshConfirmAvailability(state)
            setStatus(state.claimsFailureMessage, in: state)
            return
        }
        let retryIndex = state.targetSnapshotAttemptsCompleted - 1
        performTargetSnapshotAttempt(
            state,
            token: token,
            delayNanoseconds: targetSnapshotRetryDelaysNanoseconds[retryIndex]
        )
    }

    private func loadClaims(
        for state: ProductionLiveSourceResolverState,
        snapshot: ProductionLiveSourceTargetSnapshot,
        token: UUID
    ) {
        mappingCoordinator.load(
            targets: snapshot.connectedTargets.map(\.canonicalUDID)
        ) { [weak self, weak state] records in
            guard let self, let state, self.isCurrent(state),
                  state.targetSnapshotToken == token,
                  !state.targetSnapshotResolved
            else { return }
            let expectedTargets = Set(snapshot.connectedTargets.map(\.canonicalUDID))
            let readable = Set(records.keys) == expectedTargets
                && records.values.allSatisfy { result in
                    if case .unavailable = result { return false }
                    return true
                }
            guard readable else {
                self.targetSnapshotAttemptFailed(state, token: token)
                return
            }
            guard state.targetSnapshotCandidateTargets == expectedTargets else {
                state.targetSnapshotCandidateTargets = expectedTargets
                self.targetSnapshotAttemptFailed(
                    state,
                    token: token,
                    resetCandidate: false
                )
                return
            }
            state.targetSnapshotResolved = true
            state.targetSnapshotCandidateTargets = nil
            state.targetSnapshot = snapshot
            state.mappingRecords = records
            state.claimsReady = true
            state.targetMapping = records[state.canonicalUDID]
            state.claimsFailureMessage = nil
            let recentPreview = state.previewToken.flatMap { previewToken in
                state.previewSink?.recentFrame(
                    ownerToken: previewToken,
                    nowNanoseconds: SystemMonotonicClock().now().nanoseconds,
                    maximumAgeNanoseconds: Self.previewFreshnessNanoseconds
                )
            }
            self.rebuildCandidates(state)
            self.refreshConfirmAvailability(state)
            if recentPreview != nil {
                self.setStatus(nil, in: state)
            }
            self.maybeResolve(state)
        }
    }

    private func valid(
        _ snapshot: ProductionLiveSourceTargetSnapshot,
        for target: CanonicalUDID
    ) -> Bool {
        let connected = snapshot.connectedTargets.map(\.canonicalUDID)
        return snapshot.target.canonicalUDID == target
            && connected.contains(target)
            && Set(connected).count == connected.count
    }

    private func scheduleStableObservation(
        _ state: ProductionLiveSourceResolverState
    ) {
        let token = UUID()
        state.stableToken = token
        observeStableInventory(state, token: token)
    }

    private func observeStableInventory(
        _ state: ProductionLiveSourceResolverState,
        token: UUID
    ) {
        guard isCurrent(state), state.stableToken == token else { return }
        let now = SystemMonotonicClock().now().nanoseconds
        state.stableInventory.observe(
            inventory: state.inventory,
            atMonotonicNanoseconds: now
        )
        switch state.stableInventory.outcome(atMonotonicNanoseconds: now) {
        case .pending:
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
                [weak self, weak state] in
                MainActor.assumeIsolated {
                    guard let self, let state else { return }
                    self.observeStableInventory(state, token: token)
                }
            }
        case .stable(let sourceIDs):
            state.stableToken = nil
            state.stableQualifiedSourceIDs = sourceIDs
            state.stableSourceEpochs = Dictionary(uniqueKeysWithValues:
                (state.inventory?.sources ?? []).compactMap { descriptor in
                    sourceIDs.contains(descriptor.sourceID)
                        ? (descriptor.sourceID, descriptor.sourceEpoch)
                        : nil
                }
            )
            maybeResolve(state)
        case .unstable:
            state.stableToken = nil
            state.stableQualifiedSourceIDs = nil
            state.stableSourceEpochs.removeAll()
            showChooser(state)
        }
    }

    private func maybeResolve(_ state: ProductionLiveSourceResolverState) {
        guard isCurrent(state), state.policy == .automatic,
              !state.userInteracted,
              state.probeCapture == nil,
              state.claimsReady,
              let mapping = state.targetMapping,
              let inventory = state.inventory
        else { return }
        guard case .mapped(let record) = mapping else {
            if case .missing = mapping,
               let stableSourceIDs = state.stableQualifiedSourceIDs
            {
                attemptAutomaticBinding(
                    state,
                    qualifiedSourceIDs: stableSourceIDs
                )
                return
            }
            showChooser(state)
            return
        }
        let matches = inventory.sources.filter { $0.sourceID == record.sourceID }
        guard matches.count == 1,
              conflictingTargets(
                sourceID: record.sourceID,
                state: state
              ).isEmpty
        else {
            showChooser(state)
            return
        }
        let descriptor = matches[0]
        let key = "cache:\(descriptor.sourceID):\(descriptor.sourceEpoch)"
        guard state.attemptedProbeKeys.insert(key).inserted else { return }
        startProbe(descriptor, kind: .cached, in: state)
    }

    private func attemptAutomaticBinding(
        _ state: ProductionLiveSourceResolverState,
        qualifiedSourceIDs: [String]
    ) {
        guard isCurrent(state), state.policy == .automatic,
              !state.userInteracted,
              state.probeCapture == nil,
              state.claimsReady,
              qualifiedSourceIDs.count == 1,
              let snapshot = state.targetSnapshot,
              snapshot.connectedTargets.count == 1,
              let inventory = state.inventory,
              let descriptor = inventory.sources.first(where: {
                  $0.sourceID == qualifiedSourceIDs[0]
              }),
              descriptor.classification == .qualifiedPhoneScreen,
              state.stableSourceEpochs[descriptor.sourceID]
                == descriptor.sourceEpoch,
              VideoSourceNameGuard.canonicalEquivalentExactMatch(
                  sourceName: descriptor.displayName,
                  targetName: snapshot.target.name
              ),
              conflictingTargets(
                  sourceID: descriptor.sourceID,
                  state: state
              ).isEmpty
        else {
            showChooser(state)
            return
        }
        let key = "auto:\(descriptor.sourceID):\(descriptor.sourceEpoch)"
        guard state.attemptedProbeKeys.insert(key).inserted else { return }
        startProbe(descriptor, kind: .automatic, in: state)
    }

    private func startProbe(
        _ descriptor: VideoSourceDescriptor,
        kind: ProbeKind,
        in state: ProductionLiveSourceResolverState
    ) {
        if state.thumbnailCapture != nil {
            cancelThumbnailBatch(state) { [weak self, weak state] in
                guard let self, let state, self.isCurrent(state),
                      !state.userInteracted
                else { return }
                self.startProbe(descriptor, kind: kind, in: state)
            }
            return
        }
        let token = UUID()
        let ownerID = state.ownerID
        let sink = ProductionSourcePreviewSink(
            ownerToken: token,
            sourceID: descriptor.sourceID,
            sourceEpoch: descriptor.sourceEpoch
        ) { [weak self, weak state] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let state,
                          self.isCurrent(state),
                          state.probeToken == token,
                          state.inventory?.sources.contains(descriptor) == true
                    else { return }
                    self.completeProbe(
                        descriptor,
                        kind: kind,
                        state: state,
                        token: token
                    )
                }
            }
        }
        do {
            let capture = try captureFactory(
                descriptor.sourceID,
                descriptor.sourceEpoch,
                sink.receive
            )
            state.probeCapture = capture
            state.probeDescriptor = descriptor
            state.probeSink = sink
            state.probeToken = token
            setStatus("正在确认视频源", in: state)
            DispatchQueue.global(qos: .userInitiated).async {
                let started = (try? capture.start()) != nil
                guard !started else { return }
                DispatchQueue.main.async { [weak self, weak state] in
                    MainActor.assumeIsolated {
                        guard let self, let state,
                              self.owners[ownerID] === state,
                              state.probeToken == token
                        else { return }
                        self.stopProbe(state) { [weak self, weak state] in
                            guard let self, let state, self.isCurrent(state),
                                  !state.handingOff
                            else { return }
                            self.showChooser(state)
                        }
                    }
                }
            }
        } catch {
            showChooser(state)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + probeTimeout) {
            [weak self, weak state] in
            MainActor.assumeIsolated {
                guard let self, let state,
                      self.isCurrent(state),
                      state.probeToken == token
                else { return }
                self.stopProbe(state) { [weak self, weak state] in
                    guard let self, let state, self.isCurrent(state),
                          !state.handingOff
                    else { return }
                    self.showChooser(state)
                }
            }
        }
    }

    private func completeProbe(
        _ descriptor: VideoSourceDescriptor,
        kind: ProbeKind,
        state: ProductionLiveSourceResolverState,
        token: UUID
    ) {
        guard state.probeCapture != nil else { return }
        let initialCanvas = state.probeSink?.latestFrame(ownerToken: token)
            .flatMap(Self.normalizedInitialCanvas)
        guard state.inventory?.sources.contains(descriptor) == true,
              !state.userInteracted
        else {
            stopProbe(state)
            return
        }
        switch kind {
        case .cached:
            guard case .mapped? = state.targetMapping else {
                stopProbe(state)
                showChooser(state)
                return
            }
            handoff(state)
        case .automatic:
            mappingCoordinator.replace(
                target: state.canonicalUDID,
                sourceID: descriptor.sourceID,
                proofKind: .singleConnectedTargetSource,
                initialCanvasWidth: initialCanvas?.width,
                initialCanvasHeight: initialCanvas?.height
            ) { [weak self, weak state] result in
                guard let self, let state,
                      self.isCurrent(state), !state.userInteracted
                else { return }
                switch result {
                case .saved:
                    self.handoff(state)
                case .failed:
                    self.stopProbe(state)
                    self.showChooser(state)
                }
            }
        }
    }

    private func stopProbe(
        _ state: ProductionLiveSourceResolverState,
        completion: CaptureStopCompletion? = nil
    ) {
        let capture = state.probeCapture
        state.probeCapture = nil
        state.probeDescriptor = nil
        state.probeSink?.stop()
        state.probeSink = nil
        state.probeToken = nil
        stopCapture(capture, in: state)
        afterCaptureStops(in: state, completion: completion)
    }

    private func showChooser(_ state: ProductionLiveSourceResolverState) {
        guard isCurrent(state) else { return }
        if let window = state.window {
            if presentsWindows { window.makeKeyAndOrderFront(nil) }
            rebuildCandidates(state)
            return
        }
        let initialContentSize = NSSize(width: 920, height: 600)
        let minimumContentSize = NSSize(width: 760, height: 500)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "选择视频源"
        window.subtitle = productVersion?.displayText ?? ""
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(state.ownerID)
        window.delegate = self

        let root = NSView()
        root.wantsLayer = true

        let header = NSVisualEffectView()
        header.blendingMode = .withinWindow
        header.material = .headerView
        header.state = .active
        header.translatesAutoresizingMaskIntoConstraints = false
        let targetIcon = NSImageView(image: NSImage(
            systemSymbolName: "iphone",
            accessibilityDescription: "控制目标"
        ) ?? NSImage())
        targetIcon.contentTintColor = .secondaryLabelColor
        targetIcon.imageScaling = .scaleProportionallyDown
        targetIcon.translatesAutoresizingMaskIntoConstraints = false
        let identity = NSTextField(labelWithString: targetIdentityText(state))
        identity.font = .systemFont(ofSize: 13, weight: .semibold)
        identity.lineBreakMode = .byTruncatingMiddle
        identity.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(targetIcon)
        header.addSubview(identity)

        let listTitle = NSTextField(labelWithString: "视频源")
        listTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        listTitle.textColor = .secondaryLabelColor
        listTitle.translatesAutoresizingMaskIntoConstraints = false
        let candidateStack = ProductionSourceCandidateStackView()
        candidateStack.orientation = .vertical
        candidateStack.alignment = .leading
        candidateStack.spacing = 4
        candidateStack.edgeInsets = NSEdgeInsets(
            top: 8,
            left: 18,
            bottom: 12,
            right: 18
        )
        candidateStack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = candidateStack

        let sourcePane = NSView()
        sourcePane.translatesAutoresizingMaskIntoConstraints = false
        sourcePane.addSubview(listTitle)
        sourcePane.addSubview(scroll)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let preview = NSView()
        preview.identifier = NSUserInterfaceItemIdentifier("live-source-preview")
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.black.cgColor
        let previewPlaceholder = NSTextField(
            labelWithString: targetPlaceholderText(state)
        )
        previewPlaceholder.alignment = .center
        previewPlaceholder.lineBreakMode = .byTruncatingMiddle
        previewPlaceholder.maximumNumberOfLines = 3
        previewPlaceholder.textColor = NSColor.white.withAlphaComponent(0.72)
        previewPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(previewPlaceholder)
        let previewContainer = NSView()
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.wantsLayer = true
        previewContainer.layer?.backgroundColor = NSColor.black.cgColor
        previewContainer.layer?.cornerRadius = 6
        previewContainer.layer?.cornerCurve = .continuous
        previewContainer.addSubview(preview)

        let previewTitle = NSTextField(labelWithString: "预览")
        previewTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        previewTitle.textColor = .secondaryLabelColor
        previewTitle.translatesAutoresizingMaskIntoConstraints = false
        let previewPane = NSView()
        previewPane.translatesAutoresizingMaskIntoConstraints = false
        previewPane.addSubview(previewTitle)
        previewPane.addSubview(previewContainer)

        let workspace = NSView()
        workspace.translatesAutoresizingMaskIntoConstraints = false
        workspace.addSubview(sourcePane)
        workspace.addSubview(divider)
        workspace.addSubview(previewPane)

        let warning = NSTextField(labelWithString: "")
        warning.textColor = .secondaryLabelColor
        warning.maximumNumberOfLines = 1
        warning.lineBreakMode = .byTruncatingTail
        warning.usesSingleLineMode = true
        warning.alignment = .left
        warning.translatesAutoresizingMaskIntoConstraints = false
        warning.setContentHuggingPriority(.defaultLow, for: .horizontal)
        warning.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        warning.isHidden = true
        let status = NSTextField(labelWithString: "")
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 1
        status.lineBreakMode = .byTruncatingTail
        status.usesSingleLineMode = true
        status.alignment = .left
        status.translatesAutoresizingMaskIntoConstraints = false
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        status.isHidden = true
        let statusArea = NSStackView()
        statusArea.orientation = .vertical
        statusArea.alignment = .width
        statusArea.spacing = 2
        statusArea.translatesAutoresizingMaskIntoConstraints = false
        statusArea.setHuggingPriority(.defaultHigh, for: .horizontal)
        statusArea.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let refresh = NSButton(
            image: NSImage(
                systemSymbolName: "arrow.clockwise",
                accessibilityDescription: "刷新视频源"
            ) ?? NSImage(),
            target: self,
            action: #selector(refreshSources(_:))
        )
        refresh.identifier = NSUserInterfaceItemIdentifier(state.ownerID)
        refresh.toolTip = "刷新视频源"
        refresh.bezelStyle = .accessoryBarAction
        refresh.controlSize = .regular
        let cameraAuthorization = NSButton(
            image: NSImage(),
            target: self,
            action: #selector(handleCameraAuthorization(_:))
        )
        cameraAuthorization.identifier = NSUserInterfaceItemIdentifier(state.ownerID)
        cameraAuthorization.bezelStyle = .accessoryBarAction
        cameraAuthorization.isHidden = true
        let continueWithoutVideo = NSButton(
            title: "继续，不显示画面",
            target: self,
            action: #selector(continueWithoutVideo(_:))
        )
        continueWithoutVideo.identifier = NSUserInterfaceItemIdentifier(state.ownerID)
        continueWithoutVideo.isHidden = true
        let cancel = NSButton(
            title: "取消",
            target: self,
            action: #selector(cancelSelection(_:))
        )
        cancel.identifier = NSUserInterfaceItemIdentifier(state.ownerID)
        let confirm = NSButton(
            title: "使用此源",
            target: self,
            action: #selector(confirmSelection(_:))
        )
        confirm.identifier = NSUserInterfaceItemIdentifier(state.ownerID)
        confirm.keyEquivalent = "\r"
        confirm.isEnabled = false
        confirm.bezelStyle = .rounded

        let footerTools = NSStackView(views: [refresh, cameraAuthorization])
        footerTools.orientation = .horizontal
        footerTools.alignment = .centerY
        footerTools.spacing = 6
        footerTools.translatesAutoresizingMaskIntoConstraints = false
        footerTools.setHuggingPriority(.required, for: .horizontal)
        footerTools.setContentCompressionResistancePriority(.required, for: .horizontal)
        let footerActions = NSStackView(views: [
            continueWithoutVideo, cancel, confirm,
        ])
        footerActions.orientation = .horizontal
        footerActions.alignment = .centerY
        footerActions.spacing = 8
        footerActions.translatesAutoresizingMaskIntoConstraints = false
        footerActions.setHuggingPriority(.required, for: .horizontal)
        footerActions.setContentCompressionResistancePriority(.required, for: .horizontal)
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerTools)
        footer.addSubview(statusArea)
        footer.addSubview(footerActions)
        root.addSubview(header)
        root.addSubview(workspace)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 52),
            targetIcon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            targetIcon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            targetIcon.widthAnchor.constraint(equalToConstant: 18),
            targetIcon.heightAnchor.constraint(equalToConstant: 22),
            identity.leadingAnchor.constraint(equalTo: targetIcon.trailingAnchor, constant: 9),
            identity.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            identity.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            workspace.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            workspace.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            workspace.topAnchor.constraint(equalTo: header.bottomAnchor),
            workspace.bottomAnchor.constraint(equalTo: footer.topAnchor),
            sourcePane.leadingAnchor.constraint(equalTo: workspace.leadingAnchor),
            sourcePane.topAnchor.constraint(equalTo: workspace.topAnchor),
            sourcePane.bottomAnchor.constraint(equalTo: workspace.bottomAnchor),
            sourcePane.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            sourcePane.widthAnchor.constraint(equalToConstant: 300),
            listTitle.leadingAnchor.constraint(equalTo: sourcePane.leadingAnchor, constant: 14),
            listTitle.trailingAnchor.constraint(equalTo: sourcePane.trailingAnchor, constant: -14),
            listTitle.topAnchor.constraint(equalTo: sourcePane.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: sourcePane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sourcePane.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: listTitle.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: sourcePane.bottomAnchor),
            candidateStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            divider.leadingAnchor.constraint(equalTo: sourcePane.trailingAnchor),
            divider.topAnchor.constraint(equalTo: workspace.topAnchor),
            divider.bottomAnchor.constraint(equalTo: workspace.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            previewPane.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            previewPane.trailingAnchor.constraint(equalTo: workspace.trailingAnchor),
            previewPane.topAnchor.constraint(equalTo: workspace.topAnchor),
            previewPane.bottomAnchor.constraint(equalTo: workspace.bottomAnchor),
            previewTitle.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor, constant: 16),
            previewTitle.topAnchor.constraint(equalTo: previewPane.topAnchor, constant: 12),
            previewContainer.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor, constant: 16),
            previewContainer.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor, constant: -16),
            previewContainer.topAnchor.constraint(equalTo: previewTitle.bottomAnchor, constant: 8),
            previewContainer.bottomAnchor.constraint(equalTo: previewPane.bottomAnchor, constant: -16),
            preview.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            preview.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            preview.widthAnchor.constraint(
                equalTo: preview.heightAnchor,
                multiplier: 9.0 / 16.0
            ),
            preview.widthAnchor.constraint(
                lessThanOrEqualTo: previewContainer.widthAnchor,
                constant: -32
            ),
            preview.heightAnchor.constraint(
                lessThanOrEqualTo: previewContainer.heightAnchor,
                constant: -24
            ),
            previewPlaceholder.centerXAnchor.constraint(equalTo: preview.centerXAnchor),
            previewPlaceholder.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
            previewPlaceholder.leadingAnchor.constraint(
                greaterThanOrEqualTo: preview.leadingAnchor,
                constant: 8
            ),
            previewPlaceholder.trailingAnchor.constraint(
                lessThanOrEqualTo: preview.trailingAnchor,
                constant: -8
            ),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 58),
            footerTools.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 14),
            footerTools.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            statusArea.leadingAnchor.constraint(
                equalTo: footerTools.trailingAnchor,
                constant: 10
            ),
            statusArea.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            statusArea.trailingAnchor.constraint(
                lessThanOrEqualTo: footerActions.leadingAnchor,
                constant: -12
            ),
            footerActions.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -14),
            footerActions.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            refresh.widthAnchor.constraint(equalToConstant: 28),
            refresh.heightAnchor.constraint(equalToConstant: 28),
            cameraAuthorization.widthAnchor.constraint(equalToConstant: 28),
            cameraAuthorization.heightAnchor.constraint(equalToConstant: 28),
        ])
        let previewWidthFill = preview.widthAnchor.constraint(
            equalTo: previewContainer.widthAnchor,
            constant: -32
        )
        let windowSizePriority = NSLayoutConstraint.Priority.windowSizeStayPut.rawValue
        previewWidthFill.priority = NSLayoutConstraint.Priority(
            rawValue: windowSizePriority - 1
        )
        let previewHeightFill = preview.heightAnchor.constraint(
            equalTo: previewContainer.heightAnchor,
            constant: -24
        )
        previewHeightFill.priority = NSLayoutConstraint.Priority(
            rawValue: windowSizePriority - 2
        )
        NSLayoutConstraint.activate([previewWidthFill, previewHeightFill])
        let controller = NSViewController()
        controller.view = root
        window.contentViewController = controller
        window.contentMinSize = minimumContentSize
        window.setContentSize(initialContentSize)
        window.center()
        state.window = window
        state.identityLabel = identity
        state.statusLabel = status
        state.statusArea = statusArea
        state.cameraAuthorizationButton = cameraAuthorization
        state.continueWithoutVideoButton = continueWithoutVideo
        state.candidateStack = candidateStack
        state.previewView = preview
        state.previewPlaceholderLabel = previewPlaceholder
        state.warningLabel = warning
        state.confirmButton = confirm
        rebuildCandidates(state)
        if presentsWindows { window.makeKeyAndOrderFront(nil) }
    }

    private func apply(
        _ inventory: VideoSourceInventory,
        to state: ProductionLiveSourceResolverState
    ) {
        let currentEpochs = Dictionary(uniqueKeysWithValues:
            inventory.sources.map { ($0.sourceID, $0.sourceEpoch) }
        )
        state.thumbnails = state.thumbnails.filter {
            currentEpochs[$0.key] == state.thumbnailEpochs[$0.key]
        }
        state.thumbnailEpochs = state.thumbnailEpochs.filter {
            currentEpochs[$0.key] == $0.value
        }
        state.thumbnailDimensions = state.thumbnailDimensions.filter {
            currentEpochs[$0.key] == state.thumbnailEpochs[$0.key]
        }
        state.inventory = inventory
        if let probe = state.probeDescriptor,
           !inventory.sources.contains(probe)
        {
            stopProbe(state) { [weak self, weak state] in
                guard let self, let state, self.isCurrent(state) else { return }
                self.rebuildCandidates(state)
                self.maybeResolve(state)
            }
            return
        }
        if let selected = state.selectedDescriptor {
            if let replacement = inventory.sources.first(where: {
                sameSourceIdentity($0, selected)
            }) {
                state.selectedDescriptor = replacement
            } else {
                state.selectedDescriptor = nil
                state.confirmButton?.isEnabled = false
                stopPreview(state) { [weak self, weak state] in
                    guard let self, let state, self.isCurrent(state) else { return }
                    self.rebuildCandidates(state)
                }
                return
            }
        }
        if let thumbnail = state.thumbnailDescriptor,
           !inventory.sources.contains(thumbnail)
        {
            cancelThumbnailBatch(state) { [weak self, weak state] in
                guard let self, let state, self.isCurrent(state) else { return }
                self.rebuildCandidates(state)
            }
            return
        }
        rebuildCandidates(state)
        maybeResolve(state)
    }

    private func rebuildCandidates(_ state: ProductionLiveSourceResolverState) {
        guard let stack = state.candidateStack else { return }
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let selection = state.inventory.map(VideoSourceInventorySelection.init)
        let candidates = selection?.manualCandidates ?? []
        let authorization = videoAuthorizationStatus()
        let videoAuthorized = authorization == .authorized
        updateVideoAuthorizationControls(
            state,
            authorization: authorization
        )
        if !videoAuthorized {
            cancelThumbnailBatch(state)
            if state.claimsFailureMessage == nil {
                let status = authorization == .notDetermined
                    ? Self.videoAuthorizationRequiredStatus
                    : Self.videoAuthorizationUnavailableStatus
                if !state.videoAuthorizationRequestInFlight {
                    setStatus(status, in: state)
                }
            }
        } else if let currentStatus = state.statusLabel?.stringValue,
                  [
                    Self.videoAuthorizationUnavailableStatus,
                    Self.videoAuthorizationRequiredStatus,
                    Self.videoAuthorizationRequestingStatus,
                  ].contains(currentStatus)
        {
            setStatus(state.claimsFailureMessage, in: state)
        }
        guard !candidates.isEmpty else {
            let empty = NSTextField(labelWithString: "没有可用的 iPhone 屏幕视频源")
            empty.textColor = .secondaryLabelColor
            stack.addArrangedSubview(empty)
            cancelThumbnailBatch(state)
            return
        }
        let sections = [
            ("iPhone 屏幕", selection?.qualifiedPhoneScreens ?? []),
            ("其他候选", selection?.residual ?? []),
        ]
        for (title, descriptors) in sections where !descriptors.isEmpty {
            let heading = NSTextField(labelWithString: title)
            heading.font = .systemFont(ofSize: 12, weight: .semibold)
            heading.textColor = .secondaryLabelColor
            stack.addArrangedSubview(heading)
            for descriptor in descriptors {
                let button = ProductionSourceCandidateButton(
                    ownerID: state.ownerID,
                    sourceID: descriptor.sourceID,
                    target: self,
                    action: #selector(selectCandidate(_:))
                )
                let presentation = candidatePresentation(
                    descriptor,
                    state: state
                )
                let thumbnail = state.thumbnailEpochs[descriptor.sourceID]
                        == descriptor.sourceEpoch
                    ? state.thumbnails[descriptor.sourceID]
                    : nil
                button.configure(
                    name: presentation.name,
                    metadata: presentation.metadata,
                    mapping: presentation.mapping,
                    active: presentation.active,
                    image: thumbnail ?? NSImage(
                        systemSymbolName: "iphone",
                        accessibilityDescription: descriptor.displayName
                    ) ?? NSImage()
                )
                button.state = state.selectedDescriptor.map {
                    sameSourceIdentity($0, descriptor)
                } == true
                    ? .on
                    : .off
                button.updateSelectionStyle()
                button.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(button)
                NSLayoutConstraint.activate([
                    button.widthAnchor.constraint(
                        equalTo: stack.widthAnchor,
                        constant: -36
                    ),
                    button.heightAnchor.constraint(equalToConstant: 104),
                ])
            }
        }
        if videoAuthorized {
            ensureDefaultSelection(state, candidates: candidates)
            startThumbnailBatchIfNeeded(state, candidates: candidates)
        }
    }

    private func ensureDefaultSelection(
        _ state: ProductionLiveSourceResolverState,
        candidates: [VideoSourceDescriptor]
    ) {
        guard state.selectedDescriptor == nil,
              state.previewCapture == nil,
              let descriptor = currentActiveBinding(for: state).flatMap({ active in
                  candidates.first { sameSourceIdentity($0, active.descriptor) }
              }) ?? candidates.first
        else { return }
        selectDescriptor(descriptor, in: state, userInitiated: false)
    }

    private func startThumbnailBatchIfNeeded(
        _ state: ProductionLiveSourceResolverState,
        candidates: [VideoSourceDescriptor]
    ) {
        guard videoAuthorizationStatus() == .authorized
        else { return }
        let missing = candidates.filter {
            let key = thumbnailAttemptKey($0)
            return state.thumbnailEpochs[$0.sourceID] != $0.sourceEpoch
                && !state.thumbnailAttemptedKeys.contains(key)
        }
        guard !missing.isEmpty, state.thumbnailCapture == nil,
              state.thumbnailPending.isEmpty
        else { return }
        state.thumbnailGeneration = UUID()
        state.thumbnailPending = missing
        startNextThumbnail(state)
    }

    private func startNextThumbnail(_ state: ProductionLiveSourceResolverState) {
        guard isCurrent(state),
              let generation = state.thumbnailGeneration,
              !state.thumbnailPending.isEmpty
        else { return }
        let descriptor = state.thumbnailPending.removeFirst()
        state.thumbnailAttemptedKeys.insert(thumbnailAttemptKey(descriptor))
        let gate = ProductionOneShotGate()
        do {
            let capture = try captureFactory(
                descriptor.sourceID,
                descriptor.sourceEpoch
            ) { [weak self, weak state] sample in
                guard gate.claim() else { return }
                let dimensions = ProductionSourceThumbnailDimensions(
                    width: sample.presentationWidth,
                    height: sample.presentationHeight
                )
                self?.thumbnailQueue.async {
                    let image = ProductionSourceThumbnailRenderer.render(sample)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, let state,
                                  self.isCurrent(state),
                                  state.thumbnailGeneration == generation
                            else { return }
                            self.finishThumbnail(
                                state,
                                descriptor: descriptor,
                                image: image.map {
                                    NSImage(cgImage: $0, size: NSSize(
                                        width: $0.width,
                                        height: $0.height
                                    ))
                                },
                                dimensions: dimensions,
                                generation: generation
                            )
                        }
                    }
                }
            }
            state.thumbnailCapture = capture
            state.thumbnailDescriptor = descriptor
            DispatchQueue.global(qos: .userInitiated).async {
                let started = (try? capture.start()) != nil
                guard !started else { return }
                DispatchQueue.main.async { [weak self, weak state] in
                    MainActor.assumeIsolated {
                        guard let self, let state else { return }
                        self.finishThumbnail(
                            state,
                            descriptor: descriptor,
                            image: nil,
                            dimensions: nil,
                            generation: generation
                        )
                    }
                }
            }
        } catch {
            startNextThumbnail(state)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + thumbnailTimeout) {
            [weak self, weak state] in
            MainActor.assumeIsolated {
                guard let self, let state,
                      state.thumbnailGeneration == generation,
                      state.thumbnailDescriptor == descriptor
                else { return }
                self.finishThumbnail(
                    state,
                    descriptor: descriptor,
                    image: nil,
                    dimensions: nil,
                    generation: generation
                )
            }
        }
    }

    private func finishThumbnail(
        _ state: ProductionLiveSourceResolverState,
        descriptor: VideoSourceDescriptor,
        image: NSImage?,
        dimensions: ProductionSourceThumbnailDimensions?,
        generation: UUID
    ) {
        guard isCurrent(state), state.thumbnailGeneration == generation,
              state.thumbnailDescriptor == descriptor,
              let capture = state.thumbnailCapture
        else { return }
        state.thumbnailCapture = nil
        state.thumbnailDescriptor = nil
        if let image, let dimensions,
           state.inventory?.sources.contains(descriptor) == true
        {
            state.thumbnails[descriptor.sourceID] = image
            state.thumbnailEpochs[descriptor.sourceID] = descriptor.sourceEpoch
            state.thumbnailDimensions[descriptor.sourceID] = dimensions
        }
        stopCapture(capture, in: state)
        afterCaptureStops(in: state) { [weak self, weak state] in
            guard let self, let state,
                  self.isCurrent(state),
                  state.thumbnailGeneration == generation
            else { return }
            self.rebuildCandidates(state)
            self.startNextThumbnail(state)
        }
    }

    private func cancelThumbnailBatch(
        _ state: ProductionLiveSourceResolverState,
        completion: CaptureStopCompletion? = nil
    ) {
        state.thumbnailGeneration = nil
        state.thumbnailPending.removeAll()
        state.thumbnailDescriptor = nil
        guard let capture = state.thumbnailCapture else {
            afterCaptureStops(in: state, completion: completion)
            return
        }
        state.thumbnailCapture = nil
        stopCapture(capture, in: state)
        afterCaptureStops(in: state, completion: completion)
    }

    @objc private func selectCandidate(_ sender: ProductionSourceCandidateButton) {
        guard let state = owners[sender.ownerID],
              let descriptor = state.inventory?.sources.first(where: {
                  $0.sourceID == sender.sourceID
              })
        else { return }
        selectDescriptor(descriptor, in: state, userInitiated: true)
    }

    private func selectDescriptor(
        _ descriptor: VideoSourceDescriptor,
        in state: ProductionLiveSourceResolverState,
        userInitiated: Bool
    ) {
        if userInitiated {
            state.userInteracted = true
            state.stableToken = nil
        }
        if let selected = state.selectedDescriptor,
           sameSourceIdentity(selected, descriptor),
           state.previewCapture != nil
        {
            state.selectedDescriptor = descriptor
            updateReassignmentWarning(state)
            refreshConfirmAvailability(state)
            rebuildCandidates(state)
            return
        }
        state.selectedDescriptor = descriptor
        state.confirmButton?.isEnabled = false
        updateReassignmentWarning(state)
        rebuildCandidates(state)
        stopProbe(state) { [weak self, weak state] in
            guard let self, let state, self.isCurrent(state),
                  state.selectedDescriptor.map({
                      self.sameSourceIdentity($0, descriptor)
                  }) == true
            else { return }
            self.stopPreview(state) { [weak self, weak state] in
                guard let self, let state, self.isCurrent(state),
                      state.selectedDescriptor.map({
                          self.sameSourceIdentity($0, descriptor)
                      }) == true,
                      self.videoAuthorizationStatus() == .authorized
                else { return }
                self.startPreview(descriptor, in: state)
            }
        }
    }

    @objc private func handleCameraAuthorization(_ sender: NSButton) {
        guard let ownerID = sender.identifier?.rawValue,
              let state = owners[ownerID],
              !state.videoAuthorizationRequestInFlight
        else { return }
        switch videoAuthorizationStatus() {
        case .authorized:
            rebuildCandidates(state)
        case .notDetermined:
            state.userInteracted = true
            state.stableToken = nil
            state.videoAuthorizationRequestInFlight = true
            sender.isEnabled = false
            setStatus(Self.videoAuthorizationRequestingStatus, in: state)
            videoAuthorizationRequest { [weak self, weak state] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let state, self.isCurrent(state) else {
                            return
                        }
                        state.videoAuthorizationRequestInFlight = false
                        self.rebuildCandidates(state)
                    }
                }
            }
        case .denied, .restricted:
            state.userInteracted = true
            state.stableToken = nil
            openCameraSettings()
        @unknown default:
            state.userInteracted = true
            state.stableToken = nil
            openCameraSettings()
        }
    }

    @objc private func continueWithoutVideo(_ sender: NSButton) {
        guard let ownerID = sender.identifier?.rawValue,
              let state = owners[ownerID],
              !state.existingLive,
              videoAuthorizationStatus() != .authorized
        else { return }
        state.userInteracted = true
        state.stableToken = nil
        handoffWithoutVideo(state)
    }

    private func startPreview(
        _ descriptor: VideoSourceDescriptor,
        in state: ProductionLiveSourceResolverState
    ) {
        let token = UUID()
        let sink = ProductionSourcePreviewSink(
            ownerToken: token,
            sourceID: descriptor.sourceID,
            sourceEpoch: descriptor.sourceEpoch
        ) { [weak self, weak state] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let state, self.isCurrent(state),
                          state.previewToken == token,
                          state.selectedDescriptor.map({
                              self.sameSourceIdentity($0, descriptor)
                          }) == true,
                          self.inventoryContains(descriptor, state: state)
                    else { return }
                    state.previewPlaceholderLabel?.isHidden = true
                    self.refreshPreviewFreshness(state, token: token)
                    self.setStatus(state.claimsFailureMessage, in: state)
                }
            }
        }
        do {
            let capture = try captureFactory(
                descriptor.sourceID,
                descriptor.sourceEpoch,
                sink.receive
            )
            state.previewCapture = capture
            state.previewSink = sink
            state.previewToken = token
            state.previewView?.layer = sink.displayLayer
            setStatus("正在预览", in: state)
            DispatchQueue.global(qos: .userInitiated).async {
                let started = (try? capture.start()) != nil
                guard !started else { return }
                DispatchQueue.main.async { [weak self, weak state] in
                    MainActor.assumeIsolated {
                        guard let self, let state,
                              state.previewToken == token
                        else { return }
                        self.stopPreview(state) { [weak self, weak state] in
                            guard let self, let state, self.isCurrent(state) else {
                                return
                            }
                            self.setStatus("视频源不可用", in: state)
                        }
                    }
                }
            }
        } catch {
            setStatus("视频源不可用", in: state)
        }
    }

    private func stopPreview(
        _ state: ProductionLiveSourceResolverState,
        completion: CaptureStopCompletion? = nil
    ) {
        let capture = state.previewCapture
        state.previewCapture = nil
        state.previewSink?.stop()
        state.previewSink = nil
        state.previewToken = nil
        state.previewView?.layer = nil
        state.previewView?.wantsLayer = true
        state.previewView?.layer?.backgroundColor = NSColor.black.cgColor
        state.previewPlaceholderLabel?.isHidden = false
        stopCapture(capture, in: state)
        afterCaptureStops(in: state, completion: completion)
    }

    private func refreshPreviewFreshness(
        _ state: ProductionLiveSourceResolverState,
        token: UUID
    ) {
        guard isCurrent(state), state.previewToken == token else { return }
        let fresh = state.previewSink?.recentFrame(
            ownerToken: token,
            nowNanoseconds: SystemMonotonicClock().now().nanoseconds,
            maximumAgeNanoseconds: Self.previewFreshnessNanoseconds
        ) != nil
        refreshConfirmAvailability(state)
        if !fresh { setStatus("视频正在准备", in: state) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak state] in
            MainActor.assumeIsolated {
                guard let self, let state else { return }
                self.refreshPreviewFreshness(state, token: token)
            }
        }
    }

    @objc private func confirmSelection(_ sender: NSButton) {
        guard let ownerID = sender.identifier?.rawValue,
              let state = owners[ownerID],
              let descriptor = state.selectedDescriptor,
              inventoryContains(descriptor, state: state)
        else { return }
        if isCurrentActiveSource(descriptor, state: state) {
            closeCurrentSourceNoOp(state)
            return
        }
        guard
              let previewToken = state.previewToken,
              let previewFrame = state.previewSink?.recentFrame(
                ownerToken: previewToken,
                nowNanoseconds: SystemMonotonicClock().now().nanoseconds,
                maximumAgeNanoseconds: Self.previewFreshnessNanoseconds
              ),
              state.claimsReady,
              let snapshot = state.targetSnapshot
        else { return }
        state.userInteracted = true
        sender.isEnabled = false
        setStatus("正在保存视频源", in: state)
        let conflicts = conflictingTargets(
            sourceID: descriptor.sourceID,
            state: state
        )
        let activeConflicts = Set(activeBindings(
            sourceID: descriptor.sourceID,
            state: state
        ).compactMap { binding in
            binding.target == state.canonicalUDID ? nil : binding.target
        })
        mappingCoordinator.reassign(
            target: state.canonicalUDID,
            sourceID: descriptor.sourceID,
            proofKind: .operatorConfirmedPreview,
            initialCanvasWidth: Self.normalizedInitialCanvas(previewFrame)?.width,
            initialCanvasHeight: Self.normalizedInitialCanvas(previewFrame)?.height,
            connectedTargets: snapshot.connectedTargets.map(\.canonicalUDID),
            expectedConflictingTargets: conflicts,
            fence: { [weak self] targets in
                self?.fenceTargets(Array(Set(targets).union(activeConflicts)).sorted())
            }
        ) { [weak self, weak state] result in
            guard let self, let state, self.isCurrent(state) else { return }
            switch result {
            case .saved:
                self.handoff(
                    state
                )
            case .conflictChanged:
                self.setStatus("映射已变化，请重新确认", in: state)
                state.confirmButton?.isEnabled = false
                self.loadTargetSnapshot(state)
            case .failed:
                self.setStatus("无法保存视频源", in: state)
                state.confirmButton?.isEnabled = state.claimsReady
                    && state.previewToken.flatMap { previewToken in
                        state.previewSink?.recentFrame(
                            ownerToken: previewToken,
                            nowNanoseconds: SystemMonotonicClock().now().nanoseconds,
                            maximumAgeNanoseconds: Self.previewFreshnessNanoseconds
                        )
                    } != nil
            }
        }
    }

    private func closeCurrentSourceNoOp(
        _ state: ProductionLiveSourceResolverState
    ) {
        guard isCurrent(state), state.existingLive, !state.handingOff else { return }
        state.handingOff = true
        state.stableToken = nil
        stopAllCaptures(state) { [weak self, weak state] in
            guard let self, let state, self.isCurrent(state), state.handingOff
            else { return }
            state.window?.delegate = nil
            state.window?.close()
            self.remove(state)
            self.existingSourceRetained(state.canonicalUDID, state.ownerID)
        }
    }

    @objc private func refreshSources(_ sender: NSButton) {
        guard let ownerID = sender.identifier?.rawValue,
              let state = owners[ownerID]
        else { return }
        state.userInteracted = true
        state.stableToken = nil
        state.selectedDescriptor = nil
        state.thumbnails.removeAll()
        state.thumbnailDimensions.removeAll()
        state.thumbnailEpochs.removeAll()
        state.thumbnailAttemptedKeys.removeAll()
        state.claimsReady = false
        state.targetSnapshotToken = nil
        stopAllCaptures(state) { [weak self, weak state] in
            guard let self, let state, self.isCurrent(state) else { return }
            self.loadTargetSnapshot(state)
            do {
                self.inventoryRefresh(try self.inventoryRefreshProvider())
            } catch {
                self.setStatus("无法刷新视频源", in: state)
            }
        }
    }

    @objc private func cancelSelection(_ sender: NSButton) {
        guard let ownerID = sender.identifier?.rawValue,
              let state = owners[ownerID]
        else { return }
        state.window?.close()
    }

    private func handoff(_ state: ProductionLiveSourceResolverState) {
        guard isCurrent(state), !state.handingOff,
              let targetFacts = state.targetSnapshot?.target
        else { return }
        state.handingOff = true
        state.stableToken = nil
        let value = ProductionLiveSourceHandoff(targetFacts: targetFacts)
        transferCaptureForHandoff(state)
        stopAllCaptures(state) { [weak self, weak state] in
            guard let self, let state, self.isCurrent(state), state.handingOff
            else { return }
            state.window?.delegate = nil
            state.window?.close()
            self.remove(state)
            if state.existingLive {
                self.existingHandoff(
                    state.canonicalUDID,
                    state.ownerID,
                    value
                )
            } else {
                self.firstHandoff(
                    state.canonicalUDID,
                    state.ownerID,
                    value
                )
            }
        }
    }

    private func transferCaptureForHandoff(
        _ state: ProductionLiveSourceResolverState
    ) {
        if let capture = state.previewCapture,
           capture.transferForHandoff(
            target: state.canonicalUDID,
            ownerID: state.ownerID
           )
        {
            state.previewCapture = nil
            state.previewSink?.stop()
            state.previewSink = nil
            state.previewToken = nil
            state.previewView?.layer = nil
            return
        }
        if let capture = state.probeCapture,
           capture.transferForHandoff(
            target: state.canonicalUDID,
            ownerID: state.ownerID
           )
        {
            state.probeCapture = nil
            state.probeDescriptor = nil
            state.probeSink?.stop()
            state.probeSink = nil
            state.probeToken = nil
        }
    }

    private func handoffWithoutVideo(
        _ state: ProductionLiveSourceResolverState
    ) {
        guard isCurrent(state), !state.handingOff, !state.existingLive,
              let targetFacts = state.targetSnapshot?.target
        else { return }
        state.handingOff = true
        state.stableToken = nil
        stopAllCaptures(state) { [weak self, weak state] in
            guard let self, let state, self.isCurrent(state), state.handingOff
            else { return }
            state.window?.delegate = nil
            state.window?.close()
            self.remove(state)
            self.firstBlindHandoff(
                state.canonicalUDID,
                state.ownerID,
                targetFacts
            )
        }
    }

    private func cancel(_ state: ProductionLiveSourceResolverState) {
        guard isCurrent(state), !state.handingOff else { return }
        state.handingOff = true
        state.stableToken = nil
        stopAllCaptures(state) { [weak self, weak state] in
            guard let self, let state, self.isCurrent(state), state.handingOff
            else { return }
            self.remove(state)
            if !state.existingLive {
                self.ownerCancelled(state.canonicalUDID, state.ownerID)
            }
        }
    }

    private func stopAllCaptures(
        _ state: ProductionLiveSourceResolverState,
        completion: @escaping CaptureStopCompletion
    ) {
        stopProbe(state) { [weak self, weak state] in
            guard let self, let state else { return }
            self.stopPreview(state) { [weak self, weak state] in
                guard let self, let state else { return }
                self.cancelThumbnailBatch(state, completion: completion)
            }
        }
    }

    private func stopCapture(
        _ capture: ProductionLiveSourceCaptureHandle?,
        in state: ProductionLiveSourceResolverState
    ) {
        guard let capture else { return }
        state.captureStopsInFlight += 1
        DispatchQueue.global(qos: .utility).async { [weak self, weak state] in
            capture.stop()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let state else { return }
                    self.captureStopCompleted(in: state)
                }
            }
        }
    }

    private func afterCaptureStops(
        in state: ProductionLiveSourceResolverState,
        completion: CaptureStopCompletion?
    ) {
        guard let completion else { return }
        guard state.captureStopsInFlight > 0 else {
            completion()
            return
        }
        state.captureStopCompletions.append(completion)
    }

    private func captureStopCompleted(
        in state: ProductionLiveSourceResolverState
    ) {
        precondition(state.captureStopsInFlight > 0)
        state.captureStopsInFlight -= 1
        guard state.captureStopsInFlight == 0 else { return }
        let completions = state.captureStopCompletions
        state.captureStopCompletions.removeAll()
        for completion in completions { completion() }
    }

    private func remove(_ state: ProductionLiveSourceResolverState) {
        owners.removeValue(forKey: state.ownerID)
        if ownerIDByTarget[state.canonicalUDID] == state.ownerID {
            ownerIDByTarget.removeValue(forKey: state.canonicalUDID)
        }
    }

    private func isCurrent(_ state: ProductionLiveSourceResolverState) -> Bool {
        owners[state.ownerID] === state
    }

    private func conflictingTargets(
        sourceID: String,
        state: ProductionLiveSourceResolverState
    ) -> Set<CanonicalUDID> {
        Set(state.mappingRecords.compactMap { target, result in
            guard target != state.canonicalUDID,
                  case .mapped(let record) = result,
                  record.sourceID == sourceID
            else { return nil }
            return target
        })
    }

    private func activeBindings(
        sourceID: String,
        state: ProductionLiveSourceResolverState
    ) -> [ProductionLiveSourceActiveBinding] {
        activeBindingsProvider()
            .filter { $0.descriptor.sourceID == sourceID }
            .sorted { $0.target < $1.target }
    }

    private func currentActiveBinding(
        for state: ProductionLiveSourceResolverState
    ) -> ProductionLiveSourceActiveBinding? {
        activeBindingsProvider().first { $0.target == state.canonicalUDID }
    }

    private func isCurrentActiveSource(
        _ descriptor: VideoSourceDescriptor,
        state: ProductionLiveSourceResolverState
    ) -> Bool {
        guard state.existingLive,
              let active = currentActiveBinding(for: state)
        else { return false }
        return sameSourceIdentity(active.descriptor, descriptor)
    }

    private func sameSourceIdentity(
        _ lhs: VideoSourceDescriptor,
        _ rhs: VideoSourceDescriptor
    ) -> Bool {
        lhs.sourceID == rhs.sourceID && lhs.sourceEpoch == rhs.sourceEpoch
    }

    private func inventoryContains(
        _ descriptor: VideoSourceDescriptor,
        state: ProductionLiveSourceResolverState
    ) -> Bool {
        state.inventory?.sources.contains {
            sameSourceIdentity($0, descriptor)
        } == true
    }

    private func candidatePresentation(
        _ descriptor: VideoSourceDescriptor,
        state: ProductionLiveSourceResolverState
    ) -> ProductionSourceCandidatePresentation {
        let thumbnailDimensions = state.thumbnailEpochs[descriptor.sourceID]
                == descriptor.sourceEpoch
            ? state.thumbnailDimensions[descriptor.sourceID]
            : nil
        let dimensions: String
        if descriptor.hasActiveFormat {
            dimensions = "\(descriptor.activeFormatWidth)x\(descriptor.activeFormatHeight)"
        } else if let thumbnailDimensions {
            dimensions = "\(thumbnailDimensions.width)x\(thumbnailDimensions.height)"
        } else {
            dimensions = "等待画面"
        }
        let id = "\(descriptor.sourceID.prefix(8))...\(descriptor.sourceID.suffix(8))"
        let claims = claimLabels(sourceID: descriptor.sourceID, state: state)
        let live = activeLabels(sourceID: descriptor.sourceID, state: state)
        let mapping: String
        if state.claimsReady {
            mapping = claims.isEmpty
                ? "未绑定"
                : "已映射到：\(claims.joined(separator: ", "))"
        } else {
            mapping = state.claimsFailureMessage == nil
                ? "正在读取绑定信息..."
                : "绑定信息暂不可用"
        }
        return ProductionSourceCandidatePresentation(
            name: descriptor.displayName,
            metadata: "\(dimensions)  \(id)",
            mapping: mapping,
            active: live.joined(separator: ", ")
        )
    }

    private func claimLabels(
        sourceID: String,
        state: ProductionLiveSourceResolverState
    ) -> [String] {
        let facts = Dictionary(uniqueKeysWithValues:
            (state.targetSnapshot?.connectedTargets ?? []).map {
                ($0.canonicalUDID, $0.name)
            }
        )
        let targets: [CanonicalUDID] = state.mappingRecords.compactMap { entry in
            let (target, result) = entry
            guard case .mapped(let record) = result,
                  record.sourceID == sourceID
            else { return nil }
            return target
        }
        return targets.sorted().map {
            "\(facts[$0] ?? "iPhone") / \($0.rawValue)"
        }
    }

    private func activeLabels(
        sourceID: String,
        state: ProductionLiveSourceResolverState
    ) -> [String] {
        let facts = Dictionary(uniqueKeysWithValues:
            (state.targetSnapshot?.connectedTargets ?? []).map {
                ($0.canonicalUDID, $0.name)
            }
        )
        return activeBindings(sourceID: sourceID, state: state).map { active in
            if active.target == state.canonicalUDID {
                return "当前正在使用"
            }
            return "正在 Live 中：\(facts[active.target] ?? "iPhone") / \(active.target.rawValue)"
        }
    }

    private func updateReassignmentWarning(
        _ state: ProductionLiveSourceResolverState
    ) {
        guard let warning = state.warningLabel,
              let sourceID = state.selectedDescriptor?.sourceID
        else { return }
        if let descriptor = state.selectedDescriptor,
           isCurrentActiveSource(descriptor, state: state)
        {
            warning.isHidden = false
            warning.textColor = .secondaryLabelColor
            warning.stringValue = "当前 Live 正在使用此视频源"
            refreshFooterStatusArea(state)
            return
        }
        let conflicts = conflictingTargets(sourceID: sourceID, state: state)
            .union(activeBindings(sourceID: sourceID, state: state).compactMap {
                $0.target == state.canonicalUDID ? nil : $0.target
            })
        warning.isHidden = conflicts.isEmpty
        warning.textColor = .systemOrange
        warning.stringValue = conflicts.isEmpty ? "" :
            "确认后将重新分配此视频源，原设备的 Live 画面会停止，且后续需要重新选择视频源。"
        refreshFooterStatusArea(state)
    }

    private func refreshConfirmAvailability(
        _ state: ProductionLiveSourceResolverState
    ) {
        guard let descriptor = state.selectedDescriptor else {
            state.confirmButton?.isEnabled = false
            return
        }
        if isCurrentActiveSource(descriptor, state: state) {
            state.confirmButton?.isEnabled = true
            return
        }
        let fresh = state.previewToken.flatMap { token in
            state.previewSink?.recentFrame(
                ownerToken: token,
                nowNanoseconds: SystemMonotonicClock().now().nanoseconds,
                maximumAgeNanoseconds: Self.previewFreshnessNanoseconds
            )
        } != nil
        state.confirmButton?.isEnabled = state.claimsReady && fresh
    }

    private func updateTargetIdentity(_ state: ProductionLiveSourceResolverState) {
        state.identityLabel?.stringValue = targetIdentityText(state)
        state.previewPlaceholderLabel?.stringValue = targetPlaceholderText(state)
        state.continueWithoutVideoButton?.isEnabled = state.targetSnapshot != nil
    }

    private func updateVideoAuthorizationControls(
        _ state: ProductionLiveSourceResolverState,
        authorization: AVAuthorizationStatus
    ) {
        let camera = state.cameraAuthorizationButton
        let symbol: String?
        let tooltip: String?
        switch authorization {
        case .authorized:
            symbol = nil
            tooltip = nil
        case .notDetermined:
            symbol = "video.badge.plus"
            tooltip = "允许摄像头访问"
        case .denied, .restricted:
            symbol = "gear"
            tooltip = "打开摄像头隐私设置"
        @unknown default:
            symbol = "gear"
            tooltip = "打开摄像头隐私设置"
        }
        camera?.isHidden = symbol == nil
        camera?.isEnabled = !state.videoAuthorizationRequestInFlight
        camera?.toolTip = tooltip
        if let symbol {
            camera?.image = NSImage(
                systemSymbolName: symbol,
                accessibilityDescription: tooltip
            ) ?? NSImage()
        }
        state.continueWithoutVideoButton?.isHidden = state.existingLive
            || authorization == .authorized
        state.continueWithoutVideoButton?.isEnabled = state.targetSnapshot != nil
    }

    private func targetIdentityText(
        _ state: ProductionLiveSourceResolverState
    ) -> String {
        guard let target = state.targetSnapshot?.target else {
            return "正在为此设备选择视频源  \(state.canonicalUDID.rawValue)"
        }
        return "正在为 \(target.name) 选择视频源  iOS \(target.osVersion)  \(target.canonicalUDID.rawValue)"
    }

    private func targetPlaceholderText(
        _ state: ProductionLiveSourceResolverState
    ) -> String {
        guard let target = state.targetSnapshot?.target else {
            return "iPhone\n\(state.canonicalUDID.rawValue)"
        }
        return "\(target.name)\n\(target.canonicalUDID.rawValue)"
    }

    private func setStatus(
        _ text: String?,
        in state: ProductionLiveSourceResolverState
    ) {
        let value = text ?? ""
        state.statusLabel?.stringValue = value
        state.statusLabel?.isHidden = value.isEmpty
        refreshFooterStatusArea(state)
    }

    private func refreshFooterStatusArea(
        _ state: ProductionLiveSourceResolverState
    ) {
        guard let area = state.statusArea else { return }
        for view in area.arrangedSubviews {
            area.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if let warning = state.warningLabel, !warning.isHidden {
            area.addArrangedSubview(warning)
        }
        if let status = state.statusLabel, !status.isHidden {
            area.addArrangedSubview(status)
        }
    }

    private func thumbnailAttemptKey(
        _ descriptor: VideoSourceDescriptor
    ) -> String {
        "\(descriptor.sourceID):\(descriptor.sourceEpoch)"
    }

    private static func normalizedInitialCanvas(
        _ frame: ProductionSourcePreviewSink.FrameSnapshot
    ) -> (width: UInt64, height: UInt64)? {
        let width = min(frame.width, frame.height)
        let height = max(frame.width, frame.height)
        guard width > 0,
              height <= VideoSourceMappingRecordV2.maximumInitialCanvasDimension
        else { return nil }
        return (width, height)
    }
}

private struct ProductionSourceThumbnailDimensions {
    let width: UInt64
    let height: UInt64
}

private struct ProductionSourceCandidatePresentation {
    let name: String
    let metadata: String
    let mapping: String
    let active: String
}

@MainActor
private final class ProductionLiveSourceResolverState {
    weak var cameraAuthorizationButton: NSButton?
    let canonicalUDID: CanonicalUDID
    let existingLive: Bool
    let ownerID: String
    let policy: GUIHostSourceSelectionPolicy
    var attemptedProbeKeys = Set<String>()
    weak var candidateStack: NSStackView?
    var captureStopCompletions = [ProductionLiveSourceResolver.CaptureStopCompletion]()
    var captureStopsInFlight = 0
    weak var confirmButton: NSButton?
    weak var continueWithoutVideoButton: NSButton?
    var claimsReady = false
    var claimsFailureMessage: String?
    var handingOff = false
    weak var identityLabel: NSTextField?
    var inventory: VideoSourceInventory?
    var mappingRecords = [CanonicalUDID: VideoSourceMappingLoadResult]()
    var previewCapture: ProductionLiveSourceCaptureHandle?
    weak var previewPlaceholderLabel: NSTextField?
    var previewSink: ProductionSourcePreviewSink?
    var previewToken: UUID?
    weak var previewView: NSView?
    var probeCapture: ProductionLiveSourceCaptureHandle?
    var probeDescriptor: VideoSourceDescriptor?
    var probeSink: ProductionSourcePreviewSink?
    var probeToken: UUID?
    var selectedDescriptor: VideoSourceDescriptor?
    var stableInventory: VideoSourceStableInventoryAccumulator
    var stableQualifiedSourceIDs: [String]?
    var stableSourceEpochs = [String: UInt64]()
    var stableToken: UUID?
    weak var statusArea: NSStackView?
    var statusLabel: NSTextField?
    var targetMapping: VideoSourceMappingLoadResult?
    var targetSnapshot: ProductionLiveSourceTargetSnapshot?
    var targetSnapshotCandidateTargets: Set<CanonicalUDID>?
    var targetSnapshotExpectedAttempts = 0
    var targetSnapshotAttemptsCompleted = 0
    var targetSnapshotObservedFacts = false
    var targetSnapshotResolved = false
    var targetSnapshotToken: UUID?
    var thumbnailCapture: ProductionLiveSourceCaptureHandle?
    var thumbnailAttemptedKeys = Set<String>()
    var thumbnailDescriptor: VideoSourceDescriptor?
    var thumbnailDimensions = [String: ProductionSourceThumbnailDimensions]()
    var thumbnailGeneration: UUID?
    var thumbnailEpochs = [String: UInt64]()
    var thumbnailPending = [VideoSourceDescriptor]()
    var thumbnails = [String: NSImage]()
    var userInteracted = false
    var videoAuthorizationRequestInFlight = false
    var warningLabel: NSTextField?
    var window: NSWindow?

    init(
        canonicalUDID: CanonicalUDID,
        existingLive: Bool,
        ownerID: String,
        policy: GUIHostSourceSelectionPolicy,
        stableInventory: VideoSourceStableInventoryAccumulator
    ) {
        self.canonicalUDID = canonicalUDID
        self.existingLive = existingLive
        self.ownerID = ownerID
        self.policy = policy
        self.stableInventory = stableInventory
    }
}

@MainActor
private final class ProductionSourceCandidateStackView: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class ProductionSourceCandidateButton: NSButton {
    let ownerID: String
    let sourceID: String

    private let activeLabel = NSTextField(labelWithString: "")
    private let mappingLabel = NSTextField(labelWithString: "")
    private let metadataLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let thumbnailView = NSImageView()

    init(
        ownerID: String,
        sourceID: String,
        target: AnyObject?,
        action: Selector?
    ) {
        self.ownerID = ownerID
        self.sourceID = sourceID
        super.init(frame: .zero)
        self.target = target
        self.action = action
        setButtonType(.toggle)
        title = ""
        isBordered = false
        focusRingType = .exterior
        wantsLayer = true

        thumbnailView.imageScaling = .scaleProportionallyDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.backgroundColor = NSColor.black.cgColor
        thumbnailView.layer?.cornerRadius = 4
        thumbnailView.layer?.cornerCurve = .continuous
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail

        metadataLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        metadataLabel.textColor = .tertiaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingMiddle

        mappingLabel.font = .systemFont(ofSize: 11, weight: .regular)
        mappingLabel.textColor = .secondaryLabelColor
        mappingLabel.lineBreakMode = .byTruncatingMiddle
        mappingLabel.maximumNumberOfLines = 2

        activeLabel.font = .systemFont(ofSize: 11, weight: .medium)
        activeLabel.textColor = .systemGreen
        activeLabel.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [
            nameLabel, metadataLabel, mappingLabel, activeLabel,
        ])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumbnailView)
        addSubview(textStack)
        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            thumbnailView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: 58),
            thumbnailView.heightAnchor.constraint(equalToConstant: 78),
            textStack.leadingAnchor.constraint(
                equalTo: thumbnailView.trailingAnchor,
                constant: 10
            ),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(
        name: String,
        metadata: String,
        mapping: String,
        active: String,
        image: NSImage
    ) {
        nameLabel.stringValue = name
        metadataLabel.stringValue = metadata
        mappingLabel.stringValue = mapping
        activeLabel.stringValue = active
        activeLabel.isHidden = active.isEmpty
        thumbnailView.image = image
        setAccessibilityLabel(
            [name, metadata, mapping, active]
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        )
    }

    func updateSelectionStyle() {
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.borderWidth = state == .on ? 1 : 0
        layer?.borderColor = state == .on
            ? NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor
            : NSColor.clear.cgColor
        layer?.backgroundColor = state == .on
            ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor
    }
}

private final class ProductionOneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

struct ProductionSourcePreviewAuthority: Equatable, Sendable {
    let ownerToken: UUID
    let sourceEpoch: UInt64
    let sourceID: String

    func accepts(sourceID: String, sourceEpoch: UInt64) -> Bool {
        self.sourceID == sourceID && self.sourceEpoch == sourceEpoch
    }

    func frameIsFresh(
        ownerToken: UUID,
        capturedAtNanoseconds: UInt64,
        nowNanoseconds: UInt64,
        maximumAgeNanoseconds: UInt64
    ) -> Bool {
        self.ownerToken == ownerToken
            && capturedAtNanoseconds <= nowNanoseconds
            && nowNanoseconds - capturedAtNanoseconds <= maximumAgeNanoseconds
    }
}

private final class ProductionSourcePreviewSink: @unchecked Sendable {
    struct FrameSnapshot: Sendable {
        let capturedAtNanoseconds: UInt64
        let height: UInt64
        let width: UInt64
    }

    let displayLayer = AVSampleBufferDisplayLayer()

    private let authority: ProductionSourcePreviewAuthority
    private let firstFrame: @Sendable () -> Void
    private let lock = NSLock()
    private var frameSeen = false
    private var latest: FrameSnapshot?
    private var stopped = false

    init(
        ownerToken: UUID,
        sourceID: String,
        sourceEpoch: UInt64,
        firstFrame: @escaping @Sendable () -> Void
    ) {
        authority = ProductionSourcePreviewAuthority(
            ownerToken: ownerToken,
            sourceEpoch: sourceEpoch,
            sourceID: sourceID
        )
        self.firstFrame = firstFrame
        displayLayer.videoGravity = .resizeAspect
    }

    func receive(_ sample: AVFoundationVideoFrameSample) {
        let first = lock.withLock {
            guard !stopped,
                  authority.accepts(
                      sourceID: sample.sourceID,
                      sourceEpoch: sample.sourceEpoch
                  )
            else { return false }
            let first = !frameSeen
            frameSeen = true
            latest = FrameSnapshot(
                capturedAtNanoseconds: sample.delegateMonotonicNanoseconds,
                height: sample.presentationHeight,
                width: sample.presentationWidth
            )
            return first
        }
        if first { firstFrame() }
        DispatchQueue.main.async { [self] in
            guard lock.withLock({ !stopped }) else { return }
            ProductionSampleBufferDisplay.enqueue(
                sample.sampleBuffer,
                on: displayLayer
            )
        }
    }

    func recentFrame(
        ownerToken: UUID,
        nowNanoseconds: UInt64,
        maximumAgeNanoseconds: UInt64
    ) -> FrameSnapshot? {
        lock.withLock {
            guard !stopped, let latest,
                  authority.frameIsFresh(
                      ownerToken: ownerToken,
                      capturedAtNanoseconds: latest.capturedAtNanoseconds,
                      nowNanoseconds: nowNanoseconds,
                      maximumAgeNanoseconds: maximumAgeNanoseconds
                  )
            else { return nil }
            return latest
        }
    }

    func latestFrame(ownerToken: UUID) -> FrameSnapshot? {
        lock.withLock {
            guard !stopped, authority.ownerToken == ownerToken else { return nil }
            return latest
        }
    }

    @MainActor
    func stop() {
        lock.withLock { stopped = true }
        displayLayer.flushAndRemoveImage()
    }
}

private enum ProductionSourceThumbnailRenderer {
    private static let context = CIContext(options: nil)

    static func render(_ sample: AVFoundationVideoFrameSample) -> CGImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample.sampleBuffer) else {
            return nil
        }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = min(240 / extent.width, 240 / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: scale,
            y: scale
        ))
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: floor(extent.width * scale),
            height: floor(extent.height * scale)
        )
        return context.createCGImage(scaled, from: bounds)
    }
}
