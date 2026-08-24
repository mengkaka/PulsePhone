import Foundation
import XCTest
@testable import PulsePhoneSharedDefinitions

final class CanonicalUDIDTests: XCTestCase {
    private struct NormalizationInput: Decodable {
        struct Vector: Decodable {
            let expected: String
            let input: String
        }

        let vectors: [Vector]
    }

    private struct InvalidInput: Decodable {
        let inputs: [String]
    }

    private struct HashInput: Decodable {
        let canonicalUDID: String
    }

    private struct HashExpected: Decodable {
        let sha256: String
    }

    func testNormalizationBootstrapCase() throws {
        let fixture = try fixture("T-012/canonical-udid-normalization-l0")
        XCTAssertEqual(fixture.manifest.level, "L0")
        XCTAssertEqual(fixture.manifest.caseClass, "positive")
        let input = try fixture.decodeInput(NormalizationInput.self)
        for vector in input.vectors {
            XCTAssertEqual(
                try CanonicalUDID(rawTransportUDID: vector.input).rawValue,
                vector.expected,
                fixture.manifest.caseKey
            )
        }
    }

    func testInvalidBootstrapCase() throws {
        let fixture = try fixture("T-012/canonical-udid-invalid-l0")
        XCTAssertEqual(fixture.manifest.level, "L0")
        XCTAssertEqual(fixture.manifest.caseClass, "negative")
        for input in try fixture.decodeInput(InvalidInput.self).inputs {
            XCTAssertThrowsError(
                try CanonicalUDID(rawTransportUDID: input),
                fixture.manifest.caseKey
            )
        }
    }

    func testCanonicalStringAndCodableRequireExactCanonicalBytes() throws {
        let canonical = try CanonicalUDID(canonicalString: "ABC-123")
        XCTAssertEqual(
            try JSONEncoder().encode(canonical),
            Data("\"ABC-123\"".utf8)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                CanonicalUDID.self,
                from: Data("\"ABC-123\"".utf8)
            ),
            canonical
        )

        for nonCanonical in ["abc-123", " ABC-123 "] {
            XCTAssertThrowsError(
                try CanonicalUDID(canonicalString: nonCanonical)
            ) { error in
                XCTAssertEqual(error as? CanonicalUDIDError, .nonCanonical)
            }
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    CanonicalUDID.self,
                    from: Data("\"\(nonCanonical)\"".utf8)
                )
            )
        }
    }

    func testHashBootstrapCaseMatchesGoldenAcrossRuns() throws {
        let fixture = try fixture("T-012/canonical-udid-hash-l0")
        XCTAssertEqual(fixture.manifest.level, "L0")
        XCTAssertEqual(fixture.manifest.caseClass, "positive")
        let input = try fixture.decodeInput(HashInput.self)
        let expected = try fixture.decodeExpected(HashExpected.self).sha256
        let canonical = try CanonicalUDID(
            canonicalString: input.canonicalUDID
        )

        XCTAssertEqual(canonical.domainSeparatedHash, expected, fixture.manifest.caseKey)
        XCTAssertEqual(canonical.domainSeparatedHash, expected, fixture.manifest.caseKey)
    }

    private func fixture(_ requirementID: String) throws -> FixtureCaseBundleV1 {
        try FixtureCaseLoaderV1.load(
            requirementID: requirementID,
            repositoryRoot: FixtureCaseLoaderV1.repositoryRoot(containing: #filePath)
        )
    }
}
