import Foundation
import PulsePhoneDeveloperImageAssets
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneSharedDefinitions
import XCTest

final class AssetAcquisitionResumeTests: XCTestCase {
    func testPartialResumeIdentityMatrixFixture() throws {
        let fixture = try assetAcquisitionFixture(
            "T-019/partial-resume-identity-matrix-l2"
        )
        let input = try fixture.decodeInput(ResumeInput.self)
        let expected = try fixture.decodeExpected(AssetAcquisitionExpected.self)
        let model = try assetAcquisitionHTTPModel(input.modelRelativePath)
        let partial = Data(repeating: 0x41, count: input.partialByteCount)
        let spec = AssetAcquisitionEntrySpec(
            entryID: "classic.resume",
            image: Data("resume-image".utf8),
            signature: Data("resume-signature".utf8),
            sourceURLs: [
                "https://approved.example.invalid/resume-a.zip",
                "https://approved.example.invalid/resume-b.zip",
            ]
        )
        let catalog = try makeAssetAcquisitionCatalog(
            revision: "acquisition-resume.v1",
            entries: [spec]
        )
        let store = try makeAssetAcquisitionStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: store.rootURL) }
        let identity = try store.createOrValidateCatalog(catalog)
        let entry = catalog.entries[0]
        let assetKey = try entry.assetManifest.assetKey
        let state = try makeAssetAcquisitionPartialState(
            assetKey: assetKey,
            bytes: partial,
            catalogIdentity: identity,
            entry: entry
        )

        XCTAssertTrue(try DeveloperImageRemoteAcquisitionPlanner.mayResume(
            state: state,
            entry: entry,
            catalogIdentity: identity,
            sourceIndex: 0,
            partialFileSize: UInt64(partial.count)
        ))
        try store.persistPartial(state: state, bytes: partial)
        XCTAssertEqual(
            try store.adoptPartial(
                catalog: catalog,
                entryID: entry.entryID,
                sourceIndex: 0
            ),
            .adopted(state)
        )

        let dimensions = try XCTUnwrap(model.mismatchDimensions)
        XCTAssertEqual(Set(dimensions), Set([
            "archiveSHA256",
            "catalogEntryID",
            "catalogRevision",
            "developerImageCatalogHash",
            "partialFileSize",
            "sourceIndex",
            "sourceURLIdentityHash",
            "strongETag",
        ]))
        for dimension in dimensions {
            let mismatch = try mismatchedState(
                dimension: dimension,
                state: state,
                partial: partial,
                identity: identity,
                entry: entry,
                assetKey: assetKey
            )
            let mayResume = (try? DeveloperImageRemoteAcquisitionPlanner.mayResume(
                state: mismatch.state,
                entry: entry,
                catalogIdentity: identity,
                sourceIndex: 0,
                partialFileSize: mismatch.partialFileSize
            )) ?? false
            XCTAssertFalse(mayResume, dimension)
            var ledger = DeveloperImageRemoteAttemptLedger()
            let request = try XCTUnwrap(ledger.nextRequest(
                entry: entry,
                resumableState: mayResume ? mismatch.state : nil
            ))
            XCTAssertEqual(request.mode, .initial, dimension)
            XCTAssertEqual(request.offset, 0, dimension)
        }
        XCTAssertEqual(expected.outcome, "passed")
        XCTAssertEqual(expected.exactIdentityResumes, true)
        XCTAssertEqual(expected.identityMismatchRestartsAtZero, true)
        XCTAssertEqual(expected.strongETagRequired, true)
    }

    func testHTTPBoundedFallbackFaultFixture() throws {
        let fixture = try assetAcquisitionFixture(
            "T-019/http-bounded-fallback-fault-l2"
        )
        let input = try fixture.decodeInput(FallbackInput.self)
        let expected = try fixture.decodeExpected(AssetAcquisitionExpected.self)
        let model = try assetAcquisitionHTTPModel(input.modelRelativePath)
        let spec = AssetAcquisitionEntrySpec(
            entryID: "classic.fallback",
            image: Data("fallback-image".utf8),
            signature: Data("fallback-signature".utf8),
            sourceURLs: [
                "https://approved.example.invalid/fallback-a.zip",
                "https://approved.example.invalid/fallback-b.zip",
            ]
        )
        let catalog = try makeAssetAcquisitionCatalog(
            revision: "acquisition-fallback.v1",
            entries: [spec]
        )
        let store = try makeAssetAcquisitionStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: store.rootURL) }
        let identity = try store.createOrValidateCatalog(catalog)
        let entry = catalog.entries[0]
        let partial = Data(repeating: 0x42, count: input.partialByteCount)
        let state = try makeAssetAcquisitionPartialState(
            assetKey: try entry.assetManifest.assetKey,
            bytes: partial,
            catalogIdentity: identity,
            entry: entry
        )
        let responses = try XCTUnwrap(model.responses)
        XCTAssertEqual(responses.count, 2)

        var ledger = DeveloperImageRemoteAttemptLedger()
        let resume = try XCTUnwrap(ledger.nextRequest(
            entry: entry,
            resumableState: state
        ))
        XCTAssertEqual(resume.mode, .resume)
        XCTAssertThrowsError(try DeveloperImageRemoteTransferValidator(
            archiveSize: entry.archiveSize,
            request: resume,
            response: responseHead(responses[0])
        ))
        ledger.rejectResumeAndRestartSource(resume)

        let restarted = try XCTUnwrap(ledger.nextRequest(
            entry: entry,
            resumableState: state
        ))
        XCTAssertEqual(restarted.mode, .initial)
        XCTAssertEqual(restarted.sourceIndex, 0)
        XCTAssertEqual(restarted.offset, 0)

        let fallback = try XCTUnwrap(ledger.nextRequest(
            entry: entry,
            resumableState: state
        ))
        XCTAssertEqual(fallback.mode, .initial)
        XCTAssertEqual(fallback.sourceIndex, 1)
        XCTAssertNil(try ledger.nextRequest(entry: entry, resumableState: state))

        var validator = try DeveloperImageRemoteTransferValidator(
            archiveSize: entry.archiveSize,
            request: fallback,
            response: responseHead(responses[1])
        )
        XCTAssertThrowsError(try validator.acceptChunk(
            byteCount: DeveloperImageRemoteTransferValidator.maximumChunkBytes + 1
        ))
        var remaining = Int(entry.archiveSize)
        while remaining > 0 {
            let count = min(
                remaining,
                DeveloperImageRemoteTransferValidator.maximumChunkBytes
            )
            try validator.acceptChunk(byteCount: count)
            remaining -= count
        }
        try validator.requireComplete()

        XCTAssertEqual(expected.outcome, "passed")
        XCTAssertEqual(expected.fallbackNeverReturnsToFailedSource, true)
        XCTAssertEqual(expected.initialRequestsPerSource, 1)
        XCTAssertEqual(expected.resumeRequestsPerSource, 1)
        XCTAssertEqual(
            expected.maximumChunkBytes,
            DeveloperImageRemoteTransferValidator.maximumChunkBytes
        )
    }

    private func mismatchedState(
        dimension: String,
        state: PartialDownloadStateV1,
        partial: Data,
        identity: DeveloperImageCatalogIdentity,
        entry: DeveloperImageCatalogEntryV1,
        assetKey: String
    ) throws -> (state: PartialDownloadStateV1, partialFileSize: UInt64) {
        var overrides = [String: Any]()
        var partialFileSize = UInt64(partial.count)
        switch dimension {
        case "archiveSHA256":
            overrides[dimension] = String(repeating: "b", count: 64)
        case "catalogEntryID":
            overrides[dimension] = "classic.other"
        case "catalogRevision":
            overrides[dimension] = "acquisition-resume.other"
        case "developerImageCatalogHash":
            overrides[dimension] = String(repeating: "c", count: 64)
        case "partialFileSize":
            partialFileSize += 1
        case "sourceIndex":
            overrides[dimension] = 1
        case "sourceURLIdentityHash":
            overrides[dimension] = try DeveloperImageSourcePolicy.sourceURLIdentityHash(
                entry.sourceURLs[1]
            )
        case "strongETag":
            overrides[dimension] = NSNull()
        default:
            XCTFail("unknown mismatch dimension \(dimension)")
        }
        return (
            try makeAssetAcquisitionPartialState(
                assetKey: assetKey,
                bytes: partial,
                catalogIdentity: identity,
                entry: entry,
                overrides: overrides
            ),
            partialFileSize
        )
    }

    private func responseHead(
        _ response: AssetAcquisitionHTTPModel.Response
    ) -> DeveloperImageRemoteResponseHead {
        DeveloperImageRemoteResponseHead(
            contentLength: response.contentLength,
            contentRangeStart: response.contentRangeStart,
            statusCode: response.statusCode,
            strongETag: response.strongETag
        )
    }
}

private struct ResumeInput: Decodable {
    let modelRelativePath: String
    let partialByteCount: Int
}

private struct FallbackInput: Decodable {
    let modelRelativePath: String
    let partialByteCount: Int
}
