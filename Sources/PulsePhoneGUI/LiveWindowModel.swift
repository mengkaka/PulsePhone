import PulsePhoneSharedDefinitions

public enum LiveSamplePresentationOrientation: String, Equatable, Sendable {
    case landscape
    case portrait
}

public struct LiveSamplePresentationFormat: Equatable, Sendable {
    public static let normalizedShapeTolerance = 0.015

    public let dimensions: LiveWindowAspectRatio
    public let formatRevision: UInt64
    public let orientation: LiveSamplePresentationOrientation
    public let sourceEpoch: UInt64

    public init(
        sourceEpoch: UInt64,
        width: UInt64,
        height: UInt64,
        formatRevision: UInt64 = 1
    ) throws {
        guard sourceEpoch > 0 else {
            throw LiveWindowModelError.invalidSourceEpoch
        }
        guard formatRevision > 0 else {
            throw LiveWindowModelError.invalidFormatRevision
        }
        self.sourceEpoch = sourceEpoch
        self.formatRevision = formatRevision
        self.dimensions = try LiveWindowAspectRatio(
            widthUnits: width,
            heightUnits: height
        )
        self.orientation = width > height ? .landscape : .portrait
    }

    public var normalizedShape: Double {
        let width = Double(dimensions.widthUnits)
        let height = Double(dimensions.heightUnits)
        return min(width, height) / max(width, height)
    }

    public func aligns(with geometry: DisplayGeometryDTO) -> Bool {
        let geometryOrientation: LiveSamplePresentationOrientation =
            geometry.logicalWidth > geometry.logicalHeight ? .landscape : .portrait
        guard geometryOrientation == orientation else { return false }
        let width = Double(geometry.logicalWidth)
        let height = Double(geometry.logicalHeight)
        let geometryShape = min(width, height) / max(width, height)
        return abs(geometryShape - normalizedShape)
            <= Self.normalizedShapeTolerance
    }
}

public typealias LiveCaptureActiveFormat = LiveSamplePresentationFormat

public enum LiveWindowAspectSource: Equatable, Sendable {
    case identityPlaceholder
    case runtimeGeometry(connectionEpoch: UInt64, geometryRevision: UInt64)
    case samplePresentation(sourceEpoch: UInt64, formatRevision: UInt64)
}

public enum LiveWindowState: String, Equatable, Sendable {
    case enteringFullscreen
    case exitingFullscreen
    case fullscreen
    case windowed
}

public enum LiveWindowPlaceholderReason: String, Equatable, Sendable {
    case ambiguousSource
    case awaitingBinding
    case cameraDenied
    case deviceDetached
    case sourceUnavailable
}

public enum LiveWindowVideoPresentation: Equatable, Sendable {
    case identityPlaceholder(
        identity: IdentityPlaceholder,
        reason: LiveWindowPlaceholderReason
    )
}

public enum LiveWindowControlAvailability: Equatable, Sendable {
    case available(connectionEpoch: UInt64)
    case unavailable(reason: String)
}

public enum LiveWindowVideoAvailability: Equatable, Sendable {
    case frozen(sourceEpoch: UInt64, formatRevision: UInt64)
    case live(sourceEpoch: UInt64, formatRevision: UInt64)
    case unavailable(reason: LiveWindowPlaceholderReason)
}

public enum LiveWindowPointerAvailability: Equatable, Sendable {
    case available(connectionEpoch: UInt64, geometryRevision: UInt64)
    case preparing(reason: String)
    case unavailable(reason: String)
}

public struct LiveWindowGeometryUpdate: Equatable, Sendable {
    public let currentConnectionEpoch: UInt64
    public let currentGeometryRevision: UInt64
    public let requiresInteractionCancellation: Bool
}

public struct LiveWindowPresentationUpdate: Equatable, Sendable {
    public let currentFormatRevision: UInt64
    public let currentSourceEpoch: UInt64
    public let requiresInteractionCancellation: Bool
}

public enum LiveWindowModelError: Error, Equatable, Sendable {
    case conflictingCaptureFormat
    case conflictingRuntimeGeometry
    case invalidCanvasSize
    case invalidConnectionEpoch
    case invalidFormatRevision
    case invalidMinimumContentWidth
    case invalidSourceEpoch
    case invalidWindowState
    case staleCaptureFormat
    case staleRuntimeGeometry
}

public struct LiveWindowModel: Equatable, Sendable {
    public let identityPlaceholder: IdentityPlaceholder
    public private(set) var actualMinimumContentWidth: Double
    public private(set) var controlAvailability: LiveWindowControlAvailability
    public private(set) var pointerAvailability: LiveWindowPointerAvailability
    public private(set) var reservation: LiveWindowReservation
    public private(set) var reservationRevision: UInt64
    public private(set) var runtimeGeometry: DisplayGeometryDTO?
    public private(set) var samplePresentation: LiveSamplePresentationFormat?
    public private(set) var videoPresentation: LiveWindowVideoPresentation
    public private(set) var videoAvailability: LiveWindowVideoAvailability
    public private(set) var windowState: LiveWindowState
    private var pointerCapabilityAvailable: Bool
    private var placeholderAspectRatioHint: LiveWindowAspectRatio?
    private var preferredUserCanvasLongEdge: Double?

    public init(
        identityPlaceholder: IdentityPlaceholder,
        screenVisibleFrame: LiveWindowRect
    ) throws {
        self.identityPlaceholder = identityPlaceholder
        self.actualMinimumContentWidth = 0
        self.controlAvailability = .unavailable(reason: "runtimeNotAttached")
        self.pointerAvailability = .unavailable(reason: "runtimeNotAttached")
        self.pointerCapabilityAvailable = false
        self.placeholderAspectRatioHint = nil
        self.runtimeGeometry = nil
        self.samplePresentation = nil
        self.preferredUserCanvasLongEdge = nil
        self.reservationRevision = 1
        self.videoPresentation = .identityPlaceholder(
            identity: identityPlaceholder,
            reason: .awaitingBinding
        )
        self.videoAvailability = .unavailable(reason: .awaitingBinding)
        self.reservation = try LiveWindowReservation(
            screenVisibleFrame: screenVisibleFrame,
            contentAspectRatio: LiveWindowReservation
                .defaultPlaceholderAspectRatio
        )
        self.windowState = .windowed
    }

    public var captureActiveFormat: LiveCaptureActiveFormat? { samplePresentation }

    public var preferredWindowedCanvasLongEdge: Double {
        preferredUserCanvasLongEdge ?? max(
            reservation.canvasSize.width,
            reservation.canvasSize.height
        )
    }

    public var aspectSource: LiveWindowAspectSource {
        if let samplePresentation {
            return .samplePresentation(
                sourceEpoch: samplePresentation.sourceEpoch,
                formatRevision: samplePresentation.formatRevision
            )
        }
        if let runtimeGeometry {
            return .runtimeGeometry(
                connectionEpoch: runtimeGeometry.connectionEpoch,
                geometryRevision: runtimeGeometry.geometryRevision
            )
        }
        return .identityPlaceholder
    }

    public var controlCommandsEnabled: Bool {
        if case .available = controlAvailability { return true }
        return false
    }

    public var coordinateInputEnabled: Bool {
        guard pointerCapabilityAvailable else { return false }
        guard let runtimeGeometry else { return false }
        guard case .available(let connectionEpoch) = controlAvailability else {
            return false
        }
        guard connectionEpoch == runtimeGeometry.connectionEpoch else { return false }
        if case .live = videoAvailability {
            return samplePresentation?.aligns(with: runtimeGeometry) == true
        }
        return true
    }

    public mutating func setControlAvailable(
        connectionEpoch: UInt64
    ) throws {
        guard connectionEpoch > 0 else {
            throw LiveWindowModelError.invalidConnectionEpoch
        }
        pointerCapabilityAvailable = true
        controlAvailability = .available(connectionEpoch: connectionEpoch)
        refreshPointerAvailability()
    }

    public mutating func setControlUnavailable(reason: String) {
        pointerCapabilityAvailable = false
        controlAvailability = .unavailable(reason: reason)
        pointerAvailability = .unavailable(reason: reason)
    }

    public mutating func setPointerCapabilityAvailable(_ available: Bool) {
        pointerCapabilityAvailable = available
        refreshPointerAvailability()
    }

    public mutating func setPointerPreparing(reason: String) {
        pointerAvailability = .preparing(reason: reason)
    }

    public mutating func reconcilePointerAvailability() {
        refreshPointerAvailability()
    }

    public mutating func showIdentityPlaceholder(
        reason: LiveWindowPlaceholderReason
    ) {
        videoPresentation = .identityPlaceholder(
            identity: identityPlaceholder,
            reason: reason
        )
        videoAvailability = .unavailable(reason: reason)
        refreshPointerAvailability()
    }

    public mutating func updatePlaceholderAspectRatioHint(
        width: UInt64?,
        height: UInt64?
    ) throws {
        switch (width, height) {
        case (nil, nil):
            placeholderAspectRatioHint = nil
        case (.some(let width), .some(let height)):
            placeholderAspectRatioHint = try LiveWindowAspectRatio(
                widthUnits: width,
                heightUnits: height
            )
        default:
            throw LiveWindowModelError.invalidCanvasSize
        }
        guard samplePresentation == nil, runtimeGeometry == nil else { return }
        try rebuildReservation(advancingRevision: true)
    }

    @discardableResult
    public mutating func freezeVideo(
        unavailableReason: LiveWindowPlaceholderReason
    ) -> Bool {
        guard let samplePresentation else {
            showIdentityPlaceholder(reason: unavailableReason)
            return false
        }
        videoAvailability = .frozen(
            sourceEpoch: samplePresentation.sourceEpoch,
            formatRevision: samplePresentation.formatRevision
        )
        refreshPointerAvailability()
        return true
    }

    @discardableResult
    public mutating func updateSamplePresentation(
        _ format: LiveSamplePresentationFormat
    ) throws -> LiveWindowPresentationUpdate {
        let previous = samplePresentation
        if case .frozen = videoAvailability {
            // Frozen presentation is continuity data only. GUIHost fences the
            // replacement callback by current binding token and source identity.
            return try commitSamplePresentation(format, replacing: previous)
        }
        if let current = previous {
            guard format.sourceEpoch >= current.sourceEpoch else {
                throw LiveWindowModelError.staleCaptureFormat
            }
            if format.sourceEpoch == current.sourceEpoch {
                guard format.formatRevision >= current.formatRevision else {
                    throw LiveWindowModelError.staleCaptureFormat
                }
                if format.formatRevision == current.formatRevision {
                    guard format == current else {
                        throw LiveWindowModelError.conflictingCaptureFormat
                    }
                    videoAvailability = .live(
                        sourceEpoch: current.sourceEpoch,
                        formatRevision: current.formatRevision
                    )
                    refreshPointerAvailability()
                    return LiveWindowPresentationUpdate(
                        currentFormatRevision: current.formatRevision,
                        currentSourceEpoch: current.sourceEpoch,
                        requiresInteractionCancellation: false
                    )
                }
            }
        }
        return try commitSamplePresentation(format, replacing: previous)
    }

    public mutating func updateCaptureActiveFormat(
        _ format: LiveCaptureActiveFormat
    ) throws {
        _ = try updateSamplePresentation(format)
    }

    public mutating func clearCaptureActiveFormat(
        throughSourceEpoch sourceEpoch: UInt64
    ) throws {
        guard sourceEpoch > 0 else {
            throw LiveWindowModelError.invalidSourceEpoch
        }
        if let samplePresentation,
           samplePresentation.sourceEpoch <= sourceEpoch
        {
            self.samplePresentation = nil
            videoPresentation = .identityPlaceholder(
                identity: identityPlaceholder,
                reason: .awaitingBinding
            )
            videoAvailability = .unavailable(reason: .awaitingBinding)
            try rebuildReservation(advancingRevision: true)
            refreshPointerAvailability()
        }
    }

    @discardableResult
    public mutating func updateRuntimeGeometry(
        _ geometry: DisplayGeometryDTO
    ) throws -> LiveWindowGeometryUpdate {
        let previous = runtimeGeometry
        if let current = previous {
            guard geometry.connectionEpoch >= current.connectionEpoch else {
                throw LiveWindowModelError.staleRuntimeGeometry
            }
            if geometry.connectionEpoch == current.connectionEpoch,
               geometry.geometryRevision < current.geometryRevision
            {
                throw LiveWindowModelError.staleRuntimeGeometry
            }
            if geometry.connectionEpoch == current.connectionEpoch,
               geometry.geometryRevision == current.geometryRevision,
               geometry != current
            {
                throw LiveWindowModelError.conflictingRuntimeGeometry
            }
        }
        runtimeGeometry = geometry
        try rebuildReservation(advancingRevision: true)
        refreshPointerAvailability()
        return LiveWindowGeometryUpdate(
            currentConnectionEpoch: geometry.connectionEpoch,
            currentGeometryRevision: geometry.geometryRevision,
            requiresInteractionCancellation: previous.map {
                $0.connectionEpoch != geometry.connectionEpoch
                    || $0.geometryRevision != geometry.geometryRevision
            } ?? false
        )
    }

    public mutating func clearRuntimeGeometry(
        throughConnectionEpoch connectionEpoch: UInt64
    ) throws {
        guard connectionEpoch > 0 else {
            throw LiveWindowModelError.invalidConnectionEpoch
        }
        if let runtimeGeometry,
           runtimeGeometry.connectionEpoch <= connectionEpoch
        {
            self.runtimeGeometry = nil
            try rebuildReservation(advancingRevision: true)
            refreshPointerAvailability()
        }
    }

    public mutating func updateScreenVisibleFrame(
        _ screenVisibleFrame: LiveWindowRect
    ) throws {
        reservation = try LiveWindowReservation(
            screenVisibleFrame: screenVisibleFrame,
            contentAspectRatio: currentAspectRatio,
            minimumContentWidth: actualMinimumContentWidth,
            preferredUserCanvasLongEdge: preferredUserCanvasLongEdge
        )
        advanceReservationRevision()
    }

    public mutating func updateActualMinimumContentWidth(_ width: Double) throws {
        guard width.isFinite, width >= 0 else {
            throw LiveWindowModelError.invalidMinimumContentWidth
        }
        guard abs(width - actualMinimumContentWidth) > 0.5 else { return }
        let previous = actualMinimumContentWidth
        actualMinimumContentWidth = width
        do {
            try rebuildReservation(advancingRevision: false)
        } catch {
            actualMinimumContentWidth = previous
            throw error
        }
    }

    public mutating func recordUserCanvasSize(_ size: LiveWindowSize) throws {
        guard windowState == .windowed else {
            throw LiveWindowModelError.invalidWindowState
        }
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0
        else {
            throw LiveWindowModelError.invalidCanvasSize
        }
        guard min(size.width, size.height)
                + 0.5 >= LiveWindowReservation.minimumCanvasShortEdge
        else {
            throw LiveWindowModelError.invalidCanvasSize
        }
        preferredUserCanvasLongEdge = max(size.width, size.height)
        try rebuildReservation(advancingRevision: true)
    }

    public mutating func windowWillEnterFullscreen() -> Bool {
        guard windowState == .windowed else { return false }
        windowState = .enteringFullscreen
        return true
    }

    public mutating func windowDidEnterFullscreen() -> Bool {
        guard windowState == .enteringFullscreen else { return false }
        windowState = .fullscreen
        return true
    }

    public mutating func windowWillExitFullscreen() -> Bool {
        guard windowState == .fullscreen else { return false }
        windowState = .exitingFullscreen
        return true
    }

    public mutating func windowDidExitFullscreen() -> Bool {
        guard windowState == .exitingFullscreen else { return false }
        windowState = .windowed
        advanceReservationRevision()
        return true
    }

    private var currentAspectRatio: LiveWindowAspectRatio {
        if let samplePresentation {
            return samplePresentation.dimensions
        }
        if let runtimeGeometry {
            return try! LiveWindowAspectRatio(
                widthUnits: runtimeGeometry.logicalWidth,
                heightUnits: runtimeGeometry.logicalHeight
            )
        }
        if let placeholderAspectRatioHint { return placeholderAspectRatioHint }
        return LiveWindowReservation.defaultPlaceholderAspectRatio
    }

    private mutating func commitSamplePresentation(
        _ format: LiveSamplePresentationFormat,
        replacing previous: LiveSamplePresentationFormat?
    ) throws -> LiveWindowPresentationUpdate {
        samplePresentation = format
        videoAvailability = .live(
            sourceEpoch: format.sourceEpoch,
            formatRevision: format.formatRevision
        )
        try rebuildReservation(advancingRevision: true)
        refreshPointerAvailability()
        let cancellation = previous.map {
            $0.sourceEpoch != format.sourceEpoch
                || $0.orientation != format.orientation
                || abs($0.normalizedShape - format.normalizedShape)
                    > LiveSamplePresentationFormat.normalizedShapeTolerance
        } ?? false
        return LiveWindowPresentationUpdate(
            currentFormatRevision: format.formatRevision,
            currentSourceEpoch: format.sourceEpoch,
            requiresInteractionCancellation: cancellation
        )
    }

    private mutating func rebuildReservation(advancingRevision: Bool) throws {
        reservation = try LiveWindowReservation(
            screenVisibleFrame: reservation.screenVisibleFrame,
            contentAspectRatio: currentAspectRatio,
            minimumContentWidth: actualMinimumContentWidth,
            preferredUserCanvasLongEdge: preferredUserCanvasLongEdge
        )
        if advancingRevision { advanceReservationRevision() }
    }

    private mutating func refreshPointerAvailability() {
        guard case .available(let connectionEpoch) = controlAvailability else {
            if case .unavailable(let reason) = controlAvailability {
                pointerAvailability = .unavailable(reason: reason)
            }
            return
        }
        guard pointerCapabilityAvailable else {
            pointerAvailability = .unavailable(reason: "capabilityUnavailable")
            return
        }
        guard let runtimeGeometry,
              runtimeGeometry.connectionEpoch == connectionEpoch
        else {
            pointerAvailability = .preparing(reason: "awaitingGeometry")
            return
        }
        if case .live = videoAvailability,
           samplePresentation?.aligns(with: runtimeGeometry) != true
        {
            pointerAvailability = .preparing(reason: "awaitingGeometry")
            return
        }
        pointerAvailability = .available(
            connectionEpoch: connectionEpoch,
            geometryRevision: runtimeGeometry.geometryRevision
        )
    }

    private mutating func advanceReservationRevision() {
        if reservationRevision < UInt64.max { reservationRevision += 1 }
    }
}
