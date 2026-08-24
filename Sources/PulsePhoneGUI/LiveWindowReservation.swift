import Foundation

public struct LiveWindowPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct LiveWindowSize: Equatable, Sendable {
    public let height: Double
    public let width: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct LiveWindowRect: Equatable, Sendable {
    public let origin: LiveWindowPoint
    public let size: LiveWindowSize

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.origin = LiveWindowPoint(x: x, y: y)
        self.size = LiveWindowSize(width: width, height: height)
    }

    public func contains(_ other: LiveWindowRect) -> Bool {
        other.origin.x >= origin.x
            && other.origin.y >= origin.y
            && other.origin.x + other.size.width <= origin.x + size.width
            && other.origin.y + other.size.height <= origin.y + size.height
    }
}

public struct LiveWindowAspectRatio: Equatable, Sendable {
    public let heightUnits: UInt64
    public let widthUnits: UInt64

    public init(widthUnits: UInt64, heightUnits: UInt64) throws {
        guard widthUnits > 0, heightUnits > 0 else {
            throw LiveWindowReservationError.invalidAspectRatio
        }
        self.widthUnits = widthUnits
        self.heightUnits = heightUnits
    }

    public var value: Double {
        Double(widthUnits) / Double(heightUnits)
    }
}

public enum LiveWindowReservationError: Error, Equatable, Sendable {
    case invalidAspectRatio
    case invalidCanvasSize
    case invalidChromeHeight
    case invalidMinimumContentWidth
    case minimumContentWidthUnavailable
    case invalidVisibleFrame
}

public struct LiveWindowReservation: Equatable, Sendable {
    public static let defaultPlaceholderAspectRatio = try! LiveWindowAspectRatio(
        widthUnits: 9,
        heightUnits: 16
    )
    public static let minimumCanvasShortEdge = 320.0
    public static let preferredCanvasShortEdge = 375.0
    public static let preferredMargin = 24.0
    public static let preferredSourceControlsHeight = 52.0
    public static let preferredTitlebarHeight = 52.0

    public let actualMinimumContentWidth: Double
    public let canvasHostSize: LiveWindowSize
    public let canvasSize: LiveWindowSize
    public let canvasAspectRatio: LiveWindowAspectRatio
    public let contentSize: LiveWindowSize
    public let screenVisibleFrame: LiveWindowRect
    public let sourceControlsHeight: Double
    public let windowFrame: LiveWindowRect

    public var hasHorizontalLetterbox: Bool {
        canvasHostSize.width - canvasSize.width > 0.5
    }

    public var contentAspectRatio: LiveWindowAspectRatio {
        canvasAspectRatio
    }

    public init(
        screenVisibleFrame: LiveWindowRect,
        contentAspectRatio: LiveWindowAspectRatio,
        minimumContentWidth: Double = 0,
        titlebarHeight: Double = Self.preferredTitlebarHeight,
        sourceControlsHeight: Double = Self.preferredSourceControlsHeight,
        minimumCanvasShortEdge: Double = Self.minimumCanvasShortEdge,
        preferredCanvasShortEdge: Double = Self.preferredCanvasShortEdge,
        preferredUserCanvasLongEdge: Double? = nil
    ) throws {
        guard Self.valid(screenVisibleFrame) else {
            throw LiveWindowReservationError.invalidVisibleFrame
        }
        guard titlebarHeight.isFinite, titlebarHeight >= 0,
              sourceControlsHeight.isFinite, sourceControlsHeight >= 0
        else {
            throw LiveWindowReservationError.invalidChromeHeight
        }
        guard minimumCanvasShortEdge.isFinite, minimumCanvasShortEdge > 0,
              preferredCanvasShortEdge.isFinite, preferredCanvasShortEdge > 0,
              preferredUserCanvasLongEdge.map({ $0.isFinite && $0 > 0 }) ?? true
        else {
            throw LiveWindowReservationError.invalidCanvasSize
        }
        guard minimumContentWidth.isFinite, minimumContentWidth >= 0 else {
            throw LiveWindowReservationError.invalidMinimumContentWidth
        }

        var horizontalMargin = min(
            Self.preferredMargin,
            screenVisibleFrame.size.width * 0.05
        )
        var verticalMargin = min(
            Self.preferredMargin,
            screenVisibleFrame.size.height * 0.05
        )
        let ratio = contentAspectRatio.value
        let productMinimumCanvasWidth = ratio >= 1
            ? minimumCanvasShortEdge * ratio
            : minimumCanvasShortEdge
        let effectiveMinimumCanvasWidth = max(
            minimumContentWidth,
            productMinimumCanvasWidth
        )
        let minimumWindowHeight = effectiveMinimumCanvasWidth / ratio
            + titlebarHeight
            + sourceControlsHeight
        if effectiveMinimumCanvasWidth
                > screenVisibleFrame.size.width - horizontalMargin * 2
            || minimumWindowHeight
                > screenVisibleFrame.size.height - verticalMargin * 2
        {
            horizontalMargin = 0
            verticalMargin = 0
        }
        let availableWidth = screenVisibleFrame.size.width - horizontalMargin * 2
        let availableWindowHeight = screenVisibleFrame.size.height - verticalMargin * 2
        let fittedTitlebarHeight = min(
            titlebarHeight,
            max(0, availableWindowHeight - 1)
        )
        let fittedSourceControlsHeight = min(
            sourceControlsHeight,
            max(0, availableWindowHeight - fittedTitlebarHeight - 1)
        )
        let availableCanvasHeight = availableWindowHeight
            - fittedTitlebarHeight
            - fittedSourceControlsHeight
        let maximumCanvasWidth = min(
            availableWidth,
            availableCanvasHeight * ratio
        )
        guard minimumContentWidth <= maximumCanvasWidth + 0.5 else {
            throw LiveWindowReservationError.minimumContentWidthUnavailable
        }

        var canvasWidth: Double
        var canvasHeight: Double
        if let preferredUserCanvasLongEdge {
            if ratio >= 1 {
                canvasWidth = min(availableWidth, preferredUserCanvasLongEdge)
                canvasHeight = canvasWidth / ratio
            } else {
                canvasHeight = min(
                    availableCanvasHeight,
                    preferredUserCanvasLongEdge
                )
                canvasWidth = canvasHeight * ratio
            }
        } else if ratio >= 1 {
            canvasHeight = min(availableCanvasHeight, preferredCanvasShortEdge)
            canvasWidth = canvasHeight * ratio
        } else {
            canvasWidth = min(availableWidth, preferredCanvasShortEdge)
            canvasHeight = canvasWidth / ratio
        }
        if canvasHeight > availableCanvasHeight {
            canvasHeight = availableCanvasHeight
            canvasWidth = canvasHeight * ratio
        }
        if canvasWidth > availableWidth {
            canvasWidth = availableWidth
            canvasHeight = canvasWidth / ratio
        }

        let fittedMinimumContentWidth = min(
            effectiveMinimumCanvasWidth,
            maximumCanvasWidth
        )
        if canvasWidth < fittedMinimumContentWidth {
            canvasWidth = fittedMinimumContentWidth
            canvasHeight = canvasWidth / ratio
        }

        let contentHeight = canvasHeight + fittedSourceControlsHeight
        let windowWidth = canvasWidth
        let windowHeight = contentHeight + fittedTitlebarHeight
        let originX = screenVisibleFrame.origin.x
            + (screenVisibleFrame.size.width - windowWidth) / 2
        let originY = screenVisibleFrame.origin.y
            + (screenVisibleFrame.size.height - windowHeight) / 2
        let frame = LiveWindowRect(
            x: originX,
            y: originY,
            width: windowWidth,
            height: windowHeight
        )
        guard Self.valid(frame), screenVisibleFrame.contains(frame) else {
            throw LiveWindowReservationError.invalidVisibleFrame
        }

        self.actualMinimumContentWidth = fittedMinimumContentWidth
        self.canvasHostSize = LiveWindowSize(
            width: canvasWidth,
            height: canvasHeight
        )
        self.canvasSize = LiveWindowSize(
            width: canvasWidth,
            height: canvasHeight
        )
        self.canvasAspectRatio = contentAspectRatio
        self.contentSize = LiveWindowSize(
            width: canvasWidth,
            height: contentHeight
        )
        self.screenVisibleFrame = screenVisibleFrame
        self.sourceControlsHeight = fittedSourceControlsHeight
        self.windowFrame = frame
    }

    private static func valid(_ rect: LiveWindowRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.size.width.isFinite
            && rect.size.height.isFinite
            && rect.size.width > 0
            && rect.size.height > 0
    }
}
