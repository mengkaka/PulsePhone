import Foundation

public enum KeyboardCaptureEventKind: String, Codable, Equatable, Sendable {
    case flagsChanged
    case keyDown
    case keyUp
}

public struct KeyboardCapturedKey: Codable, Equatable, Hashable, Sendable {
    public let usage: UInt16
    public let usagePage: UInt16

    public init(usagePage: UInt16, usage: UInt16) {
        self.usagePage = usagePage
        self.usage = usage
    }
}

public struct KeyboardCaptureEvent: Equatable, Sendable {
    public let isPressed: Bool
    public let key: KeyboardCapturedKey
    public let kind: KeyboardCaptureEventKind

    public init(
        kind: KeyboardCaptureEventKind,
        key: KeyboardCapturedKey,
        isPressed: Bool
    ) {
        self.kind = kind
        self.key = key
        self.isPressed = isPressed
    }
}

public struct KeyboardCaptureFrame: Equatable, Sendable {
    public let pressedKeys: [KeyboardCapturedKey]
    public let sequence: UInt64
}

public enum KeyboardCaptureCleanupReason: String, Equatable, Sendable {
    case backpressure
    case capabilityLost
    case disabled
    case eventTapDisabled
    case focusLost
    case invalidEvent
    case openFailed
    case ownerDisconnected
    case sequenceExhausted
    case transportFailure
}

public enum KeyboardCaptureTransition: Equatable, Sendable {
    case activated
    case noChange
    case releaseAllRequired(KeyboardCaptureCleanupReason)
}

public enum KeyboardCaptureEventDisposition: Equatable, Sendable {
    case ignored
    case queued
    case releaseAllRequired(KeyboardCaptureCleanupReason)
}

public struct KeyboardCaptureEventResult: Equatable, Sendable {
    public let consumed: Bool
    public let disposition: KeyboardCaptureEventDisposition
}

public enum KeyboardCaptureControllerError: Error, Equatable, Sendable {
    case interactionHasPendingFrames
    case keysRemainPressed
}

public struct KeyboardCaptureController: Sendable {
    public static let maximumPendingFrames = 32

    private struct Interaction: Sendable {
        var nextSequence: UInt64 = 0
        var pendingFrames = [KeyboardCaptureFrame]()
        var pressedKeys = Set<KeyboardCapturedKey>()
    }

    private var captureActive = false
    private var enabled = false
    private var eventTapAvailable = false
    private var faulted = false
    private var firstResponder = false
    private var interaction: Interaction?
    private var keyWindow = false
    private var runtimeCapabilityReady = false

    public init() {}

    public var isCaptureActive: Bool { captureActive }
    public var isEnabled: Bool { enabled }
    public var hasActiveInteraction: Bool { interaction != nil }
    public var pendingFrameCount: Int {
        interaction?.pendingFrames.count ?? 0
    }

    public mutating func updateContext(
        enabled: Bool,
        keyWindow: Bool,
        firstResponder: Bool,
        eventTapAvailable: Bool,
        runtimeCapabilityReady: Bool
    ) -> KeyboardCaptureTransition {
        self.enabled = enabled
        self.keyWindow = keyWindow
        self.firstResponder = firstResponder
        self.eventTapAvailable = eventTapAvailable
        self.runtimeCapabilityReady = runtimeCapabilityReady

        let shouldCapture = enabled
            && keyWindow
            && firstResponder
            && eventTapAvailable
            && runtimeCapabilityReady
        if captureActive && !shouldCapture {
            let reason = inactiveReason()
            captureActive = false
            interaction = nil
            faulted = false
            return .releaseAllRequired(reason)
        }
        if !captureActive && shouldCapture && !faulted {
            captureActive = true
            return .activated
        }
        return .noChange
    }

    public mutating func handle(
        _ event: KeyboardCaptureEvent
    ) -> KeyboardCaptureEventResult {
        guard captureActive else {
            return KeyboardCaptureEventResult(
                consumed: false,
                disposition: .ignored
            )
        }
        guard valid(event) else {
            return failClosed(.invalidEvent)
        }
        if interaction == nil {
            interaction = Interaction()
        }
        guard var current = interaction else {
            return failClosed(.invalidEvent)
        }
        if event.isPressed {
            current.pressedKeys.insert(event.key)
        } else {
            current.pressedKeys.remove(event.key)
        }
        guard current.pendingFrames.count < Self.maximumPendingFrames else {
            return failClosed(.backpressure)
        }
        let sequence = current.nextSequence
        guard sequence < UInt64.max else {
            return failClosed(.sequenceExhausted)
        }
        current.nextSequence += 1
        current.pendingFrames.append(KeyboardCaptureFrame(
            pressedKeys: Self.sorted(current.pressedKeys),
            sequence: sequence
        ))
        interaction = current
        return KeyboardCaptureEventResult(
            consumed: true,
            disposition: .queued
        )
    }

    public mutating func dequeueFrame() -> KeyboardCaptureFrame? {
        guard var current = interaction,
              !current.pendingFrames.isEmpty
        else {
            return nil
        }
        let frame = current.pendingFrames.removeFirst()
        interaction = current
        return frame
    }

    public mutating func ownerDidDisconnect() -> KeyboardCaptureTransition {
        keyWindow = false
        guard captureActive else { return .noChange }
        captureActive = false
        interaction = nil
        faulted = false
        return .releaseAllRequired(.ownerDisconnected)
    }

    public mutating func streamOpenFailed() -> KeyboardCaptureTransition {
        streamFailed(.openFailed)
    }

    public mutating func streamFailed(
        _ reason: KeyboardCaptureCleanupReason
    ) -> KeyboardCaptureTransition {
        guard captureActive else { return .noChange }
        captureActive = false
        interaction = nil
        faulted = true
        return .releaseAllRequired(reason)
    }

    public mutating func recoverAfterCleanup() -> KeyboardCaptureTransition {
        faulted = false
        let shouldCapture = enabled
            && keyWindow
            && firstResponder
            && eventTapAvailable
            && runtimeCapabilityReady
        guard shouldCapture, !captureActive else { return .noChange }
        captureActive = true
        return .activated
    }

    public mutating func completeShortInteraction() throws {
        guard let current = interaction else { return }
        guard current.pendingFrames.isEmpty else {
            throw KeyboardCaptureControllerError.interactionHasPendingFrames
        }
        guard current.pressedKeys.isEmpty else {
            throw KeyboardCaptureControllerError.keysRemainPressed
        }
        interaction = nil
    }

    private mutating func failClosed(
        _ reason: KeyboardCaptureCleanupReason
    ) -> KeyboardCaptureEventResult {
        captureActive = false
        interaction = nil
        faulted = true
        return KeyboardCaptureEventResult(
            consumed: true,
            disposition: .releaseAllRequired(reason)
        )
    }

    private func inactiveReason() -> KeyboardCaptureCleanupReason {
        if !enabled { return .disabled }
        if !keyWindow || !firstResponder { return .focusLost }
        if !eventTapAvailable { return .eventTapDisabled }
        return .capabilityLost
    }

    private func valid(_ event: KeyboardCaptureEvent) -> Bool {
        guard event.key.usagePage == 0x07,
              (1...0xE7).contains(event.key.usage)
        else {
            return false
        }
        switch event.kind {
        case .keyDown:
            return event.isPressed
        case .keyUp:
            return !event.isPressed
        case .flagsChanged:
            return true
        }
    }

    private static func sorted(
        _ keys: Set<KeyboardCapturedKey>
    ) -> [KeyboardCapturedKey] {
        keys.sorted {
            ($0.usagePage, $0.usage) < ($1.usagePage, $1.usage)
        }
    }
}
