import PulsePhoneCLI
import PulsePhoneSharedDefinitions
import XCTest

final class SignalRaceTests: XCTestCase {
    func testClientBudgetSIGINTMatrixFixture() throws {
        let fixture = try faultFixture(
            "T-012/client-budget-sigint-matrix-l3"
        )
        let input = try fixture.decodeInput(ClientBudgetInput.self)
        let expected = try fixture.decodeExpected(ClientBudgetExpected.self)
        let start = seconds(10)
        var ordinary = try ClientWaitBudget(
            kind: .nonDDICommand,
            startedAt: start
        )
        XCTAssertNil(try ordinary.check(at: seconds(69)))
        XCTAssertEqual(
            try ordinary.check(at: seconds(70)),
            .cancelOwnedPendingWorkAndClose(
                reason: expected.ordinaryReason,
                runtimeMayContinue: true
            )
        )

        var dependent = try ClientWaitBudget(
            kind: .ddiDependentCommand,
            startedAt: start
        )
        XCTAssertNil(try dependent.check(at: seconds(600)))
        try dependent.capabilityReadyAndReplanned(at: seconds(600))
        XCTAssertNil(try dependent.check(at: seconds(659)))
        XCTAssertNotNil(try dependent.check(at: seconds(660)))

        var prepare = try ClientWaitBudget(
            kind: .devicePrepare,
            startedAt: start
        )
        XCTAssertEqual(
            try prepare.check(at: seconds(1_210)),
            .closePrepareObserver(
                reason: expected.prepareReason,
                runtimeMayContinue: true
            )
        )
        XCTAssertEqual(input.budgetKinds, [
            "nonDDICommand", "ddiDependentCommand", "devicePrepare",
        ])
        XCTAssertEqual(expected.ordinaryMilliseconds, 60_000)
        XCTAssertEqual(expected.prepareObserverMilliseconds, 1_200_000)
        XCTAssertTrue(expected.ddiBudgetStartsAfterReady)

        let workClasses: [(String, CLIWorkClass, CLIInterruptionAction)] = [
            ("control", .control, .cancelBeforeWriteOrWaitExistingTerminal),
            ("hybrid", .hybrid, .stopLaunchingChildrenAndProjectActive),
            ("local", .local, .stopLocalAndTerminateFactsProbe),
            ("oneShot", .oneShot, .requestOwnedCancellation),
        ]
        XCTAssertEqual(input.signalWorkClasses, workClasses.map(\.0))
        for (index, item) in workClasses.enumerated() {
            var signal = CLISignalCoordinator(workClass: item.1)
            let first = MonotonicInstant(
                nanoseconds: UInt64(index) * 2_000_000_000
            )
            XCTAssertEqual(
                try signal.receiveSIGINT(at: first),
                .beginGrace(
                    action: item.2,
                    deadline: MonotonicInstant(
                        nanoseconds: first.nanoseconds
                            + expected.signalGraceMilliseconds * 1_000_000
                    )
                )
            )
            XCTAssertEqual(
                try signal.receiveSIGINT(at: try first.advanced(
                    by: MonotonicDuration(nanoseconds: 1)
                )),
                .immediateExit(Int32(expected.interruptedExit))
            )
        }
        XCTAssertTrue(expected.secondSignalImmediate)
    }

    private func seconds(_ value: UInt64) -> MonotonicInstant {
        MonotonicInstant(nanoseconds: value * 1_000_000_000)
    }
}

private struct ClientBudgetInput: Decodable {
    let budgetKinds: [String]
    let signalWorkClasses: [String]
}

private struct ClientBudgetExpected: Decodable {
    let ddiBudgetStartsAfterReady: Bool
    let interruptedExit: Int
    let ordinaryMilliseconds: UInt64
    let ordinaryReason: String
    let prepareObserverMilliseconds: UInt64
    let prepareReason: String
    let secondSignalImmediate: Bool
    let signalGraceMilliseconds: UInt64
}
