public enum DisplayOrientationDTO: String, Codable, CaseIterable, Sendable {
    case landscapeLeft
    case landscapeRight
    case portrait
    case portraitUpsideDown
}

public enum GeometryDTOValidationError: Error, Equatable, Sendable {
    case invalidLogicalSize
    case connectionEpochMismatch(expected: UInt64, actual: UInt64)
    case geometryRevisionMismatch(expected: UInt64, actual: UInt64)
}

public struct DisplayGeometryDTO: Codable, Equatable, Sendable {
    public let connectionEpoch: UInt64
    public let geometryRevision: UInt64
    public let logicalHeight: UInt64
    public let logicalWidth: UInt64
    public let orientation: DisplayOrientationDTO

    public init(
        connectionEpoch: UInt64,
        geometryRevision: UInt64,
        logicalHeight: UInt64,
        logicalWidth: UInt64,
        orientation: DisplayOrientationDTO
    ) throws {
        guard logicalHeight > 0, logicalWidth > 0 else {
            throw GeometryDTOValidationError.invalidLogicalSize
        }
        self.connectionEpoch = connectionEpoch
        self.geometryRevision = geometryRevision
        self.logicalHeight = logicalHeight
        self.logicalWidth = logicalWidth
        self.orientation = orientation
    }
}

public struct GeometryAssertionDTO: Codable, Equatable, Sendable {
    public let expectedConnectionEpoch: UInt64
    public let expectedGeometryRevision: UInt64

    public init(
        expectedConnectionEpoch: UInt64,
        expectedGeometryRevision: UInt64
    ) {
        self.expectedConnectionEpoch = expectedConnectionEpoch
        self.expectedGeometryRevision = expectedGeometryRevision
    }

    public func validate(_ geometry: DisplayGeometryDTO) throws {
        guard expectedConnectionEpoch == geometry.connectionEpoch else {
            throw GeometryDTOValidationError.connectionEpochMismatch(
                expected: expectedConnectionEpoch,
                actual: geometry.connectionEpoch
            )
        }
        guard expectedGeometryRevision == geometry.geometryRevision else {
            throw GeometryDTOValidationError.geometryRevisionMismatch(
                expected: expectedGeometryRevision,
                actual: geometry.geometryRevision
            )
        }
    }
}
