import Foundation
import PulsePhoneCLI
import PulsePhoneSharedDefinitions
import XCTest

final class ClientWaitBudgetTests: XCTestCase {
    func testClientBudgetSIGINTMatrixFixture() throws {
        let expected = try loadExpected()
        let start = instant(seconds: 10)
        var ordinary = try ClientWaitBudget(
            kind: .nonDDICommand,
            startedAt: start
        )
        XCTAssertNil(try ordinary.check(at: instant(seconds: 69)))
        XCTAssertEqual(
            try ordinary.check(at: instant(seconds: 70)),
            .cancelOwnedPendingWorkAndClose(
                reason: "clientWaitDeadlineExceeded",
                runtimeMayContinue: true
            )
        )

        var dependent = try ClientWaitBudget(
            kind: .ddiDependentCommand,
            startedAt: start
        )
        XCTAssertNil(try dependent.check(at: instant(seconds: 600)))
        try dependent.capabilityReadyAndReplanned(at: instant(seconds: 600))
        XCTAssertNil(try dependent.check(at: instant(seconds: 659)))
        XCTAssertNotNil(try dependent.check(at: instant(seconds: 660)))

        var prepare = try ClientWaitBudget(
            kind: .devicePrepare,
            startedAt: start
        )
        XCTAssertEqual(
            try prepare.check(at: instant(seconds: 1_210)),
            .closePrepareObserver(
                reason: "preparationObserverDeadlineExceeded",
                runtimeMayContinue: true
            )
        )

        XCTAssertEqual(uint(expected, "ordinaryMilliseconds"), 60_000)
        XCTAssertEqual(uint(expected, "prepareObserverMilliseconds"), 1_200_000)
        XCTAssertEqual(bool(expected, "ddiBudgetStartsAfterReady"), true)
        XCTAssertEqual(string(expected, "ordinaryReason"), "clientWaitDeadlineExceeded")
        XCTAssertEqual(
            string(expected, "prepareReason"),
            "preparationObserverDeadlineExceeded"
        )
        XCTAssertEqual(uint(expected, "interruptedExit"), 130)
    }

    private func loadExpected() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root
            .appendingPathComponent("Fixtures/requirements/T-012/client-budget-sigint-matrix-l3/expected.v1.json"))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func instant(seconds: UInt64) -> MonotonicInstant {
        MonotonicInstant(nanoseconds: seconds * 1_000_000_000)
    }

    private func uint(_ object: [String: Any], _ key: String) -> UInt64? {
        (object[key] as? NSNumber)?.uint64Value
    }

    private func bool(_ object: [String: Any], _ key: String) -> Bool? {
        object[key] as? Bool
    }

    private func string(_ object: [String: Any], _ key: String) -> String? {
        object[key] as? String
    }
}
