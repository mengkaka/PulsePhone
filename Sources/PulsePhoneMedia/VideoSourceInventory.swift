import Foundation
import PulsePhoneSharedDefinitions

public enum VideoSourceInventoryError: Error, Equatable, Sendable {
    case duplicateSourceID
    case invalidActiveFormat
    case invalidMappingProofID
    case invalidSourceID
    case invalidSourceEpoch
    case invalidSourceName
    case mappingReferencesUnknownSource
    case mappingSourceEpochMismatch
}

public enum VideoSourceClassification: String, Equatable, Sendable {
    case knownNonPhone
    case qualifiedPhoneScreen
    case residual
}

public struct VideoSourceDescriptor: Equatable, Sendable {
    public let activeFormatHeight: UInt64
    public let activeFormatWidth: UInt64
    public let classification: VideoSourceClassification
    public let displayName: String
    public let sourceEpoch: UInt64
    public let sourceID: String

    public init(
        sourceID: String,
        sourceEpoch: UInt64,
        activeFormatWidth: UInt64,
        activeFormatHeight: UInt64,
        displayName: String = "Video Source",
        classification: VideoSourceClassification = .residual
    ) throws {
        guard Self.validIdentifier(sourceID) else {
            throw VideoSourceInventoryError.invalidSourceID
        }
        guard sourceEpoch > 0 else {
            throw VideoSourceInventoryError.invalidSourceEpoch
        }
        guard (activeFormatWidth == 0) == (activeFormatHeight == 0) else {
            throw VideoSourceInventoryError.invalidActiveFormat
        }
        let displayNameBytes = Array(displayName.utf8)
        guard (1...256).contains(displayNameBytes.count),
              !displayName.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw VideoSourceInventoryError.invalidSourceName
        }
        self.sourceID = sourceID
        self.sourceEpoch = sourceEpoch
        self.activeFormatWidth = activeFormatWidth
        self.activeFormatHeight = activeFormatHeight
        self.displayName = displayName
        self.classification = classification
    }

    public var hasActiveFormat: Bool {
        activeFormatWidth > 0
    }

    fileprivate static func validIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...512).contains(bytes.count)
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }
}

public struct VideoSourceMappingClaim: Equatable, Sendable {
    public let canonicalUDID: CanonicalUDID
    public let mappingProofID: String
    public let sourceEpoch: UInt64
    public let sourceID: String

    public init(
        sourceID: String,
        sourceEpoch: UInt64,
        canonicalUDID: CanonicalUDID,
        mappingProofID: String
    ) throws {
        guard VideoSourceDescriptor.validIdentifier(sourceID) else {
            throw VideoSourceInventoryError.invalidSourceID
        }
        guard sourceEpoch > 0 else {
            throw VideoSourceInventoryError.invalidSourceEpoch
        }
        guard Self.validProofID(mappingProofID) else {
            throw VideoSourceInventoryError.invalidMappingProofID
        }
        self.sourceID = sourceID
        self.sourceEpoch = sourceEpoch
        self.canonicalUDID = canonicalUDID
        self.mappingProofID = mappingProofID
    }

    private static func validProofID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...128).contains(bytes.count)
            && bytes.allSatisfy { (0x21...0x7e).contains($0) }
    }
}

public struct VideoResolvedSource: Equatable, Sendable {
    public let canonicalUDID: CanonicalUDID
    public let descriptor: VideoSourceDescriptor
    public let mappingProofID: String

    public init(
        canonicalUDID: CanonicalUDID,
        descriptor: VideoSourceDescriptor,
        mappingProofID: String
    ) {
        self.canonicalUDID = canonicalUDID
        self.descriptor = descriptor
        self.mappingProofID = mappingProofID
    }
}

public enum VideoSourceResolution: Equatable, Sendable {
    case ambiguous(sourceIDs: [String])
    case mapped(VideoResolvedSource)
    case unavailable
}

public enum CachedVideoSourceMappingResolver {
    public static func resolve(
        target canonicalUDID: CanonicalUDID,
        sourceID: String,
        mappingProofID: String,
        sources: [VideoSourceDescriptor]
    ) throws -> VideoSourceResolution {
        let matches = sources.filter { $0.sourceID == sourceID }
        guard !matches.isEmpty else { return .unavailable }
        guard matches.count == 1 else {
            return .ambiguous(sourceIDs: matches.map(\.sourceID))
        }
        let descriptor = matches[0]
        let claim = try VideoSourceMappingClaim(
            sourceID: sourceID,
            sourceEpoch: descriptor.sourceEpoch,
            canonicalUDID: canonicalUDID,
            mappingProofID: mappingProofID
        )
        return .mapped(VideoResolvedSource(
            canonicalUDID: canonicalUDID,
            descriptor: descriptor,
            mappingProofID: claim.mappingProofID
        ))
    }
}

public struct VideoSourceInventory: Equatable, Sendable {
    public let inventoryRevision: UInt64
    public let sources: [VideoSourceDescriptor]

    public init(
        inventoryRevision: UInt64,
        sources: [VideoSourceDescriptor]
    ) throws {
        guard inventoryRevision > 0 else {
            throw VideoSourceInventoryError.invalidSourceEpoch
        }
        let sorted = sources.sorted {
            $0.sourceID.utf8.lexicographicallyPrecedes($1.sourceID.utf8)
        }
        guard Set(sorted.map(\.sourceID)).count == sorted.count else {
            throw VideoSourceInventoryError.duplicateSourceID
        }
        self.inventoryRevision = inventoryRevision
        self.sources = sorted
    }

    public func resolve(
        target canonicalUDID: CanonicalUDID,
        claims: [VideoSourceMappingClaim]
    ) throws -> VideoSourceResolution {
        let sourceByID = Dictionary(uniqueKeysWithValues: sources.map {
            ($0.sourceID, $0)
        })
        for claim in claims {
            guard let source = sourceByID[claim.sourceID] else {
                throw VideoSourceInventoryError.mappingReferencesUnknownSource
            }
            guard source.sourceEpoch == claim.sourceEpoch else {
                throw VideoSourceInventoryError.mappingSourceEpochMismatch
            }
        }
        let matches = claims.compactMap { claim -> VideoResolvedSource? in
            guard claim.canonicalUDID == canonicalUDID,
                  let source = sourceByID[claim.sourceID]
            else { return nil }
            return VideoResolvedSource(
                canonicalUDID: canonicalUDID,
                descriptor: source,
                mappingProofID: claim.mappingProofID
            )
        }
        guard !matches.isEmpty else { return .unavailable }
        guard matches.count == 1 else {
            return .ambiguous(sourceIDs: matches.map {
                $0.descriptor.sourceID
            }.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
        }
        return .mapped(matches[0])
    }
}
