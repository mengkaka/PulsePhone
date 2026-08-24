import PulsePhoneRuntimeKernel
import PulsePhoneSharedDefinitions
import PulsePhoneWire
import XCTest

final class PartialWriteTests: XCTestCase {
    func testIPCMalformedBackpressureCapacityFixture() throws {
        let fixture = try faultFixture(
            "T-016/ipc-malformed-backpressure-capacity-l3"
        )
        let input = try fixture.decodeInput(IPCCapacityInput.self)
        let expected = try fixture.decodeExpected(IPCCapacityExpected.self)
        let frame = RuntimeWireFrame(
            messageType: .progress,
            payload: [1]
        )
        let saturated = SerializedWriter()
        for _ in 0..<input.regularFrameAttempts - 1 {
            XCTAssertEqual(
                try saturated.enqueue(frame, lane: .regularReliable),
                .enqueued
            )
        }
        XCTAssertEqual(
            try saturated.enqueue(frame, lane: .regularReliable),
            .regularQueueSaturated
        )
        for _ in 0..<input.finalControlAttempts - 1 {
            XCTAssertEqual(
                try saturated.enqueue(frame, lane: .finalControl),
                .enqueued
            )
        }
        XCTAssertEqual(
            try saturated.enqueue(frame, lane: .finalControl),
            .disconnectRequired
        )

        let partial = SerializedWriter()
        XCTAssertEqual(try partial.enqueue(frame, lane: .regularReliable), .enqueued)
        XCTAssertEqual(
            try partial.drainNext(now: faultInstant(0)) { bytes in
                min(input.partialWriteBytes, bytes.count)
            },
            .partial
        )
        XCTAssertEqual(
            try partial.drainNext(now: faultInstant(1)) { $0.count },
            .frameCompleted(.progress)
        )

        let stalled = SerializedWriter()
        _ = try stalled.enqueue(frame, lane: .regularReliable)
        XCTAssertEqual(
            try stalled.drainNext(now: faultInstant(0)) { _ in 0 },
            .wouldBlock
        )
        XCTAssertThrowsError(try stalled.drainNext(
            now: faultInstant(SerializedWriter.writeTimeoutNanoseconds + 1)
        ) { _ in 0 }) { error in
            XCTAssertEqual(error as? SerializedWriterError, .writeTimedOut)
        }
        XCTAssertThrowsError(try RuntimeWireFrameCodec.decode([0])) { error in
            XCTAssertEqual(error as? RuntimeWireCodecError, .invalidHeader)
        }

        for fault in input.ancillaryFaults {
            XCTAssertThrowsError(try transcript(for: fault).validate())
        }
        XCTAssertEqual(expected.regularFrameCap, SerializedWriter.regularFrameCap)
        XCTAssertEqual(
            expected.finalControlFrameCap,
            SerializedWriter.finalControlFrameCap
        )
        XCTAssertEqual(
            expected.writeTimeoutNanoseconds,
            SerializedWriter.writeTimeoutNanoseconds
        )
        XCTAssertTrue(expected.malformedFrameRejected)
        XCTAssertTrue(expected.partialWritePreservesOrder)
        XCTAssertTrue(expected.invalidAncillaryRejected)
    }

    private func transcript(
        for fault: String
    ) -> ArtifactFDSCMRightsTranscript {
        switch fault {
        case "duplicateFD":
            ArtifactFDSCMRightsTranscript(
                headerByteCount: 16,
                firstSendByteCount: 1,
                firstSendFDCount: 2,
                remainingHeaderFDCount: 0,
                payloadAncillaryFDCount: 0,
                receiverControlTruncated: false
            )
        case "remainingHeaderFD":
            ArtifactFDSCMRightsTranscript(
                headerByteCount: 16,
                firstSendByteCount: 1,
                firstSendFDCount: 1,
                remainingHeaderFDCount: 1,
                payloadAncillaryFDCount: 0,
                receiverControlTruncated: false
            )
        case "payloadFD":
            ArtifactFDSCMRightsTranscript(
                headerByteCount: 16,
                firstSendByteCount: 1,
                firstSendFDCount: 1,
                remainingHeaderFDCount: 0,
                payloadAncillaryFDCount: 1,
                receiverControlTruncated: false
            )
        default:
            ArtifactFDSCMRightsTranscript(
                headerByteCount: 16,
                firstSendByteCount: 1,
                firstSendFDCount: 1,
                remainingHeaderFDCount: 0,
                payloadAncillaryFDCount: 0,
                receiverControlTruncated: true
            )
        }
    }
}

private struct IPCCapacityInput: Decodable {
    let ancillaryFaults: [String]
    let finalControlAttempts: Int
    let partialWriteBytes: Int
    let regularFrameAttempts: Int
}

private struct IPCCapacityExpected: Decodable {
    let finalControlFrameCap: Int
    let invalidAncillaryRejected: Bool
    let malformedFrameRejected: Bool
    let partialWritePreservesOrder: Bool
    let regularFrameCap: Int
    let writeTimeoutNanoseconds: UInt64
}
