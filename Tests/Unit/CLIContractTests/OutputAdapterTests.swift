import Foundation
import PulsePhoneCLI
import PulsePhoneSharedDefinitions
import XCTest

final class OutputAdapterTests: XCTestCase {
    private struct Result: Codable, Equatable {
        let value: String
    }

    func testJSONHasExactlyOneFinalEnvelopeAndNoProgress() throws {
        let adapter = CLIOutputAdapter(mode: .json)
        XCTAssertEqual(adapter.progress("queued"), CLIOutputChunk())
        let terminal = try adapter.success(
            commandID: "device.info",
            target: .device(CanonicalUDID(canonicalString: "AAAA")),
            result: Result(value: "ok"),
            human: "ignored"
        )
        XCTAssertEqual(terminal.exitCode, 0)
        XCTAssertEqual(terminal.chunk.stdout.count, 1)
        XCTAssertTrue(terminal.chunk.stderr.isEmpty)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(terminal.chunk.stdout[0].utf8)
            ) as? [String: Any]
        )
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["commandID"] as? String, "device.info")
        XCTAssertNil(object["error"])
    }

    func testEarlyJSONErrorUsesCommandTokenAndUnresolvedTarget() throws {
        let terminal = try CLIOutputAdapter(mode: .json).failure(
            family: .argument,
            commandToken: "device prepare",
            target: .unresolved(requestedUDID: "bad"),
            error: CLIErrorPayload(code: "invalidUDID")
        )
        XCTAssertEqual(terminal.exitCode, 2)
        XCTAssertEqual(terminal.chunk.stdout.count, 1)
        XCTAssertTrue(terminal.chunk.stderr.isEmpty)
        XCTAssertTrue(terminal.chunk.stdout[0].contains("\"commandToken\":\"device prepare\""))
        XCTAssertTrue(terminal.chunk.stdout[0].contains("\"scope\":\"unresolved\""))
    }

    func testHumanSuccessAndFailureUseSeparateChannels() throws {
        let adapter = CLIOutputAdapter(mode: .human)
        XCTAssertEqual(adapter.progress("started").stderr, ["started"])
        XCTAssertEqual(
            try adapter.success(
                commandID: "devices",
                target: .global,
                result: Result(value: "ok"),
                human: "done"
            ).chunk,
            CLIOutputChunk(stdout: ["done"])
        )
        let failure = try adapter.failure(
            family: .unknownOutcome,
            commandID: "device.prepare",
            target: .device(CanonicalUDID(canonicalString: "AAAA")),
            error: CLIErrorPayload(code: "outcomeUnknown")
        )
        XCTAssertEqual(failure.exitCode, 7)
        XCTAssertEqual(failure.chunk.stderr, ["outcomeUnknown"])

        let detailed = try adapter.failure(
            family: .targetCompatibility,
            commandID: "touch.tap",
            target: .device(CanonicalUDID(canonicalString: "AAAA")),
            error: CLIErrorPayload(
                code: "unsupportedOSVersion",
                details: ["reason": "tap requires iOS 17 or later"],
                message: "Unsupported OSVersion"
            )
        )
        XCTAssertEqual(detailed.exitCode, 3)
        XCTAssertEqual(
            detailed.chunk.stderr,
            ["unsupportedOSVersion: tap requires iOS 17 or later"]
        )
    }
}
