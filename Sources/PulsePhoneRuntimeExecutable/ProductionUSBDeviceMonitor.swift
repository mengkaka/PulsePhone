import Darwin
import Foundation
import PulsePhoneSharedDefinitions

enum ProductionUSBDeviceMonitorEvent: Equatable, Sendable {
    case attached(rawTransportUDID: String)
    case detached
    case resynchronize
}

enum ProductionUSBMuxEvent: Equatable, Sendable {
    case attached(deviceID: UInt64, rawTransportUDID: String, usb: Bool)
    case detached(deviceID: UInt64)
    case result
}

struct ProductionUSBDevicePresenceReducer: Sendable {
    private let canonicalUDID: CanonicalUDID
    private var targetDeviceIDs = [UInt64: String]()

    init(canonicalUDID: CanonicalUDID) {
        self.canonicalUDID = canonicalUDID
    }

    mutating func resetTransportSession() {
        targetDeviceIDs.removeAll(keepingCapacity: true)
    }

    mutating func consume(
        _ event: ProductionUSBMuxEvent
    ) -> ProductionUSBDeviceMonitorEvent? {
        switch event {
        case .result:
            return nil
        case .attached(let deviceID, let rawTransportUDID, let usb):
            guard usb,
                  let observed = try? CanonicalUDID(
                    rawTransportUDID: rawTransportUDID
                  ),
                  observed == canonicalUDID
            else { return nil }
            let wasEmpty = targetDeviceIDs.isEmpty
            targetDeviceIDs[deviceID] = rawTransportUDID
            return wasEmpty
                ? .attached(rawTransportUDID: rawTransportUDID)
                : nil
        case .detached(let deviceID):
            guard targetDeviceIDs.removeValue(forKey: deviceID) != nil,
                  targetDeviceIDs.isEmpty
            else { return nil }
            return .detached
        }
    }
}

protocol ProductionUSBDeviceMonitoring: AnyObject, Sendable {
    func start(
        _ handler: @escaping @Sendable (ProductionUSBDeviceMonitorEvent) -> Void
    )
    func stop()
}

enum ProductionUSBDeviceMonitorError: Error, Equatable, Sendable {
    case invalidAddress
    case invalidFrame
    case invalidPayload
    case payloadTooLarge
    case transportFailure(errno: Int32)
}

final class ProductionUSBDeviceMonitor: ProductionUSBDeviceMonitoring,
    @unchecked Sendable
{
    private static let headerByteCount = 16
    private static let maximumPayloadBytes = 1 * 1_024 * 1_024
    private static let plistMessageType: UInt32 = 8
    private static let protocolVersion: UInt32 = 1
    private static let retryDelayMicroseconds: useconds_t = 250_000

    private let group = DispatchGroup()
    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "com.pulsephone.runtime.usb-monitor",
        qos: .utility
    )
    private let socketPath: String
    private var activeDescriptor: Int32 = -1
    private var presenceReducer: ProductionUSBDevicePresenceReducer
    private var started = false
    private var stopping = false

    init(
        canonicalUDID: CanonicalUDID,
        socketPath: String = "/var/run/usbmuxd"
    ) {
        self.presenceReducer = ProductionUSBDevicePresenceReducer(
            canonicalUDID: canonicalUDID
        )
        self.socketPath = socketPath
    }

    deinit {
        stop()
    }

    func start(
        _ handler: @escaping @Sendable (ProductionUSBDeviceMonitorEvent) -> Void
    ) {
        let shouldStart = lock.withLock { () -> Bool in
            guard !started else { return false }
            started = true
            stopping = false
            return true
        }
        guard shouldStart else { return }
        group.enter()
        queue.async { [weak self] in
            defer { self?.group.leave() }
            self?.run(handler)
        }
    }

    func stop() {
        let descriptor = lock.withLock { () -> Int32 in
            guard started else { return -1 }
            stopping = true
            return activeDescriptor
        }
        if descriptor >= 0 {
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        }
        _ = group.wait(timeout: .now() + 2)
        lock.withLock {
            started = false
            activeDescriptor = -1
            presenceReducer.resetTransportSession()
        }
    }

    private var isStopping: Bool {
        lock.withLock { stopping }
    }

    private func run(
        _ handler: @escaping @Sendable (ProductionUSBDeviceMonitorEvent) -> Void
    ) {
        while !isStopping {
            do {
                let descriptor = try connectSocket()
                lock.withLock {
                    activeDescriptor = descriptor
                    presenceReducer.resetTransportSession()
                }
                defer {
                    _ = Darwin.close(descriptor)
                    lock.withLock {
                        if activeDescriptor == descriptor {
                            activeDescriptor = -1
                        }
                    }
                }
                try sendListen(to: descriptor)
                handler(.resynchronize)
                while !isStopping {
                    try handle(
                        Self.readEvent(from: descriptor),
                        with: handler
                    )
                }
            } catch {
                if isStopping { return }
            }
            if !isStopping {
                usleep(Self.retryDelayMicroseconds)
            }
        }
    }

    private func handle(
        _ event: ProductionUSBMuxEvent,
        with handler: @escaping @Sendable (ProductionUSBDeviceMonitorEvent) -> Void
    ) throws {
        let reduced = lock.withLock { presenceReducer.consume(event) }
        if let reduced { handler(reduced) }
    }

    private func connectSocket() throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ProductionUSBDeviceMonitorError.transportFailure(errno: errno)
        }
        do {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw ProductionUSBDeviceMonitorError.transportFailure(errno: errno)
            }
            var noSignal: Int32 = 1
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                throw ProductionUSBDeviceMonitorError.transportFailure(errno: errno)
            }
            var address = try socketAddress(socketPath)
            let addressLength = socklen_t(address.sun_len)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, addressLength)
                }
            }
            guard result == 0 else {
                throw ProductionUSBDeviceMonitorError.transportFailure(errno: errno)
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func socketAddress(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        let offset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)!
        let length = offset + bytes.count + 1
        guard length <= MemoryLayout<sockaddr_un>.size,
              length <= Int(UInt8.max)
        else {
            throw ProductionUSBDeviceMonitorError.invalidAddress
        }
        var address = sockaddr_un()
        address.sun_len = UInt8(length)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    private func sendListen(to descriptor: Int32) throws {
        let payload = try PropertyListSerialization.data(
            fromPropertyList: [
                "ClientVersionString": "PulsePhoneRuntime",
                "MessageType": "Listen",
                "ProgName": "PulsePhoneRuntime",
                "kLibUSBMuxVersion": 3,
            ],
            format: .xml,
            options: 0
        )
        var bytes = [UInt8]()
        bytes.reserveCapacity(Self.headerByteCount + payload.count)
        Self.appendLittleEndian(UInt32(Self.headerByteCount + payload.count), to: &bytes)
        Self.appendLittleEndian(Self.protocolVersion, to: &bytes)
        Self.appendLittleEndian(Self.plistMessageType, to: &bytes)
        Self.appendLittleEndian(1, to: &bytes)
        bytes.append(contentsOf: payload)
        try Self.writeAll(bytes, to: descriptor)
    }

    private static func readEvent(
        from descriptor: Int32
    ) throws -> ProductionUSBMuxEvent {
        let header = try readExact(headerByteCount, from: descriptor)
        let totalLength = Int(littleEndianUInt32(header, offset: 0))
        guard totalLength >= headerByteCount else {
            throw ProductionUSBDeviceMonitorError.invalidFrame
        }
        let payloadLength = totalLength - headerByteCount
        guard payloadLength <= maximumPayloadBytes else {
            throw ProductionUSBDeviceMonitorError.payloadTooLarge
        }
        guard littleEndianUInt32(header, offset: 4) == protocolVersion,
              littleEndianUInt32(header, offset: 8) == plistMessageType
        else {
            throw ProductionUSBDeviceMonitorError.invalidFrame
        }
        let payload = Data(try readExact(payloadLength, from: descriptor))
        return try decodeEventPayload(payload)
    }

    static func decodeEventPayload(
        _ payload: Data
    ) throws -> ProductionUSBMuxEvent {
        guard let root = try PropertyListSerialization.propertyList(
            from: payload,
            options: [],
            format: nil
        ) as? [String: Any],
        let messageType = root["MessageType"] as? String
        else {
            throw ProductionUSBDeviceMonitorError.invalidPayload
        }
        if messageType == "Result" { return .result }
        guard let deviceID = uint64(root["DeviceID"]) else {
            throw ProductionUSBDeviceMonitorError.invalidPayload
        }
        if messageType == "Detached" {
            return .detached(deviceID: deviceID)
        }
        guard messageType == "Attached",
              let properties = root["Properties"] as? [String: Any],
              let serial = properties["SerialNumber"] as? String
        else {
            throw ProductionUSBDeviceMonitorError.invalidPayload
        }
        let connectionType = properties["ConnectionType"] as? String
        return .attached(
            deviceID: deviceID,
            rawTransportUDID: serial,
            usb: connectionType == nil || connectionType == "USB"
        )
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64 { return value }
        if let value = value as? Int, value >= 0 { return UInt64(value) }
        if let value = value as? NSNumber { return value.uint64Value }
        return nil
    }

    private static func appendLittleEndian(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func littleEndianUInt32(
        _ bytes: [UInt8],
        offset: Int
    ) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readExact(
        _ count: Int,
        from descriptor: Int32
    ) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let result = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    count - offset
                )
            }
            if result > 0 {
                offset += result
            } else if result == 0 {
                throw ProductionUSBDeviceMonitorError.transportFailure(errno: ECONNRESET)
            } else if errno == EINTR {
                continue
            } else {
                throw ProductionUSBDeviceMonitorError.transportFailure(errno: errno)
            }
        }
        return bytes
    }

    private static func writeAll(_ bytes: [UInt8], to descriptor: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let result = bytes.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if result > 0 {
                offset += result
            } else if result == -1, errno == EINTR {
                continue
            } else {
                throw ProductionUSBDeviceMonitorError.transportFailure(errno: errno)
            }
        }
    }
}
