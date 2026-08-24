import Darwin
import Foundation

public enum RepositoryContractResolverError: Error, Equatable, Sendable {
    case missing(String)
    case unsafeNode(String)
    case duplicateNodeIdentity(String)
    case invalidCanonicalJSON(String)
}

public enum RepositoryContractResolver {
    public static func resolve(
        repositoryRoot: URL,
        setID: String,
        revision: String,
        relativePaths: [String],
        maximumDocumentByteCount: Int = EvidenceContractHardCaps.otherCanonicalDocumentBytes
    ) throws -> RepositoryContractArtifactSetV1 {
        let sorted = relativePaths.sorted(by: RepositoryContractArtifactSetV1.asciiLessThan)
        guard sorted == relativePaths, Set(sorted).count == sorted.count else {
            throw RepositoryContractArtifactSetError.entriesNotSorted
        }

        var identities = Set<NodeIdentity>()
        var entries = [RepositoryContractArtifactSetV1.Entry]()
        for relativePath in sorted {
            try RepositoryContractArtifactSetV1.validateRelativePath(relativePath)
            let url = repositoryRoot.appendingPathComponent(relativePath)
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else {
                throw RepositoryContractResolverError.missing(relativePath)
            }
            guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  metadata.st_nlink == 1
            else {
                throw RepositoryContractResolverError.unsafeNode(relativePath)
            }
            let identity = NodeIdentity(device: metadata.st_dev, inode: metadata.st_ino)
            guard identities.insert(identity).inserted else {
                throw RepositoryContractResolverError.duplicateNodeIdentity(relativePath)
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            do {
                _ = try RepositoryCanonicalJSON.validateCanonicalDocument(
                    [UInt8](data),
                    maximumByteCount: maximumDocumentByteCount
                )
            } catch {
                throw RepositoryContractResolverError.invalidCanonicalJSON(relativePath)
            }
            entries.append(
                try RepositoryContractArtifactSetV1.Entry(
                    relativePath: relativePath,
                    sha256: StableBytes.sha256Hex([UInt8](data))
                )
            )
        }
        return try RepositoryContractArtifactSetV1(
            setID: setID,
            revision: revision,
            entries: entries
        )
    }
}

private struct NodeIdentity: Hashable {
    let device: dev_t
    let inode: ino_t
}
