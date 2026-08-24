import Foundation
import PulsePhoneSharedDefinitions
import PulsePhoneWire

public enum ConnectionDemultiplexerError: Error, Equatable, Sendable {
    case invalidHeader
    case payloadTooLarge
    case frameAssemblyTimedOut
    case invalidFrame(RuntimeWireCodecError)
}

public final class ConnectionDemultiplexer: @unchecked Sendable {
    public static let maximumPayloadBytes = 1 * 1_024 * 1_024
    public static let assemblyTimeoutNanoseconds: UInt64 = 2_000_000_000

    private let lock = NSLock()
    private var assembly = [UInt8]()
    private var expectedFrameBytes: Int?
    private var assemblyDeadline: MonotonicInstant?

    public init() {}

    public var pendingByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return assembly.count
    }

    public func consume(
        _ bytes: [UInt8],
        now: MonotonicInstant
    ) throws -> [RuntimeWireFrame] {
        lock.lock()
        defer { lock.unlock() }
        try checkDeadline(now)

        var frames = [RuntimeWireFrame]()
        var cursor = 0
        while cursor < bytes.count {
            if assembly.isEmpty {
                assemblyDeadline = try now.advanced(
                    by: MonotonicDuration(
                        nanoseconds: Self.assemblyTimeoutNanoseconds
                    )
                )
            }

            if expectedFrameBytes == nil {
                let needed = RuntimeWireFrame.headerByteCount - assembly.count
                let count = min(needed, bytes.count - cursor)
                assembly.append(contentsOf: bytes[cursor..<(cursor + count)])
                cursor += count
                if assembly.count == RuntimeWireFrame.headerByteCount {
                    expectedFrameBytes = try inspectHeader(assembly)
                }
            } else if let expectedFrameBytes {
                let needed = expectedFrameBytes - assembly.count
                let count = min(needed, bytes.count - cursor)
                assembly.append(contentsOf: bytes[cursor..<(cursor + count)])
                cursor += count
            }

            if let expectedFrameBytes, assembly.count == expectedFrameBytes {
                do {
                    frames.append(try RuntimeWireFrameCodec.decode(assembly))
                } catch let error as RuntimeWireCodecError {
                    reset()
                    throw ConnectionDemultiplexerError.invalidFrame(error)
                }
                reset()
            }
        }
        return frames
    }

    public func checkTimeout(now: MonotonicInstant) throws {
        lock.lock()
        defer { lock.unlock() }
        try checkDeadline(now)
    }

    private func inspectHeader(_ bytes: [UInt8]) throws -> Int {
        guard bytes.count == RuntimeWireFrame.headerByteCount,
              Array(bytes[0..<4]) == Array("PPRW".utf8),
              readUInt16(bytes, offset: 4) == RuntimeWireFrame.protocolMajor,
              RuntimeWireMessageType(rawValue: readUInt16(bytes, offset: 6)) != nil,
              readUInt16(bytes, offset: 8) & ~UInt16(1) == 0,
              readUInt16(bytes, offset: 10) == 0
        else {
            reset()
            throw ConnectionDemultiplexerError.invalidHeader
        }
        let payloadBytes = Int(readUInt32(bytes, offset: 12))
        guard payloadBytes <= Self.maximumPayloadBytes else {
            reset()
            throw ConnectionDemultiplexerError.payloadTooLarge
        }
        return RuntimeWireFrame.headerByteCount + payloadBytes
    }

    private func checkDeadline(_ now: MonotonicInstant) throws {
        guard let assemblyDeadline else {
            return
        }
        guard now <= assemblyDeadline else {
            reset()
            throw ConnectionDemultiplexerError.frameAssemblyTimedOut
        }
    }

    private func reset() {
        assembly.removeAll(keepingCapacity: true)
        expectedFrameBytes = nil
        assemblyDeadline = nil
    }

    private func readUInt16(_ bytes: [UInt8], offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private func readUInt32(_ bytes: [UInt8], offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }
}
