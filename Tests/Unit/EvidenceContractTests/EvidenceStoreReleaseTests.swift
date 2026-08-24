import Foundation
import XCTest
@testable import PulsePhoneSharedDefinitions

final class EvidenceStoreReleaseTests: XCTestCase {
    func testReleaseHoldSetFinalizeContract() throws {
        struct Input: Decodable {
            let holdPackageKeys: [String]
            let lineagePackageKeys: [String]
        }
        struct Expected: Decodable { let selectionReuse: String }
        let fixture = try FixtureCaseLoaderV1.load(
            requirementID: "T-017/release-hold-set-finalize-contract-l3",
            repositoryRoot: FixtureCaseLoaderV1.repositoryRoot(containing: #filePath)
        )
        let input = try fixture.decodeInput(Input.self)
        let expected = try fixture.decodeExpected(Expected.self)
        XCTAssertEqual(input.holdPackageKeys, input.lineagePackageKeys)
        XCTAssertEqual(input.holdPackageKeys, input.holdPackageKeys.sorted())
        XCTAssertEqual(expected.selectionReuse, "exactBytes")
    }

    func testStoreAndHoldSchemasKeepBindingOpaque() throws {
        let root = try FixtureCaseLoaderV1.repositoryRoot(containing: #filePath)
        for relativePath in [
            "Schemas/evidence/evidence-store-record.v1.schema.json",
            "Schemas/evidence/evidence-release-hold.v1.schema.json",
            "Schemas/evidence/release-flow.v1.schema.json",
        ] {
            let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
            let object = try RepositoryCanonicalJSON.validateCanonicalDocument(
                [UInt8](data),
                maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
            ).root
            let encoded = String(decoding: data, as: UTF8.self)
            XCTAssertNotNil(object["properties"]?.objectValue?["evidenceStoreBindingID"])
            XCTAssertFalse(encoded.contains("credential"))
            XCTAssertFalse(encoded.contains("accountID"))
            XCTAssertFalse(encoded.contains("backendRoot"))
        }
    }
}
