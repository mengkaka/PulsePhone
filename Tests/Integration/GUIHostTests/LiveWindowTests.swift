import Foundation
import PulsePhoneGUI
import PulsePhoneSharedDefinitions
import XCTest

final class LiveWindowTests: XCTestCase {
    func testWindowStartsWithExactIdentityPlaceholder() throws {
        let identity = try makeIdentity()
        let model = try LiveWindowModel(
            identityPlaceholder: identity,
            screenVisibleFrame: screenFrame()
        )

        XCTAssertEqual(identity.primaryText, "Lab iPhone")
        XCTAssertEqual(identity.secondaryText, "00008020-001C2D123456002E")
        XCTAssertEqual(model.aspectSource, .identityPlaceholder)
        XCTAssertEqual(
            model.videoPresentation,
            .identityPlaceholder(identity: identity, reason: .awaitingBinding)
        )
        XCTAssertTrue(screenFrame().contains(model.reservation.windowFrame))
        XCTAssertEqual(
            model.reservation.contentSize.height
                - model.reservation.canvasSize.height,
            LiveWindowReservation.preferredSourceControlsHeight,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            model.reservation.contentSize.width,
            model.reservation.canvasSize.width,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            min(
                model.reservation.canvasSize.width,
                model.reservation.canvasSize.height
            ),
            LiveWindowReservation.preferredCanvasShortEdge,
            accuracy: 0.000_001
        )
        XCTAssertFalse(model.controlCommandsEnabled)
    }

    func testMappingCanvasHintIsOnlyTheLowestPriorityLayoutAuthority() throws {
        var model = try makeModel()
        try model.updatePlaceholderAspectRatioHint(width: 1_170, height: 2_532)

        XCTAssertEqual(model.aspectSource, .identityPlaceholder)
        XCTAssertNil(model.samplePresentation)
        XCTAssertNil(model.runtimeGeometry)
        XCTAssertEqual(
            model.reservation.canvasAspectRatio.value,
            1_170.0 / 2_532.0,
            accuracy: 0.000_001
        )

        _ = try model.updateRuntimeGeometry(geometry(
            connectionEpoch: 7,
            revision: 1,
            width: 2_532,
            height: 1_170
        ))
        XCTAssertEqual(
            model.reservation.canvasAspectRatio.value,
            2_532.0 / 1_170.0,
            accuracy: 0.000_001
        )

        _ = try model.updateSamplePresentation(LiveSamplePresentationFormat(
            sourceEpoch: 9,
            width: 1_170,
            height: 2_532
        ))
        XCTAssertEqual(
            model.reservation.canvasAspectRatio.value,
            1_170.0 / 2_532.0,
            accuracy: 0.000_001
        )

        try model.clearCaptureActiveFormat(throughSourceEpoch: 9)
        XCTAssertEqual(
            model.reservation.canvasAspectRatio.value,
            2_532.0 / 1_170.0,
            accuracy: 0.000_001
        )
        try model.clearRuntimeGeometry(throughConnectionEpoch: 7)
        XCTAssertEqual(
            model.reservation.canvasAspectRatio.value,
            1_170.0 / 2_532.0,
            accuracy: 0.000_001
        )

        try model.updatePlaceholderAspectRatioHint(width: nil, height: nil)
        XCTAssertEqual(
            model.reservation.canvasAspectRatio,
            LiveWindowReservation.defaultPlaceholderAspectRatio
        )
    }

    func testSamplePresentationOverridesRuntimeGeometryAndTracksIndependentRevisions() throws {
        var model = try makeModel()
        try model.updateCaptureActiveFormat(LiveCaptureActiveFormat(
            sourceEpoch: 4,
            width: 1_920,
            height: 1_080
        ))
        XCTAssertEqual(
            model.aspectSource,
            .samplePresentation(sourceEpoch: 4, formatRevision: 1)
        )
        XCTAssertEqual(model.reservation.contentAspectRatio.value, 16.0 / 9.0)

        let first = try model.updateRuntimeGeometry(geometry(
            connectionEpoch: 7,
            revision: 2,
            width: 1_179,
            height: 2_556
        ))
        XCTAssertFalse(first.requiresInteractionCancellation)
        XCTAssertEqual(model.aspectSource,
                       .samplePresentation(sourceEpoch: 4, formatRevision: 1))
        XCTAssertEqual(
            model.reservation.contentAspectRatio,
            try LiveWindowAspectRatio(widthUnits: 1_920, heightUnits: 1_080)
        )

        let changed = try model.updateRuntimeGeometry(geometry(
            connectionEpoch: 7,
            revision: 3,
            width: 2_556,
            height: 1_179
        ))
        XCTAssertTrue(changed.requiresInteractionCancellation)
        XCTAssertGreaterThan(model.reservation.contentAspectRatio.value, 1)
        XCTAssertThrowsError(try model.updateRuntimeGeometry(geometry(
            connectionEpoch: 7,
            revision: 2,
            width: 1_179,
            height: 2_556
        ))) { error in
            XCTAssertEqual(error as? LiveWindowModelError, .staleRuntimeGeometry)
        }
        XCTAssertThrowsError(try model.updateRuntimeGeometry(geometry(
            connectionEpoch: 7,
            revision: 3,
            width: 1_179,
            height: 2_556
        ))) { error in
            XCTAssertEqual(
                error as? LiveWindowModelError,
                .conflictingRuntimeGeometry
            )
        }
    }

    func testGeometryLossFallsBackToCaptureFormat() throws {
        var model = try makeModel()
        try model.updateCaptureActiveFormat(LiveCaptureActiveFormat(
            sourceEpoch: 5,
            width: 1_920,
            height: 1_080
        ))
        _ = try model.updateRuntimeGeometry(geometry(
            connectionEpoch: 8,
            revision: 1,
            width: 1_179,
            height: 2_556
        ))
        try model.clearRuntimeGeometry(throughConnectionEpoch: 8)
        XCTAssertNil(model.runtimeGeometry)
        XCTAssertEqual(model.aspectSource,
                       .samplePresentation(sourceEpoch: 5, formatRevision: 1))
        XCTAssertTrue(screenFrame().contains(model.reservation.windowFrame))
    }

    func testGeometryAndCaptureLossRestorePlaceholderCanvasRatio() throws {
        var model = try makeModel()
        try model.updateCaptureActiveFormat(LiveCaptureActiveFormat(
            sourceEpoch: 3,
            width: 2_532,
            height: 1_170
        ))
        _ = try model.updateRuntimeGeometry(geometry(
            connectionEpoch: 4,
            revision: 1,
            width: 2_532,
            height: 1_170
        ))

        try model.clearCaptureActiveFormat(throughSourceEpoch: 3)
        try model.clearRuntimeGeometry(throughConnectionEpoch: 4)

        XCTAssertEqual(model.aspectSource, .identityPlaceholder)
        XCTAssertEqual(
            model.reservation.canvasAspectRatio,
            LiveWindowReservation.defaultPlaceholderAspectRatio
        )
        XCTAssertEqual(
            model.reservation.contentSize.height,
            model.reservation.canvasSize.height + model.reservation.sourceControlsHeight,
            accuracy: 0.000_001
        )
    }

    func testClearingSourceFormatAllowsDifferentSourceEpochAndRestoresPlaceholder() throws {
        var model = try makeModel()
        try model.updateCaptureActiveFormat(LiveCaptureActiveFormat(
            sourceEpoch: 9,
            width: 1_920,
            height: 1_080
        ))
        try model.clearCaptureActiveFormat(throughSourceEpoch: 8)
        XCTAssertEqual(model.aspectSource,
                       .samplePresentation(sourceEpoch: 9, formatRevision: 1))

        try model.clearCaptureActiveFormat(throughSourceEpoch: 9)
        XCTAssertNil(model.captureActiveFormat)
        XCTAssertEqual(model.aspectSource, .identityPlaceholder)
        XCTAssertEqual(
            model.reservation.contentAspectRatio,
            LiveWindowReservation.defaultPlaceholderAspectRatio
        )

        try model.updateCaptureActiveFormat(LiveCaptureActiveFormat(
            sourceEpoch: 2,
            width: 1_170,
            height: 2_532
        ))
        XCTAssertEqual(model.aspectSource,
                       .samplePresentation(sourceEpoch: 2, formatRevision: 1))
    }

    func testVisibleFrameAlwaysContainsReservedWindow() throws {
        let smallScreen = LiveWindowRect(
            x: -320,
            y: 40,
            width: 640,
            height: 360
        )
        let reservation = try LiveWindowReservation(
            screenVisibleFrame: smallScreen,
            contentAspectRatio: LiveWindowAspectRatio(
                widthUnits: 9,
                heightUnits: 21
            )
        )
        XCTAssertTrue(smallScreen.contains(reservation.windowFrame))
        XCTAssertEqual(
            reservation.canvasSize.width / reservation.canvasSize.height,
            9.0 / 21.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            reservation.contentSize.height,
            reservation.canvasSize.height + reservation.sourceControlsHeight,
            accuracy: 0.000_001
        )
        XCTAssertLessThan(
            min(reservation.canvasSize.width, reservation.canvasSize.height),
            LiveWindowReservation.minimumCanvasShortEdge
        )
    }

    func testGeometryChangePreservesUserCanvasLongEdge() throws {
        var model = try makeModel()
        try model.updateCaptureActiveFormat(LiveCaptureActiveFormat(
            sourceEpoch: 3,
            width: 1_170,
            height: 2_532
        ))
        try model.recordUserCanvasSize(LiveWindowSize(
            width: 320,
            height: 700
        ))

        _ = try model.updateRuntimeGeometry(geometry(
            connectionEpoch: 4,
            revision: 1,
            width: 2_532,
            height: 1_170
        ))
        _ = try model.updateSamplePresentation(LiveSamplePresentationFormat(
            sourceEpoch: 3,
            width: 2_532,
            height: 1_170,
            formatRevision: 2
        ))

        XCTAssertEqual(
            max(
                model.reservation.canvasSize.width,
                model.reservation.canvasSize.height
            ),
            700,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            model.reservation.canvasSize.width
                / model.reservation.canvasSize.height,
            2_532.0 / 1_170.0,
            accuracy: 0.000_001
        )
        XCTAssertTrue(screenFrame().contains(model.reservation.windowFrame))
    }

    func testInitialPresentationUsesPreferredCanvasShortEdgeAcrossOrientation() throws {
        var model = try LiveWindowModel(
            identityPlaceholder: makeIdentity(),
            screenVisibleFrame: LiveWindowRect(
                x: 0,
                y: 0,
                width: 1_600,
                height: 1_200
            )
        )
        _ = try model.updateSamplePresentation(LiveSamplePresentationFormat(
            sourceEpoch: 3,
            width: 1_170,
            height: 2_532
        ))
        XCTAssertEqual(
            min(model.reservation.canvasSize.width,
                model.reservation.canvasSize.height),
            LiveWindowReservation.preferredCanvasShortEdge,
            accuracy: 0.000_001
        )

        _ = try model.updateSamplePresentation(LiveSamplePresentationFormat(
            sourceEpoch: 3,
            width: 2_532,
            height: 1_170,
            formatRevision: 2
        ))
        XCTAssertEqual(
            min(model.reservation.canvasSize.width,
                model.reservation.canvasSize.height),
            LiveWindowReservation.preferredCanvasShortEdge,
            accuracy: 0.000_001
        )
    }

    func testProductMinimumCanvasShortEdgeAppliesAcrossOrientation() throws {
        let screen = LiveWindowRect(
            x: 0,
            y: 0,
            width: 2_000,
            height: 1_600
        )
        for ratio in [
            try LiveWindowAspectRatio(widthUnits: 1_170, heightUnits: 2_532),
            try LiveWindowAspectRatio(widthUnits: 2_532, heightUnits: 1_170),
        ] {
            let reservation = try LiveWindowReservation(
                screenVisibleFrame: screen,
                contentAspectRatio: ratio,
                preferredCanvasShortEdge: 100
            )
            XCTAssertEqual(
                min(
                    reservation.canvasSize.width,
                    reservation.canvasSize.height
                ),
                LiveWindowReservation.minimumCanvasShortEdge,
                accuracy: 0.000_001
            )
            XCTAssertTrue(screen.contains(reservation.windowFrame))
        }
    }

    func testVideoPlaceholderBlindControlFixture() throws {
        let input = try loadFixture()
        let expected = try loadExpected()
        let identity = try IdentityPlaceholder(
            deviceName: input.deviceName,
            canonicalUDID: CanonicalUDID(
                canonicalString: input.canonicalUDID
            )
        )
        var model = try LiveWindowModel(
            identityPlaceholder: identity,
            screenVisibleFrame: LiveWindowRect(
                x: input.screenVisibleFrame.x,
                y: input.screenVisibleFrame.y,
                width: input.screenVisibleFrame.width,
                height: input.screenVisibleFrame.height
            )
        )
        if input.cameraAvailable {
            try model.updateCaptureActiveFormat(LiveCaptureActiveFormat(
                sourceEpoch: input.captureFormat.sourceEpoch,
                width: input.captureFormat.width,
                height: input.captureFormat.height
            ))
        }
        _ = try model.updateRuntimeGeometry(DisplayGeometryDTO(
            connectionEpoch: input.runtimeGeometry.connectionEpoch,
            geometryRevision: input.runtimeGeometry.geometryRevision,
            logicalHeight: input.runtimeGeometry.logicalHeight,
            logicalWidth: input.runtimeGeometry.logicalWidth,
            orientation: try XCTUnwrap(DisplayOrientationDTO(
                rawValue: input.runtimeGeometry.orientation
            ))
        ))
        try model.setControlAvailable(
            connectionEpoch: input.controlConnectionEpoch
        )
        if !input.cameraAvailable {
            model.showIdentityPlaceholder(reason: .cameraDenied)
        }

        XCTAssertEqual(identity.primaryText, expected.placeholderDeviceName)
        XCTAssertEqual(identity.secondaryText, expected.placeholderCanonicalUDID)
        XCTAssertEqual(model.controlCommandsEnabled, expected.controlEnabled)
        XCTAssertEqual(
            model.coordinateInputEnabled,
            expected.coordinateInputEnabled
        )
        XCTAssertEqual(
            model.aspectSource,
            .runtimeGeometry(
                connectionEpoch: input.runtimeGeometry.connectionEpoch,
                geometryRevision: input.runtimeGeometry.geometryRevision
            )
        )
        XCTAssertEqual(
            model.videoPresentation,
            .identityPlaceholder(identity: identity, reason: .cameraDenied)
        )
        XCTAssertEqual(expected.videoPresentation, "identityPlaceholder")
        XCTAssertTrue(model.reservation.screenVisibleFrame.contains(
            model.reservation.windowFrame
        ))
        XCTAssertEqual(expected.sourceBindingEvidence, "deferredM2-018")
    }

    func testControlEpochMustMatchGeometryForCoordinateInputOnly() throws {
        var model = try makeModel()
        try model.setControlAvailable(connectionEpoch: 10)
        XCTAssertTrue(model.controlCommandsEnabled)
        XCTAssertFalse(model.coordinateInputEnabled)
        _ = try model.updateRuntimeGeometry(geometry(
            connectionEpoch: 9,
            revision: 1,
            width: 1_179,
            height: 2_556
        ))
        XCTAssertTrue(model.controlCommandsEnabled)
        XCTAssertFalse(model.coordinateInputEnabled)
        _ = try model.updateRuntimeGeometry(geometry(
            connectionEpoch: 10,
            revision: 1,
            width: 1_179,
            height: 2_556
        ))
        XCTAssertTrue(model.coordinateInputEnabled)
    }

    func testPointerCapabilitySnapshotCanDisableCoordinateAuthorityIndependently()
        throws
    {
        var model = try makeModel()
        try model.setControlAvailable(connectionEpoch: 10)
        _ = try model.updateRuntimeGeometry(geometry(
            connectionEpoch: 10,
            revision: 1,
            width: 1_179,
            height: 2_556
        ))
        XCTAssertTrue(model.coordinateInputEnabled)

        model.setPointerCapabilityAvailable(false)
        XCTAssertFalse(model.coordinateInputEnabled)
        XCTAssertEqual(
            model.pointerAvailability,
            .unavailable(reason: "capabilityUnavailable")
        )

        model.setPointerCapabilityAvailable(true)
        XCTAssertTrue(model.coordinateInputEnabled)
        XCTAssertEqual(
            model.pointerAvailability,
            .available(connectionEpoch: 10, geometryRevision: 1)
        )
    }

    func testVideoAndPointerAvailabilityAreIndependentAndFrozenRatioPersists()
        throws
    {
        var model = try makeModel()
        try model.setControlAvailable(connectionEpoch: 7)
        XCTAssertEqual(
            model.pointerAvailability,
            .preparing(reason: "awaitingGeometry")
        )
        let portrait = try geometry(
            connectionEpoch: 7,
            revision: 1,
            width: 1_170,
            height: 2_532
        )
        _ = try model.updateRuntimeGeometry(portrait)
        XCTAssertEqual(
            model.videoAvailability,
            .unavailable(reason: .awaitingBinding)
        )
        XCTAssertEqual(
            model.pointerAvailability,
            .available(connectionEpoch: 7, geometryRevision: 1)
        )
        XCTAssertTrue(model.coordinateInputEnabled)

        _ = try model.updateSamplePresentation(LiveSamplePresentationFormat(
            sourceEpoch: 4,
            width: 1_170,
            height: 2_532
        ))
        XCTAssertEqual(
            model.videoAvailability,
            .live(sourceEpoch: 4, formatRevision: 1)
        )
        XCTAssertEqual(
            model.pointerAvailability,
            .available(connectionEpoch: 7, geometryRevision: 1)
        )

        _ = try model.updateSamplePresentation(LiveSamplePresentationFormat(
            sourceEpoch: 4,
            width: 2_532,
            height: 1_170,
            formatRevision: 2
        ))
        XCTAssertEqual(
            model.pointerAvailability,
            .preparing(reason: "awaitingGeometry")
        )
        XCTAssertFalse(model.coordinateInputEnabled)
        let frozenRatio = model.reservation.canvasAspectRatio

        XCTAssertTrue(model.freezeVideo(unavailableReason: .deviceDetached))
        XCTAssertEqual(
            model.videoAvailability,
            .frozen(sourceEpoch: 4, formatRevision: 2)
        )
        XCTAssertEqual(
            model.pointerAvailability,
            .available(connectionEpoch: 7, geometryRevision: 1)
        )
        XCTAssertTrue(model.coordinateInputEnabled)

        model.setControlUnavailable(reason: "deviceDisconnected")
        try model.clearRuntimeGeometry(throughConnectionEpoch: 7)
        XCTAssertEqual(
            model.pointerAvailability,
            .unavailable(reason: "deviceDisconnected")
        )
        XCTAssertEqual(model.reservation.canvasAspectRatio, frozenRatio)
        XCTAssertEqual(
            model.aspectSource,
            .samplePresentation(sourceEpoch: 4, formatRevision: 2)
        )

        try model.clearCaptureActiveFormat(throughSourceEpoch: 4)
        XCTAssertEqual(
            model.videoAvailability,
            .unavailable(reason: .awaitingBinding)
        )
        XCTAssertNil(model.samplePresentation)
        XCTAssertEqual(model.aspectSource, .identityPlaceholder)
    }

    func testFreezeWithoutIdentityValidFrameFallsBackToUnavailablePlaceholder()
        throws
    {
        var model = try makeModel()
        XCTAssertFalse(model.freezeVideo(unavailableReason: .deviceDetached))
        XCTAssertEqual(
            model.videoAvailability,
            .unavailable(reason: .deviceDetached)
        )
        XCTAssertEqual(
            model.videoPresentation,
            .identityPlaceholder(
                identity: try makeIdentity(),
                reason: .deviceDetached
            )
        )
    }

    func testPresentationRevisionRejectsStaleAndCancelsOnOrientationChange() throws {
        var model = try makeModel()
        let first = try model.updateSamplePresentation(
            LiveSamplePresentationFormat(
                sourceEpoch: 5,
                width: 1_170,
                height: 2_532,
                formatRevision: 1
            )
        )
        XCTAssertFalse(first.requiresInteractionCancellation)
        let resolution = try model.updateSamplePresentation(
            LiveSamplePresentationFormat(
                sourceEpoch: 5,
                width: 1_080,
                height: 2_336,
                formatRevision: 2
            )
        )
        XCTAssertFalse(resolution.requiresInteractionCancellation)
        let rotation = try model.updateSamplePresentation(
            LiveSamplePresentationFormat(
                sourceEpoch: 5,
                width: 2_336,
                height: 1_080,
                formatRevision: 3
            )
        )
        XCTAssertTrue(rotation.requiresInteractionCancellation)
        XCTAssertEqual(model.aspectSource,
                       .samplePresentation(sourceEpoch: 5, formatRevision: 3))
        XCTAssertThrowsError(try model.updateSamplePresentation(
            LiveSamplePresentationFormat(
                sourceEpoch: 5,
                width: 1_080,
                height: 2_336,
                formatRevision: 2
            )
        )) { error in
            XCTAssertEqual(error as? LiveWindowModelError, .staleCaptureFormat)
        }
    }

    func testFrozenPresentationAcceptsCurrentReplacementWithLowerSourceEpoch()
        throws
    {
        var model = try makeModel()
        let previous = try LiveSamplePresentationFormat(
            sourceEpoch: 5,
            width: 1_170,
            height: 2_532,
            formatRevision: 1
        )
        _ = try model.updateSamplePresentation(previous)
        let replacement = try LiveSamplePresentationFormat(
            sourceEpoch: 4,
            width: 1_170,
            height: 2_532,
            formatRevision: 1
        )

        XCTAssertThrowsError(try model.updateSamplePresentation(replacement)) {
            XCTAssertEqual($0 as? LiveWindowModelError, .staleCaptureFormat)
        }
        XCTAssertTrue(model.freezeVideo(unavailableReason: .sourceUnavailable))

        let update = try model.updateSamplePresentation(replacement)

        XCTAssertEqual(
            model.videoAvailability,
            .live(sourceEpoch: 4, formatRevision: 1)
        )
        XCTAssertEqual(model.samplePresentation, replacement)
        XCTAssertTrue(update.requiresInteractionCancellation)
    }

    func testMinimumWidthExpandsBothCanvasAxesWithoutLetterbox() throws {
        let visibleFrame = LiveWindowRect(
            x: 0,
            y: 0,
            width: 1_600,
            height: 1_200
        )
        var model = try LiveWindowModel(
            identityPlaceholder: makeIdentity(),
            screenVisibleFrame: visibleFrame
        )
        _ = try model.updateSamplePresentation(LiveSamplePresentationFormat(
            sourceEpoch: 7,
            width: 1_170,
            height: 2_532
        ))
        try model.updateActualMinimumContentWidth(400)

        XCTAssertEqual(model.reservation.contentSize.width, 400, accuracy: 0.001)
        XCTAssertEqual(model.reservation.canvasHostSize.width, 400, accuracy: 0.001)
        XCTAssertEqual(model.reservation.canvasHostSize, model.reservation.canvasSize)
        XCTAssertFalse(model.reservation.hasHorizontalLetterbox)
        XCTAssertEqual(
            model.reservation.canvasSize.width / model.reservation.canvasSize.height,
            1_170.0 / 2_532.0,
            accuracy: 0.000_001
        )
        XCTAssertTrue(visibleFrame.contains(model.reservation.windowFrame))

        let accepted = model.reservation
        XCTAssertThrowsError(try model.updateActualMinimumContentWidth(520)) { error in
            XCTAssertEqual(
                error as? LiveWindowReservationError,
                .minimumContentWidthUnavailable
            )
        }
        XCTAssertEqual(model.actualMinimumContentWidth, 400, accuracy: 0.001)
        XCTAssertEqual(model.reservation, accepted)
    }

    func testFullscreenPreservesWindowedUserScaleAndDefersFrameRevision() throws {
        var model = try makeModel()
        _ = try model.updateSamplePresentation(LiveSamplePresentationFormat(
            sourceEpoch: 8,
            width: 1_170,
            height: 2_532
        ))
        try model.recordUserCanvasSize(LiveWindowSize(width: 320, height: 700))
        let windowedLongEdge = model.preferredWindowedCanvasLongEdge

        XCTAssertTrue(model.windowWillEnterFullscreen())
        XCTAssertTrue(model.windowDidEnterFullscreen())
        _ = try model.updateSamplePresentation(LiveSamplePresentationFormat(
            sourceEpoch: 8,
            width: 2_532,
            height: 1_170,
            formatRevision: 2
        ))
        XCTAssertThrowsError(try model.recordUserCanvasSize(
            LiveWindowSize(width: 1_200, height: 800)
        )) { error in
            XCTAssertEqual(error as? LiveWindowModelError, .invalidWindowState)
        }
        XCTAssertTrue(model.windowWillExitFullscreen())
        XCTAssertTrue(model.windowDidExitFullscreen())
        XCTAssertEqual(model.windowState, .windowed)
        XCTAssertEqual(model.preferredWindowedCanvasLongEdge,
                       windowedLongEdge, accuracy: 0.001)
        XCTAssertEqual(max(model.reservation.canvasSize.width,
                           model.reservation.canvasSize.height),
                       windowedLongEdge, accuracy: 0.001)
        XCTAssertGreaterThan(model.reservation.canvasAspectRatio.value, 1)
    }

    func testSubminimumUserCanvasSizeIsNotPersisted() throws {
        var model = try makeModel()
        _ = try model.updateSamplePresentation(LiveSamplePresentationFormat(
            sourceEpoch: 9,
            width: 1_170,
            height: 2_532
        ))
        try model.recordUserCanvasSize(LiveWindowSize(width: 320, height: 700))

        XCTAssertThrowsError(try model.recordUserCanvasSize(
            LiveWindowSize(width: 280, height: 600)
        )) { error in
            XCTAssertEqual(error as? LiveWindowModelError, .invalidCanvasSize)
        }
        XCTAssertEqual(model.preferredWindowedCanvasLongEdge, 700, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(
            min(
                model.reservation.canvasSize.width,
                model.reservation.canvasSize.height
            ),
            LiveWindowReservation.minimumCanvasShortEdge
        )
    }

    private func makeModel() throws -> LiveWindowModel {
        try LiveWindowModel(
            identityPlaceholder: makeIdentity(),
            screenVisibleFrame: screenFrame()
        )
    }

    private func makeIdentity() throws -> IdentityPlaceholder {
        try IdentityPlaceholder(
            deviceName: "Lab iPhone",
            canonicalUDID: CanonicalUDID(
                canonicalString: "00008020-001C2D123456002E"
            )
        )
    }

    private func screenFrame() -> LiveWindowRect {
        LiveWindowRect(x: 0, y: 0, width: 1_440, height: 900)
    }

    private func geometry(
        connectionEpoch: UInt64,
        revision: UInt64,
        width: UInt64,
        height: UInt64
    ) throws -> DisplayGeometryDTO {
        try DisplayGeometryDTO(
            connectionEpoch: connectionEpoch,
            geometryRevision: revision,
            logicalHeight: height,
            logicalWidth: width,
            orientation: width > height ? .landscapeLeft : .portrait
        )
    }

    private func fixtureURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Fixtures/requirements/T-008/video-placeholder-blind-control-l4/\(relativePath)"
            )
    }

    private func loadFixture() throws -> LiveWindowFixture {
        try JSONDecoder().decode(
            LiveWindowFixture.self,
            from: Data(contentsOf: fixtureURL("input/input.v1.json"))
        )
    }

    private func loadExpected() throws -> LiveWindowExpected {
        try JSONDecoder().decode(
            LiveWindowExpected.self,
            from: Data(contentsOf: fixtureURL("expected.v1.json"))
        )
    }
}

private struct LiveWindowFixture: Decodable {
    struct CaptureFormat: Decodable {
        let height: UInt64
        let sourceEpoch: UInt64
        let width: UInt64
    }

    struct RuntimeGeometry: Decodable {
        let connectionEpoch: UInt64
        let geometryRevision: UInt64
        let logicalHeight: UInt64
        let logicalWidth: UInt64
        let orientation: String
    }

    struct ScreenVisibleFrame: Decodable {
        let height: Double
        let width: Double
        let x: Double
        let y: Double
    }

    let cameraAvailable: Bool
    let canonicalUDID: String
    let captureFormat: CaptureFormat
    let controlConnectionEpoch: UInt64
    let deviceName: String
    let runtimeGeometry: RuntimeGeometry
    let screenVisibleFrame: ScreenVisibleFrame
}

private struct LiveWindowExpected: Decodable {
    let controlEnabled: Bool
    let coordinateInputEnabled: Bool
    let placeholderCanonicalUDID: String
    let placeholderDeviceName: String
    let sourceBindingEvidence: String
    let videoPresentation: String
}
