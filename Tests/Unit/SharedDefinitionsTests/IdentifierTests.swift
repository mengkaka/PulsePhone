import Foundation
import XCTest
@testable import PulsePhoneSharedDefinitions

final class IdentifierTests: XCTestCase {
    private enum ActionTag {}
    private enum RequestTag {}

    func testCanonicalUUIDAcceptsAndRoundTripsLowercaseForm() throws {
        let string = "123e4567-e89b-12d3-a456-426614174000"
        let identifier = try CanonicalUUID(string)

        XCTAssertEqual(identifier.canonicalString, string)
        XCTAssertEqual(identifier.description, string)
        XCTAssertEqual(try JSONEncoder().encode(identifier), Data("\"\(string)\"".utf8))
        XCTAssertEqual(try JSONDecoder().decode(CanonicalUUID.self, from: Data("\"\(string)\"".utf8)), identifier)
    }

    func testCanonicalUUIDRejectsNonCanonicalForms() {
        let invalid = [
            "123E4567-e89b-12d3-a456-426614174000",
            "123e4567e89b-12d3-a456-426614174000",
            "{123e4567-e89b-12d3-a456-426614174000}",
            "123e4567-e89b-12d3-a456-42661417400g",
            "123e4567-e89b-12d3-a456-42661417400",
        ]

        for string in invalid {
            XCTAssertThrowsError(try CanonicalUUID(string)) { error in
                XCTAssertEqual(error as? SharedPrimitiveError, .invalidCanonicalUUID)
            }
        }
    }

    func testTaggedUUIDPreservesPhantomTypeAndOrdering() throws {
        let first = try TaggedUUID<ActionTag>(
            "00000000-0000-0000-0000-000000000001"
        )
        let second = try TaggedUUID<ActionTag>(
            "00000000-0000-0000-0000-000000000002"
        )
        let request = TaggedUUID<RequestTag>(rawValue: first.rawValue)

        XCTAssertLessThan(first, second)
        XCTAssertEqual(request.description, first.description)
        XCTAssertEqual(try JSONEncoder().encode(first), try JSONEncoder().encode(request))
    }
}
