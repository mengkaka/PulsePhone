import XCTest
@testable import PulsePhoneSharedDefinitions

final class StandardErrorV1Tests: XCTestCase {
    private struct Details: Equatable, Hashable, Sendable {
        let marker: Int
    }

    func testErrorStoresUnvalidatedCodeAndOpaqueDetails() {
        let error = StandardErrorV1(
            code: "futureRegistryOwnedCode",
            details: Details(marker: 7)
        )

        XCTAssertEqual(error.code, "futureRegistryOwnedCode")
        XCTAssertEqual(error.details, Details(marker: 7))
        XCTAssertEqual(
            StandardErrorV1<Details>(code: "", details: nil).code,
            ""
        )
    }

    func testEightErrorFamiliesHaveFrozenExitCodes() {
        let expected: [(ErrorFamily, Int32)] = [
            (.internal, 1),
            (.argument, 2),
            (.targetCompatibility, 3),
            (.runtimeProtocol, 4),
            (.admissionBusy, 5),
            (.knownCommandFailure, 6),
            (.unknownOutcome, 7),
            (.interrupted, 130),
        ]

        XCTAssertEqual(ErrorFamily.allCases.count, 8)
        for (family, exitCode) in expected {
            XCTAssertEqual(family.exitCode, exitCode)
        }
    }
}
