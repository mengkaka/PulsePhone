import Darwin
import Foundation
import PulsePhoneHostPaths
import PulsePhoneSharedDefinitions
import PulsePhoneWire

enum GUIHostTransportError: Error {
    case invalidFrame
    case closed
    case systemCall(Int32)
}

struct GUIHostWireFrame {
    static let headerByteCount = 16

    let type: GUIHostWireMessageType
    let payload: [UInt8]
}

enum GUIHostWireCodec {
    private static let magic = Array("PPGW".utf8)

    static func encode(_ frame: GUIHostWireFrame) throws -> [UInt8] {
        guard frame.payload.count <= 16 * 1_024 else {
            throw GUIHostTransportError.invalidFrame
        }
        var bytes = magic
        append(UInt16(1), to: &bytes)
        append(frame.type.rawValue, to: &bytes)
        append(UInt16(0), to: &bytes)
        append(UInt16(0), to: &bytes)
        append(UInt32(frame.payload.count), to: &bytes)
        bytes.append(contentsOf: frame.payload)
        return bytes
    }

    static func decode(_ bytes: [UInt8]) throws -> GUIHostWireFrame {
        guard bytes.count >= GUIHostWireFrame.headerByteCount,
              Array(bytes[0..<4]) == magic,
              uint16(bytes, 4) == 1,
              let type = GUIHostWireMessageType(rawValue: uint16(bytes, 6)),
              uint16(bytes, 8) == 0,
              uint16(bytes, 10) == 0
        else {
            throw GUIHostTransportError.invalidFrame
        }
        let length = Int(uint32(bytes, 12))
        guard length <= 16 * 1_024,
              bytes.count == GUIHostWireFrame.headerByteCount + length
        else {
            throw GUIHostTransportError.invalidFrame
        }
        return GUIHostWireFrame(
            type: type,
            payload: Array(bytes[GUIHostWireFrame.headerByteCount...])
        )
    }

    static func hello(_ value: GUIHostHello) throws -> GUIHostWireFrame {
        GUIHostWireFrame(type: .hello, payload: bytes(try object([
            ("canonicalAppPathHash", .string(value.canonicalAppPathHash)),
            ("guiHostCompatibilityID", .string(value.guiHostCompatibilityID)),
            ("launcherBuildID", .string(value.launcherBuildID)),
            ("launcherInstanceID", .string(value.launcherInstanceID.canonicalString)),
            ("schemaVersion", .number(.uint64(1))),
            ("wireRange", .object(try object([
                ("maximum", .number(.uint64(UInt64(value.wireRange.maximum)))),
                ("minimum", .number(.uint64(UInt64(value.wireRange.minimum)))),
            ]))),
        ])))
    }

    static func decodeHello(_ frame: GUIHostWireFrame) throws -> GUIHostHello {
        let value = try payload(frame, type: .hello)
        guard value["schemaVersion"]?.numberValue.flatMap({ try? $0.requireUInt64() }) == 1,
              let hash = value["canonicalAppPathHash"]?.stringValue,
              let compatibility = value["guiHostCompatibilityID"]?.stringValue,
              let build = value["launcherBuildID"]?.stringValue,
              let instance = value["launcherInstanceID"]?.stringValue,
              let instanceID = try? CanonicalUUID(instance),
              let range = value["wireRange"]?.objectValue,
              let minimum = range["minimum"]?.numberValue.flatMap({ try? $0.requireUInt64() }),
              let maximum = range["maximum"]?.numberValue.flatMap({ try? $0.requireUInt64() }),
              minimum <= UInt16.max,
              maximum <= UInt16.max
        else {
            throw GUIHostTransportError.invalidFrame
        }
        return GUIHostHello(
            canonicalAppPathHash: hash,
            guiHostCompatibilityID: compatibility,
            launcherBuildID: build,
            launcherInstanceID: instanceID,
            wireRange: GUIHostWireRange(
                minimum: UInt16(minimum),
                maximum: UInt16(maximum)
            )
        )
    }

    static func helloAck(_ value: GUIHostHelloAck) throws -> GUIHostWireFrame {
        GUIHostWireFrame(type: .helloAck, payload: bytes(try object([
            ("canonicalAppPathHash", .string(value.canonicalAppPathHash)),
            ("guiBuildID", .string(value.guiBuildID)),
            ("guiHostCompatibilityID", .string(value.guiHostCompatibilityID)),
            ("guiHostInstanceID", .string(value.guiHostInstanceID.canonicalString)),
            ("schemaVersion", .number(.uint64(1))),
            ("selectedWireMajor", .number(.uint64(UInt64(value.selectedWireMajor)))),
        ])))
    }

    static func decodeHelloAck(
        _ frame: GUIHostWireFrame
    ) throws -> GUIHostHelloAck {
        let value = try payload(frame, type: .helloAck)
        guard let hash = value["canonicalAppPathHash"]?.stringValue,
              let build = value["guiBuildID"]?.stringValue,
              let compatibility = value["guiHostCompatibilityID"]?.stringValue,
              let instance = value["guiHostInstanceID"]?.stringValue,
              let instanceID = try? CanonicalUUID(instance),
              value["schemaVersion"]?.numberValue.flatMap({ try? $0.requireUInt64() }) == 1,
              value["selectedWireMajor"]?.numberValue.flatMap({ try? $0.requireUInt64() }) == 1
        else {
            throw GUIHostTransportError.invalidFrame
        }
        return GUIHostHelloAck(
            canonicalAppPathHash: hash,
            guiBuildID: build,
            guiHostCompatibilityID: compatibility,
            guiHostInstanceID: instanceID,
            selectedWireMajor: 1
        )
    }

    static func openLive(
        _ value: GUIHostOpenLiveRequest
    ) throws -> GUIHostWireFrame {
        GUIHostWireFrame(type: .openLive, payload: bytes(try object([
            ("payload", .object(try object([
                ("canonicalUDID", .string(value.canonicalUDID.rawValue)),
                ("sourceSelectionPolicy", .string(
                    value.sourceSelectionPolicy.rawValue
                )),
            ]))),
            ("requestID", .string(value.requestID.canonicalString)),
            ("schemaVersion", .number(.uint64(2))),
        ])))
    }

    static func decodeOpenLive(
        _ frame: GUIHostWireFrame
    ) throws -> GUIHostOpenLiveRequest {
        let value = try payload(frame, type: .openLive)
        guard value["schemaVersion"]?.numberValue.flatMap({ try? $0.requireUInt64() }) == 2,
              let request = value["requestID"]?.stringValue,
              let requestID = try? CanonicalUUID(request),
              let body = value["payload"]?.objectValue,
              let target = body["canonicalUDID"]?.stringValue,
              let canonicalUDID = try? CanonicalUDID(canonicalString: target),
              let policyValue = body["sourceSelectionPolicy"]?.stringValue,
              let policy = GUIHostSourceSelectionPolicy(rawValue: policyValue)
        else {
            throw GUIHostTransportError.invalidFrame
        }
        return GUIHostOpenLiveRequest(
            requestID: requestID,
            canonicalUDID: canonicalUDID,
            sourceSelectionPolicy: policy
        )
    }

    static func openLiveResult(
        _ value: GUIHostOpenLiveResult
    ) throws -> GUIHostWireFrame {
        var payloadMembers: [(String, RepositoryJSONValue)] = [
            ("disposition", .string(value.disposition.rawValue)),
        ]
        if let code = value.errorCode {
            payloadMembers.append(("error", .object(try object([
                ("code", .string(code.rawValue)),
            ]))))
        }
        if let target = value.canonicalUDID, let windowID = value.windowID {
            payloadMembers.append(("result", .object(try object([
                ("canonicalUDID", .string(target.rawValue)),
                ("windowID", .string(windowID)),
            ]))))
        }
        return GUIHostWireFrame(type: .openLiveResult, payload: bytes(try object([
            ("payload", .object(try object(payloadMembers))),
            ("requestID", .string(value.requestID.canonicalString)),
            ("schemaVersion", .number(.uint64(2))),
        ])))
    }

    static func decodeOpenLiveResult(
        _ frame: GUIHostWireFrame
    ) throws -> GUIHostOpenLiveResult {
        let value = try payload(frame, type: .openLiveResult)
        guard value["schemaVersion"]?.numberValue.flatMap({ try? $0.requireUInt64() }) == 2,
              let request = value["requestID"]?.stringValue,
              let requestID = try? CanonicalUUID(request),
              let body = value["payload"]?.objectValue,
              let dispositionValue = body["disposition"]?.stringValue,
              let disposition = GUIHostOpenDisposition(rawValue: dispositionValue)
        else {
            throw GUIHostTransportError.invalidFrame
        }
        let result = body["result"]?.objectValue
        let target = try result?["canonicalUDID"]?.stringValue.map {
            try CanonicalUDID(canonicalString: $0)
        }
        let code = body["error"]?.objectValue?["code"]?.stringValue
            .flatMap(GUIHostOpenErrorCode.init(rawValue:))
        return GUIHostOpenLiveResult(
            requestID: requestID,
            disposition: disposition,
            canonicalUDID: target,
            windowID: result?["windowID"]?.stringValue,
            errorCode: code
        )
    }

    static func read(from descriptor: Int32) throws -> GUIHostWireFrame {
        let header = try readExact(GUIHostWireFrame.headerByteCount, from: descriptor)
        let length = Int(uint32(header, 12))
        guard length <= 16 * 1_024 else {
            throw GUIHostTransportError.invalidFrame
        }
        return try decode(header + readExact(length, from: descriptor))
    }

    static func write(_ frame: GUIHostWireFrame, to descriptor: Int32) throws {
        let bytes = try encode(frame)
        var offset = 0
        while offset < bytes.count {
            let result = bytes.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if result > 0 { offset += result }
            else if result == -1, errno == EINTR { continue }
            else { throw GUIHostTransportError.systemCall(errno) }
        }
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
            if result > 0 { offset += result }
            else if result == 0 { throw GUIHostTransportError.closed }
            else if errno == EINTR { continue }
            else { throw GUIHostTransportError.systemCall(errno) }
        }
        return bytes
    }

    private static func payload(
        _ frame: GUIHostWireFrame,
        type: GUIHostWireMessageType
    ) throws -> RepositoryJSONObject {
        guard frame.type == type else { throw GUIHostTransportError.invalidFrame }
        return try RepositoryCanonicalJSON.parseDocument(
            frame.payload,
            maximumByteCount: 16 * 1_024
        )
    }

    private static func object(
        _ members: [(String, RepositoryJSONValue)]
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: members.map {
            RepositoryJSONMember(key: $0.0, value: $0.1)
        })
    }

    private static func bytes(_ object: RepositoryJSONObject) -> [UInt8] {
        RepositoryCanonicalJSON.encodeDocument(object)
    }

    private static func append(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xff))
    }

    private static func append(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value >> 24))
        bytes.append(UInt8((value >> 16) & 0xff))
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8(value & 0xff))
    }

    private static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }
}

public final class ProductionGUIHostTransport: LiveLauncherTransport,
    @unchecked Sendable
{
    private let canonicalAppPath: CanonicalAppPath
    private let clock: SystemMonotonicClock
    private let stateLock = NSLock()
    private var descriptor: Int32 = -1

    public init(canonicalAppPath: CanonicalAppPath) {
        self.canonicalAppPath = canonicalAppPath
        self.clock = SystemMonotonicClock()
    }

    deinit {
        stateLock.lock()
        let active = descriptor
        descriptor = -1
        stateLock.unlock()
        if active >= 0 { _ = Darwin.close(active) }
    }

    public func connectOrLaunch(
        endpoint: GUIHostEndpoint
    ) throws -> LiveLauncherTimed<Void> {
        if let connected = try? connect(path: endpoint.socketPath) {
            replaceDescriptor(connected)
            return LiveLauncherTimed(
                value: (),
                completedAtNanoseconds: clock.now().nanoseconds
            )
        }
        for _ in 0..<10 {
            usleep(10_000)
            if let connected = try? connect(path: endpoint.socketPath) {
                replaceDescriptor(connected)
                return LiveLauncherTimed(
                    value: (),
                    completedAtNanoseconds: clock.now().nanoseconds
                )
            }
        }
        try launchGUIHost()
        let deadline = clock.now().nanoseconds + LiveLauncher.deadlineNanoseconds
        while clock.now().nanoseconds < deadline {
            if let connected = try? connect(path: endpoint.socketPath) {
                replaceDescriptor(connected)
                return LiveLauncherTimed(
                    value: (),
                    completedAtNanoseconds: clock.now().nanoseconds
                )
            }
            usleep(20_000)
        }
        throw GUIHostTransportError.closed
    }

    public func hello(
        _ hello: GUIHostHello
    ) throws -> LiveLauncherTimed<GUIHostHelloAck> {
        let descriptor = try currentDescriptor()
        try GUIHostWireCodec.write(try GUIHostWireCodec.hello(hello), to: descriptor)
        let acknowledgement = try GUIHostWireCodec.decodeHelloAck(
            GUIHostWireCodec.read(from: descriptor)
        )
        return LiveLauncherTimed(
            value: acknowledgement,
            completedAtNanoseconds: clock.now().nanoseconds
        )
    }

    public func openLive(
        _ request: GUIHostOpenLiveRequest
    ) throws -> LiveLauncherTimed<GUIHostOpenLiveResult> {
        let descriptor = try currentDescriptor()
        try GUIHostWireCodec.write(
            try GUIHostWireCodec.openLive(request),
            to: descriptor
        )
        let result = try GUIHostWireCodec.decodeOpenLiveResult(
            GUIHostWireCodec.read(from: descriptor)
        )
        return LiveLauncherTimed(
            value: result,
            completedAtNanoseconds: clock.now().nanoseconds
        )
    }

    private func launchGUIHost() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath:
            canonicalAppPath.bundlePath + "/Contents/MacOS/PulsePhone"
        )
        process.arguments = [GUIHostProcessEntrypoint.roleArgument]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private func connect(path: String) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw GUIHostTransportError.systemCall(errno) }
        do {
            try configure(descriptor)
            var address = try socketAddress(path: path)
            let length = socklen_t(address.sun_len)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, length)
                }
            }
            guard result == 0 else { throw GUIHostTransportError.systemCall(errno) }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func configure(_ descriptor: Int32) throws {
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw GUIHostTransportError.systemCall(errno)
        }
        var noSignal: Int32 = 1
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0,
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            timeoutSize
        ) == 0,
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            timeoutSize
        ) == 0
        else {
            throw GUIHostTransportError.systemCall(errno)
        }
    }

    private func socketAddress(path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        let offset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)!
        let length = offset + bytes.count + 1
        guard length <= MemoryLayout<sockaddr_un>.size,
              length <= Int(UInt8.max)
        else { throw GUIHostTransportError.invalidFrame }
        var address = sockaddr_un()
        address.sun_len = UInt8(length)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    private func replaceDescriptor(_ value: Int32) {
        stateLock.lock()
        let previous = descriptor
        descriptor = value
        stateLock.unlock()
        if previous >= 0 { _ = Darwin.close(previous) }
    }

    private func currentDescriptor() throws -> Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard descriptor >= 0 else { throw GUIHostTransportError.closed }
        return descriptor
    }
}
