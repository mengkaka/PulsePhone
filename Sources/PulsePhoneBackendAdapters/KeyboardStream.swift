import Foundation
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions

public struct KeyboardHIDKey: Codable, Equatable, Hashable, Sendable {
    public let usage: UInt16
    public let usagePage: UInt16

    public init(usagePage: UInt16, usage: UInt16) {
        self.usagePage = usagePage
        self.usage = usage
    }
}

public struct KeyboardStreamInputFrame: Equatable, Sendable {
    public let pressedKeys: [KeyboardHIDKey]
    public let sequence: UInt64

    public init(sequence: UInt64, pressedKeys: [KeyboardHIDKey]) {
        self.sequence = sequence
        self.pressedKeys = pressedKeys
    }
}

public struct KeyboardDeviceFrame: Codable, Equatable, Sendable {
    public let kind: String
    public let pressedKeys: [KeyboardHIDKey]
    public let sequence: UInt64
}

public protocol KeyboardStreamTransport: Sendable {
    func open(
        sessionID: CanonicalUUID,
        interactionID: CanonicalUUID,
        routeID: String
    ) throws
    func send(
        frame: KeyboardDeviceFrame,
        deliveryAttemptID: String
    ) throws -> Bool
    func releaseAllAndClean(
        timeoutMilliseconds: UInt64
    ) throws -> OperationCleanupDisposition
}

public enum KeyboardStreamError: Error, Equatable, Sendable {
    case invalidPressedSet
    case transportFailure
}

public struct KeyboardStreamAction: Sendable {
    public static let absoluteMaximumMilliseconds: UInt64 = 5 * 60 * 1_000
    public static let cleanupMilliseconds: UInt64 = 2_000
    public static let commandID = "gui.keyboard.interaction"
    public static let preparationGroupID = "prep.coredevice.v2"
    public static let releasedCloseDelayMilliseconds: UInt64 = 300
    public static let routeID = "coredevice.keyboardStream"

    private var deliveryCounter: UInt64 = 0
    private var lastReleasedSequence: UInt64?
    private var lastReleasedAtNanoseconds: UInt64?
    private var openedAtNanoseconds: UInt64?
    private var session: StreamSession
    private let transport: any KeyboardStreamTransport

    public init(
        openRequestID: CanonicalUUID,
        actionID: CanonicalUUID,
        sessionID: CanonicalUUID,
        interactionID: CanonicalUUID,
        transport: any KeyboardStreamTransport
    ) throws {
        self.transport = transport
        self.session = try StreamSession(
            openRequestID: openRequestID,
            actionID: actionID,
            sessionID: sessionID,
            interactionID: interactionID,
            plan: StreamSessionPlan(bufferPlan: Self.bufferPlan())
        )
    }

    public var snapshot: StreamSessionSnapshot { session.snapshot }

    public static func bufferPlan() throws -> StreamBufferPlan {
        try StreamBufferPlan(
            frameRules: [
                StreamFrameRule(
                    frameKind: "pressedSet",
                    deliveryClass: .ordered
                ),
            ],
            maximumOpeningFrames: 32
        )
    }

    public mutating func beginOpening(
        inhibitorTokenID: String,
        bindings: OperationRuntimeBindings
    ) throws {
        try session.beginOpening(
            inhibitorTokenID: inhibitorTokenID,
            bindings: bindings
        )
    }

    public mutating func completeOpen(
        atMonotonicNanoseconds now: UInt64
    ) throws {
        do {
            try transport.open(
                sessionID: session.sessionID,
                interactionID: session.interactionID,
                routeID: Self.routeID
            )
            try session.markBackendOpen()
            openedAtNanoseconds = now
        } catch {
            abortActiveSession(
                outcome: .outcomeUnknown,
                cause: .runtimeAbort
            )
            throw KeyboardStreamError.transportFailure
        }
    }

    public mutating func submit(
        _ frame: KeyboardStreamInputFrame,
        atMonotonicNanoseconds now: UInt64
    ) throws {
        guard canonical(frame.pressedKeys) else {
            abortActiveSession(outcome: .cancelled, cause: .runtimeAbort)
            throw KeyboardStreamError.invalidPressedSet
        }
        let deviceFrame = KeyboardDeviceFrame(
            kind: "pressedSet",
            pressedKeys: frame.pressedKeys,
            sequence: frame.sequence
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            try session.submitFrame(StreamFrameEnvelope(
                sessionID: session.sessionID,
                interactionID: session.interactionID,
                sequence: frame.sequence,
                frameKind: deviceFrame.kind,
                encodedBytes: [UInt8](try encoder.encode(deviceFrame))
            ))
        } catch {
            _ = try? finishCleanup(
                outcome: .cancelled,
                resultDelivery: .reliableEnqueued
            )
            throw error
        }
        if frame.pressedKeys.isEmpty {
            lastReleasedSequence = frame.sequence
            lastReleasedAtNanoseconds = now
        } else {
            lastReleasedSequence = nil
            lastReleasedAtNanoseconds = nil
        }
    }

    @discardableResult
    public mutating func drainAvailableFrames(
        atMonotonicNanoseconds now: UInt64
    ) throws -> [KeyboardDeviceFrame] {
        var sent = [KeyboardDeviceFrame]()
        let decoder = JSONDecoder()
        while true {
            let attemptID = "keyboard.delivery.\(deliveryCounter)"
            guard let attempt = try session.dequeueFrameForDelivery(
                deliveryAttemptID: attemptID,
                atMonotonicNanoseconds: now
            ) else {
                break
            }
            deliveryCounter += 1
            let frame: KeyboardDeviceFrame
            do {
                frame = try decoder.decode(
                    KeyboardDeviceFrame.self,
                    from: Data(attempt.frame.encodedBytes)
                )
            } catch {
                abortActiveSession(
                    outcome: .outcomeUnknown,
                    cause: .runtimeAbort
                )
                throw KeyboardStreamError.transportFailure
            }
            let accepted: Bool
            do {
                accepted = try transport.send(
                    frame: frame,
                    deliveryAttemptID: attemptID
                )
            } catch {
                abortActiveSession(
                    outcome: .outcomeUnknown,
                    cause: .runtimeAbort
                )
                throw KeyboardStreamError.transportFailure
            }
            sent.append(frame)
            if accepted {
                try session.acceptFrame(
                    sequence: frame.sequence,
                    deliveryAttemptID: attemptID
                )
            } else {
                break
            }
        }
        return sent
    }

    public mutating func evaluateFrameAcceptedWatchdog(
        atMonotonicNanoseconds now: UInt64
    ) throws -> StreamSessionTerminalSnapshot? {
        guard try session.evaluateFrameAcceptedWatchdog(
            atMonotonicNanoseconds: now
        ) != nil else {
            return nil
        }
        return try finishCleanup(
            outcome: .cancelled,
            resultDelivery: .reliableEnqueued
        )
    }

    public mutating func evaluateAbsoluteDeadline(
        atMonotonicNanoseconds now: UInt64
    ) throws -> StreamSessionTerminalSnapshot? {
        guard let openedAtNanoseconds,
              now >= openedAtNanoseconds,
              now - openedAtNanoseconds
                >= Self.absoluteMaximumMilliseconds * 1_000_000
        else {
            return nil
        }
        _ = try session.requestClose(
            requestID: session.snapshot.lifecycle.requestID,
            mode: .cancel,
            cause: .deadlineExceeded
        )
        return try finishCleanup(
            outcome: .cancelled,
            resultDelivery: .reliableEnqueued
        )
    }

    public mutating func closeIfReleased(
        requestID: CanonicalUUID,
        atMonotonicNanoseconds now: UInt64
    ) throws -> StreamClosedResponse? {
        guard let sequence = lastReleasedSequence,
              let releasedAt = lastReleasedAtNanoseconds,
              session.snapshot.buffer.lastAcceptedSequence == sequence,
              now >= releasedAt,
              now - releasedAt
                >= Self.releasedCloseDelayMilliseconds * 1_000_000
        else {
            return nil
        }
        _ = try session.requestClose(
            requestID: requestID,
            mode: .close,
            cause: .backendResult
        )
        _ = try finishCleanup(
            outcome: .succeeded,
            resultDelivery: .reliableEnqueued
        )
        return try session.closeResponse(for: requestID)
    }

    public mutating func cancel(
        requestID: CanonicalUUID,
        cause: OperationTerminalCause,
        resultDelivery: OperationResultDelivery = .reliableEnqueued
    ) throws -> StreamClosedResponse {
        let start = try session.requestClose(
            requestID: requestID,
            mode: .cancel,
            cause: cause
        )
        if case .started = start {
            _ = try finishCleanup(
                outcome: .cancelled,
                resultDelivery: resultDelivery
            )
        }
        return try session.closeResponse(for: requestID)
    }

    private mutating func finishCleanup(
        outcome: StandardOutcome,
        resultDelivery: OperationResultDelivery
    ) throws -> StreamSessionTerminalSnapshot {
        let disposition: OperationCleanupDisposition
        do {
            disposition = try transport.releaseAllAndClean(
                timeoutMilliseconds: Self.cleanupMilliseconds
            )
        } catch {
            throw KeyboardStreamError.transportFailure
        }
        return try session.completeCleanup(
            outcome: outcome,
            resultDelivery: resultDelivery,
            disposition: disposition
        )
    }

    private mutating func abortActiveSession(
        outcome: StandardOutcome,
        cause: OperationTerminalCause
    ) {
        guard session.snapshot.lifecycle.phase == .running else { return }
        if session.snapshot.cleanupCommand == nil {
            _ = try? session.requestClose(
                requestID: session.snapshot.lifecycle.requestID,
                mode: .cancel,
                cause: cause
            )
        }
        _ = try? finishCleanup(
            outcome: outcome,
            resultDelivery: .reliableEnqueued
        )
    }

    private func canonical(_ keys: [KeyboardHIDKey]) -> Bool {
        guard keys.count <= 256,
              Set(keys).count == keys.count,
              keys.allSatisfy({
                  $0.usagePage == 0x07 && (1...0xE7).contains($0.usage)
              })
        else {
            return false
        }
        return keys == keys.sorted {
            ($0.usagePage, $0.usage) < ($1.usagePage, $1.usage)
        }
    }
}
