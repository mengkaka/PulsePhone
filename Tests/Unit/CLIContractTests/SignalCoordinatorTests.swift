import Darwin
import PulsePhoneCLI
import PulsePhoneClientCore
import PulsePhoneSharedDefinitions
import XCTest

final class SignalCoordinatorTests: XCTestCase {
    func testFirstSignalMapsWorkClassAndSecondExitsImmediately() throws {
        let cases: [(CLIWorkClass, CLIInterruptionAction)] = [
            (.local, .stopLocalAndTerminateFactsProbe),
            (.control, .cancelBeforeWriteOrWaitExistingTerminal),
            (.oneShot, .requestOwnedCancellation),
            (.hybrid, .stopLaunchingChildrenAndProjectActive),
        ]
        for (index, item) in cases.enumerated() {
            var coordinator = CLISignalCoordinator(workClass: item.0)
            let first = MonotonicInstant(
                nanoseconds: UInt64(index) * 2_000_000_000
            )
            XCTAssertEqual(
                try coordinator.receiveSIGINT(at: first),
                .beginGrace(
                    action: item.1,
                    deadline: MonotonicInstant(
                        nanoseconds: first.nanoseconds + 1_000_000_000
                    )
                )
            )
            XCTAssertEqual(
                try coordinator.receiveSIGINT(
                    at: MonotonicInstant(
                        nanoseconds: first.nanoseconds + 1
                    )
                ),
                .immediateExit(130)
            )
            XCTAssertEqual(coordinator.exitCodeAfterInterruption(), 130)
        }
    }

    func testProductionElementMonitorForwardsFirstSignalAndEscalatesSecond()
        throws
    {
        let interruption = RuntimeClientElementSnapshotInterruption()
        let exit = LockedSignalExit()
        let monitor = ProductionElementSnapshotSIGINTMonitor(
            interruption: interruption,
            immediateExit: exit.record
        )
        defer { monitor.stop() }

        XCTAssertEqual(Darwin.kill(getpid(), SIGINT), 0)
        let firstDeadline = DispatchTime.now() + 2
        while !interruption.isInterrupted,
              DispatchTime.now() < firstDeadline
        {
            usleep(1_000)
        }
        XCTAssertTrue(interruption.isInterrupted)

        XCTAssertEqual(Darwin.kill(getpid(), SIGINT), 0)
        XCTAssertEqual(exit.recorded.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(exit.code, 130)
    }
}

private final class LockedSignalExit: @unchecked Sendable {
    let recorded = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var storedCode: Int32?

    var code: Int32? {
        lock.withLock { storedCode }
    }

    func record(_ code: Int32) {
        lock.withLock { storedCode = code }
        recorded.signal()
    }
}
