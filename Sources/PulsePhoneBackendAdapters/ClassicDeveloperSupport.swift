import Foundation
import PulsePhoneDeveloperImageAssets
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneSharedDefinitions

public enum ClassicDeveloperSupportError: Error, Equatable, Sendable {
    case unsupportedImageKind
    case invalidCatalogReference
    case missingClassicRole(String)
    case invalidOperation
}

public enum ClassicDeveloperSupportOperation: String, Equatable, Sendable {
    case queryMounted
    case mount
    case probeServices
}

public struct ClassicHelperDeviceContext: Equatable, Sendable {
    public let connectionEpoch: UInt64

    public init(connectionEpoch: UInt64) {
        self.connectionEpoch = connectionEpoch
    }
}

public struct ClassicHelperBackendPayload: Equatable, Sendable {
    public let assetContentManifestSHA256: String
    public let catalogCanonicalSHA256: String
    public let catalogRevision: String
    public let deviceContext: ClassicHelperDeviceContext
    public let fileRoles: [String]
    public let operation: ClassicDeveloperSupportOperation
    public let preparationAttemptID: CanonicalUUID
    public let preparationGroupID: String

    public init(
        assetContentManifestSHA256: String,
        catalogCanonicalSHA256: String,
        catalogRevision: String,
        deviceContext: ClassicHelperDeviceContext,
        fileRoles: [String],
        operation: ClassicDeveloperSupportOperation,
        preparationAttemptID: CanonicalUUID,
        preparationGroupID: String
    ) {
        self.assetContentManifestSHA256 = assetContentManifestSHA256
        self.catalogCanonicalSHA256 = catalogCanonicalSHA256
        self.catalogRevision = catalogRevision
        self.deviceContext = deviceContext
        self.fileRoles = fileRoles
        self.operation = operation
        self.preparationAttemptID = preparationAttemptID
        self.preparationGroupID = preparationGroupID
    }
}

public enum ClassicHelperRequestFactory {
    /// Transitional fixture adapter; runtime production calls the dynamic
    /// snapshot overload once the catalog store has been injected.
    public static func make(
        operation: ClassicDeveloperSupportOperation,
        catalog: DeveloperImageCatalogV1,
        entryID: String,
        connectionEpoch: UInt64,
        preparationAttemptID: CanonicalUUID
    ) throws -> ClassicHelperBackendPayload {
        guard let entry = catalog.entries.first(where: { $0.entryID == entryID }),
              entry.imageKind == .classic
        else { throw ClassicDeveloperSupportError.invalidCatalogReference }
        let contentFiles = entry.files.map { file in
            DynamicDeveloperImageContentFile(
                path: file.archiveRelativePath,
                sha256: file.sha256,
                size: file.size
            )
        }.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        let contentManifestSHA256 = try DynamicDeveloperImageContentManifest
            .sha256(contentFiles)
        let catalogSHA256 = StableBytes.sha256Hex(Data(
            try DeveloperImageCatalog.canonicalBytes(catalog)
        ))
        return try makePayload(
            operation: operation,
            asset: DynamicDeveloperImageAssetReference(
                archiveSHA256: entry.archiveSHA256,
                archiveSize: entry.archiveSize,
                assetID: entry.entryID,
                contentManifestSHA256: contentManifestSHA256,
                ddiVersion: entry.ddiVersion,
                kind: .developerDiskImage,
                sourceURL: entry.sourceURLs.first ?? "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/developerDiskImages/fixture.tar"
            ),
            catalogSHA256: catalogSHA256,
            revision: catalog.catalogRevision,
            connectionEpoch: connectionEpoch,
            preparationAttemptID: preparationAttemptID
        )
    }

    public static func make(
        operation: ClassicDeveloperSupportOperation,
        snapshot: DynamicDeveloperImageCatalogSnapshot,
        asset: DynamicDeveloperImageAssetReference,
        connectionEpoch: UInt64,
        preparationAttemptID: CanonicalUUID
    ) throws -> ClassicHelperBackendPayload {
        guard asset.kind == .developerDiskImage,
              snapshot.catalog.developerDiskImages.contains(where: {
                  $0.ddiVersion == asset.ddiVersion
                    && $0.contentManifestSHA256 == asset.contentManifestSHA256
              })
        else {
            throw ClassicDeveloperSupportError.invalidCatalogReference
        }
        return try makePayload(
            operation: operation,
            asset: asset,
            catalogSHA256: snapshot.identity.canonicalSHA256,
            revision: snapshot.identity.revision,
            connectionEpoch: connectionEpoch,
            preparationAttemptID: preparationAttemptID
        )
    }

    private static func makePayload(
        operation: ClassicDeveloperSupportOperation,
        asset: DynamicDeveloperImageAssetReference,
        catalogSHA256: String,
        revision: String,
        connectionEpoch: UInt64,
        preparationAttemptID: CanonicalUUID
    ) throws -> ClassicHelperBackendPayload {
        let requiredRoles: [String]
        switch operation {
        case .mount:
            requiredRoles = [
                DeveloperImageFileRole.classicImage.rawValue,
                DeveloperImageFileRole.classicSignature.rawValue,
            ]
        case .queryMounted, .probeServices:
            requiredRoles = []
        }
        return ClassicHelperBackendPayload(
            assetContentManifestSHA256: asset.contentManifestSHA256,
            catalogCanonicalSHA256: catalogSHA256,
            catalogRevision: revision,
            deviceContext: ClassicHelperDeviceContext(
                connectionEpoch: connectionEpoch
            ),
            fileRoles: requiredRoles,
            operation: operation,
            preparationAttemptID: preparationAttemptID,
            preparationGroupID: "prep.legacy.developer.v2"
        )
    }
}

public struct ClassicMountedObservation: Equatable, Sendable {
    public let present: Bool
    public let signatureSHA256: String?

    public init(present: Bool, signatureSHA256: String?) {
        self.present = present
        self.signatureSHA256 = signatureSHA256
    }
}

public enum ClassicDeveloperSupportDecision: Equatable, Sendable {
    case reuseMounted(DeveloperSupportProvenance)
    case resolveSource(DeveloperImageSourceResolution)
}

public enum ClassicDeveloperSupportPlanner {
    public static func decide(
        entry: DeveloperImageCatalogEntryV1,
        mounted: ClassicMountedObservation,
        verifiedCacheAvailable: Bool,
        selectedXcode: SelectedXcodeSnapshot?,
        networkAvailable: Bool
    ) throws -> ClassicDeveloperSupportDecision {
        guard entry.imageKind == .classic else {
            throw ClassicDeveloperSupportError.unsupportedImageKind
        }
        if mounted.present {
            let signature = entry.files.first(where: {
                $0.fileRole == DeveloperImageFileRole.classicSignature.rawValue
            })
            let provenance: DeveloperSupportProvenance =
                signature?.sha256 == mounted.signatureSHA256
                ? .approved
                : .mountedUnknownUnverified
            return .reuseMounted(provenance)
        }
        return .resolveSource(
            try DeveloperImageSourceResolver.resolve(
                entry: entry,
                alreadyMounted: false,
                verifiedCacheAvailable: verifiedCacheAvailable,
                selectedXcode: selectedXcode,
                networkAvailable: networkAvailable
            )
        )
    }
}

public enum ClassicCommandDependency: String, Equatable, Sendable {
    case basic
    case developerSupport
    case unsupported
}

public enum ClassicCommandScope {
    private static let basic: Set<String> = [
        "app.install", "app.uninstall", "device.info", "device.list",
        "device.status",
    ]
    private static let developerSupport: Set<String> = [
        "app.launch", "device.prepare", "screenshot.cli", "screenshot.gui",
    ]

    public static func dependency(for commandID: String) -> ClassicCommandDependency {
        if basic.contains(commandID) { return .basic }
        if developerSupport.contains(commandID) { return .developerSupport }
        return .unsupported
    }
}
