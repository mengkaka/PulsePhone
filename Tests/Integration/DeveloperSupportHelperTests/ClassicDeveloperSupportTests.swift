import Foundation
import PulsePhoneDeveloperImageAssets
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneSharedDefinitions
import XCTest

@testable import PulsePhoneBackendAdapters

final class ClassicDeveloperSupportTests: XCTestCase {
    func testHelperRequestContainsOnlyCatalogReferenceAndFixedRoles() throws {
        let catalog = try fixtureCatalog()
        let payload = try ClassicHelperRequestFactory.make(
            operation: .mount,
            catalog: catalog,
            entryID: "classic.test",
            connectionEpoch: 4,
            preparationAttemptID: uuid(1)
        )
        XCTAssertEqual(payload.catalogRevision, "catalog.classic.test")
        XCTAssertEqual(payload.assetContentManifestSHA256.count, 64)
        XCTAssertEqual(payload.catalogCanonicalSHA256.count, 64)
        XCTAssertEqual(payload.deviceContext.connectionEpoch, 4)
        XCTAssertEqual(
            payload.fileRoles,
            ["classic.image", "classic.signature"]
        )
        XCTAssertEqual(payload.preparationGroupID, "prep.legacy.developer.v2")

        let query = try ClassicHelperRequestFactory.make(
            operation: .queryMounted,
            catalog: catalog,
            entryID: "classic.test",
            connectionEpoch: 4,
            preparationAttemptID: uuid(2)
        )
        XCTAssertTrue(query.fileRoles.isEmpty)
    }

    func testMountedProvenanceAndSourceOrderAreClosed() throws {
        let entry = try XCTUnwrap(fixtureCatalog().entries.first)
        XCTAssertEqual(
            try ClassicDeveloperSupportPlanner.decide(
                entry: entry,
                mounted: ClassicMountedObservation(
                    present: true,
                    signatureSHA256: String(repeating: "b", count: 64)
                ),
                verifiedCacheAvailable: false,
                selectedXcode: nil,
                networkAvailable: false
            ),
            .reuseMounted(.approved)
        )
        XCTAssertEqual(
            try ClassicDeveloperSupportPlanner.decide(
                entry: entry,
                mounted: ClassicMountedObservation(
                    present: true,
                    signatureSHA256: String(repeating: "c", count: 64)
                ),
                verifiedCacheAvailable: true,
                selectedXcode: nil,
                networkAvailable: true
            ),
            .reuseMounted(.mountedUnknownUnverified)
        )
        XCTAssertEqual(
            try ClassicDeveloperSupportPlanner.decide(
                entry: entry,
                mounted: ClassicMountedObservation(
                    present: false,
                    signatureSHA256: nil
                ),
                verifiedCacheAvailable: true,
                selectedXcode: nil,
                networkAvailable: true
            ),
            .resolveSource(
                DeveloperImageSourceResolution(kind: .verifiedCache)
            )
        )
    }

    func testClassicCommandScopeSeparatesBasicAndDDIDependentCommands() {
        for commandID in [
            "app.install", "app.uninstall", "device.info", "device.list",
            "device.status",
        ] {
            XCTAssertEqual(
                ClassicCommandScope.dependency(for: commandID),
                .basic,
                commandID
            )
        }
        for commandID in [
            "app.launch", "device.prepare", "screenshot.cli", "screenshot.gui",
        ] {
            XCTAssertEqual(
                ClassicCommandScope.dependency(for: commandID),
                .developerSupport,
                commandID
            )
        }
        XCTAssertEqual(
            ClassicCommandScope.dependency(for: "touch.tap"),
            .unsupported
        )
    }

    private func fixtureCatalog() throws -> DeveloperImageCatalogV1 {
        let data = Data(
            """
            {"catalogRevision":"catalog.classic.test","entries":[{"archiveSHA256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","archiveSize":3,"buildID":"18D52","compatibilityRuleID":"compat.preparation.legacy-developer.v2","ddiVersion":"14.4","deviceOSRange":{"exactBuilds":["18D52"],"maximumMajorExclusive":17,"minimumMajor":14},"entryID":"classic.test","evidenceState":"target","extractedUpperBound":3,"files":[{"archiveRelativePath":"DeveloperDiskImage.dmg","fileRole":"classic.image","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":2},{"archiveRelativePath":"DeveloperDiskImage.dmg.signature","fileRole":"classic.signature","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","size":1}],"imageKind":"classic","requiredServices":["com.apple.instruments.remoteserver","com.apple.mobile.screenshotr"],"sourceURLs":["https://example.invalid/classic.zip"]}],"schemaVersion":1}
            """.utf8
        )
        return try JSONDecoder().decode(DeveloperImageCatalogV1.self, from: data)
    }

    private func uuid(_ value: Int) throws -> CanonicalUUID {
        try CanonicalUUID(
            String(format: "00000000-0000-0000-0000-%012x", value)
        )
    }
}
