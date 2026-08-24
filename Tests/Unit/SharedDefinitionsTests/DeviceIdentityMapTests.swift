import XCTest
@testable import PulsePhoneSharedDefinitions

final class DeviceIdentityMapTests: XCTestCase {
    private struct CollisionInput: Decodable {
        let rawTransportUDIDs: [String]
    }

    private struct CollisionExpected: Decodable {
        let canonicalUDID: String
    }

    private struct OrderInput: Decodable {
        let rawTransportUDIDs: [String]
    }

    private struct OrderExpected: Decodable {
        let canonicalUDIDs: [String]
    }

    func testCollisionBootstrapCaseFailsClosed() throws {
        let fixture = try fixture("T-001/canonical-udid-collision-l1")
        XCTAssertEqual(fixture.manifest.level, "L1")
        XCTAssertEqual(fixture.manifest.caseClass, "negative")
        let input = try fixture.decodeInput(CollisionInput.self)
        let expected = try CanonicalUDID(
            canonicalString: fixture.decodeExpected(CollisionExpected.self).canonicalUDID
        )

        XCTAssertThrowsError(
            try DeviceIdentityMap(rawTransportUDIDs: input.rawTransportUDIDs),
            fixture.manifest.caseKey
        ) { error in
            XCTAssertEqual(
                error as? DeviceIdentityMapError,
                .canonicalCollision(expected)
            )
        }
        XCTAssertThrowsError(
            try DeviceIdentityMap(rawTransportUDIDs: ["ABC", "ABC"]),
            fixture.manifest.caseKey
        )
    }

    func testOrderBootstrapCaseAndBidirectionalLookup() throws {
        let fixture = try fixture("T-012/canonical-udid-order-l0")
        XCTAssertEqual(fixture.manifest.level, "L0")
        XCTAssertEqual(fixture.manifest.caseClass, "positive")
        let input = try fixture.decodeInput(OrderInput.self)
        let expected = try fixture.decodeExpected(OrderExpected.self)
        let map = try DeviceIdentityMap(rawTransportUDIDs: input.rawTransportUDIDs)

        XCTAssertEqual(
            map.canonicalUDIDs.map(\.rawValue),
            expected.canonicalUDIDs,
            fixture.manifest.caseKey
        )
        let canonicalA = try CanonicalUDID(canonicalString: "A")
        XCTAssertEqual(map.rawTransportUDID(for: canonicalA), " A ")
        XCTAssertEqual(
            map.canonicalUDID(forRawTransportUDID: " A "),
            canonicalA
        )
        XCTAssertNil(map.canonicalUDID(forRawTransportUDID: "A"))
    }

    func testInvalidRawIdentityReportsSnapshotIndex() {
        XCTAssertThrowsError(
            try DeviceIdentityMap(rawTransportUDIDs: ["VALID", "bad value"])
        ) { error in
            XCTAssertEqual(
                error as? DeviceIdentityMapError,
                .invalidRawTransportUDID(
                    index: 1,
                    reason: .invalidCharacter(byteOffset: 3)
                )
            )
        }
    }

    private func fixture(_ requirementID: String) throws -> FixtureCaseBundleV1 {
        try FixtureCaseLoaderV1.load(
            requirementID: requirementID,
            repositoryRoot: FixtureCaseLoaderV1.repositoryRoot(containing: #filePath)
        )
    }
}
