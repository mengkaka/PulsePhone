import Foundation
import PulsePhoneCommandPlanner
import PulsePhoneSharedDefinitions

public struct PointerViewPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct PointerVisibleImageRect: Equatable, Sendable {
    public let height: Double
    public let width: Double
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum PointerInteractionFrameKind: String, Equatable, Sendable {
    case begin
    case cancel
    case end
    case move
}

public enum PointerEdgeClassification: String, Equatable, Sendable {
    case bottom
    case left
    case none
    case right
    case top
}

public struct PointerInteractionFrame: Equatable, Sendable {
    public let edge: PointerEdgeClassification
    public let expectedGeometry: GeometryAssertionDTO
    public let kind: PointerInteractionFrameKind
    public let point: NormalizedPointV1
    public let sequence: UInt64
}

public enum PointerInteractionControllerError: Error, Equatable, Sendable {
    case alreadyActive
    case invalidPoint
    case invalidVisibleRect
    case notActive
    case outsideInteractionRegion
    case sequenceExhausted
}

public struct PointerInteractionController: Sendable {
    public static let edgeSlopPoints = 28.0
    public static let edgeSnapPoints = 18.0

    private struct ActiveInteraction: Sendable {
        var geometry: GeometryAssertionDTO
        var lastEdge: PointerEdgeClassification
        var lastPoint: NormalizedPointV1
        var nextSequence: UInt64
    }

    private var active: ActiveInteraction?

    public init() {}

    public var isActive: Bool { active != nil }

    public mutating func begin(
        at point: PointerViewPoint,
        visibleImageRect: PointerVisibleImageRect,
        geometry: DisplayGeometryDTO
    ) throws -> PointerInteractionFrame {
        guard active == nil else {
            throw PointerInteractionControllerError.alreadyActive
        }
        let projection = try project(
            point,
            in: visibleImageRect,
            requiresInitialHit: true
        )
        let assertion = GeometryAssertionDTO(
            expectedConnectionEpoch: geometry.connectionEpoch,
            expectedGeometryRevision: geometry.geometryRevision
        )
        active = ActiveInteraction(
            geometry: assertion,
            lastEdge: projection.edge,
            lastPoint: projection.point,
            nextSequence: 1
        )
        return PointerInteractionFrame(
            edge: projection.edge,
            expectedGeometry: assertion,
            kind: .begin,
            point: projection.point,
            sequence: 0
        )
    }

    public mutating func move(
        to point: PointerViewPoint,
        visibleImageRect: PointerVisibleImageRect
    ) throws -> PointerInteractionFrame {
        try makeActiveFrame(
            kind: .move,
            point: point,
            visibleImageRect: visibleImageRect,
            endsInteraction: false
        )
    }

    public mutating func end(
        at point: PointerViewPoint,
        visibleImageRect: PointerVisibleImageRect
    ) throws -> PointerInteractionFrame {
        try makeActiveFrame(
            kind: .end,
            point: point,
            visibleImageRect: visibleImageRect,
            endsInteraction: true
        )
    }

    public mutating func cancel() throws -> PointerInteractionFrame {
        guard let current = active else {
            throw PointerInteractionControllerError.notActive
        }
        let sequence = current.nextSequence
        guard sequence < UInt64.max else {
            throw PointerInteractionControllerError.sequenceExhausted
        }
        active = nil
        return PointerInteractionFrame(
            edge: current.lastEdge,
            expectedGeometry: current.geometry,
            kind: .cancel,
            point: current.lastPoint,
            sequence: sequence
        )
    }

    public mutating func geometryDidChange(
        to geometry: DisplayGeometryDTO
    ) throws -> PointerInteractionFrame? {
        guard let current = active else { return nil }
        do {
            try current.geometry.validate(geometry)
            return nil
        } catch is GeometryDTOValidationError {
            return try cancel()
        }
    }

    mutating func adoptGeometryRevision(
        from previous: DisplayGeometryDTO,
        to accepted: DisplayGeometryDTO
    ) -> Bool {
        guard previous.connectionEpoch == accepted.connectionEpoch,
              previous.logicalWidth == accepted.logicalWidth,
              previous.logicalHeight == accepted.logicalHeight,
              previous.orientation == accepted.orientation,
              accepted.geometryRevision >= previous.geometryRevision
        else { return false }
        guard var current = active else { return true }
        let previousAssertion = GeometryAssertionDTO(
            expectedConnectionEpoch: previous.connectionEpoch,
            expectedGeometryRevision: previous.geometryRevision
        )
        guard current.geometry == previousAssertion else { return false }
        current.geometry = GeometryAssertionDTO(
            expectedConnectionEpoch: accepted.connectionEpoch,
            expectedGeometryRevision: accepted.geometryRevision
        )
        active = current
        return true
    }

    private mutating func makeActiveFrame(
        kind: PointerInteractionFrameKind,
        point: PointerViewPoint,
        visibleImageRect: PointerVisibleImageRect,
        endsInteraction: Bool
    ) throws -> PointerInteractionFrame {
        guard var current = active else {
            throw PointerInteractionControllerError.notActive
        }
        let projection = try project(
            point,
            in: visibleImageRect,
            requiresInitialHit: false
        )
        let sequence = current.nextSequence
        guard sequence < UInt64.max else {
            throw PointerInteractionControllerError.sequenceExhausted
        }
        current.nextSequence += 1
        current.lastPoint = projection.point
        current.lastEdge = projection.edge
        active = endsInteraction ? nil : current
        return PointerInteractionFrame(
            edge: projection.edge,
            expectedGeometry: current.geometry,
            kind: kind,
            point: projection.point,
            sequence: sequence
        )
    }

    private func project(
        _ point: PointerViewPoint,
        in rect: PointerVisibleImageRect,
        requiresInitialHit: Bool
    ) throws -> (point: NormalizedPointV1, edge: PointerEdgeClassification) {
        guard point.x.isFinite, point.y.isFinite else {
            throw PointerInteractionControllerError.invalidPoint
        }
        guard rect.x.isFinite, rect.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0
        else {
            throw PointerInteractionControllerError.invalidVisibleRect
        }
        if requiresInitialHit {
            let slop = Self.edgeSlopPoints
            guard point.x >= rect.x - slop,
                  point.x <= rect.x + rect.width + slop,
                  point.y >= rect.y - slop,
                  point.y <= rect.y + rect.height + slop
            else {
                throw PointerInteractionControllerError.outsideInteractionRegion
            }
        }

        var clampedX = min(max(point.x, rect.x), rect.x + rect.width)
        var clampedY = min(max(point.y, rect.y), rect.y + rect.height)
        let candidates: [(PointerEdgeClassification, Double)] = [
            (.left, clampedX - rect.x),
            (.right, rect.x + rect.width - clampedX),
            (.top, clampedY - rect.y),
            (.bottom, rect.y + rect.height - clampedY),
        ]
        let closest = candidates.min { $0.1 < $1.1 }
        let edge: PointerEdgeClassification
        if let closest, closest.1 <= Self.edgeSnapPoints {
            edge = closest.0
            switch edge {
            case .left: clampedX = rect.x
            case .right: clampedX = rect.x + rect.width
            case .top: clampedY = rect.y
            case .bottom: clampedY = rect.y + rect.height
            case .none: break
            }
        } else {
            edge = .none
        }

        let x = try canonicalUnit((clampedX - rect.x) / rect.width)
        let y = try canonicalUnit((clampedY - rect.y) / rect.height)
        let normalized = try ArgumentNormalizer.normalize(
            schemaID: "normalizedPoint.v1",
            raw: ["point": "\(x),\(y)"]
        )
        guard case .point(let value)? = normalized.values["point"] else {
            throw PointerInteractionControllerError.invalidPoint
        }
        return (value, edge)
    }

    private func canonicalUnit(_ value: Double) throws -> String {
        if value <= 0 { return "0" }
        if value >= 1 { return "1" }
        var text = String(
            format: "%.18f",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
        while text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        guard !text.isEmpty else {
            throw PointerInteractionControllerError.invalidPoint
        }
        return text
    }
}
