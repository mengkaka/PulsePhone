import Foundation
import PulsePhoneBackendAdapters
import PulsePhoneCLI
import PulsePhoneClientCore
import PulsePhoneSharedDefinitions
import XCTest

final class TextInputTests: XCTestCase {
    func testTextTypeSetPasteReleaseAndRedactedSemanticLog() throws {
        let fixture = try loadFixture()
        let transport = RecordingTextInputTransport()
        let execution = try TextTypeAction(transport: transport).execute(
            text: fixture.text
        )
        XCTAssertEqual(transport.events, [
            .setPasteboard(fixture.text),
            .readPasteboard,
            .chord(modifiers: [.command], key: "v"),
            .releaseAll,
            .cleanup,
        ])
        XCTAssertEqual(
            execution.semanticLog.utf8ByteCount,
            fixture.expectedUTF8ByteCount
        )
        XCTAssertEqual(
            execution.semanticLog.textRedacted,
            fixture.expectedTextRedacted
        )
        let reflected = String(reflecting: execution.semanticLog)
        XCTAssertFalse(reflected.contains(fixture.text))
        XCTAssertEqual(execution.result.disposition, "pasteDispatched")
    }

    func testUTF8CapFailsBeforePasteboardMutation() {
        let transport = RecordingTextInputTransport()
        XCTAssertThrowsError(try TextTypeAction(transport: transport).execute(
            text: String(repeating: "a", count: 65_537)
        )) { error in
            XCTAssertEqual(
                error as? TextTypeActionError,
                .failure(TextInputFailure(
                    code: "argumentTooLarge",
                    commitState: .notCommitted,
                    outcome: .failed
                ))
            )
        }
        XCTAssertTrue(transport.events.isEmpty)
    }

    func testPasteboardFailureIsNotCommitted() {
        let transport = RecordingTextInputTransport(failure: .pasteboard)
        XCTAssertThrowsError(try TextTypeAction(transport: transport).execute(
            text: "hello"
        )) { error in
            XCTAssertEqual(
                error as? TextTypeActionError,
                .failure(TextInputFailure(
                    code: "pasteboardSetFailed",
                    commitState: .notCommitted,
                    outcome: .failed
                ))
            )
        }
        XCTAssertEqual(transport.events, [.setPasteboard("hello")])
    }

    func testPasteboardReadBackMismatchFailsBeforeChord() {
        let transport = RecordingTextInputTransport(readBack: "other")
        XCTAssertThrowsError(try TextTypeAction(transport: transport).execute(
            text: "hello"
        )) { error in
            XCTAssertEqual(
                error as? TextTypeActionError,
                .failure(TextInputFailure(
                    code: "backendFailed",
                    commitState: .committed,
                    outcome: .failed,
                    stage: "pasteboardReadBack"
                ))
            )
        }
        XCTAssertEqual(transport.events, [
            .setPasteboard("hello"),
            .readPasteboard,
        ])
    }

    func testPasteboardReadBackFailureFailsBeforeChord() {
        let transport = RecordingTextInputTransport(failure: .readBack)
        XCTAssertThrowsError(try TextTypeAction(transport: transport).execute(
            text: "hello"
        )) { error in
            XCTAssertEqual(
                error as? TextTypeActionError,
                .failure(TextInputFailure(
                    code: "backendFailed",
                    commitState: .committed,
                    outcome: .failed,
                    stage: "pasteboardReadBack"
                ))
            )
        }
        XCTAssertEqual(transport.events, [
            .setPasteboard("hello"),
            .readPasteboard,
        ])
    }

    func testPasteFailureAfterSetRemainsCommittedAndReleases() {
        let transport = RecordingTextInputTransport(failure: .chord)
        XCTAssertThrowsError(try TextTypeAction(transport: transport).execute(
            text: "hello"
        )) { error in
            XCTAssertEqual(
                error as? TextTypeActionError,
                .failure(TextInputFailure(
                    code: "pasteFailed",
                    commitState: .committed,
                    outcome: .failed
                ))
            )
        }
        XCTAssertEqual(transport.events, [
            .setPasteboard("hello"),
            .readPasteboard,
            .chord(modifiers: [.command], key: "v"),
            .releaseAll,
            .cleanup,
        ])
    }

    func testReleaseUncertaintyIsOutcomeUnknownAfterCommit() {
        let transport = RecordingTextInputTransport(failure: .release)
        XCTAssertThrowsError(try TextTypeAction(transport: transport).execute(
            text: "hello"
        )) { error in
            XCTAssertEqual(
                error as? TextTypeActionError,
                .failure(TextInputFailure(
                    code: "outcomeUnknown",
                    commitState: .committed,
                    outcome: .outcomeUnknown
                ))
            )
        }
        XCTAssertEqual(transport.cleanupCount, 1)
    }

    func testCLIEnforcesUTF8CapAndDoesNotExposeTextInOutput() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let secret = "secret-user-content"
        let output = try TextTypeCommand(submitter: CommandSubmitter(runtime:
            TextTypeRuntime(expectedText: secret)
        )).run(
            text: secret,
            requestID: uuid(1),
            actionID: uuid(2),
            canonicalUDID: target,
            outputMode: .json
        )
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertFalse(output.chunk.stdout[0].contains(secret))
        XCTAssertTrue(output.chunk.stdout[0].contains(
            "\"disposition\":\"pasteDispatched\""
        ))

        XCTAssertThrowsError(try TextTypeCommand(submitter: CommandSubmitter(
            runtime: TextTypeRuntime(expectedText: "unused")
        )).run(
            text: String(repeating: "a", count: 65_537),
            requestID: uuid(3),
            actionID: uuid(4),
            canonicalUDID: target,
            outputMode: .human
        ))
    }

    private func loadFixture() throws -> TextRedactionFixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/product-actions/text-redaction/cases.v1.json")
        let bytes = [UInt8](try Data(contentsOf: url))
        _ = try RepositoryCanonicalJSON.parseDocument(
            bytes,
            maximumByteCount: 64 * 1_024
        )
        return try JSONDecoder().decode(
            TextRedactionDocument.self,
            from: Data(bytes)
        ).cases[0]
    }

    private func uuid(_ value: Int) throws -> CanonicalUUID {
        try CanonicalUUID(
            String(format: "00000000-0000-0000-0000-%012x", value)
        )
    }
}

private struct TextRedactionDocument: Decodable {
    let cases: [TextRedactionFixture]
}

private struct TextRedactionFixture: Decodable {
    let expectedTextRedacted: Bool
    let expectedUTF8ByteCount: Int
    let text: String
}

private enum TextInputFailurePoint {
    case chord
    case pasteboard
    case readBack
    case release
}

private enum TextInputTransportEvent: Equatable {
    case chord(modifiers: [VirtualKeyboardModifier], key: String)
    case cleanup
    case readPasteboard
    case releaseAll
    case setPasteboard(String)
}

private final class RecordingTextInputTransport: TextInputTransport,
    @unchecked Sendable
{
    private(set) var events = [TextInputTransportEvent]()
    private let failure: TextInputFailurePoint?
    private let readBack: String?

    init(
        failure: TextInputFailurePoint? = nil,
        readBack: String? = nil
    ) {
        self.failure = failure
        self.readBack = readBack
    }

    var cleanupCount: Int {
        events.filter { $0 == .cleanup }.count
    }

    func setPasteboard(_ text: String) throws {
        events.append(.setPasteboard(text))
        if failure == .pasteboard { throw TestTextInputError.failed }
    }

    func readPasteboard() throws -> String? {
        events.append(.readPasteboard)
        if failure == .readBack { throw TestTextInputError.failed }
        if let readBack { return readBack }
        guard case .setPasteboard(let text)? = events.first else { return nil }
        return text
    }

    func sendChord(
        modifiers: [VirtualKeyboardModifier],
        key: String
    ) throws {
        events.append(.chord(modifiers: modifiers, key: key))
        if failure == .chord { throw TestTextInputError.failed }
    }

    func releaseAll() throws {
        events.append(.releaseAll)
        if failure == .release { throw TestTextInputError.failed }
    }

    func waitForCleanupAcknowledgement(
        timeoutMilliseconds: UInt64
    ) throws {
        XCTAssertEqual(timeoutMilliseconds, 2_000)
        events.append(.cleanup)
    }
}

private enum TestTextInputError: Error {
    case failed
}

private struct TextTypeRuntime: CommandSubmissionRuntime {
    let expectedText: String

    func submit(
        _ intent: CommandSubmissionIntent
    ) throws -> [CommandSubmissionEvent] {
        XCTAssertEqual(intent.commandID, "text.type")
        XCTAssertEqual(intent.rawArguments, ["text": expectedText])
        let terminal = try CommandSubmissionTerminal(
            outcome: .succeeded,
            commitState: .committed,
            routeID: "coredevice.pasteboardSetAndPaste"
        )
        return [
            .accepted,
            .authoritativePlan(
                routeID: "coredevice.pasteboardSetAndPaste",
                sourceRevision: 1,
                resumedAfterPreparation: false
            ),
            .queued,
            .started(routeID: "coredevice.pasteboardSetAndPaste"),
            .terminal(terminal),
        ]
    }
}
