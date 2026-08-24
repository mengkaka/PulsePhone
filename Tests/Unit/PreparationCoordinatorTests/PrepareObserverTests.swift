import PulsePhoneSharedDefinitions
import XCTest

@testable import PulsePhoneRuntimeState

final class PrepareObserverTests: XCTestCase {
    func testProgressDoesNotResetObserverDeadlineAndTerminalIsExactlyOnce() throws {
        let startedAt = MonotonicInstant(nanoseconds: 1_000)
        var observer = try PrepareObserver(
            identity: PrepareObserverIdentity(
                requestID: coordinatorUUID(1),
                actionID: coordinatorUUID(2),
                observerID: coordinatorUUID(3),
                ownerClientInstanceID: coordinatorUUID(4)
            ),
            startedAt: startedAt
        )
        let originalDeadline = observer.deadline
        try observer.recordProgress(
            .downloading,
            at: try startedAt.advanced(
                by: MonotonicDuration(nanoseconds: 10 * 60 * 1_000_000_000)
            )
        )
        XCTAssertEqual(observer.deadline, originalDeadline)
        let terminal = try XCTUnwrap(
            observer.checkDeadline(at: originalDeadline)
        )
        XCTAssertEqual(
            terminal,
            .outcomeUnknown(
                reason: "preparationObserverDeadlineExceeded",
                runtimeMayContinue: true,
                exitCode: 7
            )
        )
        XCTAssertNil(try observer.checkDeadline(at: originalDeadline))
        XCTAssertThrowsError(
            try observer.finish(.released(.interrupted), at: originalDeadline)
        ) { error in
            XCTAssertEqual(error as? PrepareObserverError, .alreadyTerminal)
        }
    }
}
