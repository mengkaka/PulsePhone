import Foundation
@testable import PulsePhoneSharedDefinitions
import XCTest

final class PulsePhoneProductVersionTests: XCTestCase {
    func testDisplayTextAndCodableFieldsAreStable() throws {
        let value = try XCTUnwrap(PulsePhoneProductVersion(
            version: "0.1.0",
            build: "1"
        ))

        XCTAssertEqual(value.displayText, "PulsePhone 0.1.0 (1)")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
                as? [String: String]
        )
        XCTAssertEqual(object, ["build": "1", "version": "0.1.0"])
    }

    func testRejectsMissingUnsafeAndOversizedComponents() {
        XCTAssertNil(PulsePhoneProductVersion(version: "", build: "1"))
        XCTAssertNil(PulsePhoneProductVersion(version: "0.1.0", build: ""))
        XCTAssertNil(PulsePhoneProductVersion(version: "0.1.0\n", build: "1"))
        XCTAssertNil(PulsePhoneProductVersion(
            version: String(repeating: "1", count: 129),
            build: "1"
        ))
    }
}
