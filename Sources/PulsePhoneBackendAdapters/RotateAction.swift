import Foundation
import PulsePhoneSharedDefinitions

public enum RotateDirection: String, CaseIterable, Codable, Equatable, Sendable {
    case left
    case right
}

public enum RotateActionError: Error, Equatable, Sendable {
    case geometryUnavailable
    case transportFailure
    case geometryOutcomeUnknown
}

public protocol RotateTransport: Sendable {
    func sendRotation(_ direction: RotateDirection) throws
    func waitForGeometry(
        afterRevision: UInt64,
        timeoutMilliseconds: UInt64
    ) throws -> DisplayGeometryDTO?
}

public final class RotationGeometryState: @unchecked Sendable {
    private let lock = NSLock()
    private var geometry: DisplayGeometryDTO?
    private var invalidatedConnectionEpoch: UInt64?
    private var invalidatedGeometryRevision: UInt64?
    private var invalidatedOrientation: DisplayOrientationDTO?

    public init(currentGeometry: DisplayGeometryDTO?) {
        self.geometry = currentGeometry
    }

    public var coordinateInputAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return geometry != nil
    }

    public var currentGeometry: DisplayGeometryDTO? {
        lock.lock()
        defer { lock.unlock() }
        return geometry
    }

    func invalidate(
        expected: GeometryAssertionDTO
    ) throws -> DisplayGeometryDTO {
        lock.lock()
        defer { lock.unlock() }
        guard let geometry else {
            throw RotateActionError.geometryUnavailable
        }
        try expected.validate(geometry)
        invalidatedConnectionEpoch = geometry.connectionEpoch
        invalidatedGeometryRevision = geometry.geometryRevision
        invalidatedOrientation = geometry.orientation
        self.geometry = nil
        return geometry
    }

    func accept(_ candidate: DisplayGeometryDTO) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let connectionEpoch = invalidatedConnectionEpoch,
              let geometryRevision = invalidatedGeometryRevision,
              let orientation = invalidatedOrientation,
              candidate.connectionEpoch == connectionEpoch,
              candidate.geometryRevision > geometryRevision,
              candidate.orientation != orientation
        else {
            throw RotateActionError.geometryOutcomeUnknown
        }
        geometry = candidate
        invalidatedConnectionEpoch = nil
        invalidatedGeometryRevision = nil
        invalidatedOrientation = nil
    }
}

public struct RotateActionResult: Codable, Equatable, Sendable {
    public let direction: RotateDirection
    public let geometryRevision: UInt64
    public let logicalHeight: UInt64
    public let logicalWidth: UInt64
    public let orientation: DisplayOrientationDTO
    public let outcomeKnown: Bool

    public init(direction: RotateDirection, geometry: DisplayGeometryDTO) {
        self.direction = direction
        geometryRevision = geometry.geometryRevision
        logicalHeight = geometry.logicalHeight
        logicalWidth = geometry.logicalWidth
        orientation = geometry.orientation
        outcomeKnown = true
    }
}

public struct RotateSemanticLog: Equatable, Sendable {
    public let commandID: String
    public let direction: RotateDirection
    public let geometryRevision: UInt64
    public let orientation: DisplayOrientationDTO
    public let routeID: String
}

public struct RotateExecution: Equatable, Sendable {
    public let result: RotateActionResult
    public let semanticLog: RotateSemanticLog
}

public struct RotateAction: Sendable {
    public static let commandID = "device.rotate"
    public static let deadlineMilliseconds: UInt64 = 10_000
    public static let routeID = "coredevice.orientation.rotate"

    private let geometryState: RotationGeometryState
    private let transport: any RotateTransport

    public init(
        geometryState: RotationGeometryState,
        transport: any RotateTransport
    ) {
        self.geometryState = geometryState
        self.transport = transport
    }

    public func execute(
        direction: RotateDirection,
        expectedGeometry: GeometryAssertionDTO
    ) throws -> RotateExecution {
        let previous = try geometryState.invalidate(expected: expectedGeometry)
        do {
            try transport.sendRotation(direction)
        } catch {
            throw RotateActionError.transportFailure
        }

        let candidate: DisplayGeometryDTO?
        do {
            candidate = try transport.waitForGeometry(
                afterRevision: previous.geometryRevision,
                timeoutMilliseconds: Self.deadlineMilliseconds
            )
        } catch {
            throw RotateActionError.geometryOutcomeUnknown
        }
        guard let candidate else {
            throw RotateActionError.geometryOutcomeUnknown
        }
        try geometryState.accept(candidate)
        return RotateExecution(
            result: RotateActionResult(direction: direction, geometry: candidate),
            semanticLog: RotateSemanticLog(
                commandID: Self.commandID,
                direction: direction,
                geometryRevision: candidate.geometryRevision,
                orientation: candidate.orientation,
                routeID: Self.routeID
            )
        )
    }
}
