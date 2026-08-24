import Foundation
import XCTest
@testable import PulsePhoneSharedDefinitions

final class ImplementationGateContractTests: XCTestCase {
    func testDefinitionHasSixExactRowsAndFourMemberIdentity() throws {
        let root = try FixtureCaseLoaderV1.repositoryRoot(containing: #filePath)
        let definitionData = try Data(
            contentsOf: root.appendingPathComponent(
                "Verification/implementation-gates.v1.json"
            )
        )
        let definition = try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](definitionData),
            maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
        ).root
        let gates = try XCTUnwrap(definition["gates"]?.arrayValue)
        XCTAssertEqual(gates.count, 6)
        let IDs = try gates.map {
            try XCTUnwrap($0.objectValue?["gateID"]?.stringValue)
        }
        XCTAssertEqual(
            IDs,
            ["M0-900", "M1-900", "M2-900", "M3-010A", "M3-014", "M3-900"]
        )

        let identityData = try Data(
            contentsOf: root.appendingPathComponent(
                "Fixtures/evidence/gates/implementation-gate-contract-identity.v1.json"
            )
        )
        let identity = try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](identityData),
            maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
        ).root
        let artifactSet = try XCTUnwrap(identity["artifactSet"]?.objectValue)
        XCTAssertEqual(try XCTUnwrap(artifactSet["entries"]?.arrayValue).count, 4)
    }

    func testDispatcherPureContractSelfTest() throws {
        let root = try FixtureCaseLoaderV1.repositoryRoot(containing: #filePath)
        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = root.appendingPathComponent(
            "Scripts/implementation-gate"
        )
        process.arguments = ["--self-test"]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: output, as: UTF8.self))
        let object = try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](output.dropLast()),
            maximumByteCount: 4096
        ).root
        XCTAssertEqual(object["outcome"]?.stringValue, "passed")
    }
}
