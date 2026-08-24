import Foundation

public enum RepositoryContractArtifactSetError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidRelativePath(String)
    case invalidSHA256(String)
    case duplicateRelativePath(String)
    case entriesNotSorted
}

public struct RepositoryContractArtifactSetV1: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let relativePath: String
        public let sha256: String

        public init(relativePath: String, sha256: String) throws {
            try RepositoryContractArtifactSetV1.validateRelativePath(relativePath)
            guard StableBytes.isLowercaseHex(sha256, byteCount: 32) else {
                throw RepositoryContractArtifactSetError.invalidSHA256(sha256)
            }
            self.relativePath = relativePath
            self.sha256 = sha256
        }
    }

    public let schemaVersion: UInt64
    public let setID: String
    public let revision: String
    public let entries: [Entry]

    public init(setID: String, revision: String, entries: [Entry]) throws {
        guard Self.isBoundedASCIIIdentifier(setID, maximumByteCount: 128),
              Self.isBoundedASCIIIdentifier(revision, maximumByteCount: 128)
        else {
            throw RepositoryContractArtifactSetError.invalidIdentifier
        }
        let paths = entries.map(\.relativePath)
        guard Set(paths).count == paths.count else {
            let duplicate = paths.first { path in
                paths.filter { $0 == path }.count > 1
            } ?? ""
            throw RepositoryContractArtifactSetError.duplicateRelativePath(duplicate)
        }
        guard paths == paths.sorted(by: Self.asciiLessThan) else {
            throw RepositoryContractArtifactSetError.entriesNotSorted
        }
        self.schemaVersion = 1
        self.setID = setID
        self.revision = revision
        self.entries = entries
    }

    public var canonicalBytes: [UInt8] {
        RepositoryCanonicalJSON.encodeDocument(canonicalObject)
    }

    public var sha256Hex: String {
        StableBytes.sha256Hex(canonicalBytes)
    }

    public func domainSeparatedHash(domainID: String) throws -> String {
        try StableBytes.domainSeparatedSHA256Hex(
            domainID: domainID,
            payload: canonicalBytes
        )
    }

    private var canonicalObject: RepositoryJSONObject {
        let entryValues = entries.map { entry in
            RepositoryJSONValue.object(
                RepositoryJSONObject(validatedMembers: [
                    RepositoryJSONMember(
                        key: "relativePath",
                        value: .string(entry.relativePath)
                    ),
                    RepositoryJSONMember(
                        key: "sha256",
                        value: .string(entry.sha256)
                    ),
                ])
            )
        }
        return RepositoryJSONObject(validatedMembers: [
            RepositoryJSONMember(key: "entries", value: .array(entryValues)),
            RepositoryJSONMember(key: "revision", value: .string(revision)),
            RepositoryJSONMember(
                key: "schemaVersion",
                value: .number(.uint64(schemaVersion))
            ),
            RepositoryJSONMember(key: "setID", value: .string(setID)),
        ])
    }

    static func validateRelativePath(_ value: String) throws {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty,
              bytes.count <= EvidenceContractHardCaps.normalizedRelativePathBytes,
              bytes.allSatisfy({ $0 < 0x80 }),
              !value.hasPrefix("/"),
              !value.hasSuffix("/"),
              !value.contains("\\")
        else {
            throw RepositoryContractArtifactSetError.invalidRelativePath(value)
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RepositoryContractArtifactSetError.invalidRelativePath(value)
        }
    }

    static func asciiLessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func isBoundedASCIIIdentifier(
        _ value: String,
        maximumByteCount: Int
    ) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty
            && bytes.count <= maximumByteCount
            && bytes.allSatisfy { (0x21...0x7e).contains($0) }
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("://")
    }
}
