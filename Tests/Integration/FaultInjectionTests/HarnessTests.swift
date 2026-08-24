import PulsePhoneSharedDefinitions
import XCTest

final class FaultInjectionHarnessTests: XCTestCase {
    func testAllFaultKindsExecuteInCanonicalOrderWithoutSleeping() throws {
        let script = try completeScript()
        var harness = try makeHarness(script: script)

        try harness.runToCompletion()

        XCTAssertEqual(harness.clock.now(), instant(5))
        XCTAssertEqual(harness.observations, [
            .slowPeerConfigured(
                maximumBytesPerDrain: 3,
                stalledUntil: instant(2)
            ),
            .malformedRejected(byteCount: 3),
            .deadlineExpired(id: "read-frame", at: instant(2)),
            .deviceDetached(previousEpoch: 7, newEpoch: 8),
            .helperCrashed(generation: 4, exitCode: 9),
            .peerEOF,
        ])
        XCTAssertEqual(harness.helper.crashExitCode, 9)
        XCTAssertEqual(harness.device.connectionEpoch, 8)
        XCTAssertFalse(harness.device.isAttached)
        XCTAssertFalse(harness.peer.isOpen)
    }

    func testSameScriptProducesIdenticalTranscriptAcrossRuns() throws {
        let script = try completeScript()
        var first = try makeHarness(script: script)
        var second = try makeHarness(script: script)

        try first.runToCompletion()
        try second.runToCompletion()

        XCTAssertEqual(first.observations, second.observations)
        XCTAssertEqual(first.peer, second.peer)
        XCTAssertEqual(first.helper, second.helper)
        XCTAssertEqual(first.device, second.device)
    }

    func testSlowPeerUsesVirtualStallAndBoundedPartialDrain() throws {
        let script = try FaultScript(steps: [
            step(0, at: 10, target: .peer, fault: .slowPeer(
                maximumBytesPerDrain: 4,
                stallNanoseconds: 5
            )),
        ])
        var harness = try makeHarness(script: script)
        try harness.advance(to: instant(10))

        XCTAssertEqual(
            try harness.peer.drainCount(requestedBytes: 12, now: instant(14)),
            0
        )
        XCTAssertEqual(
            try harness.peer.drainCount(requestedBytes: 12, now: instant(15)),
            4
        )
    }

    func testClockAndScriptRejectAmbiguousOrUnboundedInputs() throws {
        let clock = DeterministicClock(start: MonotonicInstant(nanoseconds: .max))
        XCTAssertThrowsError(try clock.advance(
            by: MonotonicDuration(nanoseconds: 1)
        )) { error in
            XCTAssertEqual(error as? DeterministicClockError, .integerOverflow)
        }
        XCTAssertThrowsError(try DeterministicClock(
            start: instant(2)
        ).advance(to: instant(1))) { error in
            XCTAssertEqual(
                error as? DeterministicClockError,
                .nonMonotonicAdvance
            )
        }
        XCTAssertThrowsError(try FaultScript(steps: [
            step(1, at: 0, target: .peer, fault: .eof),
        ])) { error in
            XCTAssertEqual(
                error as? FaultScriptError,
                .nonContiguousSequence(expected: 0, actual: 1)
            )
        }
        XCTAssertThrowsError(try FaultScript(steps: [
            step(0, at: 0, target: .peer, fault: .slowPeer(
                maximumBytesPerDrain: 0,
                stallNanoseconds: 0
            )),
        ])) { error in
            XCTAssertEqual(error as? FaultScriptError, .invalidSlowPeerLimit)
        }
        XCTAssertThrowsError(try FaultScript(steps: [
            step(0, at: 0, target: .device, fault: .eof),
        ])) { error in
            XCTAssertEqual(
                error as? FaultScriptError,
                .targetMismatch(sequence: 0)
            )
        }
    }

    func testFakeComponentsRejectDuplicateTerminalFaults() throws {
        var helper = try FakeHelper(generation: 1)
        try helper.crash(exitCode: 1)
        XCTAssertThrowsError(try helper.crash(exitCode: 2)) { error in
            XCTAssertEqual(error as? FakeHelperError, .alreadyCrashed)
        }

        var device = try FakeDevice(connectionEpoch: 1)
        _ = try device.detach()
        XCTAssertThrowsError(try device.detach()) { error in
            XCTAssertEqual(error as? FakeDeviceError, .alreadyDetached)
        }

        var peer = FakePeer()
        try peer.injectEOF()
        XCTAssertThrowsError(try peer.injectMalformed([0xff])) { error in
            XCTAssertEqual(error as? FakePeerError, .closed)
        }
    }

    private func completeScript() throws -> FaultScript {
        try FaultScript(steps: [
            step(0, at: 0, target: .peer, fault: .slowPeer(
                maximumBytesPerDrain: 3,
                stallNanoseconds: 2
            )),
            step(1, at: 1, target: .peer, fault: .malformed(bytes: [1, 2, 3])),
            step(2, at: 2, target: .harness, fault: .timeout(
                deadlineID: "read-frame"
            )),
            step(3, at: 3, target: .device, fault: .detach),
            step(4, at: 4, target: .helper, fault: .crash(exitCode: 9)),
            step(5, at: 5, target: .peer, fault: .eof),
        ])
    }

    private func makeHarness(script: FaultScript) throws -> FaultInjectionHarness {
        FaultInjectionHarness(
            script: script,
            helper: try FakeHelper(generation: 4),
            device: try FakeDevice(connectionEpoch: 7)
        )
    }

    private func step(
        _ sequence: UInt64,
        at nanoseconds: UInt64,
        target: FaultTarget,
        fault: ScriptedFault
    ) -> FaultStep {
        FaultStep(
            sequence: sequence,
            scheduledAt: instant(nanoseconds),
            target: target,
            fault: fault
        )
    }

    private func instant(_ nanoseconds: UInt64) -> MonotonicInstant {
        MonotonicInstant(nanoseconds: nanoseconds)
    }
}
