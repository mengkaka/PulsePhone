import Foundation
import PulsePhoneBackendAdapters
import PulsePhoneCLI
import PulsePhoneClientCore
import PulsePhoneSharedDefinitions
import XCTest

final class HomeButtonActionTests: XCTestCase {
    func testPressReleaseCleanupAckAndSemanticLog() throws {
        let transport = RecordingHomeButtonTransport()
        let execution = try HomeButtonAction(transport: transport).execute()

        XCTAssertEqual(transport.events, [
            .button(page: 0x0c, usage: 0x40, pressed: true),
            .wait(milliseconds: 50),
            .button(page: 0x0c, usage: 0x40, pressed: false),
            .cleanupAck(timeoutMilliseconds: 2_000),
        ])
        XCTAssertEqual(execution.result.disposition, "acknowledged")
        XCTAssertEqual(execution.semanticLog.commandID, "button.home")
        XCTAssertEqual(execution.semanticLog.routeID, "coredevice.button.home")
        XCTAssertTrue(execution.semanticLog.inputReleased)
    }

    func testFailureAfterPressStillReleasesAndWaitsForCleanupAck() {
        let transport = RecordingHomeButtonTransport(failWait: true)
        XCTAssertThrowsError(
            try HomeButtonAction(transport: transport).execute()
        ) { error in
            XCTAssertEqual(error as? HomeButtonActionError, .transportFailure)
        }
        XCTAssertEqual(transport.events, [
            .button(page: 0x0c, usage: 0x40, pressed: true),
            .wait(milliseconds: 50),
            .button(page: 0x0c, usage: 0x40, pressed: false),
            .cleanupAck(timeoutMilliseconds: 2_000),
        ])
    }

    func testMissingCleanupAckIsTerminalFailure() {
        let transport = RecordingHomeButtonTransport(failCleanup: true)
        XCTAssertThrowsError(
            try HomeButtonAction(transport: transport).execute()
        ) { error in
            XCTAssertEqual(
                error as? HomeButtonActionError,
                .cleanupAcknowledgementMissing
            )
        }
    }

    func testCLIProjectsAcknowledgedResultAndUnknownOutcome() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let success = try HomeButtonCommand(
            submitter: CommandSubmitter(runtime: HomeButtonRuntime(
                terminal: CommandSubmissionTerminal(
                    outcome: .succeeded,
                    commitState: .committed,
                    routeID: "coredevice.button.home"
                )
            ))
        ).run(
            requestID: uuid(1),
            actionID: uuid(2),
            canonicalUDID: target,
            outputMode: .json
        )
        XCTAssertEqual(success.exitCode, 0)
        XCTAssertTrue(success.chunk.stdout[0].contains("\"disposition\":\"acknowledged\""))

        let unknown = try HomeButtonCommand(
            submitter: CommandSubmitter(runtime: HomeButtonRuntime(
                terminal: CommandSubmissionTerminal(
                    outcome: .outcomeUnknown,
                    commitState: .unknown,
                    errorCode: "outcomeUnknown"
                )
            ))
        ).run(
            requestID: uuid(3),
            actionID: uuid(4),
            canonicalUDID: target,
            outputMode: .json
        )
        XCTAssertEqual(unknown.exitCode, 7)
        XCTAssertTrue(unknown.chunk.stdout[0].contains("\"runtimeMayContinue\":true"))
    }

    private func uuid(_ value: Int) throws -> CanonicalUUID {
        try CanonicalUUID(
            String(format: "00000000-0000-0000-0000-%012x", value)
        )
    }
}

private enum HomeButtonTransportEvent: Equatable {
    case button(page: UInt16, usage: UInt16, pressed: Bool)
    case wait(milliseconds: UInt64)
    case cleanupAck(timeoutMilliseconds: UInt64)
}

private final class RecordingHomeButtonTransport: HomeButtonTransport,
    @unchecked Sendable
{
    private(set) var events = [HomeButtonTransportEvent]()
    private let failWait: Bool
    private let failCleanup: Bool

    init(failWait: Bool = false, failCleanup: Bool = false) {
        self.failWait = failWait
        self.failCleanup = failCleanup
    }

    func sendButton(
        usagePage: UInt16,
        usage: UInt16,
        pressed: Bool
    ) throws {
        events.append(.button(
            page: usagePage,
            usage: usage,
            pressed: pressed
        ))
    }

    func wait(milliseconds: UInt64) throws {
        events.append(.wait(milliseconds: milliseconds))
        if failWait { throw HomeButtonActionError.transportFailure }
    }

    func waitForCleanupAcknowledgement(
        timeoutMilliseconds: UInt64
    ) throws {
        events.append(.cleanupAck(
            timeoutMilliseconds: timeoutMilliseconds
        ))
        if failCleanup {
            throw HomeButtonActionError.cleanupAcknowledgementMissing
        }
    }
}

private struct HomeButtonRuntime: CommandSubmissionRuntime {
    let terminal: CommandSubmissionTerminal

    func submit(
        _ intent: CommandSubmissionIntent
    ) throws -> [CommandSubmissionEvent] {
        XCTAssertEqual(intent.commandID, "button.home")
        XCTAssertTrue(intent.rawArguments.isEmpty)
        return [
            .accepted,
            .authoritativePlan(
                routeID: "coredevice.button.home",
                sourceRevision: 1,
                resumedAfterPreparation: false
            ),
            .queued,
            .started(routeID: "coredevice.button.home"),
            .terminal(terminal),
        ]
    }
}
