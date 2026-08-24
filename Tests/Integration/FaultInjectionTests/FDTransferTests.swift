import PulsePhoneRuntimeKernel
import XCTest

final class FDTransferTests: XCTestCase {
    func testDescriptorAppearsOnlyOnFirstHeaderWrite() throws {
        try ArtifactFDSCMRightsTranscript(
            headerByteCount: 16,
            firstSendByteCount: 1,
            firstSendFDCount: 1,
            remainingHeaderFDCount: 0,
            payloadAncillaryFDCount: 0,
            receiverControlTruncated: false
        ).validate()
        XCTAssertThrowsError(try ArtifactFDSCMRightsTranscript(
            headerByteCount: 16,
            firstSendByteCount: 0,
            firstSendFDCount: 1,
            remainingHeaderFDCount: 0,
            payloadAncillaryFDCount: 0,
            receiverControlTruncated: false
        ).validate())
    }
}
