import Darwin
import Foundation
import PulsePhoneDeveloperImageAssets
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneSharedDefinitions
import XCTest

struct AssetAcquisitionEntrySpec {
    let archiveSHA256: String
    let entryID: String
    let image: Data
    let signature: Data
    let sourceURLs: [String]

    init(
        archiveSHA256: String = String(repeating: "a", count: 64),
        entryID: String,
        image: Data,
        signature: Data,
        sourceURLs: [String] = [
            "https://approved.example.invalid/developer-image.zip"
        ]
    ) {
        self.archiveSHA256 = archiveSHA256
        self.entryID = entryID
        self.image = image
        self.signature = signature
        self.sourceURLs = sourceURLs
    }

    var archiveEntries: [DeveloperImageArchiveEntry] {
        [
            DeveloperImageArchiveEntry(
                path: "DeveloperDiskImage.dmg",
                kind: .regularFile,
                bytes: image
            ),
            DeveloperImageArchiveEntry(
                path: "DeveloperDiskImage.dmg.signature",
                kind: .regularFile,
                bytes: signature
            ),
        ]
    }
}

struct AssetAcquisitionExpected: Decodable {
    let boundedWaitFailsBusy: Bool?
    let canonicalCorruptionRebuilt: Bool?
    let downloadCount: Int?
    let exactIdentityResumes: Bool?
    let externalTargetUnchanged: Bool?
    let fallbackNeverReturnsToFailedSource: Bool?
    let identityMismatchRestartsAtZero: Bool?
    let initialRequestsPerSource: Int?
    let kernelLockAuthoritative: Bool?
    let maximumChunkBytes: Int?
    let maximumConcurrentOwners: Int?
    let outcome: String
    let resumeRequestsPerSource: Int?
    let sharedAssetKey: Bool?
    let staleMetadataIgnored: Bool?
    let storeLockReleasedOnBusyAsset: Bool?
    let strongETagRequired: Bool?
    let takeoverAfterRelease: Bool?
    let unsafeNodeRejected: Bool?
}

struct AssetAcquisitionHTTPModel: Decodable {
    struct Response: Decodable {
        let contentLength: UInt64
        let contentRangeStart: UInt64?
        let statusCode: Int
        let strongETag: String?
    }

    let corruptions: [String]?
    let mismatchDimensions: [String]?
    let responses: [Response]?
    let schemaVersion: Int
}

func makeAssetAcquisitionCatalog(
    revision: String,
    entries: [AssetAcquisitionEntrySpec]
) throws -> DeveloperImageCatalogV1 {
    let entryObjects: [[String: Any]] = entries.sorted {
        $0.entryID < $1.entryID
    }.map { entry in
        [
            "archiveSHA256": entry.archiveSHA256,
            "archiveSize": entry.image.count + entry.signature.count,
            "buildID": "20H350",
            "compatibilityRuleID": "compat.preparation.legacy-developer.v2",
            "ddiVersion": "16.7",
            "deviceOSRange": [
                "exactBuilds": ["20H350"],
                "maximumMajorExclusive": 17,
                "minimumMajor": 16,
            ],
            "entryID": entry.entryID,
            "evidenceState": "target",
            "extractedUpperBound": entry.image.count + entry.signature.count,
            "files": [
                [
                    "archiveRelativePath": "DeveloperDiskImage.dmg",
                    "fileRole": "classic.image",
                    "sha256": StableBytes.sha256Hex(entry.image),
                    "size": entry.image.count,
                ],
                [
                    "archiveRelativePath": "DeveloperDiskImage.dmg.signature",
                    "fileRole": "classic.signature",
                    "sha256": StableBytes.sha256Hex(entry.signature),
                    "size": entry.signature.count,
                ],
            ],
            "imageKind": "classic",
            "requiredServices": ["com.apple.mobile.screenshotr"],
            "sourceURLs": entry.sourceURLs,
        ]
    }
    let data = try assetAcquisitionCanonicalJSONData([
        "catalogRevision": revision,
        "entries": entryObjects,
        "schemaVersion": 1,
    ])
    return try DeveloperImageCatalog.decodeCanonical([UInt8](data))
}

func makeAssetAcquisitionPartialState(
    assetKey: String,
    bytes: Data,
    catalogIdentity: DeveloperImageCatalogIdentity,
    entry: DeveloperImageCatalogEntryV1,
    overrides: [String: Any] = [:]
) throws -> PartialDownloadStateV1 {
    var object: [String: Any] = [
        "acquisitionAttemptID": "attempt.acquisition-fault.v1",
        "archiveSHA256": entry.archiveSHA256,
        "archiveSize": entry.archiveSize,
        "assetKey": assetKey,
        "catalogEntryID": entry.entryID,
        "catalogRevision": catalogIdentity.revision,
        "developerImageCatalogHash": catalogIdentity.hash,
        "receivedBytes": bytes.count,
        "sourceIndex": 0,
        "sourceURLIdentityHash": try DeveloperImageSourcePolicy.sourceURLIdentityHash(
            entry.sourceURLs[0]
        ),
        "strongETag": "\"etag-v1\"",
    ]
    for (key, value) in overrides {
        if value is NSNull {
            object.removeValue(forKey: key)
        } else {
            object[key] = value
        }
    }
    return try JSONDecoder().decode(
        PartialDownloadStateV1.self,
        from: assetAcquisitionCanonicalJSONData(object)
    )
}

func assetAcquisitionFixture(_ requirementID: String) throws -> FixtureCaseBundleV1 {
    try FixtureCaseLoaderV1.load(
        requirementID: requirementID,
        repositoryRoot: FixtureCaseLoaderV1.repositoryRoot(containing: #filePath)
    )
}

func assetAcquisitionHTTPModel(_ relativePath: String) throws -> AssetAcquisitionHTTPModel {
    let root = try FixtureCaseLoaderV1.repositoryRoot(containing: #filePath)
    let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
    return try JSONDecoder().decode(AssetAcquisitionHTTPModel.self, from: data)
}

func makeAssetAcquisitionStore() throws -> DeveloperImageAssetStore {
    try DeveloperImageAssetStore(
        rootURL: try assetAcquisitionTemporaryDirectory()
            .appendingPathComponent("DeveloperImages")
    )
}

func assetAcquisitionTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("pulsephone-acquisition-faults-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false
    )
    chmod(url.path, 0o700)
    return url
}

func assetAcquisitionCanonicalJSONData(_ object: Any) throws -> Data {
    let encoded = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys]
    )
    let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        .replacingOccurrences(of: "\\/", with: "/")
    return Data(text.utf8)
}

final class AssetAcquisitionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var activeOwners = 0
    private var downloadStorage = 0
    private var maximumOwners = 0

    var downloadCount: Int {
        lock.withLock { downloadStorage }
    }

    var maximumConcurrentOwners: Int {
        lock.withLock { maximumOwners }
    }

    func enterOwner() {
        lock.withLock {
            activeOwners += 1
            maximumOwners = max(maximumOwners, activeOwners)
        }
    }

    func leaveOwner() {
        lock.withLock { activeOwners -= 1 }
    }

    func recordDownload() {
        lock.withLock { downloadStorage += 1 }
    }
}

final class AssetAcquisitionErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [any Error]()

    var values: [any Error] {
        lock.withLock { storage }
    }

    func append(_ error: any Error) {
        lock.withLock { storage.append(error) }
    }
}
