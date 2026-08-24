import Darwin
import Foundation

public enum FixtureCaseError: Error, Equatable, Sendable {
    case repositoryRootNotFound
    case invalidRequirementID
    case invalidManifest
    case unsafePath(String)
    case unsafeNode(String)
    case missingInput(String)
    case inputHashMismatch(String)
    case inputCoverageMismatch
}

public struct FixtureCaseV1: Codable, Equatable, Sendable {
    public struct InputRef: Codable, Equatable, Sendable {
        public let relativePath: String
        public let sha256: String
    }

    public let schemaVersion: UInt64
    public let caseKey: String
    public let title: String
    public let primaryVerificationID: String
    public let verificationIDs: [String]
    public let contractRefs: [String]
    public let level: String
    public let caseClass: String
    public let inputRefs: [InputRef]
    public let preconditions: [String]
    public let clockMode: String
    public let fixtureExecutionProfileID: String
    public let faultInjectionRef: String?
    public let expectedRef: String
    public let privacyClass: String
}

public struct FixtureCaseBundleV1: Sendable {
    public let manifest: FixtureCaseV1
    public let rootURL: URL

    public func inputData(relativePath: String = "input/input.v1.json") throws -> Data {
        try Self.readSafeRegularFile(
            rootURL.appendingPathComponent(relativePath),
            relativePath: relativePath
        )
    }

    public func expectedData() throws -> Data {
        try Self.readSafeRegularFile(
            rootURL.appendingPathComponent(manifest.expectedRef),
            relativePath: manifest.expectedRef
        )
    }

    public func decodeInput<Value: Decodable>(
        _ type: Value.Type,
        relativePath: String = "input/input.v1.json"
    ) throws -> Value {
        try JSONDecoder().decode(type, from: inputData(relativePath: relativePath))
    }

    public func decodeExpected<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try JSONDecoder().decode(type, from: expectedData())
    }

    static func readSafeRegularFile(
        _ url: URL,
        relativePath: String
    ) throws -> Data {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw FixtureCaseError.missingInput(relativePath)
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_nlink == 1
        else {
            throw FixtureCaseError.unsafeNode(relativePath)
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }
}

public enum FixtureCaseLoaderV1 {
    public static func repositoryRoot(containing filePath: String) throws -> URL {
        var candidate = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        while candidate.path != "/" {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("Package.swift").path
            ) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw FixtureCaseError.repositoryRootNotFound
    }

    public static func load(
        requirementID: String,
        repositoryRoot: URL
    ) throws -> FixtureCaseBundleV1 {
        guard requirementID.range(
            of: #"^T-[0-9]{3}/[a-z0-9]+(?:-[a-z0-9]+)*-l[0-5]$"#,
            options: .regularExpression
        ) != nil else {
            throw FixtureCaseError.invalidRequirementID
        }
        let root = repositoryRoot
            .appendingPathComponent("Fixtures/requirements", isDirectory: true)
            .appendingPathComponent(requirementID, isDirectory: true)
        var rootMetadata = stat()
        guard lstat(root.path, &rootMetadata) == 0,
              rootMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            throw FixtureCaseError.unsafeNode(requirementID)
        }
        let manifestURL = root.appendingPathComponent("case.v1.json")
        let manifestData = try FixtureCaseBundleV1.readSafeRegularFile(
            manifestURL,
            relativePath: "case.v1.json"
        )
        _ = try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](manifestData),
            maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
        )
        let manifest = try JSONDecoder().decode(FixtureCaseV1.self, from: manifestData)
        guard manifest.schemaVersion == 1,
              manifest.caseKey == requirementID,
              manifest.primaryVerificationID == String(requirementID.prefix(5)),
              manifest.verificationIDs == [manifest.primaryVerificationID],
              manifest.privacyClass == "synthetic",
              ["L0", "L1", "L2", "L3", "L4", "L5"].contains(manifest.level),
              ["boundary", "concurrency", "fault", "negative", "positive"].contains(manifest.caseClass),
              ["real", "virtual"].contains(manifest.clockMode),
              ["isolatedHost", "processHarness", "syntheticContract"].contains(
                  manifest.fixtureExecutionProfileID
              )
        else {
            throw FixtureCaseError.invalidManifest
        }
        try validateRelativeFilePath(manifest.expectedRef)
        _ = try FixtureCaseBundleV1.readSafeRegularFile(
            root.appendingPathComponent(manifest.expectedRef),
            relativePath: manifest.expectedRef
        )

        let refPaths = manifest.inputRefs.map(\.relativePath)
        guard refPaths == refPaths.sorted(by: asciiLessThan),
              Set(refPaths).count == refPaths.count
        else {
            throw FixtureCaseError.invalidManifest
        }
        var referenced = Set<String>()
        for inputRef in manifest.inputRefs {
            try validateRelativeFilePath(inputRef.relativePath)
            guard inputRef.relativePath.hasPrefix("input/")
                    || inputRef.relativePath.hasPrefix("scripts/")
            else {
                throw FixtureCaseError.unsafePath(inputRef.relativePath)
            }
            let data = try FixtureCaseBundleV1.readSafeRegularFile(
                root.appendingPathComponent(inputRef.relativePath),
                relativePath: inputRef.relativePath
            )
            guard StableBytes.sha256Hex([UInt8](data)) == inputRef.sha256 else {
                throw FixtureCaseError.inputHashMismatch(inputRef.relativePath)
            }
            referenced.insert(inputRef.relativePath)
        }
        let actual = try fixtureInputPaths(root: root)
        guard actual == referenced else {
            throw FixtureCaseError.inputCoverageMismatch
        }
        return FixtureCaseBundleV1(manifest: manifest, rootURL: root)
    }

    private static func fixtureInputPaths(root: URL) throws -> Set<String> {
        var result = Set<String>()
        for directoryName in ["input", "scripts"] {
            let directory = root.appendingPathComponent(directoryName, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else {
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            ) else {
                throw FixtureCaseError.unsafeNode(directoryName)
            }
            for case let url as URL in enumerator {
                var metadata = stat()
                guard lstat(url.path, &metadata) == 0 else {
                    throw FixtureCaseError.unsafeNode(url.path)
                }
                if metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                    continue
                }
                guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                      metadata.st_nlink == 1
                else {
                    throw FixtureCaseError.unsafeNode(url.path)
                }
                result.insert(url.path.replacingOccurrences(of: root.path + "/", with: ""))
            }
        }
        return result
    }

    private static func validateRelativeFilePath(_ value: String) throws {
        do {
            try RepositoryContractArtifactSetV1.validateRelativePath(value)
        } catch {
            throw FixtureCaseError.unsafePath(value)
        }
    }

    private static func asciiLessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}
