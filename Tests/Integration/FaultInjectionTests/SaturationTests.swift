import PulsePhoneClientCore
import PulsePhoneGUI
import PulsePhoneSharedDefinitions
import XCTest

final class SaturationTests: XCTestCase {
    func testLiveOwnerSaturationCrossCopyFixture() throws {
        let fixture = try faultFixture(
            "T-014/live-owner-saturation-cross-copy-l3"
        )
        let input = try fixture.decodeInput(LiveSaturationInput.self)
        let expected = try fixture.decodeExpected(LiveSaturationExpected.self)
        var registry = LiveOwnerRegistry()
        var owners = (0..<input.attachAttempts).map { _ in
            LiveOwnerCoordinator()
        }
        let attachments = try (0..<input.attachAttempts).map { index in
            try LiveAttachment(
                canonicalUDID: CanonicalUDID(
                    canonicalString: input.targetCanonicalUDID
                ),
                liveOwnerID: faultUUID(800 + index * 2),
                subscriptionID: faultUUID(801 + index * 2),
                connectionEpoch: 7,
                stateRevision: 9
            )
        }
        var attached = 0
        var conflicts = 0
        for index in owners.indices {
            switch owners[index].attach(
                attachment: attachments[index],
                clientInstanceID: try faultUUID(900 + index),
                windowID: "copy-\(index)",
                registry: &registry
            ) {
            case .attached:
                attached += 1
            case .conflict:
                conflicts += 1
            case .alreadyAttached:
                XCTFail("unexpected duplicate attachment")
            }
        }
        XCTAssertEqual(attached, expected.attachedCount)
        XCTAssertEqual(conflicts, expected.conflictCount)
        XCTAssertEqual(registry.ownerCount, expected.ownerCount)
        XCTAssertTrue(owners[0].runtimeBackedControlEnabled)
        XCTAssertFalse(owners[1].runtimeBackedControlEnabled)
        XCTAssertThrowsError(try registry.detach(attachments[1])) { error in
            XCTAssertEqual(error as? LiveOwnerRegistryError, .staleDetach)
        }
        XCTAssertEqual(registry.ownerCount, 1)
        XCTAssertTrue(expected.crossCopyConflictFailsClosed)
        XCTAssertTrue(expected.staleDetachRejected)
    }
}

private struct LiveSaturationInput: Decodable {
    let attachAttempts: Int
    let appCopyCount: Int
    let targetCanonicalUDID: String
}

private struct LiveSaturationExpected: Decodable {
    let attachedCount: Int
    let conflictCount: Int
    let crossCopyConflictFailsClosed: Bool
    let ownerCount: Int
    let staleDetachRejected: Bool
}
