import XCTest

final class ReviewedDevelopmentInputTests: XCTestCase {
    func testContinuityAllowsOnlySourceCommitToChange() {
        let reviewed: [String: String] = [
            "candidate": "same",
            "catalogExposureHash": "same",
            "implementationContractIdentity": "same",
            "sourceCommit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ]
        var fresh = reviewed
        fresh["sourceCommit"] = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        XCTAssertEqual(
            reviewed.filter { $0.key != "sourceCommit" },
            fresh.filter { $0.key != "sourceCommit" }
        )
        fresh["catalogExposureHash"] = "changed"
        XCTAssertNotEqual(
            reviewed.filter { $0.key != "sourceCommit" },
            fresh.filter { $0.key != "sourceCommit" }
        )
    }
}
