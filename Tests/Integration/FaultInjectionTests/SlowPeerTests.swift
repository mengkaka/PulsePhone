import PulsePhoneRuntimeKernel
import PulsePhoneWire
import XCTest

final class SlowPeerTests: XCTestCase {
    func testSlowPeerNeverExtendsSerializedWriteDeadline() throws {
        var peer = FakePeer()
        try peer.configureSlowPeer(
            maximumBytesPerDrain: 2,
            stallNanoseconds: 10,
            now: faultInstant(0)
        )
        let writer = SerializedWriter()
        _ = try writer.enqueue(
            RuntimeWireFrame(messageType: .progress, payload: [1, 2, 3]),
            lane: .regularReliable
        )
        XCTAssertEqual(
            try writer.drainNext(now: faultInstant(0)) { bytes in
                try peer.drainCount(requestedBytes: bytes.count, now: faultInstant(0))
            },
            .wouldBlock
        )
        XCTAssertThrowsError(try writer.drainNext(
            now: faultInstant(SerializedWriter.writeTimeoutNanoseconds + 1)
        ) { bytes in
            try peer.drainCount(
                requestedBytes: bytes.count,
                now: faultInstant(SerializedWriter.writeTimeoutNanoseconds + 1)
            )
        }) { error in
            XCTAssertEqual(error as? SerializedWriterError, .writeTimedOut)
        }
    }
}
