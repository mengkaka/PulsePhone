import Foundation
import PulsePhoneRuntimeKernel
import PulsePhoneSharedDefinitions

enum ProductionRuntimeCoordinateProjectionError: Error, Equatable, Sendable {
    case invalidCoordinate
    case invalidEdge
    case staleGeometry
    case unknownStream
}

struct ProductionRuntimeProjectedPoint: Equatable, Sendable {
    let x: UInt16
    let y: UInt16
    let edge: String
}

struct ProductionRuntimeCoordinateProjection: Equatable, Sendable {
    let geometry: DisplayGeometryDTO

    func project(x: String, y: String, edge: String) throws
        -> ProductionRuntimeProjectedPoint
    {
        let visualX = try NormalizedRational(x)
        let visualY = try NormalizedRational(y)
        let digitizer: (NormalizedRational, NormalizedRational)
        switch geometry.orientation {
        case .portrait:
            digitizer = (visualX, visualY)
        case .landscapeRight:
            digitizer = (visualY, visualX.complement)
        case .portraitUpsideDown:
            digitizer = (visualX.complement, visualY.complement)
        case .landscapeLeft:
            digitizer = (visualY.complement, visualX)
        }
        return ProductionRuntimeProjectedPoint(
            x: try digitizer.0.projectedAxis(),
            y: try digitizer.1.projectedAxis(),
            edge: try projectedEdge(edge)
        )
    }

    private func projectedEdge(_ edge: String) throws -> String {
        let edges = ["top", "right", "bottom", "left"]
        guard edge == "none" || edges.contains(edge) else {
            throw ProductionRuntimeCoordinateProjectionError.invalidEdge
        }
        guard edge != "none" else { return edge }
        let mapped: [String]
        switch geometry.orientation {
        case .portrait:
            mapped = ["top", "right", "bottom", "left"]
        case .landscapeRight:
            mapped = ["left", "top", "right", "bottom"]
        case .portraitUpsideDown:
            mapped = ["bottom", "left", "top", "right"]
        case .landscapeLeft:
            mapped = ["right", "bottom", "left", "top"]
        }
        guard let index = edges.firstIndex(of: edge) else {
            throw ProductionRuntimeCoordinateProjectionError.invalidEdge
        }
        return mapped[index]
    }
}

final class ProductionRuntimeCoordinateProjectionStore: @unchecked Sendable {
    private enum Entry {
        case keyboard(interactionID: CanonicalUUID)
        case pointer(
            interactionID: CanonicalUUID,
            projection: ProductionRuntimeCoordinateProjection
        )
    }

    private let lock = NSLock()
    private var entries = [String: Entry]()

    func registerKeyboard(
        sessionID: CanonicalUUID,
        interactionID: CanonicalUUID
    ) {
        lock.withLock {
            entries[sessionID.canonicalString] = .keyboard(
                interactionID: interactionID
            )
        }
    }

    func registerPointer(
        sessionID: CanonicalUUID,
        interactionID: CanonicalUUID,
        geometry: DisplayGeometryDTO
    ) {
        lock.withLock {
            entries[sessionID.canonicalString] = .pointer(
                interactionID: interactionID,
                projection: ProductionRuntimeCoordinateProjection(
                    geometry: geometry
                )
            )
        }
    }

    func remove(
        sessionID: CanonicalUUID,
        interactionID: CanonicalUUID
    ) {
        lock.withLock {
            guard let entry = entries[sessionID.canonicalString],
                  Self.interactionID(entry) == interactionID
            else { return }
            entries.removeValue(forKey: sessionID.canonicalString)
        }
    }

    func invalidateAll() {
        lock.withLock { entries.removeAll(keepingCapacity: true) }
    }

    func payload(
        for frame: RuntimeStreamFrameEnvelope,
        currentGeometry: DisplayGeometryDTO?
    ) throws
        -> RepositoryJSONObject
    {
        let entry = lock.withLock { entries[frame.sessionID.canonicalString] }
        guard let entry,
              Self.interactionID(entry) == frame.interactionID
        else {
            throw ProductionRuntimeCoordinateProjectionError.unknownStream
        }
        switch entry {
        case .keyboard:
            return frame.payload
        case .pointer(_, let projection):
            guard currentGeometry == projection.geometry,
            let expectedConnectionEpoch = frame.payload[
                "expectedConnectionEpoch"
            ]?.numberValue.flatMap({ try? $0.requireUInt64() }),
            let expectedGeometryRevision = frame.payload[
                "expectedGeometryRevision"
            ]?.numberValue.flatMap({ try? $0.requireUInt64() }),
            expectedConnectionEpoch == projection.geometry.connectionEpoch,
            expectedGeometryRevision == projection.geometry.geometryRevision,
            let x = frame.payload["x"]?.stringValue,
            let y = frame.payload["y"]?.stringValue,
            let edge = frame.payload["edge"]?.stringValue
            else {
                throw ProductionRuntimeCoordinateProjectionError.staleGeometry
            }
            let point = try projection.project(x: x, y: y, edge: edge)
            var members = frame.payload.members.filter {
                $0.key != "x" && $0.key != "y" && $0.key != "edge"
            }
            members.append(RepositoryJSONMember(
                key: "edge",
                value: .string(point.edge)
            ))
            members.append(RepositoryJSONMember(
                key: "x",
                value: .number(.uint64(UInt64(point.x)))
            ))
            members.append(RepositoryJSONMember(
                key: "y",
                value: .number(.uint64(UInt64(point.y)))
            ))
            return try RepositoryJSONObject(members: members)
        }
    }

    private static func interactionID(_ entry: Entry) -> CanonicalUUID {
        switch entry {
        case .keyboard(let interactionID), .pointer(let interactionID, _):
            return interactionID
        }
    }
}

private struct NormalizedRational: Equatable, Sendable {
    let numerator: UInt64
    let scale: UInt64

    init(_ value: String) throws {
        if value == "0" {
            numerator = 0
            scale = 1
            return
        }
        if value == "1" {
            numerator = 1
            scale = 1
            return
        }
        guard value.hasPrefix("0."), !value.hasSuffix("0") else {
            throw ProductionRuntimeCoordinateProjectionError.invalidCoordinate
        }
        let digits = value.dropFirst(2)
        guard !digits.isEmpty,
              digits.count <= 18,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let parsed = UInt64(digits)
        else {
            throw ProductionRuntimeCoordinateProjectionError.invalidCoordinate
        }
        var parsedScale: UInt64 = 1
        for _ in digits {
            let (next, overflow) = parsedScale.multipliedReportingOverflow(by: 10)
            guard !overflow else {
                throw ProductionRuntimeCoordinateProjectionError.invalidCoordinate
            }
            parsedScale = next
        }
        guard parsed < parsedScale else {
            throw ProductionRuntimeCoordinateProjectionError.invalidCoordinate
        }
        numerator = parsed
        scale = parsedScale
    }

    var complement: NormalizedRational {
        NormalizedRational(numerator: scale - numerator, scale: scale)
    }

    func projectedAxis() throws -> UInt16 {
        let product = numerator.multipliedFullWidth(by: UInt64(UInt16.max))
        let division = scale.dividingFullWidth(product)
        let rounded = division.quotient
            + (division.remainder * 2 >= scale ? 1 : 0)
        guard let value = UInt16(exactly: rounded) else {
            throw ProductionRuntimeCoordinateProjectionError.invalidCoordinate
        }
        return value
    }

    private init(numerator: UInt64, scale: UInt64) {
        self.numerator = numerator
        self.scale = scale
    }
}
