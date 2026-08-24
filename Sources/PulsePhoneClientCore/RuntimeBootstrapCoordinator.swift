import Darwin
import Dispatch
import PulsePhoneHostPaths
import PulsePhoneSharedDefinitions

public struct RuntimeProcessStartIdentity: Hashable, Sendable {
    public let seconds: UInt64
    public let microseconds: UInt64

    public init(seconds: UInt64, microseconds: UInt64) {
        self.seconds = seconds
        self.microseconds = microseconds
    }
}

public struct LaunchedRuntimeGeneration: Equatable, Sendable {
    public let pid: pid_t
    public let runtimeEpoch: CanonicalUUID
    public let processStartIdentity: RuntimeProcessStartIdentity
    public let executablePath: String

    public init(
        pid: pid_t,
        runtimeEpoch: CanonicalUUID,
        processStartIdentity: RuntimeProcessStartIdentity,
        executablePath: String
    ) {
        self.pid = pid
        self.runtimeEpoch = runtimeEpoch
        self.processStartIdentity = processStartIdentity
        self.executablePath = executablePath
    }
}

public enum RuntimeBootstrapResult: Equatable, Sendable {
    case existing
    case launched(LaunchedRuntimeGeneration)
}

public enum RuntimeBootstrapCoordinatorError: Error, Equatable, Sendable {
    case generationBusy(RuntimeGenerationClassification)
    case invalidRuntimeExecutable
    case spawnFailed(errno: Int32)
    case readinessTimeout
    case readinessClosedWithoutFrame
    case invalidReadinessFrame
    case runtimeFailed(code: String)
    case processIdentityUnavailable
    case systemCall(operation: String, errno: Int32)
}

public struct RuntimeBootstrapCoordinator: Sendable {
    public static let generationTransitionRetryIntervalMicroseconds: useconds_t = 50_000
    public static let startupDeadlineNanoseconds: UInt64 = 5_000_000_000
    public static let maximumReadinessFrameBytes = 4_096

    private let generationObserver: any RuntimeGenerationObserving
    private let deadGenerationRecoverer: any RuntimeDeadGenerationRecovering
    private let startupDeadline: MonotonicDuration
    private let clock: any MonotonicClock
    private let waitForGenerationTransition: @Sendable () -> Void

    public init(
        generationObserver: any RuntimeGenerationObserving = RuntimeGenerationClassifier(),
        deadGenerationRecoverer: any RuntimeDeadGenerationRecovering =
            ProductionRuntimeDeadGenerationRecoverer()
    ) {
        self.generationObserver = generationObserver
        self.deadGenerationRecoverer = deadGenerationRecoverer
        self.startupDeadline = MonotonicDuration(
            nanoseconds: Self.startupDeadlineNanoseconds
        )
        self.clock = SystemMonotonicClock()
        self.waitForGenerationTransition = {
            usleep(Self.generationTransitionRetryIntervalMicroseconds)
        }
    }

    init(
        generationObserver: any RuntimeGenerationObserving,
        deadGenerationRecoverer: any RuntimeDeadGenerationRecovering =
            ProductionRuntimeDeadGenerationRecoverer(),
        startupDeadline: MonotonicDuration,
        clock: any MonotonicClock = SystemMonotonicClock(),
        waitForGenerationTransition: @escaping @Sendable () -> Void = {
            usleep(Self.generationTransitionRetryIntervalMicroseconds)
        }
    ) {
        self.generationObserver = generationObserver
        self.deadGenerationRecoverer = deadGenerationRecoverer
        self.startupDeadline = startupDeadline
        self.clock = clock
        self.waitForGenerationTransition = waitForGenerationTransition
    }

    public func ensureRunning(
        for canonicalUDID: CanonicalUDID,
        from canonicalAppPath: CanonicalAppPath
    ) throws -> RuntimeBootstrapResult {
        let bootstrapLock = try BootstrapLock.acquire(for: canonicalUDID)
        return try ensureRunning(
            for: canonicalUDID,
            from: canonicalAppPath,
            whileHolding: bootstrapLock
        )
    }

    public func recoverAfterSocketUnavailable(
        for canonicalUDID: CanonicalUDID,
        from canonicalAppPath: CanonicalAppPath
    ) throws -> RuntimeBootstrapResult {
        let bootstrapLock = try BootstrapLock.acquire(for: canonicalUDID)
        return try ensureRunning(
            for: canonicalUDID,
            from: canonicalAppPath,
            whileHolding: bootstrapLock,
            waitingForExistingGenerationToSettle: true
        )
    }

    func ensureRunning(
        for canonicalUDID: CanonicalUDID,
        from canonicalAppPath: CanonicalAppPath,
        whileHolding bootstrapLock: BootstrapLock,
        waitingForExistingGenerationToSettle: Bool = false
    ) throws -> RuntimeBootstrapResult {
        guard bootstrapLock.canonicalUDID == canonicalUDID else {
            throw RuntimeBootstrapCoordinatorError.invalidRuntimeExecutable
        }
        let transitionDeadline = try clock.now().advanced(by: startupDeadline)
        while true {
            let classification = try generationObserver.classification(
                for: canonicalUDID,
                whileHolding: bootstrapLock
            )
            switch classification {
            case .alive:
                guard waitingForExistingGenerationToSettle else {
                    return .existing
                }
                guard clock.now() < transitionDeadline else {
                    throw RuntimeBootstrapCoordinatorError.generationBusy(
                        classification
                    )
                }
                waitForGenerationTransition()
            case .absent:
                return try spawnRuntime(
                    for: canonicalUDID,
                    from: canonicalAppPath
                )
            case .identityUnknown:
                let runtimeExecutablePath: String
                do {
                    runtimeExecutablePath = try resolveRuntimeExecutable(
                        in: canonicalAppPath
                    )
                } catch {
                    throw RuntimeBootstrapCoordinatorError.generationBusy(
                        classification
                    )
                }
                if try deadGenerationRecoverer.recover(
                    canonicalUDID: canonicalUDID,
                    runtimeExecutablePath: runtimeExecutablePath,
                    whileHolding: bootstrapLock
                ) {
                    return try spawnRuntime(
                        for: canonicalUDID,
                        from: canonicalAppPath
                    )
                }
                fallthrough
            case .exiting, .orphanHelpers:
                guard clock.now() < transitionDeadline else {
                    throw RuntimeBootstrapCoordinatorError.generationBusy(
                        classification
                    )
                }
                waitForGenerationTransition()
            }
        }
    }

    private func spawnRuntime(
        for canonicalUDID: CanonicalUDID,
        from canonicalAppPath: CanonicalAppPath
    ) throws -> RuntimeBootstrapResult {
        let executablePath = try resolveRuntimeExecutable(
            in: canonicalAppPath
        )
        let (reader, writer, fillerDescriptors) = try makeReadinessPipe()
        defer {
            fillerDescriptors.forEach { _ = Darwin.close($0) }
        }
        var actions: posix_spawn_file_actions_t?
        let actionsResult = posix_spawn_file_actions_init(&actions)
        guard actionsResult == 0 else {
            _ = Darwin.close(reader)
            _ = Darwin.close(writer)
            throw RuntimeBootstrapCoordinatorError.spawnFailed(errno: actionsResult)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        try configureFileActions(
            &actions,
            reader: reader,
            writer: writer
        )

        var attributes: posix_spawnattr_t?
        let attributesResult = posix_spawnattr_init(&attributes)
        guard attributesResult == 0 else {
            _ = Darwin.close(reader)
            _ = Darwin.close(writer)
            throw RuntimeBootstrapCoordinatorError.spawnFailed(errno: attributesResult)
        }
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        let flagsResult = posix_spawnattr_setflags(&attributes, flags)
        guard flagsResult == 0 else {
            _ = Darwin.close(reader)
            _ = Darwin.close(writer)
            throw RuntimeBootstrapCoordinatorError.spawnFailed(errno: flagsResult)
        }

        let rawArguments = [
            executablePath,
            "--canonical-udid",
            canonicalUDID.rawValue,
        ]
        var arguments = rawArguments.map { strdup($0) } + [nil]
        defer { arguments.compactMap { $0 }.forEach { free($0) } }
        var pid: pid_t = 0
        let spawnResult = executablePath.withCString { path in
            arguments.withUnsafeMutableBufferPointer { buffer in
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
        _ = Darwin.close(writer)
        guard spawnResult == 0, pid > 0 else {
            _ = Darwin.close(reader)
            throw RuntimeBootstrapCoordinatorError.spawnFailed(errno: spawnResult)
        }
        defer { _ = Darwin.close(reader) }

        do {
            let deadline = try clock.now().advanced(by: startupDeadline)
            let bytes = try readReadinessFrame(
                from: reader,
                deadline: deadline
            )
            let readiness = try decodeReadinessFrame(bytes, expectedPID: pid)
            switch readiness {
            case .ready(let runtimeEpoch):
                guard let identity = processStartIdentity(for: pid) else {
                    throw RuntimeBootstrapCoordinatorError.processIdentityUnavailable
                }
                RuntimeChildReaper.reapWhenExited(pid)
                return .launched(
                    LaunchedRuntimeGeneration(
                        pid: pid,
                        runtimeEpoch: runtimeEpoch,
                        processStartIdentity: identity,
                        executablePath: executablePath
                    )
                )
            case .failed(let code):
                throw RuntimeBootstrapCoordinatorError.runtimeFailed(code: code)
            }
        } catch {
            terminateAndReap(pid)
            throw error
        }
    }

    private func configureFileActions(
        _ actions: inout posix_spawn_file_actions_t?,
        reader: Int32,
        writer: Int32
    ) throws {
        let nullPath = "/dev/null"
        let operations = [
            posix_spawn_file_actions_addclose(&actions, reader),
            posix_spawn_file_actions_addopen(
                &actions,
                STDIN_FILENO,
                nullPath,
                O_RDONLY,
                0
            ),
            posix_spawn_file_actions_addopen(
                &actions,
                STDOUT_FILENO,
                nullPath,
                O_WRONLY,
                0
            ),
            posix_spawn_file_actions_addopen(
                &actions,
                STDERR_FILENO,
                nullPath,
                O_WRONLY,
                0
            ),
            posix_spawn_file_actions_adddup2(
                &actions,
                writer,
                3
            ),
            writer == 3
                ? 0
                : posix_spawn_file_actions_addclose(&actions, writer),
            posix_spawn_file_actions_addchdir_np(&actions, "/"),
        ]
        guard operations.allSatisfy({ $0 == 0 }) else {
            throw RuntimeBootstrapCoordinatorError.spawnFailed(
                errno: operations.first(where: { $0 != 0 }) ?? EIO
            )
        }
    }

    private func makeReadinessPipe() throws -> (
        reader: Int32,
        writer: Int32,
        fillerDescriptors: [Int32]
    ) {
        var fillers = [Int32]()
        for descriptor in STDIN_FILENO...STDERR_FILENO where fcntl(descriptor, F_GETFD) == -1 {
            let filler = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
            guard filler == descriptor else {
                if filler >= 0 {
                    _ = Darwin.close(filler)
                }
                fillers.forEach { _ = Darwin.close($0) }
                throw RuntimeBootstrapCoordinatorError.systemCall(
                    operation: "fill-standard-descriptor",
                    errno: filler < 0 ? errno : EIO
                )
            }
            fillers.append(filler)
        }
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else {
            fillers.forEach { _ = Darwin.close($0) }
            throw RuntimeBootstrapCoordinatorError.systemCall(
                operation: "pipe-readiness",
                errno: errno
            )
        }
        return (descriptors[0], descriptors[1], fillers)
    }

    private func readReadinessFrame(
        from reader: Int32,
        deadline: MonotonicInstant
    ) throws -> [UInt8] {
        var output = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let now = clock.now()
            guard now < deadline else {
                throw RuntimeBootstrapCoordinatorError.readinessTimeout
            }
            let remaining = try deadline.duration(since: now).nanoseconds
            let milliseconds = min(
                UInt64(Int32.max),
                max(1, (remaining + 999_999) / 1_000_000)
            )
            var descriptor = pollfd(
                fd: reader,
                events: Int16(POLLIN),
                revents: 0
            )
            let pollResult = Darwin.poll(
                &descriptor,
                1,
                Int32(milliseconds)
            )
            if pollResult == 0 {
                throw RuntimeBootstrapCoordinatorError.readinessTimeout
            }
            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                throw RuntimeBootstrapCoordinatorError.systemCall(
                    operation: "poll-readiness",
                    errno: errno
                )
            }
            let count = Darwin.read(reader, &buffer, buffer.count)
            if count > 0 {
                output.append(contentsOf: buffer.prefix(count))
                guard output.count <= Self.maximumReadinessFrameBytes else {
                    throw RuntimeBootstrapCoordinatorError.invalidReadinessFrame
                }
            } else if count == 0 {
                guard !output.isEmpty else {
                    throw RuntimeBootstrapCoordinatorError.readinessClosedWithoutFrame
                }
                return output
            } else if errno != EINTR {
                throw RuntimeBootstrapCoordinatorError.systemCall(
                    operation: "read-readiness",
                    errno: errno
                )
            }
        }
    }

    private enum ReadinessFrame {
        case ready(CanonicalUUID)
        case failed(String)
    }

    private func decodeReadinessFrame(
        _ bytes: [UInt8],
        expectedPID: pid_t
    ) throws -> ReadinessFrame {
        let object: RepositoryJSONObject
        do {
            object = try RepositoryCanonicalJSON.validateCanonicalDocument(
                bytes,
                maximumByteCount: Self.maximumReadinessFrameBytes
            ).root
        } catch {
            throw RuntimeBootstrapCoordinatorError.invalidReadinessFrame
        }
        guard let schemaNumber = object["schemaVersion"]?.numberValue,
              let schemaVersion = try? schemaNumber.requireUInt64(),
              schemaVersion == 1,
              let state = object["state"]?.stringValue
        else {
            throw RuntimeBootstrapCoordinatorError.invalidReadinessFrame
        }
        switch state {
        case "ready":
            guard exactKeys(object) == ["pid", "runtimeEpoch", "schemaVersion", "state"],
                  let rawPID = try? object["pid"]?.numberValue?.requireUInt64(),
                  rawPID == UInt64(expectedPID),
                  let rawEpoch = object["runtimeEpoch"]?.stringValue,
                  let epoch = try? CanonicalUUID(rawEpoch)
            else {
                throw RuntimeBootstrapCoordinatorError.invalidReadinessFrame
            }
            return .ready(epoch)
        case "failed":
            guard exactKeys(object) == ["error", "schemaVersion", "state"],
                  let error = object["error"]?.objectValue,
                  exactKeys(error) == ["code"],
                  let code = error["code"]?.stringValue,
                  isValidErrorCode(code)
            else {
                throw RuntimeBootstrapCoordinatorError.invalidReadinessFrame
            }
            return .failed(code)
        default:
            throw RuntimeBootstrapCoordinatorError.invalidReadinessFrame
        }
    }

    private func exactKeys(_ object: RepositoryJSONObject) -> [String] {
        object.members.map(\.key).sorted { lhs, rhs in
            lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
        }
    }

    private func isValidErrorCode(_ code: String) -> Bool {
        let bytes = Array(code.utf8)
        return !bytes.isEmpty
            && bytes.count <= 128
            && bytes.allSatisfy { (0x21...0x7e).contains($0) }
    }

    private func processStartIdentity(
        for pid: pid_t
    ) -> RuntimeProcessStartIdentity? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(size))
        }
        guard result == Int32(size), info.pbi_pid == UInt32(pid) else {
            return nil
        }
        return RuntimeProcessStartIdentity(
            seconds: info.pbi_start_tvsec,
            microseconds: info.pbi_start_tvusec
        )
    }

    private func terminateAndReap(_ pid: pid_t) {
        var status: Int32 = 0
        while true {
            let waitResult = Darwin.waitpid(pid, &status, WNOHANG)
            if waitResult == pid {
                return
            }
            if waitResult == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            return
        }
        _ = Darwin.kill(pid, SIGKILL)
        while Darwin.waitpid(pid, &status, 0) == -1, errno == EINTR {}
    }

    private func resolveRuntimeExecutable(
        in canonicalAppPath: CanonicalAppPath
    ) throws -> String {
        let path = canonicalAppPath.bundlePath
            + "/Contents/Helpers/PulsePhoneRuntime"
        guard !path.utf8.contains(0), let resolved = realpath(path, nil) else {
            throw RuntimeBootstrapCoordinatorError.invalidRuntimeExecutable
        }
        defer { free(resolved) }
        guard String(cString: resolved) == path else {
            throw RuntimeBootstrapCoordinatorError.invalidRuntimeExecutable
        }

        var before = stat()
        guard lstat(path, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_mode & mode_t(0o111) != 0
        else {
            throw RuntimeBootstrapCoordinatorError.invalidRuntimeExecutable
        }
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw RuntimeBootstrapCoordinatorError.invalidRuntimeExecutable
        }
        defer { _ = Darwin.close(descriptor) }
        var opened = stat()
        var after = stat()
        guard fstat(descriptor, &opened) == 0,
              lstat(path, &after) == 0,
              before.st_dev == opened.st_dev,
              before.st_ino == opened.st_ino,
              opened.st_dev == after.st_dev,
              opened.st_ino == after.st_ino
        else {
            throw RuntimeBootstrapCoordinatorError.invalidRuntimeExecutable
        }
        return path
    }
}

private enum RuntimeChildReaper {
    static func reapWhenExited(_ pid: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while true {
                let result = Darwin.waitpid(pid, &status, 0)
                if result == pid || (result == -1 && errno == ECHILD) {
                    return
                }
                if result == -1 && errno == EINTR {
                    continue
                }
                return
            }
        }
    }
}
