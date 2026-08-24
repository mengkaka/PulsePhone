import XCTest
@testable import PulsePhoneSharedDefinitions

final class StableBytesTests: XCTestCase {
    func testUTF8ASCIIAndASCIIOrdering() throws {
        XCTAssertEqual(StableBytes.utf8("\u{00e9}"), [0xc3, 0xa9])
        XCTAssertEqual(try StableBytes.ascii("Az-09"), [65, 122, 45, 48, 57])
        XCTAssertEqual(try StableBytes.compareASCII("Z", "a"), .ascending)
        XCTAssertEqual(try StableBytes.compareASCII("same", "same"), .equal)
        XCTAssertThrowsError(try StableBytes.ascii("\u{00e9}")) { error in
            XCTAssertEqual(error as? SharedPrimitiveError, .invalidASCII)
        }
    }

    func testLowercaseHexRoundTripsAndRejectsInvalidInput() throws {
        let bytes: [UInt8] = [0x00, 0x0f, 0x10, 0xab, 0xff]
        let encoded = StableBytes.lowercaseHex(bytes)

        XCTAssertEqual(encoded, "000f10abff")
        XCTAssertEqual(try StableBytes.decodeLowercaseHex(encoded), bytes)
        for invalid in ["0", "0A", "0g", "\u{00e9}\u{00e9}"] {
            XCTAssertThrowsError(try StableBytes.decodeLowercaseHex(invalid)) { error in
                XCTAssertEqual(error as? SharedPrimitiveError, .invalidLowercaseHex)
            }
        }
    }

    func testDomainSeparatorUsesExactlyOneNULAndMatchesGolden() throws {
        let payload = StableBytes.utf8("abc")
        let bytes = try StableBytes.domainSeparatedBytes(
            domainID: "pulsephone.test.v1",
            payload: payload
        )

        XCTAssertEqual(
            bytes,
            StableBytes.utf8("pulsephone.test.v1") + [0] + payload
        )
        XCTAssertEqual(bytes.filter { $0 == 0 }.count, 1)
        XCTAssertEqual(
            try StableBytes.domainSeparatedSHA256Hex(
                domainID: "pulsephone.test.v1",
                payload: payload
            ),
            "9008378f4c9c3c672459dd81fa7fc56c98c1809c58238100e1213761de1cf87b"
        )
    }

    func testDomainIdentityChangesDigestAndRejectsInvalidIDs() throws {
        let payload: [UInt8] = [1, 2, 3]
        let first = try StableBytes.domainSeparatedSHA256(
            domainID: "pulsephone.first.v1",
            payload: payload
        )
        let second = try StableBytes.domainSeparatedSHA256(
            domainID: "pulsephone.second.v1",
            payload: payload
        )

        XCTAssertNotEqual(first, second)
        for invalid in ["pulsephone.t\u{00e9}st.v1", "pulsephone\0test.v1"] {
            XCTAssertThrowsError(
                try StableBytes.domainSeparatedSHA256(
                    domainID: invalid,
                    payload: payload
                )
            ) { error in
                XCTAssertEqual(error as? SharedPrimitiveError, .invalidDomainID)
            }
        }
    }
}
