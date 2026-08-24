import Foundation
import PulsePhoneDeveloperImageAssets
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneSharedDefinitions
import XCTest

@testable import PulsePhoneBackendAdapters

final class PersonalizedDeveloperSupportTests: XCTestCase {
    func testHelperRequestsUseOnlyCatalogReferenceAndFixedRoles() throws {
        let catalog = try fixtureCatalog()
        let attempt = try uuid(1)
        let tss = try PersonalizedHelperRequestFactory.make(
            operation: .requestTSS,
            catalog: catalog,
            entryID: "personalized.test",
            connectionEpoch: 17,
            preparationAttemptID: attempt
        )
        XCTAssertEqual(tss.catalogRevision, "catalog.personalized.test")
        XCTAssertEqual(tss.assetContentManifestSHA256.count, 64)
        XCTAssertEqual(tss.catalogCanonicalSHA256.count, 64)
        XCTAssertEqual(tss.deviceContext.connectionEpoch, 17)
        XCTAssertEqual(
            tss.fileRoles,
            ["personalized.buildManifest", "personalized.image"]
        )
        XCTAssertEqual(tss.preparationGroupID, "prep.coredevice.v2")

        let mount = try PersonalizedHelperRequestFactory.make(
            operation: .mount,
            catalog: catalog,
            entryID: "personalized.test",
            connectionEpoch: 17,
            preparationAttemptID: attempt
        )
        XCTAssertEqual(
            mount.fileRoles,
            [
                "personalized.buildManifest", "personalized.image",
                "personalized.trustCache",
            ]
        )
        XCTAssertTrue(
            try PersonalizedHelperRequestFactory.make(
                operation: .queryMounted,
                catalog: catalog,
                entryID: "personalized.test",
                connectionEpoch: 17,
                preparationAttemptID: attempt
            ).fileRoles.isEmpty
        )
    }

    func testAlreadyMountedSkipsManifestAndPreservesUnknownProvenance() throws {
        let start = PersonalizedPreparationSnapshot(phase: .queryMounted)
        let mounted = try PersonalizedPreparationStateMachine.advance(
            start,
            event: .mountedObserved(knownApproved: false)
        )
        XCTAssertEqual(mounted.phase, .warmGeneration)
        XCTAssertEqual(mounted.provenance, .mountedUnknownUnverified)
        let ready = try PersonalizedPreparationStateMachine.advance(
            mounted,
            event: .generationReady
        )
        XCTAssertEqual(ready.phase, .ready)
        XCTAssertEqual(ready.provenance, .mountedUnknownUnverified)
    }

    func testManifestMountAndGenerationOrderIsClosed() throws {
        var state = PersonalizedPreparationSnapshot(phase: .queryMounted)
        state = try PersonalizedPreparationStateMachine.advance(
            state,
            event: .mountAbsent
        )
        XCTAssertEqual(state.phase, .requestManifest)
        state = try PersonalizedPreparationStateMachine.advance(
            state,
            event: .manifestReady(.reusableDeviceManifest)
        )
        XCTAssertEqual(state.phase, .mount)
        XCTAssertThrowsError(
            try PersonalizedPreparationStateMachine.advance(
                state,
                event: .generationReady
            )
        )
        state = try PersonalizedPreparationStateMachine.advance(
            state,
            event: .mountCompleted
        )
        XCTAssertEqual(state.phase, .warmGeneration)
        XCTAssertEqual(state.provenance, .approved)
        state = try PersonalizedPreparationStateMachine.advance(
            state,
            event: .generationReady
        )
        XCTAssertEqual(state.phase, .ready)
    }

    func testSourceResolutionAndMountedDecisionAreDeterministic() throws {
        let entry = try XCTUnwrap(fixtureCatalog().entries.first)
        XCTAssertEqual(
            try PersonalizedDeveloperSupportPlanner.decide(
                entry: entry,
                mounted: true,
                knownApprovedMount: false,
                verifiedCacheAvailable: false,
                selectedXcode: nil,
                networkAvailable: false
            ),
            .reuseMounted(.mountedUnknownUnverified)
        )
        XCTAssertEqual(
            try PersonalizedDeveloperSupportPlanner.decide(
                entry: entry,
                mounted: false,
                knownApprovedMount: false,
                verifiedCacheAvailable: true,
                selectedXcode: nil,
                networkAvailable: true
            ),
            .resolveSource(
                DeveloperImageSourceResolution(kind: .verifiedCache)
            )
        )
    }

    private func fixtureCatalog() throws -> DeveloperImageCatalogV1 {
        let data = Data(
            """
            {"catalogRevision":"catalog.personalized.test","entries":[{"archiveSHA256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","archiveSize":6,"buildID":"21A329","compatibilityRuleID":"compat.preparation.coredevice.v2","ddiVersion":"17.0","deviceOSRange":{"exactBuilds":["21A329"],"minimumMajor":17},"entryID":"personalized.test","evidenceState":"target","extractedUpperBound":6,"files":[{"archiveRelativePath":"BuildManifest.plist","fileRole":"personalized.buildManifest","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":2},{"archiveRelativePath":"DeveloperDiskImage.dmg","fileRole":"personalized.image","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","size":2},{"archiveRelativePath":"DeveloperDiskImage.dmg.trustcache","fileRole":"personalized.trustCache","sha256":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","size":2}],"imageKind":"personalized","requiredServices":["com.apple.coredevice.appservice","com.apple.coredevice.screencaptureservice"],"sourceURLs":["https://example.invalid/personalized.zip"]}],"schemaVersion":1}
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
