import Foundation
import XCTest
@testable import PulsePhoneSharedDefinitions

final class StageRunWALTests: XCTestCase {
    func testFormalCohortIsExactAndThreeConsecutiveRuns() throws {
        let root = try FixtureCaseLoaderV1.repositoryRoot(containing: #filePath)
        let data = try Data(
            contentsOf: root.appendingPathComponent("Verification/evidence-policy.v1.json")
        )
        let policy = try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](data),
            maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
        ).root
        let multiplicity = try XCTUnwrap(policy["currentCandidateMultiplicity"]?.objectValue)
        let cohorts = try XCTUnwrap(multiplicity["cohorts"]?.arrayValue)
        XCTAssertEqual(cohorts.count, 1)
        let cohort = try XCTUnwrap(cohorts[0].objectValue)
        XCTAssertEqual(cohort["cohortID"]?.stringValue, "formal.stability-performance.v1")
        XCTAssertEqual(
            try XCTUnwrap(cohort["requiredDistinctPassingScenarioCount"]?.numberValue).requireUInt64(),
            3
        )
        let ordinalValues = try XCTUnwrap(cohort["requiredStageRunOrdinals"]?.arrayValue)
        let ordinals: [UInt64] = try ordinalValues.map { value in
            try XCTUnwrap(value.numberValue).requireUInt64()
        }
        XCTAssertEqual(ordinals, [1, 2, 3])
    }
}
