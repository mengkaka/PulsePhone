import Foundation
import PulsePhoneCLI
import PulsePhoneClientCore
import PulsePhoneLogging
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions
import XCTest

final class ReplayTraceTests: XCTestCase {
    func testReplayTraceFooterCapFinalizeFixture() throws {
        let input = try loadRequirementObject(
            "T-013/replay-trace-footer-cap-finalize-l3",
            relativePath: "input/input.v1.json"
        )
        let expected = try loadRequirementObject(
            "T-013/replay-trace-footer-cap-finalize-l3",
            relativePath: "expected.v1.json"
        )
        let maximum = Int(try XCTUnwrap(uint(input["maximumFileBytes"])))
        let reserve = Int(try XCTUnwrap(uint(input["footerReserveBytes"])))
        var controller = ReplayTraceController()
        var inhibitorVisibleBeforeOpen = false
        _ = try controller.start(
            traceID: uuid(1),
            inhibitorTokenID: uuid(2),
            absolutePath: "/tmp/pulsephone-trace-cap.jsonl",
            maximumFileBytes: maximum,
            footerReserveBytes: reserve,
            beforeWriterOpen: { snapshot in
                inhibitorVisibleBeforeOpen = snapshot.blockers.contains {
                    $0.kind == .activeTrace && $0.state == "traceStarting"
                }
            }
        )
        XCTAssertTrue(inhibitorVisibleBeforeOpen)

        var automatic: ReplayTraceFinalization?
        for index in 0..<16 {
            let disposition = try controller.append(event(index))
            if case .autoFinalized(let finalization) = disposition {
                automatic = finalization
                break
            }
        }
        let capped = try XCTUnwrap(automatic)
        XCTAssertEqual(
            capped.completeness.rawValue,
            string(expected["automaticCompleteness"])
        )
        XCTAssertLessThanOrEqual(capped.byteCount, maximum)
        XCTAssertNil(controller.snapshot.activeTraceID)
        XCTAssertEqual(controller.snapshot.inhibitorSnapshot.tokenCount, 0)
        XCTAssertFalse(controller.snapshot.lastAutomaticReceiptExists)

        var noFooterController = ReplayTraceController()
        _ = try noFooterController.start(
            traceID: uuid(3),
            inhibitorTokenID: uuid(4),
            absolutePath: "/tmp/pulsephone-trace-no-footer.jsonl",
            maximumFileBytes: maximum,
            footerReserveBytes: reserve
        )
        let failedWrite = try noFooterController.append(
            event(99),
            semanticWriteAvailable: false,
            incompleteFooterWriteAvailable: false
        )
        guard case .autoFinalized(let noFooter) = failedWrite else {
            return XCTFail("expected automatic no-footer finalization")
        }
        XCTAssertEqual(
            noFooter.completeness.rawValue,
            string(expected["noFooterCompleteness"])
        )
        XCTAssertEqual(noFooterController.snapshot.inhibitorSnapshot.tokenCount, 0)
    }

    func testReplayTraceRedactionFixture() throws {
        let input = try loadRequirementObject(
            "T-013/replay-trace-redaction-l5",
            relativePath: "input/input.v1.json"
        )
        let expected = try loadRequirementObject(
            "T-013/replay-trace-redaction-l5",
            relativePath: "expected.v1.json"
        )
        var writer = try ReplayTraceWriter(
            traceID: uuid(10),
            absolutePath: try XCTUnwrap(string(input["path"]))
        )
        _ = try writer.append(ReplayTraceSemanticEvent(
            actionID: uuid(11),
            commandID: "text.type",
            eventKind: .result,
            outcome: .succeeded,
            payloadByteCount: 42
        ))
        _ = try writer.stop()
        let trace = String(decoding: writer.bytes, as: UTF8.self)
        for key in stringArray(expected["forbiddenKeys"]) {
            XCTAssertFalse(trace.contains("\"\(key)\""), key)
        }
        for key in ["artifactBytes", "inputFrame", "path", "text"] {
            if let secret = string(input[key]) {
                XCTAssertFalse(trace.contains(secret), key)
            }
        }
        XCTAssertTrue(trace.contains("\"redacted\":true"))
        XCTAssertFalse(trace.contains(try XCTUnwrap(string(input["path"]))))
    }

    func testReplayTraceSingleActiveFixture() throws {
        let input = try loadRequirementObject(
            "T-013/replay-trace-single-active-l3",
            relativePath: "input/input.v1.json"
        )
        let expected = try loadRequirementObject(
            "T-013/replay-trace-single-active-l3",
            relativePath: "expected.v1.json"
        )
        let path = try XCTUnwrap(string(input["absolutePath"]))
        var controller = ReplayTraceController()
        let start = try controller.start(
            traceID: uuid(20),
            inhibitorTokenID: uuid(21),
            absolutePath: path
        )
        XCTAssertThrowsError(try controller.start(
            traceID: uuid(22),
            inhibitorTokenID: uuid(23),
            absolutePath: "/tmp/second-trace.jsonl"
        )) { error in
            XCTAssertEqual(
                error as? ReplayTraceControlError,
                .traceAlreadyActive
            )
        }
        let stop = try controller.stop()
        XCTAssertEqual(start.absolutePath, stop.absolutePath)
        XCTAssertEqual(stop.absolutePath, string(expected["stablePath"]))
        XCTAssertEqual(stop.completeness, .complete)
        XCTAssertThrowsError(try controller.stop()) { error in
            XCTAssertEqual(error as? ReplayTraceControlError, .noActiveTrace)
        }
    }

    func testReplayTraceStopBlockerFixture() throws {
        let expected = try loadRequirementObject(
            "T-013/replay-trace-stop-blocker-l3",
            relativePath: "expected.v1.json"
        )
        var controller = ReplayTraceController()
        _ = try controller.start(
            traceID: uuid(30),
            inhibitorTokenID: uuid(31),
            absolutePath: "/tmp/pulsephone-trace-blocker.jsonl"
        )
        let blocker = try XCTUnwrap(
            controller.snapshot.inhibitorSnapshot.blockers.first
        )
        XCTAssertEqual(blocker.kind.rawValue, string(expected["blockerKind"]))
        XCTAssertEqual(blocker.retryWhen.rawValue, string(expected["retryWhen"]))
        XCTAssertEqual(blocker.count, 1)
        _ = try controller.stop()
        XCTAssertEqual(controller.snapshot.inhibitorSnapshot.tokenCount, 0)
    }

    func testProductFixtureAndCLIProjection() throws {
        let fixture = try loadObject(
            "Fixtures/product-actions/replay-trace/cases.v1.json"
        )
        XCTAssertEqual(
            uint(fixture["maximumFileBytes"]),
            UInt64(ReplayTraceWriter.maximumFileBytes)
        )
        XCTAssertEqual(
            uint(fixture["footerReserveBytes"]),
            UInt64(ReplayTraceWriter.footerReserveBytes)
        )
        XCTAssertTrue(TraceStartCommand.runtimeActivationRequested)
        XCTAssertFalse(TraceStopCommand.runtimeActivationRequested)
        XCTAssertEqual(
            TraceStopCommand.route(runtimePresence: .compatible),
            .runtimeStop
        )
        XCTAssertEqual(
            TraceStopCommand.route(runtimePresence: .incompatible),
            .bootstrapStopAndFinalize
        )
        XCTAssertEqual(
            TraceStopCommand.route(runtimePresence: .absent),
            .noActiveTrace
        )
        let udid = try CanonicalUDID(canonicalString: "A")
        let start = ReplayTraceStartResult(
            absolutePath: "/tmp/pulsephone-trace-cli.jsonl",
            traceID: try uuid(40)
        )
        let startOutput = try TraceStartCommand.render(
            start,
            canonicalUDID: udid,
            outputMode: .json
        )
        XCTAssertEqual(startOutput.exitCode, 0)
        XCTAssertTrue(startOutput.chunk.stdout[0].contains("trace.start"))
    }

    private func event(_ value: Int) throws -> ReplayTraceSemanticEvent {
        try ReplayTraceSemanticEvent(
            actionID: uuid(1_000 + value),
            commandID: "touch.tap",
            eventKind: .result,
            outcome: .succeeded,
            payloadByteCount: 512
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
