import Foundation
import PulsePhoneSharedDefinitions
import PulsePhoneWire

public enum RuntimeWriterLane: Equatable, Sendable {
    case regularReliable
    case finalControl
}

public enum RuntimeWriterEnqueueResult: Equatable, Sendable {
    case enqueued
    case regularQueueSaturated
    case disconnectRequired
}

public enum RuntimeWriterDrainResult: Equatable, Sendable {
    case empty
    case wouldBlock
    case partial
    case frameCompleted(RuntimeWireMessageType)
}

public enum SerializedWriterError: Error, Equatable, Sendable {
    case invalidFrame(RuntimeWireCodecError)
    case finalControlFrameTooLarge
    case writeTimedOut
    case invalidWriteCount
}

public final class SerializedWriter: @unchecked Sendable {
    public static let regularFrameCap = 128
    public static let regularByteCap = 2 * 1_024 * 1_024
    public static let finalControlFrameCap = 4
    public static let finalControlByteCap = 1 * 1_024 * 1_024
    public static let finalControlPayloadCap = 256 * 1_024
    public static let writeTimeoutNanoseconds: UInt64 = 2_000_000_000

    private struct QueuedFrame {
        let frame: RuntimeWireFrame
        let bytes: [UInt8]
        let lane: RuntimeWriterLane
        var offset: Int
        var deadline: MonotonicInstant?
    }

    private let lock = NSLock()
    private var queue = [QueuedFrame]()
    private var regularFrameCount = 0
    private var regularByteCount = 0
    private var finalControlFrameCount = 0
    private var finalControlByteCount = 0

    public init() {}

    public var queuedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queue.count
    }

    public func enqueue(
        _ frame: RuntimeWireFrame,
        lane: RuntimeWriterLane
    ) throws -> RuntimeWriterEnqueueResult {
        let bytes: [UInt8]
        do {
            bytes = try RuntimeWireFrameCodec.encode(frame)
        } catch let error as RuntimeWireCodecError {
            throw SerializedWriterError.invalidFrame(error)
        }
        if lane == .finalControl,
           frame.payload.count > Self.finalControlPayloadCap
        {
            throw SerializedWriterError.finalControlFrameTooLarge
        }

        lock.lock()
        defer { lock.unlock() }
        switch lane {
        case .regularReliable:
            guard bytes.count <= Self.regularByteCap,
                  regularFrameCount < Self.regularFrameCap,
                  regularByteCount <= Self.regularByteCap - bytes.count
            else {
                return .regularQueueSaturated
            }
            regularFrameCount += 1
            regularByteCount += bytes.count
        case .finalControl:
            guard bytes.count <= Self.finalControlByteCap,
                  finalControlFrameCount < Self.finalControlFrameCap,
                  finalControlByteCount <= Self.finalControlByteCap - bytes.count
            else {
                return .disconnectRequired
            }
            finalControlFrameCount += 1
            finalControlByteCount += bytes.count
        }
        queue.append(
            QueuedFrame(
                frame: frame,
                bytes: bytes,
                lane: lane,
                offset: 0,
                deadline: nil
            )
        )
        return .enqueued
    }

    public func drainNext(
        now: MonotonicInstant,
        write: ([UInt8]) throws -> Int
    ) throws -> RuntimeWriterDrainResult {
        lock.lock()
        defer { lock.unlock() }
        guard !queue.isEmpty else {
            return .empty
        }
        if queue[0].deadline == nil {
            queue[0].deadline = try now.advanced(
                by: MonotonicDuration(
                    nanoseconds: Self.writeTimeoutNanoseconds
                )
            )
        }
        guard let deadline = queue[0].deadline, now <= deadline else {
            throw SerializedWriterError.writeTimedOut
        }

        let remaining = Array(queue[0].bytes[queue[0].offset...])
        let written = try write(remaining)
        guard written >= 0, written <= remaining.count else {
            throw SerializedWriterError.invalidWriteCount
        }
        guard written > 0 else {
            return .wouldBlock
        }
        queue[0].offset += written
        guard queue[0].offset == queue[0].bytes.count else {
            return .partial
        }

        let completed = queue.removeFirst()
        releaseCapacity(for: completed)
        return .frameCompleted(completed.frame.messageType)
    }

    private func releaseCapacity(for frame: QueuedFrame) {
        switch frame.lane {
        case .regularReliable:
            regularFrameCount -= 1
            regularByteCount -= frame.bytes.count
        case .finalControl:
            finalControlFrameCount -= 1
            finalControlByteCount -= frame.bytes.count
        }
    }
}
