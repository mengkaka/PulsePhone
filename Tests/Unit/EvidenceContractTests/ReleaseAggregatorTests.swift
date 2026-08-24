import Foundation
import XCTest
@testable import PulsePhoneSharedDefinitions

final class ReleaseAggregatorTests: XCTestCase {
    func testReleasedScopeNoOverstatement() throws {
        struct Input: Decodable {
            let proposedScopeIDs: [String]
            let releasedScopeIDs: [String]
        }
        struct Expected: Decodable {
            let outcome: String
            let reasonCode: String
        }
        let fixture = try loadFixture("T-004/released-scope-no-overstatement-l5")
        let input = try fixture.decodeInput(Input.self)
        let expected = try fixture.decodeExpected(Expected.self)
        XCTAssertFalse(Set(input.releasedScopeIDs).isSubset(of: Set(input.proposedScopeIDs)))
        XCTAssertEqual(expected.outcome, "failed")
        XCTAssertEqual(expected.reasonCode, "releasedScopeOverstatement")
    }

    func testCandidateContractPolicyScopeBinding() throws {
        struct Input: Decodable {
            let candidateInputHash: String
            let evidencePolicyHash: String
            let profileCandidateInputHash: String
            let profileEvidencePolicyHash: String
            let profileScopeHash: String
            let scenarioScopeHash: String
        }
        let fixture = try loadFixture("T-017/candidate-contract-policy-scope-binding-l5")
        let input = try fixture.decodeInput(Input.self)
        XCTAssertEqual(input.candidateInputHash, input.profileCandidateInputHash)
        XCTAssertEqual(input.evidencePolicyHash, input.profileEvidencePolicyHash)
        XCTAssertEqual(input.profileScopeHash, input.scenarioScopeHash)
    }

    func testReleaseProfileRequiredSetDerivation() throws {
        struct Input: Decodable {
            let callerProvidedRequiredSet: Bool
            let formalCohortRequirementIDs: [String]
            let formalOrdinals: [Int]
            let ordinaryMultiplicity: Int
        }
        struct Expected: Decodable {
            let formalMultiplicity: Int
            let requiredSetAuthority: String
        }
        let fixture = try loadFixture("T-017/release-profile-required-set-derivation-l0")
        let input = try fixture.decodeInput(Input.self)
        let expected = try fixture.decodeExpected(Expected.self)
        XCTAssertFalse(input.callerProvidedRequiredSet)
        XCTAssertEqual(input.formalCohortRequirementIDs, [
            "T-018/performance-threshold-evaluation-l5",
            "T-018/stability-stage-run-l5",
        ])
        XCTAssertEqual(input.formalOrdinals, [1, 2, 3])
        XCTAssertEqual(input.ordinaryMultiplicity, 1)
        XCTAssertEqual(expected.formalMultiplicity, 3)
        XCTAssertEqual(expected.requiredSetAuthority, "evidencePolicy")
    }

    func testStageGateAggregation() throws {
        struct Case: Decodable {
            let expected: String
            let outcomes: [String]
        }
        struct Input: Decodable { let cases: [Case] }
        let fixture = try loadFixture("T-017/stage-gate-aggregation-l5")
        let input = try fixture.decodeInput(Input.self)
        for item in input.cases {
            XCTAssertEqual(aggregate(item.outcomes), item.expected)
        }
    }

    func testBetaFormalThresholdIdentity() throws {
        struct Input: Decodable {
            let betaFreezeHash: String
            let betaProfileHash: String
            let formalFreezeHash: String
            let formalProfileHash: String
            let ordinals: [Int]
            let runnerSourceCommits: [String]
        }
        let fixture = try loadFixture("T-018/beta-formal-threshold-identity-l5")
        let input = try fixture.decodeInput(Input.self)
        XCTAssertEqual(input.betaFreezeHash, input.formalFreezeHash)
        XCTAssertEqual(input.betaProfileHash, input.formalProfileHash)
        XCTAssertEqual(input.ordinals, [1, 2, 3])
        XCTAssertEqual(Set(input.runnerSourceCommits).count, 1)
    }

    func testReleaseCompleteContractProfile() throws {
        let result = try runEvidenceTool([
            "contracts", "verify", "--profile", "evidence-policy-release-complete",
        ])
        XCTAssertEqual(result.status, 0, result.output)
        let data = Data(result.output.dropLast().utf8)
        let object = try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](data),
            maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
        ).root
        XCTAssertEqual(object["outcome"]?.stringValue, "passed")
        XCTAssertEqual(
            try XCTUnwrap(object["fixtureCount"]?.numberValue).requireUInt64(), 7
        )
        XCTAssertEqual(
            try XCTUnwrap(object["runnerAdapterCount"]?.numberValue).requireUInt64(), 7
        )
        XCTAssertEqual(
            try XCTUnwrap(object["durableStoreConfigurationTests"]?.numberValue).requireUInt64(),
            9
        )
        XCTAssertEqual(
            try XCTUnwrap(object["stageObservationTests"]?.numberValue).requireUInt64(),
            16
        )
    }

    func testStabilityStageAdapterRequiresTypedObservationInputs() throws {
        let root = try FixtureCaseLoaderV1.repositoryRoot(containing: #filePath)
        let path = root.appendingPathComponent(
            "Verification/runner-adapters/T-018/stability-stage-run-l5.v1.json"
        )
        let data = try Data(contentsOf: path)
        let object = try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](data),
            maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
        ).root
        XCTAssertEqual(object["adapterKind"]?.stringValue, "releaseStageOperation")
        let inputs = try XCTUnwrap(object["inputArtifacts"]?.arrayValue)
        let roles = try inputs.map { value in
            try XCTUnwrap(value.objectValue?["role"]?.stringValue)
        }
        XCTAssertEqual(roles, [
            "developmentCandidateInput",
            "performanceMeasurementProfile",
            "performanceMetrics",
            "performanceThresholdProfile",
        ])
        let cardinalities = try inputs.map { value in
            try XCTUnwrap(value.objectValue?["cardinality"]?.stringValue)
        }
        XCTAssertEqual(cardinalities, ["zeroOrOne", "exactlyOne", "exactlyOne", "zeroOrOne"])

        let tool = try String(
            contentsOf: root.appendingPathComponent("Scripts/evidence-tool"),
            encoding: .utf8
        )
        XCTAssertTrue(tool.contains("--release-profile"))
        XCTAssertTrue(tool.contains("--evidence-record"))
        XCTAssertTrue(tool.contains("--profile-input-artifact"))
        XCTAssertTrue(tool.contains("validate_stage_operation("))
        XCTAssertTrue(tool.contains("validate_profile_evidence_record("))
        XCTAssertTrue(tool.contains("validate_formal_profile_inputs("))
        XCTAssertTrue(tool.contains("missing_required_input_roles("))
        XCTAssertTrue(tool.contains("performance-evidence.evaluate.v1"))
    }

    private func aggregate(_ outcomes: [String]) -> String {
        if outcomes.contains("failed") { return "failed" }
        if outcomes.contains("unknown") { return "unknown" }
        return "passed"
    }

    private func loadFixture(_ requirementID: String) throws -> FixtureCaseBundleV1 {
        try FixtureCaseLoaderV1.load(
            requirementID: requirementID,
            repositoryRoot: FixtureCaseLoaderV1.repositoryRoot(containing: #filePath)
        )
    }

    private func runEvidenceTool(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let root = try FixtureCaseLoaderV1.repositoryRoot(containing: #filePath)
        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = root.appendingPathComponent("Scripts/evidence-tool")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
