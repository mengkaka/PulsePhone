import Foundation
import PulsePhoneCLI
import PulsePhoneClientCore
import PulsePhoneLogging
import PulsePhoneSharedDefinitions
import XCTest

final class DiagnosticLogTests: XCTestCase {
    func testDiagnosticsLifecycleCapPathFixture() throws {
        let input = try loadRequirementObject(
            "T-010/diagnostics-lifecycle-cap-path-l3",
            relativePath: "input/input.v1.json"
        )
        let expected = try loadRequirementObject(
            "T-010/diagnostics-lifecycle-cap-path-l3",
            relativePath: "expected.v1.json"
        )
        let path = try XCTUnwrap(string(input["absolutePath"]))
        let maximum = Int(try XCTUnwrap(uint(input["maximumFileBytes"])))
        let reserve = Int(try XCTUnwrap(uint(input["footerReserveBytes"])))
        var controller = DiagnosticController()
        let start = try controller.start(
            sessionID: uuid(1),
            controlTokenID: uuid(2),
            absolutePath: path,
            maximumFileBytes: maximum,
            footerReserveBytes: reserve
        )
        XCTAssertEqual(start.absolutePath, path)
        XCTAssertEqual(controller.snapshot.controlMutationTokenCount, 0)

        var automatic: DiagnosticLogFinalization?
        for index in 0..<32 {
            let result = try controller.recordBestEffort(event(index))
            if case .autoFinalized(let finalization) = result.disposition {
                automatic = finalization
                break
            }
        }
        let capped = try XCTUnwrap(automatic)
        XCTAssertEqual(capped.completeness, .incomplete)
        XCTAssertLessThanOrEqual(capped.byteCount, maximum)
        XCTAssertNil(controller.snapshot.activeSessionID)
        XCTAssertFalse(controller.snapshot.lastAutomaticReceiptExists)
        XCTAssertThrowsError(try controller.stop(controlTokenID: uuid(3))) {
            error in
            XCTAssertEqual(
                error as? DiagnosticControlError,
                .noActiveDiagnostics
            )
        }
        XCTAssertEqual(string(expected["stablePath"]), path)
        XCTAssertEqual(uint(expected["hardCapBytes"]), UInt64(maximum))

        let second = try controller.start(
            sessionID: uuid(4),
            controlTokenID: uuid(5),
            absolutePath: path
        )
        let stopped = try controller.stop(controlTokenID: uuid(6))
        XCTAssertEqual(second.absolutePath, stopped.absolutePath)
        XCTAssertEqual(stopped.completeness, .complete)
        XCTAssertEqual(controller.snapshot.controlMutationTokenCount, 0)
    }

    func testLoggingFailureCommandIsolationFixture() throws {
        let input = try loadRequirementObject(
            "T-010/logging-failure-command-isolation-l3",
            relativePath: "input/input.v1.json"
        )
        let expected = try loadRequirementObject(
            "T-010/logging-failure-command-isolation-l3",
            relativePath: "expected.v1.json"
        )
        var controller = DiagnosticController()
        _ = try controller.start(
            sessionID: uuid(10),
            controlTokenID: uuid(11),
            absolutePath: "/tmp/pulsephone-diagnostic-isolation.jsonl"
        )
        let result = try controller.recordBestEffort(
            DiagnosticLogEvent(
                category: .backend,
                code: try XCTUnwrap(string(input["diagnosticCode"]))
            ),
            writeAvailable: false,
            footerWriteAvailable: false
        )
        XCTAssertTrue(result.commandMayContinue)
        guard case .autoFinalized(let finalization) = result.disposition else {
            return XCTFail("expected automatic finalization")
        }
        XCTAssertEqual(finalization.completeness, .incomplete)
        XCTAssertEqual(
            string(input["commandOutcome"]),
            string(expected["commandOutcomeAfterLoggingFailure"])
        )
        XCTAssertNil(controller.snapshot.activeSessionID)
        XCTAssertEqual(
            try controller.recordBestEffort(event(99)).disposition,
            .noActive
        )
    }

    func testLoggingRedactionPrivacyFixture() throws {
        let input = try loadRequirementObject(
            "T-010/logging-redaction-privacy-l5",
            relativePath: "input/input.v1.json"
        )
        let expected = try loadRequirementObject(
            "T-010/logging-redaction-privacy-l5",
            relativePath: "expected.v1.json"
        )
        var writer = try DiagnosticLogWriter(
            sessionID: uuid(20),
            absolutePath: try XCTUnwrap(string(input["path"]))
        )
        _ = try writer.append(DiagnosticLogEvent(
            category: .supervision,
            code: "backend.failure",
            occurrenceCount: 2
        ))
        _ = try writer.stop()
        let diagnostic = String(decoding: writer.bytes, as: UTF8.self)
        for key in stringArray(expected["forbiddenKeys"]) {
            XCTAssertFalse(diagnostic.contains("\"\(key)\""), key)
        }
        for key in ["artifactBytes", "inputFrame", "path", "text"] {
            if let secret = string(input[key]) {
                XCTAssertFalse(diagnostic.contains(secret), key)
            }
        }
        XCTAssertTrue(diagnostic.contains("\"redacted\":true"))
    }

    func testShutdownFinalizeDeadlineAndCLIProjection() throws {
        var controller = DiagnosticController()
        _ = try controller.start(
            sessionID: uuid(30),
            controlTokenID: uuid(31),
            absolutePath: "/tmp/pulsephone-diagnostic-shutdown.jsonl"
        )
        let timedOut = try XCTUnwrap(controller.finalizeForShutdown(
            elapsedNanoseconds: DiagnosticController
                .shutdownFinalizeDeadlineNanoseconds + 1
        ))
        XCTAssertEqual(timedOut.completeness, .incomplete)
        XCTAssertEqual(timedOut.reason, .shutdownTimeout)
        XCTAssertFalse(timedOut.footerWritten)
        XCTAssertEqual(controller.snapshot.controlMutationTokenCount, 0)

        let udid = try CanonicalUDID(canonicalString: "A")
        let startOutput = try DiagnosticsStartCommand.render(
            DiagnosticStartResult(
                absolutePath: timedOut.absolutePath,
                sessionID: timedOut.sessionID
            ),
            canonicalUDID: udid,
            outputMode: .json
        )
        XCTAssertEqual(startOutput.exitCode, 0)
        XCTAssertEqual(
            DiagnosticsStopCommand.route(runtimePresence: .compatible),
            .runtimeStop
        )
        XCTAssertEqual(
            DiagnosticsStopCommand.route(runtimePresence: .incompatible),
            .unavailable
        )
        XCTAssertEqual(
            DiagnosticsStopCommand.route(runtimePresence: .absent),
            .noActiveDiagnostics
        )
    }

    private func event(_ value: Int) throws -> DiagnosticLogEvent {
        try DiagnosticLogEvent(
            category: .lifecycle,
            code: "operation.\(value)",
            occurrenceCount: 1
        )
    }

    private func uuid(_ value: Int) throws -> CanonicalUUID {
        try CanonicalUUID(
            String(format: "00000000-0000-0000-0000-%012x", value)
        )
    }

    private func loadRequirementObject(
        _ requirementID: String,
        relativePath: String
    ) throws -> RepositoryJSONObject {
        try loadObject(
            "Fixtures/requirements/\(requirementID)/\(relativePath)"
        )
    }

    private func loadObject(_ relativePath: String) throws -> RepositoryJSONObject {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
        return try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](data),
            maximumByteCount: 16 * 1_024
        ).root
    }

    private func string(_ value: RepositoryJSONValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        return value
    }

    private func stringArray(_ value: RepositoryJSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap(string)
    }

    private func uint(_ value: RepositoryJSONValue?) -> UInt64? {
        guard let number = value?.numberValue else { return nil }
        return try? number.requireUInt64()
    }
}
