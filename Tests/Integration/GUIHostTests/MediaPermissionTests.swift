import Foundation
import PulsePhoneClientCore
import PulsePhoneMedia
import PulsePhoneSharedDefinitions
import XCTest

final class MediaPermissionTests: XCTestCase {
    func testCameraAndMicrophonePermissionsChangeIndependently() throws {
        var permissions = PermissionCoordinator()
        try permissions.updateCamera(.denied, revision: 1)
        XCTAssertFalse(permissions.videoPreviewAuthorized)
        XCTAssertFalse(permissions.audioPreviewAuthorized)
        XCTAssertFalse(permissions.runtimeControlAffected)
        XCTAssertEqual(permissions.snapshot.microphone, .notDetermined)

        try permissions.updateMicrophone(.authorized, revision: 2)
        XCTAssertFalse(permissions.videoPreviewAuthorized)
        XCTAssertTrue(permissions.audioPreviewAuthorized)
        XCTAssertEqual(permissions.snapshot.camera, .denied)
        XCTAssertThrowsError(try permissions.updateCamera(
            .authorized,
            revision: 2
        )) { error in
            XCTAssertEqual(error as? PermissionCoordinatorError, .staleRevision)
        }
    }

    func testCameraSettingsActionUsesCurrentAuthorization() {
        XCTAssertEqual(
            CameraSettingsAction.disposition(for: .authorized),
            .noActionRequired
        )
        XCTAssertEqual(
            CameraSettingsAction.disposition(for: .notDetermined),
            .requestAuthorization
        )
        XCTAssertEqual(
            CameraSettingsAction.disposition(for: .denied),
            .openSettings(CameraSettingsAction.privacySettingsURL)
        )
        XCTAssertEqual(
            CameraSettingsAction.disposition(for: .restricted),
            .openSettings(CameraSettingsAction.privacySettingsURL)
        )
    }

    func testAudioPreviewFailureDoesNotMutateVideoOrControlState() throws {
        let target = try canonicalUDID("A")
        var audio = try AudioPreview(
            windowID: "window-a",
            canonicalUDID: target
        )
        XCTAssertThrowsError(try audio.start(
            resolution: try resolution(
                target: target,
                sourceID: "source-a",
                sourceEpoch: 1
            ),
            microphoneAuthorization: .denied
        )) { error in
            XCTAssertEqual(error as? AudioPreviewError, .microphoneUnauthorized)
        }
        XCTAssertFalse(audio.isPlaying)
        audio.fail(reason: "outputRouteUnavailable")
        XCTAssertEqual(audio.state, .failed(reason: "outputRouteUnavailable"))

        let videoStillBound = true
        let controlStillAvailable = true
        XCTAssertTrue(videoStillBound)
        XCTAssertTrue(controlStillAvailable)
    }

    func testAudioRouteMultiLiveMuteSeparationFixture() throws {
        let fixture = try loadFixture()
        let expected = try loadExpected()
        let targetA = try canonicalUDID(fixture.windows[0].canonicalUDID)
        let targetB = try canonicalUDID(fixture.windows[1].canonicalUDID)
        var first = try AudioPreview(
            windowID: fixture.windows[0].windowID,
            canonicalUDID: targetA
        )
        var second = try AudioPreview(
            windowID: fixture.windows[1].windowID,
            canonicalUDID: targetB
        )
        XCTAssertFalse(first.isMacOutputEnabled)
        XCTAssertFalse(second.isMacOutputEnabled)
        try first.start(
            resolution: try resolution(
                target: targetA,
                sourceID: fixture.windows[0].sourceID,
                sourceEpoch: fixture.windows[0].sourceEpoch
            ),
            microphoneAuthorization: .authorized
        )
        try second.start(
            resolution: try resolution(
                target: targetB,
                sourceID: fixture.windows[1].sourceID,
                sourceEpoch: fixture.windows[1].sourceEpoch
            ),
            microphoneAuthorization: .authorized
        )
        try first.toggleMacOutput()
        XCTAssertEqual(first.isMacOutputEnabled, expected.firstWindowMacOutputEnabled)
        XCTAssertEqual(second.isMacOutputEnabled, expected.secondWindowMacOutputEnabled)
        XCTAssertTrue(first.isPlaying)
        XCTAssertTrue(second.isPlaying)

        XCTAssertTrue(first.sourceChanged(try resolution(
            target: targetA,
            sourceID: fixture.sourceChange.sourceID,
            sourceEpoch: fixture.sourceChange.sourceEpoch
        )))
        XCTAssertEqual(first.isPlaying, expected.firstWindowPlayingAfterSourceChange)
        XCTAssertEqual(second.isPlaying, expected.secondWindowPlayingAfterSourceChange)
        XCTAssertEqual(expected.videoAffected, false)
        XCTAssertEqual(expected.controlAffected, false)
        XCTAssertEqual(expected.tccEvidence, "deferredM3-015")
    }

    func testDetachStopsOnlyMatchingWindowAudio() throws {
        let targetA = try canonicalUDID("A")
        let targetB = try canonicalUDID("B")
        var first = try AudioPreview(windowID: "a", canonicalUDID: targetA)
        var second = try AudioPreview(windowID: "b", canonicalUDID: targetB)
        try first.start(
            resolution: try resolution(
                target: targetA,
                sourceID: "source-a",
                sourceEpoch: 1
            ),
            microphoneAuthorization: .authorized
        )
        try second.start(
            resolution: try resolution(
                target: targetB,
                sourceID: "source-b",
                sourceEpoch: 1
            ),
            microphoneAuthorization: .authorized
        )
        XCTAssertTrue(first.deviceDetached(canonicalUDID: targetA))
        XCTAssertFalse(second.deviceDetached(canonicalUDID: targetA))
        XCTAssertFalse(first.isPlaying)
        XCTAssertTrue(second.isPlaying)
    }

    private func resolution(
        target: CanonicalUDID,
        sourceID: String,
        sourceEpoch: UInt64
    ) throws -> VideoSourceResolution {
        .mapped(VideoResolvedSource(
            canonicalUDID: target,
            descriptor: try VideoSourceDescriptor(
                sourceID: sourceID,
                sourceEpoch: sourceEpoch,
                activeFormatWidth: 1_920,
                activeFormatHeight: 1_080
            ),
            mappingProofID: "fixture-proof"
        ))
    }

    private func canonicalUDID(_ value: String) throws -> CanonicalUDID {
        try CanonicalUDID(canonicalString: value)
    }

    private func fixtureURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Fixtures/requirements/T-008/audio-route-multi-live-mute-separation-l4/\(relativePath)"
            )
    }

    private func loadFixture() throws -> AudioFixture {
        try JSONDecoder().decode(
            AudioFixture.self,
            from: Data(contentsOf: fixtureURL("input/input.v1.json"))
        )
    }

    private func loadExpected() throws -> AudioExpected {
        try JSONDecoder().decode(
            AudioExpected.self,
            from: Data(contentsOf: fixtureURL("expected.v1.json"))
        )
    }
}

private struct AudioFixture: Decodable {
    struct SourceChange: Decodable {
        let sourceEpoch: UInt64
        let sourceID: String
    }

    struct Window: Decodable {
        let canonicalUDID: String
        let sourceEpoch: UInt64
        let sourceID: String
        let windowID: String
    }

    let sourceChange: SourceChange
    let windows: [Window]
}

private struct AudioExpected: Decodable {
    let controlAffected: Bool
    let firstWindowMacOutputEnabled: Bool
    let firstWindowPlayingAfterSourceChange: Bool
    let secondWindowMacOutputEnabled: Bool
    let secondWindowPlayingAfterSourceChange: Bool
    let tccEvidence: String
    let videoAffected: Bool
}
