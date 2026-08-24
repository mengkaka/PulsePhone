import AppKit
import Foundation
import PulsePhoneClientCore
import PulsePhoneCommandCatalog
import PulsePhoneMedia
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions

protocol ProductionGUIHostRuntimeSession: AnyObject, Sendable {
    var clientInstanceID: CanonicalUUID { get }
    var currentAttachment: LiveAttachment? { get }
    var ownedStreamCount: Int { get }

    func setRuntimeEventHandler(
        _ handler: (@Sendable (RepositoryJSONObject) -> Void)?
    )
    func setRuntimeObservationHandler(
        _ handler: (@Sendable (RuntimeObservation) -> Void)?
    )
    func setObservationResetHandler(
        _ handler: (@Sendable (ObservationStreamReset) -> Void)?
    )
    func setTransportFailureHandler(
        _ handler: (@Sendable (RuntimeClientError) -> Void)?
    )
    func prepareCapabilities() throws -> RepositoryJSONObject
    func attach(observationTopics: [String]) throws -> LiveAttachment
    func availability() throws -> RepositoryJSONObject
    func markLiveCaptureReady(
        captureActivationID: CanonicalUUID
    ) throws -> ProductionRuntimeCaptureReadyTransition
    func submit(
        commandID: String,
        rawArguments: [String: String],
        actionID: CanonicalUUID
    ) throws -> RepositoryJSONObject
    func recordLocalAction(_ body: RepositoryJSONObject) throws
    func openStream(
        commandID: String,
        rawArguments: [String: String],
        actionID: CanonicalUUID,
        interactionID: CanonicalUUID
    ) throws -> ProductionRuntimeLiveStream
    func sendFrame(
        stream: ProductionRuntimeLiveStream,
        sequence: UInt64,
        frameKind: String,
        payload: RepositoryJSONObject,
        clientSubmittedMonotonicNanoseconds: UInt64?
    ) throws
    func closeStream(
        _ stream: ProductionRuntimeLiveStream,
        expectedLastSequence: UInt64?,
        reason: String
    ) throws -> RepositoryJSONObject
    func cancelStream(
        _ stream: ProductionRuntimeLiveStream,
        reason: String
    ) throws -> RepositoryJSONObject
    func detach() throws -> LiveDetachResult
    func close() throws
}

extension ProductionRuntimeLiveSession: ProductionGUIHostRuntimeSession {}

extension ProductionGUIHostRuntimeSession {
    func setRuntimeEventHandler(
        _ handler: (@Sendable (RepositoryJSONObject) -> Void)?
    ) {}

    func setRuntimeObservationHandler(
        _ handler: (@Sendable (RuntimeObservation) -> Void)?
    ) {}

    func setObservationResetHandler(
        _ handler: (@Sendable (ObservationStreamReset) -> Void)?
    ) {}

    func setTransportFailureHandler(
        _ handler: (@Sendable (RuntimeClientError) -> Void)?
    ) {}
}

enum ProductionGUIHostViewIdentifier {
    static let availabilityOverlay = NSUserInterfaceItemIdentifier(
        "pulsephone.live.availability-overlay"
    )
    static let canvasHost = NSUserInterfaceItemIdentifier(
        "pulsephone.live.canvas-host"
    )
    static let interactionCanvas = NSUserInterfaceItemIdentifier(
        "pulsephone.live.interaction-canvas"
    )
    static let sourceControls = NSUserInterfaceItemIdentifier(
        "pulsephone.live.source-controls"
    )
    static let sourceSummary = NSUserInterfaceItemIdentifier(
        "pulsephone.live.source-summary"
    )
    static let videoCanvas = NSUserInterfaceItemIdentifier(
        "pulsephone.live.video-canvas"
    )
}

@MainActor
final class ProductionGUIHostCanvasHost: NSView {
    private let availabilityOverlay: NSView
    private let interactionView: NSView
    private let videoView: NSView
    private var canvasAspectRatio: CGFloat

    init(
        frame: NSRect,
        aspectRatio: CGFloat,
        videoView: NSView,
        interactionView: NSView,
        availabilityOverlay: NSView
    ) {
        self.availabilityOverlay = availabilityOverlay
        self.canvasAspectRatio = aspectRatio
        self.videoView = videoView
        self.interactionView = interactionView
        super.init(frame: frame)
        identifier = ProductionGUIHostViewIdentifier.canvasHost
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(videoView)
        addSubview(interactionView)
        addSubview(availabilityOverlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let rect = Self.aspectFitRect(
            aspectRatio: canvasAspectRatio,
            in: bounds
        )
        videoView.frame = rect
        interactionView.frame = rect
        availabilityOverlay.frame = rect
    }

    func updateAspectRatio(_ aspectRatio: CGFloat) {
        guard aspectRatio.isFinite, aspectRatio > 0,
              aspectRatio != canvasAspectRatio
        else { return }
        canvasAspectRatio = aspectRatio
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    static func aspectFitRect(
        aspectRatio: CGFloat,
        in bounds: NSRect
    ) -> NSRect {
        guard aspectRatio.isFinite, aspectRatio > 0,
              bounds.width > 0, bounds.height > 0
        else { return .zero }
        let availableAspectRatio = bounds.width / bounds.height
        let size: NSSize
        if aspectRatio >= availableAspectRatio {
            size = NSSize(
                width: bounds.width,
                height: bounds.width / aspectRatio
            )
        } else {
            size = NSSize(
                width: bounds.height * aspectRatio,
                height: bounds.height
            )
        }
        return NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

struct ProductionLiveAvailabilityOverlayPresentation: Equatable, Sendable {
    let pointerIsPreparing: Bool
    let pointerMessage: String?
    let pointerSymbolName: String?
    let videoIsPreparing: Bool
    let videoMessage: String?
    let videoSymbolName: String?

    init(
        videoAvailability: LiveWindowVideoAvailability,
        pointerAvailability: LiveWindowPointerAvailability,
        pointerFailure: ProductionPointerInteractionFailure? = nil
    ) {
        switch videoAvailability {
        case .live:
            videoIsPreparing = false
            videoMessage = nil
            videoSymbolName = nil
        case .frozen:
            videoIsPreparing = false
            videoMessage = "Video disconnected"
            videoSymbolName = "video.slash.fill"
        case .unavailable(let reason):
            videoIsPreparing = reason == .awaitingBinding
            videoMessage = switch reason {
            case .awaitingBinding:
                "Video preparing"
            case .cameraDenied:
                "Camera unavailable"
            case .deviceDetached:
                "Video disconnected"
            case .ambiguousSource, .sourceUnavailable:
                "Video unavailable"
            }
            videoSymbolName = switch reason {
            case .awaitingBinding:
                nil
            case .cameraDenied:
                "camera.fill"
            case .deviceDetached, .ambiguousSource, .sourceUnavailable:
                "video.slash.fill"
            }
        }
        if pointerFailure != nil {
            pointerIsPreparing = false
            pointerMessage = "Touch unavailable"
            pointerSymbolName = "exclamationmark.circle.fill"
        } else {
            switch pointerAvailability {
            case .available:
                pointerIsPreparing = false
                pointerMessage = nil
                pointerSymbolName = nil
            case .preparing:
                pointerIsPreparing = true
                pointerMessage = "Touch preparing"
                pointerSymbolName = nil
            case .unavailable:
                pointerIsPreparing = false
                pointerMessage = "Touch unavailable"
                pointerSymbolName = "hand.raised.slash.fill"
            }
        }
    }

    var isHidden: Bool { videoMessage == nil && pointerMessage == nil }
}

@MainActor
final class ProductionGUIHostAvailabilityOverlayView: NSView {
    static let videoScrimAlpha: CGFloat = 0.27

    private var identityMessage: String?
    private let pointerBadge = NSView()
    private let pointerIcon = NSImageView()
    private let pointerLabel = NSTextField(labelWithString: "")
    private let pointerProgress = NSProgressIndicator()
    private let pointerStack = NSStackView()
    private let videoIcon = NSImageView()
    private let videoLabel = NSTextField(labelWithString: "")
    private let videoProgress = NSProgressIndicator()
    private let videoStatusSurface = NSView()
    private let videoStack = NSStackView()
    private(set) var presentation: ProductionLiveAvailabilityOverlayPresentation?

    var pointerStatusFrame: NSRect { pointerBadge.frame }
    var pointerUsesProgressIndicator: Bool { !pointerProgress.isHidden }
    var pointerUsesSymbol: Bool { !pointerIcon.isHidden }
    var videoScrimOpacity: CGFloat {
        primaryMessage == nil ? 0 : Self.videoScrimAlpha
    }
    var videoStatusFrame: NSRect { videoStatusSurface.frame }
    var videoStatusText: String { videoLabel.stringValue }
    var videoStatusSurfaceOpacity: CGFloat {
        videoStatusSurface.layer?.backgroundColor.flatMap {
            NSColor(cgColor: $0)?.alphaComponent
        } ?? 0
    }
    var statusForegroundsUseHighContrastTint: Bool {
        let foregroundColors = [
            videoLabel.textColor,
            pointerLabel.textColor,
            videoIcon.contentTintColor,
            pointerIcon.contentTintColor,
        ]
        let progressIndicators = [videoProgress, pointerProgress]
        return foregroundColors.allSatisfy {
            $0?.isEqual(NSColor.white) == true
        } && progressIndicators.allSatisfy {
            $0.appearance?.name == .darkAqua
        }
    }
    var videoUsesProgressIndicator: Bool { !videoProgress.isHidden }
    var videoUsesSymbol: Bool { !videoIcon.isHidden }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = ProductionGUIHostViewIdentifier.availabilityOverlay
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        alphaValue = 0
        isHidden = true

        for label in [videoLabel, pointerLabel] {
            label.alignment = .center
            label.textColor = .white
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        videoLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        videoLabel.maximumNumberOfLines = 4
        videoLabel.lineBreakMode = .byWordWrapping
        pointerLabel.font = .systemFont(ofSize: 12, weight: .medium)

        for icon in [videoIcon, pointerIcon] {
            icon.contentTintColor = .white
            icon.imageScaling = .scaleProportionallyDown
            icon.translatesAutoresizingMaskIntoConstraints = false
        }
        for progress in [videoProgress, pointerProgress] {
            progress.appearance = NSAppearance(named: .darkAqua)
            progress.controlSize = .small
            progress.isDisplayedWhenStopped = false
            progress.style = .spinning
            progress.translatesAutoresizingMaskIntoConstraints = false
        }

        videoStack.orientation = .vertical
        videoStack.alignment = .centerX
        videoStack.spacing = 10
        videoStack.translatesAutoresizingMaskIntoConstraints = false
        videoStack.addArrangedSubview(videoIcon)
        videoStack.addArrangedSubview(videoProgress)
        videoStack.addArrangedSubview(videoLabel)

        videoStatusSurface.wantsLayer = true
        videoStatusSurface.layer?.borderColor = NSColor.white
            .withAlphaComponent(0.16).cgColor
        videoStatusSurface.layer?.borderWidth = 1
        videoStatusSurface.layer?.cornerRadius = 8
        videoStatusSurface.layer?.cornerCurve = .continuous
        videoStatusSurface.translatesAutoresizingMaskIntoConstraints = false
        videoStatusSurface.addSubview(videoStack)
        updateStatusSurfaceAppearance()

        pointerStack.orientation = .horizontal
        pointerStack.alignment = .centerY
        pointerStack.edgeInsets = NSEdgeInsets(
            top: 7,
            left: 11,
            bottom: 7,
            right: 11
        )
        pointerStack.spacing = 7
        pointerStack.translatesAutoresizingMaskIntoConstraints = false
        pointerStack.addArrangedSubview(pointerIcon)
        pointerStack.addArrangedSubview(pointerProgress)
        pointerStack.addArrangedSubview(pointerLabel)

        pointerBadge.wantsLayer = true
        pointerBadge.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(0.68).cgColor
        pointerBadge.layer?.borderColor = NSColor.white
            .withAlphaComponent(0.14).cgColor
        pointerBadge.layer?.borderWidth = 1
        pointerBadge.layer?.cornerRadius = 7
        pointerBadge.layer?.cornerCurve = .continuous
        pointerBadge.translatesAutoresizingMaskIntoConstraints = false
        pointerBadge.addSubview(pointerStack)

        addSubview(videoStatusSurface)
        addSubview(pointerBadge)
        NSLayoutConstraint.activate([
            videoIcon.widthAnchor.constraint(equalToConstant: 28),
            videoIcon.heightAnchor.constraint(equalToConstant: 28),
            videoProgress.widthAnchor.constraint(equalToConstant: 18),
            videoProgress.heightAnchor.constraint(equalToConstant: 18),
            pointerIcon.widthAnchor.constraint(equalToConstant: 15),
            pointerIcon.heightAnchor.constraint(equalToConstant: 15),
            pointerProgress.widthAnchor.constraint(equalToConstant: 14),
            pointerProgress.heightAnchor.constraint(equalToConstant: 14),
            videoStack.leadingAnchor.constraint(
                equalTo: videoStatusSurface.leadingAnchor,
                constant: 18
            ),
            videoStack.trailingAnchor.constraint(
                equalTo: videoStatusSurface.trailingAnchor,
                constant: -18
            ),
            videoStack.topAnchor.constraint(
                equalTo: videoStatusSurface.topAnchor,
                constant: 16
            ),
            videoStack.bottomAnchor.constraint(
                equalTo: videoStatusSurface.bottomAnchor,
                constant: -16
            ),
            videoStatusSurface.centerXAnchor.constraint(equalTo: centerXAnchor),
            videoStatusSurface.centerYAnchor.constraint(equalTo: centerYAnchor),
            videoStatusSurface.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            videoStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: 24
            ),
            videoStack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -24
            ),
            pointerStack.leadingAnchor.constraint(equalTo: pointerBadge.leadingAnchor),
            pointerStack.trailingAnchor.constraint(equalTo: pointerBadge.trailingAnchor),
            pointerStack.topAnchor.constraint(equalTo: pointerBadge.topAnchor),
            pointerStack.bottomAnchor.constraint(equalTo: pointerBadge.bottomAnchor),
            pointerBadge.centerXAnchor.constraint(equalTo: centerXAnchor),
            pointerBadge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            pointerBadge.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: 18
            ),
            pointerBadge.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -18
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateStatusSurfaceAppearance()
    }

    func update(
        _ presentation: ProductionLiveAvailabilityOverlayPresentation,
        identityMessage: String? = nil
    ) {
        guard self.presentation != presentation || self.identityMessage != identityMessage
        else { return }
        let wasHidden = isHidden
        self.presentation = presentation
        self.identityMessage = identityMessage
        configureStatus(
            icon: videoIcon,
            label: videoLabel,
            message: primaryMessage,
            preparing: presentation.videoIsPreparing,
            progress: videoProgress,
            symbolName: presentation.videoSymbolName,
            symbolPointSize: 25,
            symbolWeight: .medium
        )
        configureStatus(
            icon: pointerIcon,
            label: pointerLabel,
            message: presentation.pointerMessage,
            preparing: presentation.pointerIsPreparing,
            progress: pointerProgress,
            symbolName: presentation.pointerSymbolName,
            symbolPointSize: 13,
            symbolWeight: .semibold
        )
        videoStatusSurface.isHidden = primaryMessage == nil
        pointerBadge.isHidden = presentation.pointerMessage == nil
        layer?.backgroundColor = primaryMessage == nil
            ? NSColor.clear.cgColor
            : NSColor.black.withAlphaComponent(Self.videoScrimAlpha).cgColor
        setAccessibilityLabel(
            [primaryMessage, presentation.pointerMessage]
                .compactMap { $0 }
                .joined(separator: ". ")
        )
        updateStatusSurfaceAppearance()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let hidden = primaryMessage == nil && presentation.pointerMessage == nil
        guard window != nil, !reduceMotion else {
            isHidden = hidden
            alphaValue = hidden ? 0 : 1
            return
        }
        if hidden {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                animator().alphaValue = 0
            } completionHandler: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self,
                              self.presentation == presentation
                        else { return }
                        self.isHidden = true
                    }
                }
            }
        } else {
            isHidden = false
            if wasHidden { alphaValue = 0 }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                animator().alphaValue = 1
            }
        }
    }

    private var primaryMessage: String? {
        let parts = [identityMessage, presentation?.videoMessage]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private func updateStatusSurfaceAppearance() {
        let workspace = NSWorkspace.shared
        let alpha = Self.statusSurfaceAlpha(
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast
        )
        videoStatusSurface.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(alpha).cgColor
    }

    static func statusSurfaceAlpha(
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> CGFloat {
        reduceTransparency || increaseContrast ? 0.92 : 0.76
    }

    private func configureStatus(
        icon: NSImageView,
        label: NSTextField,
        message: String?,
        preparing: Bool,
        progress: NSProgressIndicator,
        symbolName: String?,
        symbolPointSize: CGFloat,
        symbolWeight: NSFont.Weight
    ) {
        label.stringValue = message ?? ""
        label.isHidden = message == nil
        progress.isHidden = !preparing
        if preparing { progress.startAnimation(nil) }
        else { progress.stopAnimation(nil) }
        let configuration = NSImage.SymbolConfiguration(
            pointSize: symbolPointSize,
            weight: symbolWeight
        )
        icon.image = symbolName.flatMap {
            NSImage(
                systemSymbolName: $0,
                accessibilityDescription: message
            )?.withSymbolConfiguration(configuration)
        }
        icon.isHidden = icon.image == nil
    }
}

struct ProductionSourceControlsSizing {
    static func minimumContentWidth(
        horizontalInset: CGFloat,
        spacing: CGFloat,
        arrangedSubviewCount: Int,
        noncompressibleWidths: [CGFloat]
    ) -> CGFloat {
        guard horizontalInset.isFinite, horizontalInset >= 0,
              spacing.isFinite, spacing >= 0,
              arrangedSubviewCount >= 0,
              noncompressibleWidths.allSatisfy({ $0.isFinite && $0 >= 0 })
        else { return 0 }
        let gapCount = max(0, arrangedSubviewCount - 1)
        return horizontalInset * 2
            + spacing * CGFloat(gapCount)
            + noncompressibleWidths.reduce(0, +)
    }
}

enum ProductionLiveResizeDriver: String, Equatable, Sendable {
    case corner
    case heightEdge
    case widthEdge
}

struct ProductionLiveWindowSizing {
    enum PreferredPrimaryConstraint {
        case unrestricted
        case notExceedingPreferred
    }

    static func minimumCanvasWidth(
        canvasAspectRatio: CGFloat,
        minimumCanvasShortEdge: CGFloat = CGFloat(
            LiveWindowReservation.minimumCanvasShortEdge
        )
    ) -> CGFloat {
        guard canvasAspectRatio.isFinite, canvasAspectRatio > 0,
              minimumCanvasShortEdge.isFinite, minimumCanvasShortEdge > 0
        else { return 0 }
        return canvasAspectRatio >= 1
            ? minimumCanvasShortEdge * canvasAspectRatio
            : minimumCanvasShortEdge
    }

    static func minimumContentSize(
        canvasAspectRatio: CGFloat,
        sourceControlsHeight: CGFloat,
        maximumFrameSize: NSSize,
        frameChromeHeight: CGFloat,
        minimumContentWidth: CGFloat
    ) -> NSSize {
        guard canvasAspectRatio.isFinite, canvasAspectRatio > 0,
              sourceControlsHeight.isFinite, sourceControlsHeight >= 0,
              frameChromeHeight.isFinite, frameChromeHeight >= 0,
              minimumContentWidth.isFinite, minimumContentWidth >= 0
        else { return .zero }
        let maximumCanvasSize = NSSize(
            width: max(1, maximumFrameSize.width),
            height: max(
                1,
                maximumFrameSize.height
                    - frameChromeHeight
                    - sourceControlsHeight
            )
        )
        let maximumRatioWidth = min(
            maximumCanvasSize.width,
            maximumCanvasSize.height * canvasAspectRatio
        )
        let effectiveMinimumWidth = min(
            max(
                minimumContentWidth,
                minimumCanvasWidth(canvasAspectRatio: canvasAspectRatio)
            ),
            maximumRatioWidth
        )
        return adoptableContentSize(
            preferredCanvasSize: NSSize(
                width: effectiveMinimumWidth,
                height: effectiveMinimumWidth / canvasAspectRatio
            ),
            canvasAspectRatio: canvasAspectRatio,
            sourceControlsHeight: sourceControlsHeight,
            maximumCanvasSize: maximumCanvasSize,
            minimumContentWidth: effectiveMinimumWidth
        )
    }

    static func reconciledLiveResizeFrame(
        referenceFrame: NSRect,
        adoptedFrame: NSRect,
        expectedFrameSize: NSSize,
        visibleFrame: NSRect
    ) -> NSRect {
        guard expectedFrameSize.width.isFinite, expectedFrameSize.width > 0,
              expectedFrameSize.height.isFinite, expectedFrameSize.height > 0
        else { return adoptedFrame }

        func reconciledOrigin(
            referenceMin: CGFloat,
            referenceMax: CGFloat,
            adoptedMin: CGFloat,
            adoptedMax: CGFloat,
            adoptedLength: CGFloat,
            expectedLength: CGFloat
        ) -> CGFloat {
            guard abs(adoptedLength - (referenceMax - referenceMin)) > 0.5 else {
                return (adoptedMin + adoptedMax - expectedLength) / 2
            }
            let minimumEdgeMovement = abs(adoptedMin - referenceMin)
            let maximumEdgeMovement = abs(adoptedMax - referenceMax)
            if minimumEdgeMovement + 0.5 < maximumEdgeMovement {
                return adoptedMin
            }
            if maximumEdgeMovement + 0.5 < minimumEdgeMovement {
                return adoptedMax - expectedLength
            }
            return (adoptedMin + adoptedMax - expectedLength) / 2
        }

        var origin = NSPoint(
            x: reconciledOrigin(
                referenceMin: referenceFrame.minX,
                referenceMax: referenceFrame.maxX,
                adoptedMin: adoptedFrame.minX,
                adoptedMax: adoptedFrame.maxX,
                adoptedLength: adoptedFrame.width,
                expectedLength: expectedFrameSize.width
            ),
            y: reconciledOrigin(
                referenceMin: referenceFrame.minY,
                referenceMax: referenceFrame.maxY,
                adoptedMin: adoptedFrame.minY,
                adoptedMax: adoptedFrame.maxY,
                adoptedLength: adoptedFrame.height,
                expectedLength: expectedFrameSize.height
            )
        )
        if visibleFrame.width >= expectedFrameSize.width {
            origin.x = min(
                max(origin.x, visibleFrame.minX),
                visibleFrame.maxX - expectedFrameSize.width
            )
        }
        if visibleFrame.height >= expectedFrameSize.height {
            origin.y = min(
                max(origin.y, visibleFrame.minY),
                visibleFrame.maxY - expectedFrameSize.height
            )
        }
        return NSRect(origin: origin, size: expectedFrameSize)
    }

    static func constrainedContentSize(
        proposedContentSize: NSSize,
        currentContentSize: NSSize,
        canvasAspectRatio: CGFloat,
        sourceControlsHeight: CGFloat,
        maximumFrameSize: NSSize,
        frameChromeHeight: CGFloat,
        minimumContentWidth: CGFloat = 0,
        minimumCanvasShortEdge: CGFloat = CGFloat(
            LiveWindowReservation.minimumCanvasShortEdge
        ),
        resizeDriver: ProductionLiveResizeDriver? = nil
    ) -> NSSize {
        guard canvasAspectRatio.isFinite, canvasAspectRatio > 0,
              sourceControlsHeight.isFinite, sourceControlsHeight >= 0,
              frameChromeHeight.isFinite, frameChromeHeight >= 0,
              minimumContentWidth.isFinite, minimumContentWidth >= 0
        else { return currentContentSize }

        let proposedCanvasHeight = max(
            1,
            proposedContentSize.height - sourceControlsHeight
        )
        let currentCanvasHeight = max(
            1,
            currentContentSize.height - sourceControlsHeight
        )
        let widthDelta = abs(
            proposedContentSize.width - currentContentSize.width
        ) / max(1, currentContentSize.width)
        let heightDelta = abs(
            proposedCanvasHeight - currentCanvasHeight
        ) / max(1, currentCanvasHeight)

        let driver = resizeDriver ?? (widthDelta >= heightDelta
            ? .widthEdge
            : .heightEdge)
        var canvasWidth: CGFloat
        var canvasHeight: CGFloat
        switch driver {
        case .widthEdge:
            canvasWidth = max(1, proposedContentSize.width)
            canvasHeight = canvasWidth / canvasAspectRatio
        case .heightEdge:
            canvasHeight = proposedCanvasHeight
            canvasWidth = canvasHeight * canvasAspectRatio
        case .corner:
            // Project the pointer candidate onto width = ratio * height once.
            // Keeping this projection mode for the transaction prevents axis
            // switching when WindowServer rounds alternating callbacks.
            canvasHeight = max(
                1,
                (canvasAspectRatio * proposedContentSize.width
                    + proposedCanvasHeight)
                    / (canvasAspectRatio * canvasAspectRatio + 1)
            )
            canvasWidth = canvasHeight * canvasAspectRatio
        }

        let maximumCanvasWidth = max(1, maximumFrameSize.width)
        let maximumCanvasHeight = max(
            1,
            maximumFrameSize.height - frameChromeHeight - sourceControlsHeight
        )
        let maximumRatioWidth = min(
            maximumCanvasWidth,
            maximumCanvasHeight * canvasAspectRatio
        )
        let boundedMinimumWidth = min(
            max(
                minimumContentWidth,
                minimumCanvasWidth(
                    canvasAspectRatio: canvasAspectRatio,
                    minimumCanvasShortEdge: minimumCanvasShortEdge
                )
            ),
            maximumRatioWidth
        )
        canvasWidth = min(max(canvasWidth, boundedMinimumWidth), maximumRatioWidth)
        canvasHeight = canvasWidth / canvasAspectRatio
        return adoptableContentSize(
            preferredCanvasSize: NSSize(width: canvasWidth, height: canvasHeight),
            canvasAspectRatio: canvasAspectRatio,
            sourceControlsHeight: sourceControlsHeight,
            maximumCanvasSize: NSSize(
                width: maximumCanvasWidth,
                height: maximumCanvasHeight
            ),
            minimumContentWidth: boundedMinimumWidth
        )
    }

    static func liveResizeDriver(
        proposedFrameSize: NSSize,
        referenceFrameSize: NSSize,
        sourceControlsHeight: CGFloat,
        frameChromeHeight: CGFloat,
        threshold: CGFloat = 0.5
    ) -> ProductionLiveResizeDriver? {
        guard proposedFrameSize.width.isFinite,
              proposedFrameSize.height.isFinite,
              referenceFrameSize.width.isFinite,
              referenceFrameSize.height.isFinite
        else { return nil }
        let proposedCanvasHeight = max(
            1,
            proposedFrameSize.height - frameChromeHeight - sourceControlsHeight
        )
        let referenceCanvasHeight = max(
            1,
            referenceFrameSize.height - frameChromeHeight - sourceControlsHeight
        )
        let widthChanged = abs(
            proposedFrameSize.width - referenceFrameSize.width
        ) > threshold
        let heightChanged = abs(
            proposedCanvasHeight - referenceCanvasHeight
        ) > threshold
        switch (widthChanged, heightChanged) {
        case (true, true): return .corner
        case (true, false): return .widthEdge
        case (false, true): return .heightEdge
        case (false, false): return nil
        }
    }

    static func adoptableContentSize(
        preferredCanvasSize: NSSize,
        canvasAspectRatio: CGFloat,
        sourceControlsHeight: CGFloat,
        maximumCanvasSize: NSSize,
        minimumContentWidth: CGFloat,
        preferredPrimaryConstraint: PreferredPrimaryConstraint = .unrestricted
    ) -> NSSize {
        let maximumRatioWidth = min(
            maximumCanvasSize.width,
            maximumCanvasSize.height * canvasAspectRatio
        )
        let boundedMinimumWidth = min(minimumContentWidth, maximumRatioWidth)
        let preferredWidth = min(
            max(preferredCanvasSize.width, boundedMinimumWidth),
            maximumRatioWidth
        )
        let preferredHeight = preferredWidth / canvasAspectRatio

        // AppKit rounds fractional window frames outward. Quantize the short axis
        // first so the adopted canvas remains within half a point of the ratio.
        var primaryCandidates = Set<Int>()
        let preferredPrimary = canvasAspectRatio >= 1
            ? preferredHeight
            : preferredWidth
        let minimumPrimary = canvasAspectRatio >= 1
            ? boundedMinimumWidth / canvasAspectRatio
            : boundedMinimumWidth
        let maximumPrimary = canvasAspectRatio >= 1
            ? min(
                maximumCanvasSize.height,
                maximumCanvasSize.width / canvasAspectRatio
            )
            : maximumRatioWidth
        for value in [preferredPrimary, minimumPrimary, maximumPrimary] {
            let rounded = Int(value.rounded())
            for delta in -2...2 {
                primaryCandidates.insert(max(1, rounded + delta))
            }
        }

        var best: (
            size: NSSize,
            primaryDisplacement: CGFloat,
            ratioMismatch: CGFloat,
            totalDisplacement: CGFloat
        )?
        for primary in primaryCandidates.sorted() {
            let primaryValue = CGFloat(primary)
            if preferredPrimaryConstraint == .notExceedingPreferred,
               primaryValue > preferredPrimary + 0.001
            {
                continue
            }
            let size: NSSize
            if canvasAspectRatio >= 1 {
                size = NSSize(
                    width: (primaryValue * canvasAspectRatio).rounded(),
                    height: primaryValue
                )
            } else {
                size = NSSize(
                    width: primaryValue,
                    height: (primaryValue / canvasAspectRatio).rounded()
                )
            }
            guard size.width + 0.001 >= boundedMinimumWidth,
                  size.width <= maximumCanvasSize.width + 0.001,
                  size.height <= maximumCanvasSize.height + 0.001
            else { continue }
            let ratioMismatch = abs(
                size.width - size.height * canvasAspectRatio
            )
            let displacement = abs(size.width - preferredWidth)
                + abs(size.height - preferredHeight)
            let primaryDisplacement = abs(primaryValue - preferredPrimary)
            let shouldReplace: Bool
            if let best {
                if primaryDisplacement != best.primaryDisplacement {
                    shouldReplace = primaryDisplacement < best.primaryDisplacement
                } else if ratioMismatch != best.ratioMismatch {
                    shouldReplace = ratioMismatch < best.ratioMismatch
                } else {
                    shouldReplace = displacement < best.totalDisplacement
                }
            } else {
                shouldReplace = true
            }
            if shouldReplace {
                best = (
                    size,
                    primaryDisplacement,
                    ratioMismatch,
                    displacement
                )
            }
        }

        let canvasSize = best?.size
            ?? NSSize(width: preferredWidth, height: preferredHeight)
        return NSSize(
            width: canvasSize.width,
            height: canvasSize.height + sourceControlsHeight
        )
    }

    static func shouldRetryProgrammaticReservation(
        adoptedContentWidth: Double,
        desiredContentWidth: Double,
        minimumContentWidthChanged: Bool
    ) -> Bool {
        minimumContentWidthChanged
            || adoptedContentWidth > desiredContentWidth + 0.5
    }
}

enum ProductionLiveGeometryProjection {
    struct InitialVideoGeometry: Equatable {
        let geometry: DisplayGeometryDTO
        let isAuthoritative: Bool
    }

    enum PresentationGeometry: Equatable {
        case current(DisplayGeometryDTO)
        case deferred
    }

    static func presentationGeometry(
        format: LiveSamplePresentationFormat,
        current: DisplayGeometryDTO?
    ) -> PresentationGeometry {
        if let current, geometry(current, matches: format) {
            return .current(current)
        }
        return .deferred
    }

    static func coordinateAdmissionGeometry(
        liveModel: LiveWindowModel,
        videoBinding: VideoBindingIdentity?,
        videoBindingInFlight: Bool
    ) -> DisplayGeometryDTO? {
        guard liveModel.coordinateInputEnabled,
              let geometry = liveModel.runtimeGeometry
        else { return nil }
        if case .live = liveModel.videoAvailability {
            guard !videoBindingInFlight,
                  let videoBinding,
                  let presentation = liveModel.samplePresentation,
                  presentation.sourceEpoch == videoBinding.sourceEpoch,
                  presentation.aligns(with: geometry),
                  videoBinding.connectionEpoch == geometry.connectionEpoch,
                  videoBinding.geometryRevision == geometry.geometryRevision
            else { return nil }
        }
        return geometry
    }

    static func initialVideoGeometry(
        width: UInt64,
        height: UInt64,
        current: DisplayGeometryDTO?,
        expectedConnectionEpoch: UInt64
    ) throws -> InitialVideoGeometry {
        if let current,
           current.connectionEpoch == expectedConnectionEpoch,
           current.logicalWidth == width,
           current.logicalHeight == height,
           orientation(current.orientation, matchesWidth: width, height: height)
        {
            return InitialVideoGeometry(
                geometry: current,
                isAuthoritative: true
            )
        }
        return InitialVideoGeometry(
            geometry: try DisplayGeometryDTO(
                connectionEpoch: expectedConnectionEpoch,
                geometryRevision: 0,
                logicalHeight: height,
                logicalWidth: width,
                orientation: width > height ? .landscapeRight : .portrait
            ),
            isAuthoritative: false
        )
    }

    static func rotatedGeometry(
        result: RepositoryJSONObject,
        current: DisplayGeometryDTO,
        expectedConnectionEpoch: UInt64
    ) -> DisplayGeometryDTO? {
        guard current.connectionEpoch == expectedConnectionEpoch,
              result["outcome"]?.stringValue == "succeeded",
              let value = result["value"]?.objectValue,
              let direction = value["direction"]?.stringValue,
              ["left", "right"].contains(direction),
              case .bool(true)? = value["visibleOrientationConfirmed"],
              let revision = value["geometryRevision"]?.numberValue
                .flatMap({ try? $0.requireUInt64() }),
              let logicalHeight = value["logicalHeight"]?.numberValue
                .flatMap({ try? $0.requireUInt64() }),
              let logicalWidth = value["logicalWidth"]?.numberValue
                .flatMap({ try? $0.requireUInt64() }),
              let orientationText = value["orientation"]?.stringValue,
              let orientation = DisplayOrientationDTO(rawValue: orientationText),
              revision > current.geometryRevision
        else { return nil }
        return try? DisplayGeometryDTO(
            connectionEpoch: expectedConnectionEpoch,
            geometryRevision: revision,
            logicalHeight: logicalHeight,
            logicalWidth: logicalWidth,
            orientation: orientation
        )
    }

    private static func geometry(
        _ geometry: DisplayGeometryDTO,
        matches format: LiveSamplePresentationFormat
    ) -> Bool {
        let orientationMatches = switch format.orientation {
        case .portrait:
            geometry.orientation == .portrait
        case .landscape:
            geometry.orientation == .landscapeLeft
                || geometry.orientation == .landscapeRight
        }
        return orientationMatches
            && geometry.logicalWidth == format.dimensions.widthUnits
            && geometry.logicalHeight == format.dimensions.heightUnits
    }

    private static func orientation(
        _ orientation: DisplayOrientationDTO,
        matchesWidth width: UInt64,
        height: UInt64
    ) -> Bool {
        if width > height {
            return orientation == .landscapeLeft
                || orientation == .landscapeRight
        }
        return orientation == .portrait
            || orientation == .portraitUpsideDown
    }
}

struct ProductionCaptureReadyGeometryAdoption {
    let cancellation: PointerInteractionFrame?
    let geometryUpdate: LiveWindowGeometryUpdate
    let liveModel: LiveWindowModel
    let pointerController: PointerInteractionController

    static func prepare(
        geometry: DisplayGeometryDTO,
        attachmentConnectionEpoch: UInt64,
        captureReadyConnectionEpoch: UInt64?,
        videoBinding: VideoBindingIdentity,
        liveModel: LiveWindowModel,
        pointerController: PointerInteractionController,
        rebindVideo: (DisplayGeometryDTO) -> Bool
    ) -> ProductionCaptureReadyGeometryAdoption? {
        guard geometry.geometryRevision > 0,
              attachmentConnectionEpoch == geometry.connectionEpoch,
              captureReadyConnectionEpoch == geometry.connectionEpoch,
              liveModel.samplePresentation?.aligns(with: geometry) == true,
              videoBinding.connectionEpoch == geometry.connectionEpoch,
              videoBinding.geometryRevision <= geometry.geometryRevision
        else { return nil }
        if let current = liveModel.runtimeGeometry {
            guard geometry.connectionEpoch > current.connectionEpoch
                    || geometry.geometryRevision >= current.geometryRevision
            else { return nil }
        }

        var updatedModel = liveModel
        var updatedController = pointerController
        let geometryUpdate: LiveWindowGeometryUpdate
        let cancellation: PointerInteractionFrame?
        do {
            geometryUpdate = try updatedModel.updateRuntimeGeometry(geometry)
            cancellation = try updatedController.geometryDidChange(to: geometry)
        } catch {
            return nil
        }
        if videoBinding.geometryRevision < geometry.geometryRevision,
           !rebindVideo(geometry)
        {
            return nil
        }
        return ProductionCaptureReadyGeometryAdoption(
            cancellation: cancellation,
            geometryUpdate: geometryUpdate,
            liveModel: updatedModel,
            pointerController: updatedController
        )
    }
}

enum ProductionGUIHostToolbarProjection {
    static func commandIsAvailable(
        _ commandID: String,
        availability: RepositoryJSONObject
    ) -> Bool {
        guard let rows = availability["commands"]?.arrayValue else { return false }
        return rows.contains { value in
            guard let row = value.objectValue else { return false }
            return row["commandID"]?.stringValue == commandID
                && row["state"]?.stringValue == "enabled"
        }
    }

    static func loading(repositoryRoot: URL) throws -> LiveToolbar {
        let catalog = try CommandCatalog.load(repositoryRoot: repositoryRoot)
        return try ToolbarBinding.freeze(
            catalog: catalog,
            compatibilityByCommand: Dictionary(uniqueKeysWithValues:
                catalog.productActions.map { ($0.commandID, .unknown) }
            ),
            availabilityByCommand: Dictionary(uniqueKeysWithValues:
                catalog.productActions.map {
                    ($0.commandID, .unknown(reason: "runtimeStateUnknown"))
                }
            )
        )
    }

    static func make(
        availability: RepositoryJSONObject,
        repositoryRoot: URL
    ) throws -> LiveToolbar {
        let catalog = try CommandCatalog.load(repositoryRoot: repositoryRoot)
        guard let rows = availability["commands"]?.arrayValue else {
            throw RuntimeClientError.invalidResponse
        }
        var compatibility = [String: ToolbarCompatibilityProjection]()
        var projectedAvailability = [String: ToolbarAvailabilityProjection]()
        for rowValue in rows {
            guard let row = rowValue.objectValue,
                  let commandID = row["commandID"]?.stringValue,
                  let state = row["state"]?.stringValue
            else {
                throw RuntimeClientError.invalidResponse
            }
            let reason = row["reasonCode"]?.stringValue ?? "runtimeStateUnknown"
            if [
                "unsupportedDeviceClass", "unsupportedOSVersion",
                "unsupportedTransport",
            ].contains(reason) {
                compatibility[commandID] = .incompatible(reason: reason)
            } else {
                compatibility[commandID] = .compatible
            }
            switch state {
            case "enabled":
                projectedAvailability[commandID] = .available
            case "loading":
                projectedAvailability[commandID] = .loading(reason: reason)
            case "disabled":
                projectedAvailability[commandID] = .unavailable(reason: reason)
            default:
                throw RuntimeClientError.invalidResponse
            }
        }
        return try ToolbarBinding.freeze(
            catalog: catalog,
            compatibilityByCommand: compatibility,
            availabilityByCommand: projectedAvailability
        )
    }
}

enum ProductionGUIHostFramePayload {
    static func pointer(
        _ frame: PointerInteractionFrame
    ) throws -> RepositoryJSONObject {
        try object([
            ("edge", .string(frame.edge.rawValue)),
            ("expectedConnectionEpoch", .number(.uint64(
                frame.expectedGeometry.expectedConnectionEpoch
            ))),
            ("expectedGeometryRevision", .number(.uint64(
                frame.expectedGeometry.expectedGeometryRevision
            ))),
            ("x", .string(frame.point.x)),
            ("y", .string(frame.point.y)),
        ])
    }

    static func keyboard(
        _ frame: KeyboardCaptureFrame
    ) throws -> RepositoryJSONObject {
        try object([
            ("usages", .array(frame.pressedKeys.map {
                .number(.uint64(UInt64($0.usage)))
            })),
        ])
    }

    private static func object(
        _ members: [(String, RepositoryJSONValue)]
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: members.map {
            RepositoryJSONMember(key: $0.0, value: $0.1)
        })
    }
}

enum ProductionPointerStreamTerminalDisposition: Equatable {
    case cancel
    case close(expectedLastSequence: UInt64)
    case keepOpen

    static func resolve(
        _ pending: [(frame: PointerInteractionFrame, sequence: UInt64)]
    ) -> ProductionPointerStreamTerminalDisposition {
        guard let terminal = pending.last(where: {
            $0.frame.kind == .end || $0.frame.kind == .cancel
        }) else {
            return .keepOpen
        }
        switch terminal.frame.kind {
        case .cancel:
            return .cancel
        case .end:
            return .close(expectedLastSequence: terminal.sequence)
        case .begin, .move:
            return .keepOpen
        }
    }
}

enum ProductionPointerInteractionFailureStage: String, Equatable, Sendable {
    case admission
    case frameEncode
    case frameSend
    case streamCancel
    case streamClose
    case streamOpen
}

struct ProductionPointerInteractionFailure: Equatable, Sendable {
    let stage: ProductionPointerInteractionFailureStage
    let code: String
}

struct ProductionQueuedPointerInteraction: Sendable {
    let interactionID: CanonicalUUID
    let startedAtNanoseconds: UInt64
    var pendingFrames: [(frame: PointerInteractionFrame, sequence: UInt64)]

    var geometryAssertion: GeometryAssertionDTO? {
        pendingFrames.first?.frame.expectedGeometry
    }

    mutating func adoptGeometryRevision(
        from previous: DisplayGeometryDTO,
        to accepted: DisplayGeometryDTO
    ) -> Bool {
        let previousAssertion = GeometryAssertionDTO(
            expectedConnectionEpoch: previous.connectionEpoch,
            expectedGeometryRevision: previous.geometryRevision
        )
        let acceptedAssertion = GeometryAssertionDTO(
            expectedConnectionEpoch: accepted.connectionEpoch,
            expectedGeometryRevision: accepted.geometryRevision
        )
        guard previous.connectionEpoch == accepted.connectionEpoch,
              previous.logicalWidth == accepted.logicalWidth,
              previous.logicalHeight == accepted.logicalHeight,
              previous.orientation == accepted.orientation,
              accepted.geometryRevision >= previous.geometryRevision,
              pendingFrames.allSatisfy({
                $0.frame.expectedGeometry == previousAssertion
              })
        else { return false }
        pendingFrames = pendingFrames.map { item in
            (
                PointerInteractionFrame(
                    edge: item.frame.edge,
                    expectedGeometry: acceptedAssertion,
                    kind: item.frame.kind,
                    point: item.frame.point,
                    sequence: item.frame.sequence
                ),
                item.sequence
            )
        }
        return true
    }
}

@MainActor
final class ProductionGUIHostInteractionView: NSView {
    var geometry: DisplayGeometryDTO?
    var pointerBegan: ((PointerViewPoint, PointerVisibleImageRect) -> Bool)?
    var pointerMoved: ((PointerViewPoint, PointerVisibleImageRect) -> Bool)?
    var pointerEnded: ((PointerViewPoint, PointerVisibleImageRect) -> Bool)?
    var keyEvent: ((NSEvent, KeyboardCaptureEventKind, Bool) -> Bool)?
    var firstResponderChanged: ((Bool) -> Void)?

    private var overlayPoint: NSPoint?
    private var overlayRevision: UInt64 = 0
    private var pointerGestureAccepted = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var hasPointerOverlay: Bool { overlayPoint != nil }
    var pointerOverlayPoint: NSPoint? { overlayPoint }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { firstResponderChanged?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { firstResponderChanged?(false) }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        pointerGestureAccepted = pointerBegan?(
            viewPoint(point),
            visibleImageRect()
        ) == true
        if pointerGestureAccepted {
            showOverlay(at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard pointerGestureAccepted else { return }
        let point = convert(event.locationInWindow, from: nil)
        if pointerMoved?(viewPoint(point), visibleImageRect()) == true {
            showOverlay(at: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard pointerGestureAccepted else {
            pointerGestureAccepted = false
            return
        }
        pointerGestureAccepted = false
        let point = convert(event.locationInWindow, from: nil)
        if pointerEnded?(viewPoint(point), visibleImageRect()) == true {
            showOverlay(at: point)
        }
        schedulePointerOverlayClear(after: 0.18)
    }

    override func keyDown(with event: NSEvent) {
        if keyEvent?(event, .keyDown, true) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if keyEvent?(event, .keyUp, false) != true { super.keyUp(with: event) }
    }

    override func flagsChanged(with event: NSEvent) {
        if keyEvent?(event, .flagsChanged, modifierIsPressed(event)) != true {
            super.flagsChanged(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let overlayPoint else { return }
        NSColor.systemBlue.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: overlayPoint.x - 9,
            y: overlayPoint.y - 9,
            width: 18,
            height: 18
        )).fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(
            x: overlayPoint.x - 6,
            y: overlayPoint.y - 6,
            width: 12,
            height: 12
        ))
        ring.lineWidth = 2
        ring.stroke()
    }

    func visibleImageRect() -> PointerVisibleImageRect {
        guard let geometry else {
            return PointerVisibleImageRect(
                x: bounds.minX,
                y: bounds.minY,
                width: bounds.width,
                height: bounds.height
            )
        }
        let imageAspect = CGFloat(geometry.logicalWidth)
            / CGFloat(geometry.logicalHeight)
        let viewAspect = bounds.width / bounds.height
        let size: NSSize
        if imageAspect > viewAspect {
            size = NSSize(width: bounds.width, height: bounds.width / imageAspect)
        } else {
            size = NSSize(width: bounds.height * imageAspect, height: bounds.height)
        }
        let rect = NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        return PointerVisibleImageRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: rect.height
        )
    }

    func clearPointerOverlay() {
        overlayRevision &+= 1
        overlayPoint = nil
        needsDisplay = true
    }

    func showPointerOverlay(
        projection: RuntimePointerProjection
    ) -> Bool {
        guard let x = Double(projection.x),
              let y = Double(projection.y),
              x.isFinite,
              y.isFinite,
              (0...1).contains(x),
              (0...1).contains(y)
        else { return false }
        if projection.frameKind == .cancel {
            clearPointerOverlay()
            return true
        }
        let rect = visibleImageRect()
        showOverlay(at: NSPoint(
            x: rect.x + x * rect.width,
            y: rect.y + y * rect.height
        ))
        if projection.frameKind == .end {
            schedulePointerOverlayClear(after: 0.18)
        }
        return true
    }

    private func viewPoint(_ point: NSPoint) -> PointerViewPoint {
        PointerViewPoint(x: point.x, y: point.y)
    }

    private func showOverlay(at point: NSPoint) {
        overlayRevision &+= 1
        overlayPoint = point
        needsDisplay = true
    }

    private func schedulePointerOverlayClear(after delay: TimeInterval) {
        let expectedRevision = overlayRevision
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.overlayRevision == expectedRevision else {
                return
            }
            self.clearPointerOverlay()
        }
    }

    private func modifierIsPressed(_ event: NSEvent) -> Bool {
        let flagByKeyCode: [UInt16: NSEvent.ModifierFlags] = [
            54: .command, 55: .command, 56: .shift, 57: .capsLock,
            58: .option, 59: .control, 60: .shift, 61: .option,
            62: .control,
        ]
        guard let flag = flagByKeyCode[event.keyCode] else { return false }
        return event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .contains(flag)
    }
}

enum ProductionKeyboardHIDUsage {
    static func key(for event: NSEvent) -> KeyboardCapturedKey? {
        key(forKeyCode: event.keyCode)
    }

    static func key(forKeyCode keyCode: UInt16) -> KeyboardCapturedKey? {
        guard let usage = usageByKeyCode[keyCode] else { return nil }
        return KeyboardCapturedKey(usagePage: 0x07, usage: usage)
    }

    static func modifierIsPressed(
        keyCode: UInt16,
        flags: CGEventFlags
    ) -> Bool {
        let flagByKeyCode: [UInt16: CGEventFlags] = [
            54: .maskCommand, 55: .maskCommand,
            56: .maskShift, 57: .maskAlphaShift,
            58: .maskAlternate, 59: .maskControl,
            60: .maskShift, 61: .maskAlternate, 62: .maskControl,
        ]
        guard let flag = flagByKeyCode[keyCode] else { return false }
        return flags.contains(flag)
    }

    private static let usageByKeyCode: [UInt16: UInt16] = [
        0: 0x04, 1: 0x16, 2: 0x07, 3: 0x09, 4: 0x0B, 5: 0x0A,
        6: 0x1D, 7: 0x1B, 8: 0x06, 9: 0x19, 11: 0x05, 12: 0x14,
        13: 0x1A, 14: 0x08, 15: 0x15, 16: 0x1C, 17: 0x17, 18: 0x1E,
        19: 0x1F, 20: 0x20, 21: 0x21, 22: 0x23, 23: 0x22, 24: 0x2E,
        25: 0x26, 26: 0x24, 27: 0x2D, 28: 0x25, 29: 0x27, 30: 0x30,
        31: 0x12, 32: 0x18, 33: 0x2F, 34: 0x0C, 35: 0x13, 36: 0x28,
        37: 0x0F, 38: 0x0D, 39: 0x34, 40: 0x0E, 41: 0x33, 42: 0x31,
        43: 0x36, 44: 0x38, 45: 0x11, 46: 0x10, 47: 0x37, 48: 0x2B,
        49: 0x2C, 50: 0x35, 51: 0x2A, 53: 0x29, 54: 0xE7, 55: 0xE3,
        56: 0xE1, 57: 0x39, 58: 0xE2, 59: 0xE0, 60: 0xE5, 61: 0xE6,
        62: 0xE4, 123: 0x50, 124: 0x4F, 125: 0x51, 126: 0x52,
    ]
}
