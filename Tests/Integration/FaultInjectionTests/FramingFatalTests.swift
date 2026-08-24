import Foundation
import PulsePhoneRuntimeKernel
import PulsePhoneWire
import XCTest

final class FramingFatalTests: XCTestCase {
    func testFailureIsolationFixture() throws {
        let fixture = try faultFixture("T-020/failure-isolation-l3")
        let input = try fixture.decodeInput(FailureIsolationInput.self)
        let expected = try fixture.decodeExpected(
            FailureIsolationExpected.self
        )
        var latch = FramingFatalLatch()
        var rejected = 0
        for fault in input.framingFaults {
            XCTAssertThrowsError(try decodeFault(fault)) { error in
                XCTAssertNotNil(error as? HelperWireCodecError)
            }
            rejected += 1
            _ = latch.observeFatalFraming()
        }

        var failed = try ExecutorGenerationController(
            runtimeEpoch: input.runtimeEpoch,
            connectionEpoch: input.connectionEpoch,
            executorGeneration: input.failedExecutorGeneration,
            preparationAttemptID: "preparation.framing"
        )
        _ = try failed.commitReady(callback: failed.preparationFenceToken())
        _ = try failed.markSuspectDisconnect()
        let terminal = try failed.confirmFatalTransport()

        var healthy = try ExecutorGenerationController(
            runtimeEpoch: input.runtimeEpoch,
            connectionEpoch: input.connectionEpoch,
            executorGeneration: input.healthyExecutorGeneration,
            preparationAttemptID: "preparation.healthy"
        )
        _ = try healthy.commitReady(callback: healthy.preparationFenceToken())

        XCTAssertEqual(rejected, expected.rejectedFaultCount)
        XCTAssertEqual(latch.fatalTransitionCount, expected.fatalTransitionCount)
        XCTAssertEqual(terminal.state.rawValue, expected.failedState)
        XCTAssertEqual(terminal.failure?.rawValue, expected.failure)
        XCTAssertEqual(healthy.snapshot.state.rawValue, expected.healthyState)
    }

    private func decodeFault(_ fault: String) throws -> HelperWireMessage {
        switch fault {
        case "missingNewline":
            return try HelperWireCodec.decodeLine(
                Array("{}".utf8),
                direction: .helperToRuntime
            )
        case "invalidJSON":
            return try HelperWireCodec.decodeLine(
                Array("{\n".utf8),
                direction: .helperToRuntime
            )
        case "unsupportedMessage":
            return try HelperWireCodec.decodeLine(
                Array("{\"type\":\"Unknown\"}\n".utf8),
                direction: .helperToRuntime
            )
        case "wrongDirection":
            let line = try HelperWireCodec.encodeLine(
                fields: helloFields(),
                direction: .helperToRuntime
            )
            return try HelperWireCodec.decodeLine(
                line,
                direction: .runtimeToHelper
            )
        default:
            throw FramingFatalTestError.unknownFault
        }
    }

    private func helloFields() -> [String: HelperWireJSONValue] {
        [
            "executorGeneration": .unsignedInteger(3),
            "helperBuildID": .string("build"),
            "helperKind": .string("direct"),
            "manifestHash": .string(String(repeating: "a", count: 64)),
            "messageID": .string(
                "00000000-0000-0000-0000-000000000001"
            ),
            "processStartIdentity": .string("1.000002"),
            "runtimeEpoch": .unsignedInteger(7),
            "schemaVersion": .unsignedInteger(1),
            "type": .string(HelperWireMessageID.hello.rawValue),
        ]
    }
}

private enum FramingFatalTestError: Error {
    case unknownFault
}

private struct FramingFatalLatch {
    private(set) var fatalTransitionCount = 0
    private var observed = false

    mutating func observeFatalFraming() -> Bool {
        guard !observed else { return false }
        observed = true
        fatalTransitionCount += 1
        return true
    }
}

private struct FailureIsolationInput: Decodable {
    let connectionEpoch: UInt64
    let failedExecutorGeneration: UInt64
    let framingFaults: [String]
    let healthyExecutorGeneration: UInt64
    let runtimeEpoch: UInt64
}

private struct FailureIsolationExpected: Decodable {
    let failedState: String
    let failure: String
    let fatalTransitionCount: Int
    let healthyState: String
    let rejectedFaultCount: Int
}
