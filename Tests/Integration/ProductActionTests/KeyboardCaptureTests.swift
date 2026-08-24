import Foundation
import PulsePhoneBackendAdapters
import PulsePhoneGUI
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions
import XCTest

final class KeyboardCaptureTests: XCTestCase {
    func testControllerConsumesDeviceFirstAndQueuesCompletePressedSets() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(
            KeyboardCaptureController.maximumPendingFrames,
            fixture.maximumOpeningFrames
        )
        var controller = KeyboardCaptureController()
        XCTAssertEqual(activate(&controller), .activated)

        for event in fixture.events {
            let result = controller.handle(captureEvent(event))
            XCTAssertTrue(result.consumed)
            XCTAssertEqual(result.disposition, .queued)
        }
        var snapshots = [[String]]()
        while let frame = controller.dequeueFrame() {
            snapshots.append(frame.pressedKeys.map(keyText))
        }
        XCTAssertEqual(snapshots, fixture.expectedPressedSets)
        XCTAssertTrue(controller.hasActiveInteraction)
        try controller.completeShortInteraction()
        XCTAssertFalse(controller.hasActiveInteraction)
        XCTAssertTrue(controller.isCaptureActive)
        XCTAssertTrue(controller.isEnabled)
    }

    func testFocusEventTapAndOwnerLossRequireReleaseAll() throws {
        var controller = KeyboardCaptureController()
        XCTAssertEqual(activate(&controller), .activated)
        _ = controller.handle(keyDown(usage: 4))
        XCTAssertEqual(controller.updateContext(
            enabled: true,
            keyWindow: false,
            firstResponder: true,
            eventTapAvailable: true,
            runtimeCapabilityReady: true
        ), .releaseAllRequired(.focusLost))
        XCTAssertFalse(controller.isCaptureActive)
        XCTAssertFalse(controller.hasActiveInteraction)

        XCTAssertEqual(activate(&controller), .activated)
        XCTAssertEqual(controller.updateContext(
            enabled: true,
            keyWindow: true,
            firstResponder: true,
            eventTapAvailable: false,
            runtimeCapabilityReady: true
        ), .releaseAllRequired(.eventTapDisabled))
        XCTAssertEqual(activate(&controller), .activated)
        XCTAssertEqual(
            controller.ownerDidDisconnect(),
            .releaseAllRequired(.ownerDisconnected)
        )
    }

    func testCallbackBackpressureAndInvalidEventFailClosedAfterConsumption() {
        var controller = KeyboardCaptureController()
        XCTAssertEqual(activate(&controller), .activated)
        for index in 0..<KeyboardCaptureController.maximumPendingFrames {
            let usage = UInt16(4 + index % 2)
            let event = index.isMultiple(of: 2)
                ? keyDown(usage: usage)
                : keyUp(usage: usage)
            XCTAssertEqual(controller.handle(event).disposition, .queued)
        }
        let overflow = controller.handle(keyDown(usage: 6))
        XCTAssertTrue(overflow.consumed)
        XCTAssertEqual(
            overflow.disposition,
            .releaseAllRequired(.backpressure)
        )
        XCTAssertFalse(controller.isCaptureActive)
        XCTAssertEqual(controller.pendingFrameCount, 0)
        XCTAssertEqual(controller.recoverAfterCleanup(), .activated)

        let invalid = controller.handle(KeyboardCaptureEvent(
            kind: .keyDown,
            key: KeyboardCapturedKey(usagePage: 0x0C, usage: 0x40),
            isPressed: true
        ))
        XCTAssertTrue(invalid.consumed)
        XCTAssertEqual(
            invalid.disposition,
            .releaseAllRequired(.invalidEvent)
        )
    }

    func testOpeningFlushesAllOrderedFramesAndShortCloseKeepsPreference() throws {
        let transport = RecordingKeyboardTransport()
        var backend = try makeBackend(transport: transport)
        try beginOpening(&backend)
        XCTAssertEqual(try KeyboardStreamAction.bufferPlan().maximumOpeningFrames, 32)
        XCTAssertEqual(KeyboardStreamAction.absoluteMaximumMilliseconds, 300_000)
        XCTAssertEqual(KeyboardStreamAction.releasedCloseDelayMilliseconds, 300)

        try backend.submit(
            KeyboardStreamInputFrame(sequence: 0, pressedKeys: [hidKey(4)]),
            atMonotonicNanoseconds: 10
        )
        try backend.submit(
            KeyboardStreamInputFrame(
                sequence: 1,
                pressedKeys: [hidKey(4), hidKey(225)]
            ),
            atMonotonicNanoseconds: 20
        )
        try backend.submit(
            KeyboardStreamInputFrame(sequence: 2, pressedKeys: []),
            atMonotonicNanoseconds: 30
        )
        try backend.completeOpen(atMonotonicNanoseconds: 100)
        let delivered = try backend.drainAvailableFrames(
            atMonotonicNanoseconds: 200
        )
        XCTAssertEqual(delivered.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(delivered.map { $0.pressedKeys.count }, [1, 2, 0])
        XCTAssertNil(try backend.closeIfReleased(
            requestID: uuid(20),
            atMonotonicNanoseconds: 299_999_999
        ))
        let closed = try XCTUnwrap(backend.closeIfReleased(
            requestID: uuid(20),
            atMonotonicNanoseconds: 300_000_030
        ))
        XCTAssertEqual(closed.disposition, .closed)
        XCTAssertEqual(closed.terminal.terminalBundle.outcome, .succeeded)
        XCTAssertEqual(transport.releaseAllCount, 1)
        XCTAssertEqual(KeyboardStreamAction.routeID, "coredevice.keyboardStream")
        XCTAssertEqual(
            KeyboardStreamAction.preparationGroupID,
            "prep.coredevice.v2"
        )
    }

    func testWatchdogAbsoluteDeadlineAndOwnerCancelReleaseAll() throws {
        let slow = RecordingKeyboardTransport(acceptsFrames: false)
        var watchdog = try makeBackend(transport: slow)
        try beginOpening(&watchdog)
        try watchdog.completeOpen(atMonotonicNanoseconds: 0)
        try watchdog.submit(
            KeyboardStreamInputFrame(sequence: 0, pressedKeys: [hidKey(4)]),
            atMonotonicNanoseconds: 0
        )
        _ = try watchdog.drainAvailableFrames(atMonotonicNanoseconds: 0)
        XCTAssertNil(try watchdog.evaluateFrameAcceptedWatchdog(
            atMonotonicNanoseconds: 999_999_999
        ))
        let watchdogTerminal = try XCTUnwrap(
            watchdog.evaluateFrameAcceptedWatchdog(
                atMonotonicNanoseconds: 1_000_000_000
            )
        )
        XCTAssertEqual(watchdogTerminal.closingCause, .deadlineExceeded)
        XCTAssertEqual(slow.releaseAllCount, 1)

        let deadlineTransport = RecordingKeyboardTransport()
        var deadline = try makeBackend(transport: deadlineTransport)
        try beginOpening(&deadline)
        try deadline.completeOpen(atMonotonicNanoseconds: 5)
        XCTAssertNil(try deadline.evaluateAbsoluteDeadline(
            atMonotonicNanoseconds: 300_000_000_004
        ))
        let deadlineTerminal = try XCTUnwrap(
            deadline.evaluateAbsoluteDeadline(
                atMonotonicNanoseconds: 300_000_000_005
            )
        )
        XCTAssertEqual(deadlineTerminal.closingCause, .deadlineExceeded)
        XCTAssertEqual(deadlineTransport.releaseAllCount, 1)

        let ownerTransport = RecordingKeyboardTransport()
        var owner = try makeBackend(transport: ownerTransport)
        try beginOpening(&owner)
        try owner.completeOpen(atMonotonicNanoseconds: 0)
        let response = try owner.cancel(
            requestID: uuid(30),
            cause: .ownerDisconnected,
            resultDelivery: .clientGone
        )
        XCTAssertEqual(response.disposition, .cancelled)
        XCTAssertEqual(response.terminal.closingCause, .ownerDisconnected)
        XCTAssertEqual(response.terminal.terminalBundle.resultDelivery, .clientGone)
        XCTAssertEqual(ownerTransport.releaseAllCount, 1)
    }

    func testInvalidSetOpenAndSendFailuresReleaseAll() throws {
        let invalidTransport = RecordingKeyboardTransport()
        var invalid = try makeBackend(transport: invalidTransport)
        try beginOpening(&invalid)
        XCTAssertThrowsError(try invalid.submit(
            KeyboardStreamInputFrame(
                sequence: 0,
                pressedKeys: [hidKey(5), hidKey(4)]
            ),
            atMonotonicNanoseconds: 0
        )) { error in
            XCTAssertEqual(error as? KeyboardStreamError, .invalidPressedSet)
        }
        XCTAssertEqual(invalidTransport.releaseAllCount, 1)
        XCTAssertEqual(invalid.snapshot.lifecycle.phase, .terminal)

        let openTransport = RecordingKeyboardTransport(failOpen: true)
        var open = try makeBackend(transport: openTransport)
        try beginOpening(&open)
        XCTAssertThrowsError(try open.completeOpen(atMonotonicNanoseconds: 0))
        XCTAssertEqual(openTransport.releaseAllCount, 1)

        let sendTransport = RecordingKeyboardTransport(failSend: true)
        var send = try makeBackend(transport: sendTransport)
        try beginOpening(&send)
        try send.completeOpen(atMonotonicNanoseconds: 0)
        try send.submit(
            KeyboardStreamInputFrame(sequence: 0, pressedKeys: [hidKey(4)]),
            atMonotonicNanoseconds: 0
        )
        XCTAssertThrowsError(try send.drainAvailableFrames(
            atMonotonicNanoseconds: 0
        ))
        XCTAssertEqual(sendTransport.releaseAllCount, 1)
        XCTAssertEqual(send.snapshot.lifecycle.phase, .terminal)
    }

    private func activate(
        _ controller: inout KeyboardCaptureController
    ) -> KeyboardCaptureTransition {
        controller.updateContext(
            enabled: true,
            keyWindow: true,
            firstResponder: true,
            eventTapAvailable: true,
            runtimeCapabilityReady: true
        )
    }

    private func beginOpening(
        _ backend: inout KeyboardStreamAction
    ) throws {
        try backend.beginOpening(
            inhibitorTokenID: "keyboard.inhibitor",
            bindings: OperationRuntimeBindings(
                attemptID: "keyboard.attempt",
                executorGeneration: 1,
                leaseIDs: ["input.channel", "input.keyboard"]
            )
        )
    }

    private func captureEvent(
        _ event: KeyboardFixture.Event
    ) -> KeyboardCaptureEvent {
        KeyboardCaptureEvent(
            kind: KeyboardCaptureEventKind(rawValue: event.kind)!,
            key: key(event.usage),
            isPressed: event.isPressed
        )
    }

    private func keyDown(usage: UInt16) -> KeyboardCaptureEvent {
        KeyboardCaptureEvent(
            kind: .keyDown,
            key: key(usage),
            isPressed: true
        )
    }

    private func keyUp(usage: UInt16) -> KeyboardCaptureEvent {
        KeyboardCaptureEvent(
            kind: .keyUp,
            key: key(usage),
            isPressed: false
        )
    }

    private func key(_ usage: UInt16) -> KeyboardCapturedKey {
        KeyboardCapturedKey(usagePage: 0x07, usage: usage)
    }

    private func hidKey(_ usage: UInt16) -> KeyboardHIDKey {
        KeyboardHIDKey(usagePage: 0x07, usage: usage)
    }

    private func keyText(_ key: KeyboardCapturedKey) -> String {
        String(format: "%04x:%04x", key.usagePage, key.usage)
    }

    private func makeBackend(
        transport: RecordingKeyboardTransport
    ) throws -> KeyboardStreamAction {
        try KeyboardStreamAction(
            openRequestID: uuid(1),
            actionID: uuid(2),
            sessionID: uuid(3),
            interactionID: uuid(4),
            transport: transport
        )
    }

    private func uuid(_ value: Int) throws -> CanonicalUUID {
        try CanonicalUUID(String(
            format: "00000000-0000-0000-0000-%012x",
            value
        ))
    }

    private func loadFixture() throws -> KeyboardFixture {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try JSONDecoder().decode(
            KeyboardFixture.self,
            from: Data(contentsOf: root.appendingPathComponent(
                "Fixtures/requirements/T-008/keyboard-eventtap-focus-cleanup-l4/input/input.v1.json"
            ))
        )
    }
}

private struct KeyboardFixture: Decodable {
    struct Event: Decodable {
        let isPressed: Bool
        let kind: String
        let usage: UInt16
    }

    let events: [Event]
    let expectedPressedSets: [[String]]
    let maximumOpeningFrames: Int
}

private final class RecordingKeyboardTransport: KeyboardStreamTransport,
    @unchecked Sendable
{
    private let acceptsFrames: Bool
    private let failOpen: Bool
    private let failSend: Bool
    private(set) var releaseAllCount = 0

    init(
        acceptsFrames: Bool = true,
        failOpen: Bool = false,
        failSend: Bool = false
    ) {
        self.acceptsFrames = acceptsFrames
        self.failOpen = failOpen
        self.failSend = failSend
    }

    func open(
        sessionID: CanonicalUUID,
        interactionID: CanonicalUUID,
        routeID: String
    ) throws {
        if failOpen { throw KeyboardStreamError.transportFailure }
    }

    func send(
        frame: KeyboardDeviceFrame,
        deliveryAttemptID: String
    ) throws -> Bool {
        if failSend { throw KeyboardStreamError.transportFailure }
        return acceptsFrames
    }

    func releaseAllAndClean(
        timeoutMilliseconds: UInt64
    ) throws -> OperationCleanupDisposition {
        releaseAllCount += 1
        return .acknowledged
    }
}
