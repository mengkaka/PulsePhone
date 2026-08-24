import Foundation
import XCTest
@testable import PulsePhoneSharedDefinitions

final class RepositoryCanonicalJSONTests: XCTestCase {
    private struct GoldenCase {
        let name: String
        let expectation: String
        let input: [UInt8]
        let expectedSHA256: String?
    }

    func testSharedGoldenCorpus() throws {
        let cases = try loadGoldenCases()
        XCTAssertEqual(cases.count, 30)

        for golden in cases {
            switch golden.expectation {
            case "canonical":
                let document = try RepositoryCanonicalJSON
                    .validateCanonicalDocument(
                        golden.input,
                        maximumByteCount: 1 << 20
                    )
                XCTAssertEqual(document.exactBytes, golden.input, golden.name)
                XCTAssertEqual(
                    RepositoryCanonicalJSON.encodeDocument(document.root),
                    golden.input,
                    golden.name
                )
                XCTAssertEqual(
                    document.sha256Hex,
                    golden.expectedSHA256,
                    golden.name
                )
                XCTAssertEqual(document.sha256Hex, document.sha256Hex, golden.name)
            case "nonCanonical":
                assertError(.nonCanonicalEncoding, golden: golden)
            case "unsignedOverflow":
                assertErrorKind(golden) {
                    if case .unsignedIntegerOverflow = $0 { return true }
                    return false
                }
            case "signedOverflow":
                assertErrorKind(golden) {
                    if case .signedIntegerOverflow = $0 { return true }
                    return false
                }
            case "negativeZero":
                assertErrorKind(golden) {
                    if case .negativeZero = $0 { return true }
                    return false
                }
            case "invalidSyntax":
                assertErrorKind(golden) {
                    if case .invalidSyntax = $0 { return true }
                    return false
                }
            case "unsupportedNumber":
                assertErrorKind(golden) {
                    if case .unsupportedNumber = $0 { return true }
                    return false
                }
            case "duplicateKey":
                assertErrorKind(golden) {
                    if case .duplicateObjectKey = $0 { return true }
                    return false
                }
            case "bom":
                assertError(.byteOrderMarkForbidden, golden: golden)
            case "invalidUTF8":
                assertError(.invalidUTF8, golden: golden)
            case "invalidStringControl":
                assertErrorKind(golden) {
                    if case .invalidStringControl = $0 { return true }
                    return false
                }
            case "invalidUnicodeEscape":
                assertErrorKind(golden) {
                    if case .invalidUnicodeEscape = $0 { return true }
                    return false
                }
            case "topLevelObject":
                assertError(.topLevelObjectRequired, golden: golden)
            case "rejectUInt64":
                let number = try canonicalValueNumber(golden.input)
                XCTAssertThrowsError(try number.requireUInt64(), golden.name) {
                    XCTAssertEqual(
                        $0 as? RepositoryCanonicalJSONError,
                        .integerNotUInt64
                    )
                }
            case "rejectInt64":
                let number = try canonicalValueNumber(golden.input)
                XCTAssertThrowsError(try number.requireInt64(), golden.name) {
                    XCTAssertEqual(
                        $0 as? RepositoryCanonicalJSONError,
                        .integerNotInt64
                    )
                }
            default:
                XCTFail("Unknown corpus expectation: \(golden.expectation)")
            }
        }
    }

    func testIntegerASTPreservesCheckedDomainsBeyondDoublePrecision() throws {
        let golden = try XCTUnwrap(
            loadGoldenCases().first { $0.name == "integer-boundaries" }
        )
        let document = try RepositoryCanonicalJSON.validateCanonicalDocument(
            golden.input,
            maximumByteCount: 1 << 20
        )
        let values = try XCTUnwrap(document.root["values"]?.arrayValue)

        XCTAssertEqual(values[3].numberValue, .uint64(9_007_199_254_740_991))
        XCTAssertEqual(values[4].numberValue, .uint64(9_007_199_254_740_992))
        XCTAssertEqual(values[5].numberValue, .uint64(9_007_199_254_740_993))
        XCTAssertEqual(values[7].numberValue, .uint64(UInt64(Int64.max) + 1))
        XCTAssertEqual(values[8].numberValue, .int64(.min))
        XCTAssertEqual(values[9].numberValue, .uint64(.max))
        XCTAssertEqual(
            try XCTUnwrap(values[6].numberValue).requireInt64(),
            .max
        )
    }

    func testCanonicalFixedDecimalPreservesExactTokenAndRejectsFloatSyntax() throws {
        let bytes = Array("{\"negative\":-0.25,\"normalized\":0.125}".utf8)
        let document = try RepositoryCanonicalJSON.validateCanonicalDocument(
            bytes,
            maximumByteCount: 1 << 20
        )
        XCTAssertEqual(
            document.root["negative"]?.numberValue,
            .decimal(try RepositoryJSONDecimal("-0.25"))
        )
        XCTAssertEqual(
            document.root["normalized"]?.numberValue,
            .decimal(try RepositoryJSONDecimal("0.125"))
        )
        XCTAssertEqual(
            RepositoryCanonicalJSON.encodeDocument(document.root),
            bytes
        )
        XCTAssertThrowsError(
            try XCTUnwrap(document.root["normalized"]?.numberValue).requireUInt64()
        ) { error in
            XCTAssertEqual(
                error as? RepositoryCanonicalJSONError,
                .integerNotUInt64
            )
        }

        for invalid in [
            "1", "1.0", "1.20", ".5", "01.5", "+1.5", "1e-1",
            "0.1234567890", "-0.0",
        ] {
            XCTAssertThrowsError(try RepositoryJSONDecimal(invalid), invalid)
        }
    }

    func testEncoderSortsObjectKeysButPreservesArrayAndUnicodeBytes() throws {
        let object = try RepositoryJSONObject(
            members: [
                RepositoryJSONMember(
                    key: "z",
                    value: .array([.number(.uint64(2)), .number(.uint64(1))])
                ),
                RepositoryJSONMember(key: "a", value: .string("e\u{301}/é")),
            ]
        )

        XCTAssertEqual(
            String(decoding: RepositoryCanonicalJSON.encodeDocument(object), as: UTF8.self),
            "{\"a\":\"e\u{301}/é\",\"z\":[2,1]}"
        )
        XCTAssertThrowsError(
            try RepositoryJSONObject(
                members: [
                    RepositoryJSONMember(key: "a", value: .null),
                    RepositoryJSONMember(key: "a", value: .bool(true)),
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? RepositoryCanonicalJSONError,
                .duplicateConstructedObjectKey
            )
        }
    }

    func testNFCAndNFDKeysRemainDistinctByExactUTF8Bytes() throws {
        let golden = try XCTUnwrap(
            loadGoldenCases().first { $0.name == "unicode-key-order" }
        )
        let document = try RepositoryCanonicalJSON.validateCanonicalDocument(
            golden.input,
            maximumByteCount: 1 << 20
        )

        XCTAssertEqual(document.root["e\u{301}"]?.numberValue, .uint64(2))
        XCTAssertEqual(document.root["é"]?.numberValue, .uint64(3))
        XCTAssertNotEqual(
            Array("e\u{301}".utf8),
            Array("é".utf8)
        )
    }

    func testHardCapExactDigestAndDomainSeparator() throws {
        let golden = try XCTUnwrap(
            loadGoldenCases().first { $0.name == "domain-golden" }
        )
        let document = try RepositoryCanonicalJSON.validateCanonicalDocument(
            golden.input,
            maximumByteCount: golden.input.count
        )

        XCTAssertEqual(
            document.sha256Hex,
            "015abd7f5cc57a2dd94b7590f04ad8084273905ee33ec5cebeae62276a97f862"
        )
        XCTAssertEqual(
            try document.domainSeparatedSHA256Hex(
                domainID: "pulsephone.test.canonical.v1"
            ),
            "6205a75879c105dd19638e6cb661688c94eddaebc2139b9ea35c4b4f494bd106"
        )
        XCTAssertThrowsError(
            try RepositoryCanonicalJSON.validateCanonicalDocument(
                golden.input,
                maximumByteCount: golden.input.count - 1
            )
        ) { error in
            XCTAssertEqual(
                error as? RepositoryCanonicalJSONError,
                .hardCapExceeded(
                    maximumByteCount: golden.input.count - 1,
                    actualByteCount: golden.input.count
                )
            )
        }
        XCTAssertThrowsError(
            try RepositoryCanonicalJSON.validateCanonicalDocument(
                golden.input,
                maximumByteCount: -1
            )
        ) { error in
            XCTAssertEqual(
                error as? RepositoryCanonicalJSONError,
                .invalidMaximumByteCount(-1)
            )
        }
    }

    private func canonicalValueNumber(_ input: [UInt8]) throws -> RepositoryJSONNumber {
        let document = try RepositoryCanonicalJSON.validateCanonicalDocument(
            input,
            maximumByteCount: 1 << 20
        )
        return try XCTUnwrap(document.root["value"]?.numberValue)
    }

    private func assertError(
        _ expected: RepositoryCanonicalJSONError,
        golden: GoldenCase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try RepositoryCanonicalJSON.validateCanonicalDocument(
                golden.input,
                maximumByteCount: 1 << 20
            ),
            golden.name,
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? RepositoryCanonicalJSONError,
                expected,
                golden.name,
                file: file,
                line: line
            )
        }
    }

    private func assertErrorKind(
        _ golden: GoldenCase,
        matches: (RepositoryCanonicalJSONError) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try RepositoryCanonicalJSON.validateCanonicalDocument(
                golden.input,
                maximumByteCount: 1 << 20
            ),
            golden.name,
            file: file,
            line: line
        ) { error in
            guard let canonicalError = error as? RepositoryCanonicalJSONError else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
            XCTAssertTrue(
                matches(canonicalError),
                "\(golden.name): \(canonicalError)",
                file: file,
                line: line
            )
        }
    }

    private func loadGoldenCases() throws -> [GoldenCase] {
        let data = try Data(contentsOf: fixtureURL())
        return try data.split(separator: 0x0a).map { line in
            let metadata = try RepositoryCanonicalJSON.validateCanonicalDocument(
                Array(line),
                maximumByteCount: 16 * 1024
            )
            return GoldenCase(
                name: try XCTUnwrap(metadata.root["name"]?.stringValue),
                expectation: try XCTUnwrap(
                    metadata.root["expectation"]?.stringValue
                ),
                input: try StableBytes.decodeLowercaseHex(
                    XCTUnwrap(metadata.root["inputHex"]?.stringValue)
                ),
                expectedSHA256: metadata.root["expectedSHA256"]?.stringValue
            )
        }
    }

    private func fixtureURL() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 {
            root.deleteLastPathComponent()
        }
        return root.appendingPathComponent(
            "Fixtures/contracts/canonical-json/cases.v1.jsonl"
        )
    }
}
