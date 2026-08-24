import Foundation
import PulsePhoneBackendAdapters
import PulsePhoneCLI
import PulsePhoneClientCore
import PulsePhoneSharedDefinitions
import XCTest

final class ButtonActionTests: XCTestCase {
    func testFrozenSingleButtonMappingsAndReleaseBarrier() throws {
        let cases: [(SystemButtonDescriptor, UInt16, UInt64)] = [
            (LockButtonAction.descriptor, 0x30, 500),
            (VolumeButtonAction(direction: .up, transport: transport()).descriptor, 0xe9, 50),
            (VolumeButtonAction(direction: .down, transport: transport()).descriptor, 0xea, 50),
            (DeviceMuteAction.descriptor, 0xe2, 50),
        ]
        for (descriptor, usage, hold) in cases {
            XCTAssertEqual(descriptor.usagePage, 0x0c)
            XCTAssertEqual(descriptor.usage, usage)
            XCTAssertEqual(descriptor.deadlineMilliseconds, 5_000)
            XCTAssertEqual(descriptor.steps, [
                .button(pressed: true),
                .wait(milliseconds: hold),
                .button(pressed: false),
            ])
        }
    }

    func testAppSwitcherUsesFrozenDoubleHomeSequence() throws {
        let recorder = RecordingSystemButtonTransport()
        let execution = try AppSwitcherAction(transport: recorder).execute()
        XCTAssertEqual(AppSwitcherAction.descriptor.routeID, "coredevice.button.doubleHome")
        XCTAssertEqual(AppSwitcherAction.descriptor.deadlineMilliseconds, 10_000)
        XCTAssertEqual(recorder.events, [
            .button(usage: 0x40, pressed: true),
            .wait(milliseconds: 35),
            .button(usage: 0x40, pressed: false),
            .wait(milliseconds: 120),
            .button(usage: 0x40, pressed: true),
            .wait(milliseconds: 35),
            .button(usage: 0x40, pressed: false),
            .cleanup,
        ])
        XCTAssertEqual(execution.semanticLog.commandID, "button.appSwitcher")
        XCTAssertTrue(execution.semanticLog.inputReleased)
    }

    func testEveryActionProjectsCandidateAndAcknowledgedResult() throws {
        let lock = RecordingSystemButtonTransport()
        XCTAssertEqual(
            try LockButtonAction(transport: lock).execute().semanticLog.routeID,
            "coredevice.button.lock"
        )
        let up = RecordingSystemButtonTransport()
        XCTAssertEqual(
            try VolumeButtonAction(direction: .up, transport: up)
                .execute().semanticLog.routeID,
            "coredevice.button.volumeUp"
        )
        let down = RecordingSystemButtonTransport()
        XCTAssertEqual(
            try VolumeButtonAction(direction: .down, transport: down)
                .execute().semanticLog.routeID,
            "coredevice.button.volumeDown"
        )
        let mute = RecordingSystemButtonTransport()
        XCTAssertEqual(
            try DeviceMuteAction(transport: mute).execute().result.disposition,
            "acknowledged"
        )
    }

    func testFailureAfterDownBestEffortReleasesThenCleansUp() {
        let recorder = RecordingSystemButtonTransport(failFirstWait: true)
        XCTAssertThrowsError(try LockButtonAction(transport: recorder).execute()) {
            XCTAssertEqual(
                $0 as? SystemButtonActionError,
                .transportFailure
            )
        }
        XCTAssertEqual(recorder.events, [
            .button(usage: 0x30, pressed: true),
            .wait(milliseconds: 500),
            .button(usage: 0x30, pressed: false),
            .cleanup,
        ])
    }

    func testCLICommandsSubmitOnlyCommandIdentity() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let cases: [(String, CLITerminalOutput)] = [
            ("button.appSwitcher", try AppSwitcherCommand(submitter: submitter(
                "button.appSwitcher", "coredevice.button.doubleHome"
            )).run(requestID: uuid(1), actionID: uuid(2), canonicalUDID: target, outputMode: .json)),
            ("button.lock", try LockButtonCommand(submitter: submitter(
                "button.lock", "coredevice.button.lock"
            )).run(requestID: uuid(3), actionID: uuid(4), canonicalUDID: target, outputMode: .json)),
            ("button.volumeUp", try VolumeButtonCommand(direction: .up, submitter: submitter(
                "button.volumeUp", "coredevice.button.volumeUp"
            )).run(requestID: uuid(5), actionID: uuid(6), canonicalUDID: target, outputMode: .json)),
            ("button.volumeDown", try VolumeButtonCommand(direction: .down, submitter: submitter(
                "button.volumeDown", "coredevice.button.volumeDown"
            )).run(requestID: uuid(7), actionID: uuid(8), canonicalUDID: target, outputMode: .json)),
            ("button.mute", try DeviceMuteCommand(submitter: submitter(
                "button.mute", "coredevice.button.mute"
            )).run(requestID: uuid(9), actionID: uuid(10), canonicalUDID: target, outputMode: .json)),
        ]
        for (commandID, output) in cases {
            XCTAssertEqual(output.exitCode, 0, commandID)
            XCTAssertTrue(output.chunk.stdout[0].contains("\"disposition\":\"acknowledged\""))
        }
    }

    private func transport() -> RecordingSystemButtonTransport {
        RecordingSystemButtonTransport()
    }

    private func submitter(_ commandID: String, _ routeID: String) -> CommandSubmitter {
        CommandSubmitter(runtime: SystemButtonRuntime(
            commandID: commandID,
            routeID: routeID
        ))
    }

    private func uuid(_ value: Int) throws -> CanonicalUUID {
        try CanonicalUUID(
            String(format: "00000000-0000-0000-0000-%012x", value)
        )
    }
}

private enum SystemButtonTransportEvent: Equatable {
    case button(usage: UInt16, pressed: Bool)
    case cleanup
    case wait(milliseconds: UInt64)
}

private final class RecordingSystemButtonTransport: SystemButtonTransport,
    @unchecked Sendable
{
    private(set) var events = [SystemButtonTransportEvent]()
    private let failFirstWait: Bool

    init(failFirstWait: Bool = false) {
        self.failFirstWait = failFirstWait
    }

    func sendButton(
        usagePage: UInt16,
        usage: UInt16,
        pressed: Bool
    ) throws {
        XCTAssertEqual(usagePage, 0x0c)
        events.append(.button(usage: usage, pressed: pressed))
    }

    func wait(milliseconds: UInt64) throws {
        events.append(.wait(milliseconds: milliseconds))
        if failFirstWait {
            throw SystemButtonActionError.transportFailure
        }
    }

    func waitForCleanupAcknowledgement(
        timeoutMilliseconds: UInt64
    ) throws {
        XCTAssertEqual(timeoutMilliseconds, 2_000)
        events.append(.cleanup)
    }
}

private struct SystemButtonRuntime: CommandSubmissionRuntime {
    let commandID: String
    let routeID: String

    func submit(
        _ intent: CommandSubmissionIntent
    ) throws -> [CommandSubmissionEvent] {
        XCTAssertEqual(intent.commandID, commandID)
        XCTAssertTrue(intent.rawArguments.isEmpty)
        let terminal = try CommandSubmissionTerminal(
            outcome: .succeeded,
            commitState: .committed,
            routeID: routeID
        )
        return [
            .accepted,
            .authoritativePlan(
                routeID: routeID,
                sourceRevision: 1,
                resumedAfterPreparation: false
            ),
            .queued,
            .started(routeID: routeID),
            .terminal(terminal),
        ]
    }
}
