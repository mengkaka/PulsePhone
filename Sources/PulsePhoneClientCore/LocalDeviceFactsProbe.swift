import Darwin
import Foundation
import PulsePhoneSharedDefinitions

public enum FactsProbeTransport: String, Equatable, Sendable {
    case network
    case usb
}

public struct RawDiscoveredDevice: Equatable, Sendable {
    public let deviceID: UInt64
    public let rawTransportUDID: String
    public let transport: FactsProbeTransport
}

public struct RawDiscoverySnapshot: Equatable, Sendable {
    public let observedAtMonotonicNanoseconds: UInt64
    public let devices: [RawDiscoveredDevice]
}

public struct LocalDeviceFacts: Equatable, Sendable {
    public let buildVersion: String
    public let deviceClass: String
    public let deviceName: String
    public let productType: String
    public let productVersion: String
    public let uniqueDeviceID: String
}

public struct LocalDeviceCondition: Equatable, Sendable {
    public let connected: Bool
    public let locked: Bool
    public let trusted: Bool
}

public struct FactsProbeProvenance: Equatable, Sendable {
    public let autopair: Bool
    public let mode: String
    public let queriedKeys: [String]
}

public struct LocalDeviceFactsResult: Equatable, Sendable {
    public let facts: LocalDeviceFacts
    public let condition: LocalDeviceCondition
    public let provenance: FactsProbeProvenance
}

public enum LocalDeviceFactsProbeError: Error, Equatable, Sendable {
    case invalidExecutable
    case invalidRequest
    case spawnFailed(errno: Int32)
    case workTimeout
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)
    case responseTooLarge
    case invalidResponse
    case responseMismatch
    case childExitedNonzero(status: Int32)
    case remoteFailure(code: String)
    case terminationTimeout
    case systemCall(operation: String, errno: Int32)
}

public struct LocalDeviceFactsProbe: Sendable {
    public static let requestLimitBytes = 16 * 1_024
    public static let responseLimitBytes = 256 * 1_024
    public static let deviceLimit = 256
    public static let workTimeout = MonotonicDuration(
        nanoseconds: 2_000_000_000
    )
    public static let abnormalTerminationTimeout = MonotonicDuration(
        nanoseconds: 1_000_000_000
    )

    private let executablePath: String
    private let arguments: [String]
    private let requestIDFactory: @Sendable () -> CanonicalUUID
    private let clock: any MonotonicClock
    private let workTimeout: MonotonicDuration
    private let terminationTimeout: MonotonicDuration

    public init(executablePath: String) {
        self.init(
            executablePath: executablePath,
            arguments: ["--mode", "facts"],
            requestIDFactory: {
                try! CanonicalUUID(UUID().uuidString.lowercased())
            },
            clock: SystemMonotonicClock(),
            workTimeout: Self.workTimeout,
            terminationTimeout: Self.abnormalTerminationTimeout
        )
    }

    init(
        executablePath: String,
        arguments: [String],
        requestIDFactory: @escaping @Sendable () -> CanonicalUUID,
        clock: any MonotonicClock = SystemMonotonicClock(),
        workTimeout: MonotonicDuration,
        terminationTimeout: MonotonicDuration
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.requestIDFactory = requestIDFactory
        self.clock = clock
        self.workTimeout = workTimeout
        self.terminationTimeout = terminationTimeout
    }

    public func enumerate() throws -> RawDiscoverySnapshot {
        let requestID = requestIDFactory()
        let response = try invoke(
            requestID: requestID,
            operation: "enumerate",
            payload: [:]
        )
        return try decodeEnumeration(response)
    }

    public func probe(
        deviceID: UInt64,
        rawTransportUDID: String
    ) throws -> LocalDeviceFactsResult {
        guard Self.validString(rawTransportUDID, maximumBytes: 256) else {
            throw LocalDeviceFactsProbeError.invalidRequest
        }
        let requestID = requestIDFactory()
        let response = try invoke(
            requestID: requestID,
            operation: "probe",
            payload: [
                "deviceID": NSNumber(value: deviceID),
                "rawTransportUDID": rawTransportUDID,
            ]
        )
        return try decodeFacts(response)
    }

    private func invoke(
        requestID: CanonicalUUID,
        operation: String,
        payload: [String: Any]
    ) throws -> [String: Any] {
        try validateExecutable()
        let request = [
            "operation": operation,
            "payload": payload,
            "requestID": requestID.canonicalString,
            "schemaVersion": 1,
        ] as [String: Any]
        guard JSONSerialization.isValidJSONObject(request) else {
            throw LocalDeviceFactsProbeError.invalidRequest
        }
        var requestBytes = try JSONSerialization.data(
            withJSONObject: request,
            options: [.sortedKeys]
        )
        requestBytes.append(0x0a)
        guard requestBytes.count <= Self.requestLimitBytes else {
            throw LocalDeviceFactsProbeError.invalidRequest
        }

        let startedAt = clock.now()
        let workDeadline = try startedAt.advanced(by: workTimeout)
        let pipes = try makePipes()
        var parentInput = pipes.stdinWriter
        var parentOutput = pipes.stdoutReader
        var childInput = pipes.stdinReader
        var childOutput = pipes.stdoutWriter
        defer {
            for descriptor in [parentInput, parentOutput, childInput, childOutput]
                where descriptor >= 0
            {
                _ = Darwin.close(descriptor)
            }
            pipes.fillerDescriptors.forEach { _ = Darwin.close($0) }
        }

        var actions: posix_spawn_file_actions_t?
        let actionsResult = posix_spawn_file_actions_init(&actions)
        guard actionsResult == 0 else {
            throw LocalDeviceFactsProbeError.spawnFailed(errno: actionsResult)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        try configureFileActions(
            &actions,
            stdinReader: childInput,
            stdinWriter: parentInput,
            stdoutReader: parentOutput,
            stdoutWriter: childOutput
        )

        var attributes: posix_spawnattr_t?
        let attributesResult = posix_spawnattr_init(&attributes)
        guard attributesResult == 0 else {
            throw LocalDeviceFactsProbeError.spawnFailed(errno: attributesResult)
        }
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)
        let flagResult = posix_spawnattr_setflags(&attributes, flags)
        let groupResult = posix_spawnattr_setpgroup(&attributes, 0)
        guard flagResult == 0, groupResult == 0 else {
            throw LocalDeviceFactsProbeError.spawnFailed(
                errno: flagResult != 0 ? flagResult : groupResult
            )
        }

        let rawArguments = [executablePath] + arguments
        var cArguments = rawArguments.map { strdup($0) } + [nil]
        defer { cArguments.compactMap { $0 }.forEach { free($0) } }
        var pid: pid_t = 0
        let spawnResult = executablePath.withCString { path in
            cArguments.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(
                    &pid,
                    path,
                    &actions,
                    &attributes,
                    buffer.baseAddress!,
                    environ
                )
            }
        }
        guard spawnResult == 0, pid > 0 else {
            throw LocalDeviceFactsProbeError.spawnFailed(errno: spawnResult)
        }

        _ = Darwin.close(childInput)
        childInput = -1
        _ = Darwin.close(childOutput)
        childOutput = -1

        do {
            try writeAll(
                [UInt8](requestBytes),
                to: parentInput,
                deadline: workDeadline
            )
            _ = Darwin.close(parentInput)
            parentInput = -1
            let responseBytes = try readExactlyOneLine(
                from: parentOutput,
                deadline: workDeadline
            )
            _ = Darwin.close(parentOutput)
            parentOutput = -1
            let status = try waitForExit(pid, deadline: workDeadline)
            guard Self.exitedSuccessfully(status) else {
                throw LocalDeviceFactsProbeError.childExitedNonzero(status: status)
            }
            return try decodeResponse(
                responseBytes,
                requestID: requestID,
                operation: operation
            )
        } catch {
            if parentInput >= 0 {
                _ = Darwin.close(parentInput)
                parentInput = -1
            }
            if parentOutput >= 0 {
                _ = Darwin.close(parentOutput)
                parentOutput = -1
            }
            try terminateAndReap(pid)
            throw error
        }
    }

    private func configureFileActions(
        _ actions: inout posix_spawn_file_actions_t?,
        stdinReader: Int32,
        stdinWriter: Int32,
        stdoutReader: Int32,
        stdoutWriter: Int32
    ) throws {
        let operations = [
            posix_spawn_file_actions_addclose(&actions, stdinWriter),
            posix_spawn_file_actions_addclose(&actions, stdoutReader),
            posix_spawn_file_actions_adddup2(&actions, stdinReader, STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&actions, stdoutWriter, STDOUT_FILENO),
            posix_spawn_file_actions_addopen(
                &actions,
                STDERR_FILENO,
                "/dev/null",
                O_WRONLY,
                0
            ),
            stdinReader == STDIN_FILENO
                ? 0
                : posix_spawn_file_actions_addclose(&actions, stdinReader),
            stdoutWriter == STDOUT_FILENO
                ? 0
                : posix_spawn_file_actions_addclose(&actions, stdoutWriter),
            posix_spawn_file_actions_addchdir_np(&actions, "/"),
        ]
        guard let failure = operations.first(where: { $0 != 0 }) else {
            return
        }
        throw LocalDeviceFactsProbeError.spawnFailed(errno: failure)
    }

    private func makePipes() throws -> (
        stdinReader: Int32,
        stdinWriter: Int32,
        stdoutReader: Int32,
        stdoutWriter: Int32,
        fillerDescriptors: [Int32]
    ) {
        var fillers = [Int32]()
        for descriptor in STDIN_FILENO...STDERR_FILENO
            where fcntl(descriptor, F_GETFD) == -1
        {
            let filler = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
            guard filler == descriptor else {
                if filler >= 0 { _ = Darwin.close(filler) }
                fillers.forEach { _ = Darwin.close($0) }
                throw LocalDeviceFactsProbeError.systemCall(
                    operation: "fill-standard-descriptor",
                    errno: filler < 0 ? errno : EIO
                )
            }
            fillers.append(filler)
        }
        var input = [Int32](repeating: -1, count: 2)
        var output = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&input) == 0 else {
            fillers.forEach { _ = Darwin.close($0) }
            throw LocalDeviceFactsProbeError.systemCall(
                operation: "pipe-stdin",
                errno: errno
            )
        }
        guard Darwin.pipe(&output) == 0 else {
            input.forEach { _ = Darwin.close($0) }
            fillers.forEach { _ = Darwin.close($0) }
            throw LocalDeviceFactsProbeError.systemCall(
                operation: "pipe-stdout",
                errno: errno
            )
        }
        return (input[0], input[1], output[0], output[1], fillers)
    }

    private func writeAll(
        _ bytes: [UInt8],
        to descriptor: Int32,
        deadline: MonotonicInstant
    ) throws {
        var offset = 0
        while offset < bytes.count {
            try waitForDescriptor(descriptor, events: Int16(POLLOUT), deadline: deadline)
            let written = bytes.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if written > 0 {
                offset += written
            } else if written == -1, errno == EINTR {
                continue
            } else {
                throw LocalDeviceFactsProbeError.writeFailed(errno: errno)
            }
        }
    }

    private func readExactlyOneLine(
        from descriptor: Int32,
        deadline: MonotonicInstant
    ) throws -> [UInt8] {
        var output = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            try waitForDescriptor(descriptor, events: Int16(POLLIN), deadline: deadline)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                output.append(contentsOf: buffer.prefix(count))
                guard output.count <= Self.responseLimitBytes else {
                    throw LocalDeviceFactsProbeError.responseTooLarge
                }
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw LocalDeviceFactsProbeError.readFailed(errno: errno)
            }
        }
        guard output.last == 0x0a,
              output.dropLast().allSatisfy({ $0 != 0x0a && $0 != 0x0d }),
              output.count > 1
        else {
            throw LocalDeviceFactsProbeError.invalidResponse
        }
        return Array(output.dropLast())
    }

    private func waitForDescriptor(
        _ descriptor: Int32,
        events: Int16,
        deadline: MonotonicInstant
    ) throws {
        while true {
            let now = clock.now()
            guard now < deadline else {
                throw LocalDeviceFactsProbeError.workTimeout
            }
            let remaining = try deadline.duration(since: now).nanoseconds
            let milliseconds = min(
                UInt64(Int32.max),
                max(1, (remaining + 999_999) / 1_000_000)
            )
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&item, 1, Int32(milliseconds))
            if result == 0 {
                throw LocalDeviceFactsProbeError.workTimeout
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw LocalDeviceFactsProbeError.systemCall(
                    operation: "poll-facts-probe",
                    errno: errno
                )
            }
            if item.revents & Int16(POLLERR | POLLNVAL) != 0 {
                throw LocalDeviceFactsProbeError.readFailed(errno: EIO)
            }
            if item.revents & (events | Int16(POLLHUP)) != 0 {
                return
            }
        }
    }

    private func waitForExit(
        _ pid: pid_t,
        deadline: MonotonicInstant
    ) throws -> Int32 {
        var status: Int32 = 0
        while clock.now() < deadline {
            let result = Darwin.waitpid(pid, &status, WNOHANG)
            if result == pid { return status }
            if result == -1, errno != EINTR {
                throw LocalDeviceFactsProbeError.systemCall(
                    operation: "waitpid-facts-probe",
                    errno: errno
                )
            }
            usleep(1_000)
        }
        throw LocalDeviceFactsProbeError.workTimeout
    }

    private func terminateAndReap(_ pid: pid_t) throws {
        var status: Int32 = 0
        let initial = Darwin.waitpid(pid, &status, WNOHANG)
        if initial == pid || (initial == -1 && errno == ECHILD) {
            return
        }
        _ = Darwin.killpg(pid, SIGKILL)
        let deadline = try clock.now().advanced(by: terminationTimeout)
        while clock.now() < deadline {
            let result = Darwin.waitpid(pid, &status, WNOHANG)
            if result == pid || (result == -1 && errno == ECHILD) {
                return
            }
            if result == -1, errno != EINTR {
                return
            }
            usleep(1_000)
        }
        throw LocalDeviceFactsProbeError.terminationTimeout
    }

    private func decodeResponse(
        _ bytes: [UInt8],
        requestID: CanonicalUUID,
        operation: String
    ) throws -> [String: Any] {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: Data(bytes))
        } catch {
            throw LocalDeviceFactsProbeError.invalidResponse
        }
        guard let object = value as? [String: Any],
              let schemaVersion = Self.uint(object["schemaVersion"]),
              schemaVersion == 1,
              object["requestID"] as? String == requestID.canonicalString,
              object["operation"] as? String == operation,
              let ok = object["ok"] as? Bool
        else {
            throw LocalDeviceFactsProbeError.responseMismatch
        }
        if ok {
            guard Set(object.keys) == [
                "ok", "operation", "requestID", "result", "schemaVersion",
            ], let result = object["result"] as? [String: Any]
            else {
                throw LocalDeviceFactsProbeError.invalidResponse
            }
            return result
        }
        guard Set(object.keys) == [
            "error", "ok", "operation", "requestID", "schemaVersion",
        ], let remoteError = object["error"] as? [String: Any],
              Set(remoteError.keys).isSubset(of: ["code", "details"]),
              let code = remoteError["code"] as? String,
              Self.validString(code, maximumBytes: 128)
        else {
            throw LocalDeviceFactsProbeError.invalidResponse
        }
        throw LocalDeviceFactsProbeError.remoteFailure(code: code)
    }

    private func decodeEnumeration(
        _ result: [String: Any]
    ) throws -> RawDiscoverySnapshot {
        guard Set(result.keys) == ["devices", "observedAtMonotonicNs"],
              let observedAt = Self.uint(result["observedAtMonotonicNs"]),
              let values = result["devices"] as? [Any],
              values.count <= Self.deviceLimit
        else {
            throw LocalDeviceFactsProbeError.invalidResponse
        }
        let devices = try values.map { value -> RawDiscoveredDevice in
            guard let item = value as? [String: Any],
                  Set(item.keys) == ["deviceID", "rawTransportUDID", "transport"],
                  let deviceID = Self.uint(item["deviceID"]),
                  let rawUDID = item["rawTransportUDID"] as? String,
                  Self.validString(rawUDID, maximumBytes: 256),
                  let rawTransport = item["transport"] as? String,
                  let transport = FactsProbeTransport(rawValue: rawTransport)
            else {
                throw LocalDeviceFactsProbeError.invalidResponse
            }
            return RawDiscoveredDevice(
                deviceID: deviceID,
                rawTransportUDID: rawUDID,
                transport: transport
            )
        }
        return RawDiscoverySnapshot(
            observedAtMonotonicNanoseconds: observedAt,
            devices: devices
        )
    }

    private func decodeFacts(
        _ result: [String: Any]
    ) throws -> LocalDeviceFactsResult {
        guard Set(result.keys) == ["condition", "facts", "provenance"],
              let condition = result["condition"] as? [String: Any],
              Set(condition.keys) == ["connected", "locked", "trusted"],
              let connected = condition["connected"] as? Bool,
              let locked = condition["locked"] as? Bool,
              let trusted = condition["trusted"] as? Bool,
              let facts = result["facts"] as? [String: Any],
              Set(facts.keys) == [
                "buildVersion", "deviceClass", "deviceName", "productType",
                "productVersion", "uniqueDeviceID",
              ],
              let buildVersion = facts["buildVersion"] as? String,
              let deviceClass = facts["deviceClass"] as? String,
              let deviceName = facts["deviceName"] as? String,
              let productType = facts["productType"] as? String,
              let productVersion = facts["productVersion"] as? String,
              let uniqueDeviceID = facts["uniqueDeviceID"] as? String,
              Self.validString(buildVersion, maximumBytes: 128),
              Self.validString(deviceClass, maximumBytes: 128),
              Self.validString(deviceName, maximumBytes: 256),
              Self.validString(productType, maximumBytes: 128),
              Self.validString(productVersion, maximumBytes: 128),
              Self.validString(uniqueDeviceID, maximumBytes: 256),
              let provenance = result["provenance"] as? [String: Any],
              Set(provenance.keys) == ["autopair", "mode", "queriedKeys"],
              provenance["autopair"] as? Bool == false,
              provenance["mode"] as? String == "directHelperFacts",
              let queriedKeys = provenance["queriedKeys"] as? [String],
              queriedKeys.count <= 6,
              Set(queriedKeys).count == queriedKeys.count
        else {
            throw LocalDeviceFactsProbeError.invalidResponse
        }
        let allowedKeys = Set([
            "BuildVersion", "DeviceClass", "DeviceName", "ProductType",
            "ProductVersion", "UniqueDeviceID",
        ])
        guard Set(queriedKeys).isSubset(of: allowedKeys) else {
            throw LocalDeviceFactsProbeError.invalidResponse
        }
        return LocalDeviceFactsResult(
            facts: LocalDeviceFacts(
                buildVersion: buildVersion,
                deviceClass: deviceClass,
                deviceName: deviceName,
                productType: productType,
                productVersion: productVersion,
                uniqueDeviceID: uniqueDeviceID
            ),
            condition: LocalDeviceCondition(
                connected: connected,
                locked: locked,
                trusted: trusted
            ),
            provenance: FactsProbeProvenance(
                autopair: false,
                mode: "directHelperFacts",
                queriedKeys: queriedKeys
            )
        )
    }

    private func validateExecutable() throws {
        guard executablePath.hasPrefix("/"), !executablePath.utf8.contains(0) else {
            throw LocalDeviceFactsProbeError.invalidExecutable
        }
        var metadata = stat()
        guard lstat(executablePath, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_mode & mode_t(0o111) != 0,
              let resolved = realpath(executablePath, nil)
        else {
            throw LocalDeviceFactsProbeError.invalidExecutable
        }
        defer { free(resolved) }
        guard String(cString: resolved) == executablePath else {
            throw LocalDeviceFactsProbeError.invalidExecutable
        }
    }

    private static func validString(_ value: String, maximumBytes: Int) -> Bool {
        let count = value.utf8.count
        return (1...maximumBytes).contains(count) && !value.utf8.contains(0)
    }

    private static func uint(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        return UInt64(number.stringValue)
    }

    private static func exitedSuccessfully(_ status: Int32) -> Bool {
        (status & 0x7f) == 0 && ((status >> 8) & 0xff) == 0
    }
}
