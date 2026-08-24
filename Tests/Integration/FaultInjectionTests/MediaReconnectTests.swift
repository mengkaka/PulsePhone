import PulsePhoneMedia
import PulsePhoneSharedDefinitions
import XCTest

final class MediaReconnectTests: XCTestCase {
    func testControlVideoDualReconnectFixture() throws {
        let fixture = try faultFixture(
            "T-014/control-video-dual-reconnect-l4"
        )
        let input = try fixture.decodeInput(MediaReconnectInput.self)
        let expected = try fixture.decodeExpected(MediaReconnectExpected.self)
        let target = try CanonicalUDID(
            canonicalString: input.targetCanonicalUDID
        )
        var coordinator = VideoReconnectCoordinator(canonicalUDID: target)
        try apply(input.initial, target: target, coordinator: &coordinator)
        let initial = try XCTUnwrap(coordinator.bindIfReady())

        try coordinator.sourceChanged(try faultVideoResolution(
            target: target,
            sourceID: input.sourceReconnect.sourceID,
            sourceEpoch: input.sourceReconnect.sourceEpoch
        ))
        XCTAssertEqual(
            coordinator.receive(VideoFrameIdentity(
                binding: initial,
                frameSequence: 1
            )),
            .discarded(.unbound)
        )
        let sourceRebound = try XCTUnwrap(coordinator.bindIfReady())
        XCTAssertEqual(
            sourceRebound.sourceEpoch,
            expected.sourceReconnectBindingEpoch
        )

        try coordinator.runtimeReconnected(
            connectionEpoch: input.controlReconnect.connectionEpoch
        )
        XCTAssertTrue(coordinator.controlAvailable)
        XCTAssertFalse(coordinator.coordinateInputAvailable)
        XCTAssertEqual(
            coordinator.receive(VideoFrameIdentity(
                binding: sourceRebound,
                frameSequence: 2
            )),
            .discarded(.unbound)
        )
        try coordinator.updateGeometry(DisplayGeometryDTO(
            connectionEpoch: input.controlReconnect.connectionEpoch,
            geometryRevision: input.controlReconnect.geometryRevision,
            logicalHeight: input.controlReconnect.logicalHeight,
            logicalWidth: input.controlReconnect.logicalWidth,
            orientation: .portrait
        ))
        let controlRebound = try XCTUnwrap(coordinator.bindIfReady())
        XCTAssertEqual(
            controlRebound.connectionEpoch,
            expected.controlReconnectBindingEpoch
        )
        XCTAssertEqual(
            coordinator.receive(VideoFrameIdentity(
                binding: sourceRebound,
                frameSequence: 3
            )),
            .discarded(.connectionEpochMismatch)
        )
    }

    private func apply(
        _ state: MediaReconnectInput.State,
        target: CanonicalUDID,
        coordinator: inout VideoReconnectCoordinator
    ) throws {
        try coordinator.runtimeReconnected(
            connectionEpoch: state.connectionEpoch
        )
        try coordinator.updateGeometry(DisplayGeometryDTO(
            connectionEpoch: state.connectionEpoch,
            geometryRevision: state.geometryRevision,
            logicalHeight: state.logicalHeight,
            logicalWidth: state.logicalWidth,
            orientation: .portrait
        ))
        try coordinator.sourceChanged(try faultVideoResolution(
            target: target,
            sourceID: state.sourceID,
            sourceEpoch: state.sourceEpoch
        ))
    }
}

private struct MediaReconnectInput: Decodable {
    struct ControlReconnect: Decodable {
        let connectionEpoch: UInt64
        let geometryRevision: UInt64
        let logicalHeight: UInt64
        let logicalWidth: UInt64
    }

    struct SourceReconnect: Decodable {
        let sourceEpoch: UInt64
        let sourceID: String
    }

    struct State: Decodable {
        let connectionEpoch: UInt64
        let geometryRevision: UInt64
        let logicalHeight: UInt64
        let logicalWidth: UInt64
        let sourceEpoch: UInt64
        let sourceID: String
    }

    let controlReconnect: ControlReconnect
    let initial: State
    let sourceReconnect: SourceReconnect
    let targetCanonicalUDID: String
}

private struct MediaReconnectExpected: Decodable {
    let controlReconnectBindingEpoch: UInt64
    let sourceReconnectBindingEpoch: UInt64
}
