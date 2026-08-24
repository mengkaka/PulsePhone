import PulsePhoneCommandPlanner
import PulsePhoneSharedDefinitions

public enum TapActionError: Error, Equatable, Sendable {
    case invalidCoordinate
    case transportFailure
    case cleanupAcknowledgementMissing
}

public protocol TapTransport: Sendable {
    func sendTouch(
        coordinate: HIDCoordinateDTO,
        touching: Bool
    ) throws
    func waitForCleanupAcknowledgement(
        timeoutMilliseconds: UInt64
    ) throws
}

public struct TapExecutionRequest: Equatable, Sendable {
    public let currentGeometry: DisplayGeometryDTO
    public let expectedGeometry: GeometryAssertionDTO
    public let point: NormalizedPointV1

    public init(
        point: NormalizedPointV1,
        expectedGeometry: GeometryAssertionDTO,
        currentGeometry: DisplayGeometryDTO
    ) {
        self.point = point
        self.expectedGeometry = expectedGeometry
        self.currentGeometry = currentGeometry
    }
}

public struct TapActionResult: Codable, Equatable, Sendable {
    public let disposition: String

    public init(disposition: String = "acknowledged") {
        self.disposition = disposition
    }
}

public struct TapSemanticLog: Equatable, Sendable {
    public let commandID: String
    public let inputReleased: Bool
    public let normalizedX: String
    public let normalizedY: String
    public let routeID: String
}

public struct TapExecution: Equatable, Sendable {
    public let result: TapActionResult
    public let semanticLog: TapSemanticLog
}

public struct TapAction: Sendable {
    public static let cleanupAcknowledgementMilliseconds: UInt64 = 2_000
    public static let commandID = "touch.tap"
    public static let deadlineMilliseconds: UInt64 = 5_000
    public static let preparationGroupID = "prep.coredevice.v2"
    public static let routeID = "coredevice.normalTouch"

    private let transport: any TapTransport

    public init(transport: any TapTransport) {
        self.transport = transport
    }

    public func execute(_ request: TapExecutionRequest) throws -> TapExecution {
        let normalizedPoint = try validate(request.point)
        let coordinate = try project(normalizedPoint)
        try request.expectedGeometry.validate(request.currentGeometry)

        var touching = false
        do {
            try transport.sendTouch(coordinate: coordinate, touching: true)
            touching = true
            try transport.sendTouch(coordinate: coordinate, touching: false)
            touching = false
        } catch {
            if touching {
                try? transport.sendTouch(coordinate: coordinate, touching: false)
            }
            try cleanupAcknowledgement()
            throw TapActionError.transportFailure
        }
        try cleanupAcknowledgement()
        return TapExecution(
            result: TapActionResult(),
            semanticLog: TapSemanticLog(
                commandID: Self.commandID,
                inputReleased: true,
                normalizedX: normalizedPoint.x,
                normalizedY: normalizedPoint.y,
                routeID: Self.routeID
            )
        )
    }

    private func validate(_ point: NormalizedPointV1) throws -> NormalizedPointV1 {
        do {
            let normalized = try ArgumentNormalizer.normalize(
                schemaID: "normalizedPoint.v1",
                raw: ["point": "\(point.x),\(point.y)"]
            )
            guard case .point(let value)? = normalized.values["point"] else {
                throw TapActionError.invalidCoordinate
            }
            return value
        } catch is ArgumentNormalizationError {
            throw TapActionError.invalidCoordinate
        }
    }

    private func project(_ point: NormalizedPointV1) throws -> HIDCoordinateDTO {
        HIDCoordinateDTO(
            x: try projectAxis(point.x),
            y: try projectAxis(point.y)
        )
    }

    private func projectAxis(_ value: String) throws -> UInt16 {
        if value == "0" { return 0 }
        if value == "1" { return UInt16.max }

        let fraction = value.dropFirst(2)
        guard let numerator = UInt64(fraction) else {
            throw TapActionError.invalidCoordinate
        }
        var scale: UInt64 = 1
        for _ in fraction {
            let (next, overflow) = scale.multipliedReportingOverflow(by: 10)
            guard !overflow else {
                throw TapActionError.invalidCoordinate
            }
            scale = next
        }

        let product = numerator.multipliedFullWidth(by: UInt64(UInt16.max))
        let division = scale.dividingFullWidth(product)
        let rounded = division.quotient
            + (division.remainder >= scale / 2 ? 1 : 0)
        guard let coordinate = UInt16(exactly: rounded) else {
            throw TapActionError.invalidCoordinate
        }
        return coordinate
    }

    private func cleanupAcknowledgement() throws {
        do {
            try transport.waitForCleanupAcknowledgement(
                timeoutMilliseconds: Self.cleanupAcknowledgementMilliseconds
            )
        } catch {
            throw TapActionError.cleanupAcknowledgementMissing
        }
    }
}
