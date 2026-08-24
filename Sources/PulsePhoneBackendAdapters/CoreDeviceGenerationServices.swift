public enum CoreDeviceGenerationFacet: String, CaseIterable, Hashable, Sendable {
    case appControl
    case button
    case hid
    case keyboard
    case orientation
    case pasteboard
    case screenshot
}

public enum CoreDeviceServiceSetError: Error, Equatable, Sendable {
    case invalidSurfaceRevision
    case duplicateFacet
    case missingPreparationFacet
}

public struct CoreDeviceServiceSet: Equatable, Sendable {
    public static let preparationFacets = CoreDeviceGenerationFacet.allCases

    public let surfaceRevision: String
    public let facets: [CoreDeviceGenerationFacet]

    public init(
        surfaceRevision: String,
        facets: [CoreDeviceGenerationFacet]
    ) throws {
        let revisionBytes = Array(surfaceRevision.utf8)
        guard (1...128).contains(revisionBytes.count),
              revisionBytes.allSatisfy({ (0x21...0x7e).contains($0) })
        else {
            throw CoreDeviceServiceSetError.invalidSurfaceRevision
        }
        guard Set(facets).count == facets.count else {
            throw CoreDeviceServiceSetError.duplicateFacet
        }
        let normalized = facets.sorted {
            $0.rawValue.utf8.lexicographicallyPrecedes($1.rawValue.utf8)
        }
        guard Set(Self.preparationFacets).isSubset(of: Set(normalized)) else {
            throw CoreDeviceServiceSetError.missingPreparationFacet
        }
        self.surfaceRevision = surfaceRevision
        self.facets = normalized
    }
}
