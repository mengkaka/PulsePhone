import Foundation
import XCTest
@testable import PulsePhoneSharedDefinitions

final class EvidencePolicyContractTests: XCTestCase {
    func testPolicySuiteRequirementAndOwnerCounts() throws {
        let root = try repositoryRoot()
        let policy = try loadObject(root.appendingPathComponent("Verification/evidence-policy.v1.json"))
        XCTAssertEqual(try uint64(policy, "schemaVersion"), 1)
        XCTAssertEqual(try string(policy, "implementationEnvironmentProfileID"), "env.implementation.clean-source")
        XCTAssertEqual(try uint64(policy, "maximumScenarioCountPerSuite"), 4096)
        XCTAssertEqual(try array(policy, "environmentProfiles").count, 17)
        XCTAssertEqual(try array(policy, "stageBindingPresets").count, 29)
        XCTAssertEqual(try array(policy, "subjectSets").count, 25)
        XCTAssertEqual(try array(policy, "applicabilityRules").count, 2)
        XCTAssertEqual(try array(policy, "failurePolicies").count, 5)
        XCTAssertEqual(try array(policy, "evidenceRolePolicies").count, 3)

        let suites = try loadObject(
            root.appendingPathComponent("Verification/execution-suites.v1.json")
        )
        XCTAssertEqual(try array(suites, "suites").count, 21)

        let requirements = try FileManager.default.subpathsOfDirectory(
            atPath: root.appendingPathComponent(
                "Verification/release-requirements"
            ).path
        ).filter { $0.hasSuffix(".json") }
        XCTAssertEqual(requirements.count, 147)

        let owners = try loadObject(
            root.appendingPathComponent("Verification/requirement-owners.v1.json")
        )
        XCTAssertEqual(try array(owners, "routes").count, 147)
    }

    func testRegistryWireErrorCodecFixture() throws {
        let fixture = try fixture(
            "T-016/registry-wire-error-codec-contract-l0"
        )
        struct Input: Decodable {
            let expectedErrorCount: Int
            let expectedSchemaCount: Int
            let expectedWireEntryCount: Int
        }
        struct Expected: Decodable {
            let standardErrorRegistrySHA256: String
            let wireRegistrySHA256: String
        }
        let input = try fixture.decodeInput(Input.self)
        let expected = try fixture.decodeExpected(Expected.self)
        XCTAssertEqual(input.expectedErrorCount, 87)
        XCTAssertEqual(input.expectedSchemaCount, 90)
        XCTAssertEqual(input.expectedWireEntryCount, 59)
        XCTAssertEqual(
            expected.standardErrorRegistrySHA256,
            "0e9cdbee93d04400aa6dee3edc3e24f3e613d5eba77a3ecf0d825429bfe7dbde"
        )
        XCTAssertEqual(
            expected.wireRegistrySHA256,
            "85414363f1e84a4c9f8fe863319355beab20d2845aded1fb382f6d33094762dd"
        )
    }

    func testEvidenceSchemaCanonicalHash() throws {
        let fixture = try fixture("T-017/evidence-schema-canonical-hash-l0")
        struct Expected: Decodable {
            let evidencePolicyHash: String
            let implementationGateContractHash: String
        }
        let expected = try fixture.decodeExpected(Expected.self)
        let root = try repositoryRoot()
        let policyIdentity = try loadObject(
            root.appendingPathComponent(
                "Fixtures/evidence/policy/evidence-policy-identity.v1.json"
            )
        )
        let gateIdentity = try loadObject(
            root.appendingPathComponent(
                "Fixtures/evidence/gates/implementation-gate-contract-identity.v1.json"
            )
        )
        XCTAssertEqual(try string(policyIdentity, "hash"), expected.evidencePolicyHash)
        XCTAssertEqual(
            try string(gateIdentity, "hash"),
            expected.implementationGateContractHash
        )
    }

    func testM0011OwnerQueryHasExactBootstrapRoutes() throws {
        let result = try runTool([
            "owners", "--task", "M0-011",
        ])
        XCTAssertEqual(result.status, 0, result.output)
        let object = try parseObject(Data(result.output.dropLast().utf8))
        XCTAssertEqual(try string(object, "taskID"), "M0-011")
        XCTAssertEqual(try array(object, "fixtureRoutes").count, 18)
        XCTAssertEqual(try array(object, "runnerRoutes").count, 18)
    }

    private func fixture(_ requirementID: String) throws -> FixtureCaseBundleV1 {
        try FixtureCaseLoaderV1.load(
            requirementID: requirementID,
            repositoryRoot: repositoryRoot()
        )
    }

    private func runTool(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.currentDirectoryURL = try repositoryRoot()
        process.executableURL = try repositoryRoot().appendingPathComponent(
            "Scripts/evidence-tool"
        )
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

    private func repositoryRoot() throws -> URL {
        try FixtureCaseLoaderV1.repositoryRoot(containing: #filePath)
    }

    private func loadObject(_ url: URL) throws -> RepositoryJSONObject {
        try parseObject(Data(contentsOf: url))
    }

    private func parseObject(_ data: Data) throws -> RepositoryJSONObject {
        try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](data),
            maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
        ).root
    }

    private func string(
        _ object: RepositoryJSONObject,
        _ key: String
    ) throws -> String {
        try XCTUnwrap(object[key]?.stringValue)
    }

    private func uint64(
        _ object: RepositoryJSONObject,
        _ key: String
    ) throws -> UInt64 {
        try XCTUnwrap(object[key]?.numberValue).requireUInt64()
    }

    private func array(
        _ object: RepositoryJSONObject,
        _ key: String
    ) throws -> [RepositoryJSONValue] {
        try XCTUnwrap(object[key]?.arrayValue)
    }
}
