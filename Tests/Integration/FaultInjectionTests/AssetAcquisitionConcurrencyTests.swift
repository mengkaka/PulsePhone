import Foundation
import PulsePhoneDeveloperImageAssets
import XCTest

final class AssetAcquisitionConcurrencyTests: XCTestCase {
    func testCrossProcessSingleFlightFixture() throws {
        let fixture = try assetAcquisitionFixture(
            "T-019/cross-process-single-flight-l3"
        )
        let input = try fixture.decodeInput(SingleFlightInput.self)
        let expected = try fixture.decodeExpected(AssetAcquisitionExpected.self)
        let image = Data("shared-image".utf8)
        let signature = Data("shared-signature".utf8)
        let first = AssetAcquisitionEntrySpec(
            archiveSHA256: String(repeating: "a", count: 64),
            entryID: "classic.copy-a",
            image: image,
            signature: signature
        )
        let second = AssetAcquisitionEntrySpec(
            archiveSHA256: String(repeating: "b", count: 64),
            entryID: "classic.copy-b",
            image: image,
            signature: signature,
            sourceURLs: ["https://approved.example.invalid/copy-b.zip"]
        )
        let catalog = try makeAssetAcquisitionCatalog(
            revision: "acquisition-single-flight.v1",
            entries: [first, second]
        )
        let root = try assetAcquisitionTemporaryDirectory()
            .appendingPathComponent("DeveloperImages")
        let stores = try (0..<input.contenderCount).map { _ in
            try DeveloperImageAssetStore(rootURL: root)
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
        let assetKeys = try catalog.entries.map { try $0.assetManifest.assetKey }
        XCTAssertEqual(Set(assetKeys).count, 1)
        let assetKey = try XCTUnwrap(assetKeys.first)
        let marker = root.appendingPathComponent("state/download-complete.marker")
        let counter = AssetAcquisitionCounter()
        let errors = AssetAcquisitionErrors()
        let group = DispatchGroup()

        for index in stores.indices {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    try stores[index].withAcquisitionOwnership(assetKey: assetKey) {
                        counter.enterOwner()
                        defer { counter.leaveOwner() }
                        if !FileManager.default.fileExists(atPath: marker.path) {
                            counter.recordDownload()
                            Thread.sleep(forTimeInterval: 0.002)
                            try Data("complete".utf8).write(to: marker)
                            chmod(marker.path, 0o600)
                        }
                    }
                } catch {
                    errors.append(error)
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(errors.values.isEmpty)
        XCTAssertEqual(counter.maximumConcurrentOwners, 1)
        XCTAssertEqual(counter.downloadCount, 1)
        XCTAssertEqual(expected.outcome, "passed")
        XCTAssertEqual(expected.sharedAssetKey, true)
        XCTAssertEqual(expected.maximumConcurrentOwners, 1)
        XCTAssertEqual(expected.downloadCount, 1)
    }
}

private struct SingleFlightInput: Decodable {
    let contenderCount: Int
}
