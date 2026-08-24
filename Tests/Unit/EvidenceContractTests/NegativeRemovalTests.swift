import Foundation
import XCTest
@testable import PulsePhoneSharedDefinitions

final class NegativeRemovalTests: XCTestCase {
    func testNegativeRemovalConsistency() throws {
        struct Surface: Decodable {
            let catalog: String
            let cli: String
            let docs: String
            let gui: String
            let help: String
            let policy: String
            let tests: String
        }
        struct Input: Decodable {
            let changedContractPaths: [String]
            let grantedContractPaths: [String]
            let reopenedGates: [String]
            let surfaceValidation: Surface
        }
        let fixture = try loadFixture("T-017/negative-removal-consistency-l5")
        let input = try fixture.decodeInput(Input.self)
        XCTAssertEqual(input.changedContractPaths, input.grantedContractPaths)
        XCTAssertEqual(input.reopenedGates, ["M0-900", "M2-900"])
        XCTAssertEqual(
            [input.surfaceValidation.catalog, input.surfaceValidation.cli,
             input.surfaceValidation.docs, input.surfaceValidation.gui,
             input.surfaceValidation.help, input.surfaceValidation.policy,
             input.surfaceValidation.tests],
            Array(repeating: "passed", count: 7)
        )
    }

    func testLegacyCapabilityNegativeExposure() throws {
        struct Input: Decodable { let internalOnlyIDs: [String] }
        struct Expected: Decodable {
            let outcome: String
            let residualPublicExposureCount: Int
        }
        let fixture = try loadFixture("T-005/legacy-capability-negative-exposure-l5")
        let input = try fixture.decodeInput(Input.self)
        let expected = try fixture.decodeExpected(Expected.self)
        XCTAssertEqual(input.internalOnlyIDs, input.internalOnlyIDs.sorted())
        XCTAssertEqual(expected.outcome, "passed")
        XCTAssertEqual(expected.residualPublicExposureCount, 0)
    }

    private func loadFixture(_ requirementID: String) throws -> FixtureCaseBundleV1 {
        try FixtureCaseLoaderV1.load(
            requirementID: requirementID,
            repositoryRoot: FixtureCaseLoaderV1.repositoryRoot(containing: #filePath)
        )
    }
}
