import Darwin
import Foundation

public actor AppleRegionSubprocessTransport: AppleRegionWorkerTransport {
    public static let hiddenRole = "--element-apple-region-worker-v1"
    public static let requestTimeout: Duration = .seconds(2)
    public static let startupTimeout: Duration = .seconds(3)

    private let executablePath: String
    private let requestTimeout: Duration
    private let startupTimeout: Duration
    private var process: AppleRegionWorkerProcess?

    public init(
        executablePath: String,
        startupTimeout: Duration = AppleRegionSubprocessTransport.startupTimeout,
        requestTimeout: Duration = AppleRegionSubprocessTransport.requestTimeout
    ) {
        self.executablePath = executablePath
        self.requestTimeout = requestTimeout
        self.startupTimeout = startupTimeout
    }

    deinit {
        process?.terminateAndReap()
    }

    public func start() async throws -> AppleRegionWorkerMessage {
        guard process == nil else { throw AppleRegionWorkerError.invalidMessage }
        let child = try AppleRegionWorkerProcess.spawn(executablePath: executablePath)
        process = child
        do {
            let payload = try await child.readFrame(
                maximumBytes: AppleRegionWorkerMessage.maximumResponseFrameBytes,
                timeout: startupTimeout
            )
            let hello = try AppleRegionWorkerCodec.decode(
                payload,
                maximumBytes: AppleRegionWorkerMessage.maximumResponseFrameBytes
            )
            guard hello.type == .hello else {
                throw AppleRegionWorkerError.invalidResponse
            }
            return hello
        } catch {
            child.terminateAndReap()
            process = nil
            throw error
        }
    }

    public func detect(
        _ request: AppleRegionWorkerMessage
    ) async throws -> AppleRegionWorkerMessage {
        guard let process else { throw AppleRegionWorkerError.processExited }
        let requestID = request.requestID
        do {
            try await process.writeFrame(
                try AppleRegionWorkerCodec.encode(request),
                timeout: requestTimeout
            )
            let payload = try await process.readFrame(
                maximumBytes: AppleRegionWorkerMessage.maximumResponseFrameBytes,
                timeout: requestTimeout
            )
            let response = try AppleRegionWorkerCodec.decode(
                payload,
                maximumBytes: AppleRegionWorkerMessage.maximumResponseFrameBytes
            )
            guard response.type == .result, response.requestID == requestID else {
                throw AppleRegionWorkerError.invalidResponse
            }
            return response
        } catch {
            process.terminateAndReap()
            self.process = nil
            throw error
        }
    }

    public func shutdown() async {
        guard let process else { return }
        self.process = nil
        if let payload = try? AppleRegionWorkerCodec.encode(.shutdown()) {
            try? await process.writeFrame(payload, timeout: .milliseconds(250))
        }
        process.closeInputAndReap(grace: .milliseconds(500))
    }
}

private final class AppleRegionWorkerProcess: @unchecked Sendable {
    private var commandWriter: Int32
    private let lock = NSLock()
    private let pid: pid_t
    private let processGroupID: pid_t
    private var responseReader: Int32
    private var reaped = false

    private init(
        pid: pid_t,
        commandWriter: Int32,
        responseReader: Int32
    ) {
        self.commandWriter = commandWriter
        self.pid = pid
        self.processGroupID = pid
        self.responseReader = responseReader
    }

    deinit {
        terminateAndReap()
    }

    static func spawn(executablePath: String) throws -> AppleRegionWorkerProcess {
        guard let executable = canonicalExecutable(executablePath) else {
            throw AppleRegionWorkerError.invalidExecutable
        }
        var created = [Int32]()
        defer { created.forEach { _ = Darwin.close($0) } }
        let command = try makePipe(operation: "pipe-worker-command")
        created += [command.reader, command.writer]
        guard fcntl(command.writer, F_SETNOSIGPIPE, 1) == 0 else {
            throw AppleRegionWorkerError.systemCall(
                operation: "fcntl-worker-nosigpipe",
                errno: errno
            )
        }
        let response = try makePipe(operation: "pipe-worker-response")
        created += [response.reader, response.writer]

        var actions: posix_spawn_file_actions_t?
        var result = posix_spawn_file_actions_init(&actions)
        guard result == 0 else { throw AppleRegionWorkerError.spawnFailed(errno: result) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let operations = [
            posix_spawn_file_actions_adddup2(&actions, command.reader, STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&actions, response.writer, STDOUT_FILENO),
            posix_spawn_file_actions_addopen(
                &actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0
            ),
            posix_spawn_file_actions_addclose(&actions, command.reader),
            posix_spawn_file_actions_addclose(&actions, command.writer),
            posix_spawn_file_actions_addclose(&actions, response.reader),
            posix_spawn_file_actions_addclose(&actions, response.writer),
            posix_spawn_file_actions_addchdir_np(&actions, "/"),
        ]
        guard let failure = operations.first(where: { $0 != 0 }) else {
            var attributes: posix_spawnattr_t?
            result = posix_spawnattr_init(&attributes)
            guard result == 0 else {
                throw AppleRegionWorkerError.spawnFailed(errno: result)
            }
            defer { posix_spawnattr_destroy(&attributes) }
            let flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)
            let flagResult = posix_spawnattr_setflags(&attributes, flags)
            let groupResult = posix_spawnattr_setpgroup(&attributes, 0)
            guard flagResult == 0, groupResult == 0 else {
                throw AppleRegionWorkerError.spawnFailed(
                    errno: flagResult != 0 ? flagResult : groupResult
                )
            }
            let rawArguments = [
                executable,
                AppleRegionSubprocessTransport.hiddenRole,
            ]
            var arguments: [UnsafeMutablePointer<CChar>?] = rawArguments.map {
                strdup($0)
            }
            arguments.append(nil)
            defer {
                for case let pointer? in arguments { free(pointer) }
            }
            var pid: pid_t = 0
            result = executable.withCString { path in
                arguments.withUnsafeMutableBufferPointer { values in
                    posix_spawn(
                        &pid,
                        path,
                        &actions,
                        &attributes,
                        values.baseAddress!,
                        environ
                    )
                }
            }
            guard result == 0, pid > 0 else {
                throw AppleRegionWorkerError.spawnFailed(errno: result)
            }
            _ = Darwin.close(command.reader)
            created.removeAll { $0 == command.reader }
            _ = Darwin.close(response.writer)
            created.removeAll { $0 == response.writer }
            let worker = AppleRegionWorkerProcess(
                pid: pid,
                commandWriter: command.writer,
                responseReader: response.reader
            )
            created.removeAll {
                $0 == command.writer || $0 == response.reader
            }
            return worker
        }
        throw AppleRegionWorkerError.spawnFailed(errno: failure)
    }

    func writeFrame(_ payload: Data, timeout: Duration) async throws {
        let writer = try lock.withLock {
            guard commandWriter >= 0 else {
                throw AppleRegionWorkerError.processExited
            }
            return commandWriter
        }
        let operation = Task.detached {
            try Self.writeFrame(
                descriptor: writer,
                payload: payload,
                deadline: Self.deadline(after: timeout)
            )
        }
        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
            self.terminateAndReap()
        }
    }

    func readFrame(maximumBytes: Int, timeout: Duration) async throws -> Data {
        let reader = try lock.withLock {
            guard responseReader >= 0 else {
                throw AppleRegionWorkerError.processExited
            }
            return responseReader
        }
        let operation = Task.detached {
            try Self.readFrame(
                descriptor: reader,
                maximumBytes: maximumBytes,
                deadline: Self.deadline(after: timeout)
            )
        }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
            self.terminateAndReap()
        }
    }

    func closeInputAndReap(grace: Duration) {
        lock.withLock {
            guard !reaped else { return }
            if commandWriter >= 0 {
                _ = Darwin.close(commandWriter)
                commandWriter = -1
            }
        }
        let until = Self.deadline(after: grace)
        while DispatchTime.now().uptimeNanoseconds < until {
            var status: Int32 = 0
            let result = Darwin.waitpid(pid, &status, WNOHANG)
            if result == pid {
                lock.withLock {
                    guard !reaped else { return }
                    reaped = true
                    if responseReader >= 0 {
                        _ = Darwin.close(responseReader)
                        responseReader = -1
                    }
                }
                return
            }
            if result < 0, errno != EINTR { break }
            usleep(10_000)
        }
        terminateAndReap()
    }

    func terminateAndReap() {
        lock.withLock {
            guard !reaped else { return }
            reaped = true
            if commandWriter >= 0 {
                _ = Darwin.close(commandWriter)
                commandWriter = -1
            }
            if responseReader >= 0 {
                _ = Darwin.close(responseReader)
                responseReader = -1
            }
            _ = Darwin.killpg(processGroupID, SIGKILL)
            var status: Int32 = 0
            while Darwin.waitpid(pid, &status, 0) == -1, errno == EINTR {}
        }
    }

    private static func writeFrame(
        descriptor: Int32,
        payload: Data,
        deadline: UInt64
    ) throws {
        guard !payload.isEmpty, payload.count <= Int(UInt32.max) else {
            throw AppleRegionWorkerError.invalidMessage
        }
        let length = UInt32(payload.count)
        var framed = Data([
            UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff), UInt8(length & 0xff),
        ])
        framed.append(payload)
        try framed.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(descriptor: descriptor, events: Int16(POLLOUT), deadline: deadline)
                if Task.isCancelled { throw CancellationError() }
                let written = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if written > 0 { offset += written }
                else if written < 0, errno == EINTR || errno == EAGAIN { continue }
                else { throw AppleRegionWorkerError.processExited }
            }
        }
    }

    private static func readFrame(
        descriptor: Int32,
        maximumBytes: Int,
        deadline: UInt64
    ) throws -> Data {
        let header = try readExact(descriptor: descriptor, count: 4, deadline: deadline)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= UInt32(maximumBytes) else {
            throw AppleRegionWorkerError.invalidResponse
        }
        return try readExact(
            descriptor: descriptor,
            count: Int(length),
            deadline: deadline
        )
    }

    private static func readExact(
        descriptor: Int32,
        count: Int,
        deadline: UInt64
    ) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            try wait(descriptor: descriptor, events: Int16(POLLIN), deadline: deadline)
            if Task.isCancelled { throw CancellationError() }
            let readCount = data.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    count - offset
                )
            }
            if readCount > 0 { offset += readCount }
            else if readCount == 0 { throw AppleRegionWorkerError.processExited }
            else if errno == EINTR || errno == EAGAIN { continue }
            else { throw AppleRegionWorkerError.processExited }
        }
        return data
    }

    private static func wait(
        descriptor: Int32,
        events: Int16,
        deadline: UInt64
    ) throws {
        while true {
            if Task.isCancelled { throw CancellationError() }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw AppleRegionWorkerError.timedOut }
            let remaining = min(deadline - now, 50_000_000)
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&item, 1, Int32((remaining + 999_999) / 1_000_000))
            if result > 0 {
                if item.revents & Int16(POLLNVAL | POLLERR) != 0 {
                    throw AppleRegionWorkerError.processExited
                }
                if item.revents & events != 0 { return }
                if item.revents & Int16(POLLHUP) != 0 {
                    throw AppleRegionWorkerError.processExited
                }
            } else if result == 0 {
                continue
            } else if errno != EINTR {
                throw AppleRegionWorkerError.systemCall(
                    operation: "poll-worker",
                    errno: errno
                )
            }
        }
    }

    private static func deadline(after duration: Duration) -> UInt64 {
        let components = duration.components
        let seconds = max(0, components.seconds)
        let nanoseconds = max(0, components.attoseconds) / 1_000_000_000
        let delta = UInt64(seconds).multipliedReportingOverflow(by: 1_000_000_000)
        let interval: UInt64
        if delta.overflow {
            interval = UInt64.max
        } else {
            let total = delta.partialValue.addingReportingOverflow(
                UInt64(nanoseconds)
            )
            interval = total.overflow ? UInt64.max : total.partialValue
        }
        let deadline = DispatchTime.now().uptimeNanoseconds
            .addingReportingOverflow(interval)
        return deadline.overflow ? UInt64.max : deadline.partialValue
    }

    private static func makePipe(
        operation: String
    ) throws -> (reader: Int32, writer: Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else {
            throw AppleRegionWorkerError.systemCall(operation: operation, errno: errno)
        }
        for descriptor in descriptors {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                let failure = errno
                descriptors.forEach { _ = Darwin.close($0) }
                throw AppleRegionWorkerError.systemCall(
                    operation: "fcntl-worker-cloexec",
                    errno: failure
                )
            }
        }
        return (descriptors[0], descriptors[1])
    }

    private static func canonicalExecutable(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              let resolved = realpath(path, nil)
        else { return nil }
        defer { free(resolved) }
        var status = stat()
        guard lstat(resolved, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_mode & mode_t(0o111) != 0
        else { return nil }
        return String(cString: resolved)
    }
}
