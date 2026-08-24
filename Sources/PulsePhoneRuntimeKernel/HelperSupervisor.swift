import Darwin
import Foundation

public enum HelperKind: String, Codable, Equatable, Sendable {
    case coreDevice
    case direct
}

public struct HelperLaunchConfiguration: Sendable {
    public let helperID: String
    public let kind: HelperKind
    public let role: String
    public let executorID: String
    public let executorGeneration: UInt64
    public let executablePath: String
    public let arguments: [String]
    public let helperBuildID: String
    public let helperManifestHash: String

    public init(
        helperID: String,
        kind: HelperKind,
        role: String,
        executorID: String,
        executorGeneration: UInt64,
        executablePath: String,
        arguments: [String] = [],
        helperBuildID: String,
        helperManifestHash: String
    ) {
        self.helperID = helperID
        self.kind = kind
        self.role = role
        self.executorID = executorID
        self.executorGeneration = executorGeneration
        self.executablePath = executablePath
        self.arguments = arguments
        self.helperBuildID = helperBuildID
        self.helperManifestHash = helperManifestHash
    }
}

public struct HelperHello: Equatable, Sendable {
    public let runtimeEpoch: UInt64
    public let executorGeneration: UInt64
    public let helperBuildID: String
    public let helperKind: HelperKind
    public let manifestHash: String
    public let processStartIdentity: String

    public init(
        runtimeEpoch: UInt64,
        executorGeneration: UInt64,
        helperBuildID: String,
        helperKind: HelperKind,
        manifestHash: String,
        processStartIdentity: String
    ) {
        self.runtimeEpoch = runtimeEpoch
        self.executorGeneration = executorGeneration
        self.helperBuildID = helperBuildID
        self.helperKind = helperKind
        self.manifestHash = manifestHash
        self.processStartIdentity = processStartIdentity
    }
}

public struct HelperHelloAccepted: Equatable, Sendable {
    public let runtimeEpoch: UInt64
    public let executorGeneration: UInt64
    public let manifestHash: String
}

public struct HelperDeviceIOAuthorization: Equatable, Sendable {
    public let helperID: String
    public let runtimeEpoch: UInt64
    public let executorGeneration: UInt64
    public let processStartIdentity: HelperProcessStartIdentity
}

public struct HelperAcceptance: Equatable, Sendable {
    public let helloAccepted: HelperHelloAccepted
    public let deviceIOAuthorization: HelperDeviceIOAuthorization
}

public enum DeveloperImageFileRole: String, CaseIterable, Codable, Sendable {
    case classicImage = "classic.image"
    case classicSignature = "classic.signature"
    case personalizedBuildManifest = "personalized.buildManifest"
    case personalizedImage = "personalized.image"
    case personalizedTrustCache = "personalized.trustCache"
}

public struct DeveloperImageAssetReferenceKey: Hashable, Sendable {
    public let catalogRevision: String
    public let catalogEntryID: String
    public let fileRole: DeveloperImageFileRole
}

public struct DeveloperSupportAssetReference: Equatable, Sendable {
    public let catalogRevision: String
    public let catalogEntryID: String
    public let fileRoles: [DeveloperImageFileRole]

    public init(
        catalogRevision: String,
        catalogEntryID: String,
        fileRoles: [DeveloperImageFileRole]
    ) throws {
        guard Self.valid(catalogRevision, maximumBytes: 256),
              Self.valid(catalogEntryID, maximumBytes: 128),
              !fileRoles.isEmpty,
              fileRoles.count <= DeveloperImageFileRole.allCases.count,
              Set(fileRoles.map(\.rawValue)).count == fileRoles.count
        else {
            throw HelperSupervisorError.invalidAssetReference
        }
        self.catalogRevision = catalogRevision
        self.catalogEntryID = catalogEntryID
        self.fileRoles = fileRoles
    }

    public var keys: [DeveloperImageAssetReferenceKey] {
        fileRoles.map {
            DeveloperImageAssetReferenceKey(
                catalogRevision: catalogRevision,
                catalogEntryID: catalogEntryID,
                fileRole: $0
            )
        }
    }

    private static func valid(_ value: String, maximumBytes: Int) -> Bool {
        let bytes = Array(value.utf8)
        return (1...maximumBytes).contains(bytes.count)
            && bytes.allSatisfy { (0x21...0x7e).contains($0) }
    }
}

public enum HelperSupervisorError: Error, Equatable, Sendable {
    case invalidConfiguration
    case duplicateHelperID
    case helperNotFound
    case helloMismatch
    case processIdentityMismatch
    case invalidAssetReference
    case spawnFailed(errno: Int32)
    case systemCall(operation: String, errno: Int32)
}

public final class SpawnedHelper: @unchecked Sendable {
    public let configuration: HelperLaunchConfiguration
    public let processIdentity: HelperProcessIdentity
    public let commandWriter: Int32
    public let eventReader: Int32
    public let lifetimeWriter: Int32

    private var closed = false

    init(
        configuration: HelperLaunchConfiguration,
        processIdentity: HelperProcessIdentity,
        commandWriter: Int32,
        eventReader: Int32,
        lifetimeWriter: Int32
    ) {
        self.configuration = configuration
        self.processIdentity = processIdentity
        self.commandWriter = commandWriter
        self.eventReader = eventReader
        self.lifetimeWriter = lifetimeWriter
    }

    deinit {
        closeDescriptors()
    }

    public func closeDescriptors() {
        guard !closed else { return }
        closed = true
        _ = Darwin.close(commandWriter)
        _ = Darwin.close(eventReader)
        _ = Darwin.close(lifetimeWriter)
    }

    public func terminateAndReap() {
        _ = Darwin.killpg(processIdentity.processGroupID, SIGKILL)
        var status: Int32 = 0
        while Darwin.waitpid(processIdentity.pid, &status, 0) == -1, errno == EINTR {}
        closeDescriptors()
    }
}

public struct HelperSupervisor: Sendable {
    private struct Entry: Sendable {
        let spawned: SpawnedHelper
        var authorization: HelperDeviceIOAuthorization?
    }

    private let runtimeEpoch: UInt64
    private let manifestStore: HelperManifestStore
    private var entries = [String: Entry]()

    public init(runtimeEpoch: UInt64, manifestStore: HelperManifestStore) {
        self.runtimeEpoch = runtimeEpoch
        self.manifestStore = manifestStore
    }

    public mutating func spawn(
        _ configuration: HelperLaunchConfiguration,
        inheritedRuntimeLockDescriptor: Int32
    ) throws -> SpawnedHelper {
        try Self.validate(configuration)
        guard entries[configuration.helperID] == nil else {
            throw HelperSupervisorError.duplicateHelperID
        }
        let spawned = try Self.spawnProcess(
            configuration,
            inheritedRuntimeLockDescriptor: inheritedRuntimeLockDescriptor
        )
        entries[configuration.helperID] = Entry(
            spawned: spawned,
            authorization: nil
        )
        return spawned
    }

    public mutating func acceptHello(
        _ hello: HelperHello,
        from helperID: String
    ) throws -> HelperAcceptance {
        guard var entry = entries[helperID] else {
            throw HelperSupervisorError.helperNotFound
        }
        let configuration = entry.spawned.configuration
        guard entry.authorization == nil,
              hello.runtimeEpoch == runtimeEpoch,
              hello.executorGeneration == configuration.executorGeneration,
              hello.helperBuildID == configuration.helperBuildID,
              hello.helperKind == configuration.kind,
              hello.manifestHash == configuration.helperManifestHash,
              hello.processStartIdentity
                == entry.spawned.processIdentity.processStartIdentity.wireValue
        else {
            throw HelperSupervisorError.helloMismatch
        }
        guard entry.spawned.processIdentity.matchesCurrentProcess() else {
            throw HelperSupervisorError.processIdentityMismatch
        }

        let authorization = HelperDeviceIOAuthorization(
            helperID: helperID,
            runtimeEpoch: runtimeEpoch,
            executorGeneration: configuration.executorGeneration,
            processStartIdentity: entry.spawned.processIdentity.processStartIdentity
        )
        entry.authorization = authorization
        entries[helperID] = entry
        do {
            try manifestStore.publish(stateRecords())
        } catch {
            entry.authorization = nil
            entries[helperID] = entry
            throw error
        }
        return HelperAcceptance(
            helloAccepted: HelperHelloAccepted(
                runtimeEpoch: runtimeEpoch,
                executorGeneration: configuration.executorGeneration,
                manifestHash: configuration.helperManifestHash
            ),
            deviceIOAuthorization: authorization
        )
    }

    public func deviceIOAuthorization(
        for helperID: String
    ) -> HelperDeviceIOAuthorization? {
        entries[helperID]?.authorization
    }

    public mutating func remove(helperID: String) throws {
        guard let entry = entries.removeValue(forKey: helperID) else {
            throw HelperSupervisorError.helperNotFound
        }
        entry.spawned.closeDescriptors()
        try manifestStore.publish(stateRecords())
    }

    private func stateRecords() -> [HelperStateRecord] {
        entries.values.compactMap { entry in
            guard entry.authorization != nil else { return nil }
            let configuration = entry.spawned.configuration
            return HelperStateRecord(
                helperID: configuration.helperID,
                role: configuration.role,
                executorID: configuration.executorID,
                executorGeneration: configuration.executorGeneration,
                processIdentity: entry.spawned.processIdentity
            )
        }
    }

    private static func validate(
        _ configuration: HelperLaunchConfiguration
    ) throws {
        guard validASCII(configuration.helperID, maximumBytes: 128),
              validASCII(configuration.role, maximumBytes: 128),
              validASCII(configuration.executorID, maximumBytes: 128),
              validASCII(configuration.helperBuildID, maximumBytes: 256),
              configuration.helperManifestHash.utf8.count == 64,
              configuration.helperManifestHash.utf8.allSatisfy({
                (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
              }),
              configuration.executablePath.hasPrefix("/"),
              configuration.arguments.count <= 64,
              configuration.arguments.allSatisfy({ $0.utf8.count <= 4_096 && !$0.utf8.contains(0) })
        else {
            throw HelperSupervisorError.invalidConfiguration
        }
    }

    private static func validASCII(_ value: String, maximumBytes: Int) -> Bool {
        let bytes = Array(value.utf8)
        return (1...maximumBytes).contains(bytes.count)
            && bytes.allSatisfy { (0x21...0x7e).contains($0) }
    }

    private static func spawnProcess(
        _ configuration: HelperLaunchConfiguration,
        inheritedRuntimeLockDescriptor: Int32
    ) throws -> SpawnedHelper {
        var lockStatus = stat()
        guard fstat(inheritedRuntimeLockDescriptor, &lockStatus) == 0,
              lockStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else {
            throw HelperSupervisorError.invalidConfiguration
        }

        var createdDescriptors = [Int32]()
        defer {
            createdDescriptors.forEach { _ = Darwin.close($0) }
        }
        let commandPipe = try makePipe()
        createdDescriptors += [commandPipe.reader, commandPipe.writer]
        let eventPipe = try makePipe()
        createdDescriptors += [eventPipe.reader, eventPipe.writer]
        let lifetimePipe = try makePipe()
        createdDescriptors += [lifetimePipe.reader, lifetimePipe.writer]

        let childInput = try duplicateHigh(commandPipe.reader)
        createdDescriptors.append(childInput)
        let childOutput = try duplicateHigh(eventPipe.writer)
        createdDescriptors.append(childOutput)
        let childLifetime = try duplicateHigh(lifetimePipe.reader)
        createdDescriptors.append(childLifetime)
        let childRuntimeLock = try duplicateHigh(inheritedRuntimeLockDescriptor)
        createdDescriptors.append(childRuntimeLock)
        let tracesTouchStages = ProcessInfo.processInfo.environment[
            "PULSEPHONE_RUNTIME_TOUCH_STAGE_TRACE"
        ] == "1"
        let childError: Int32?
        if tracesTouchStages,
           let tracePath = ProcessInfo.processInfo.environment[
               "PULSEPHONE_RUNTIME_TOUCH_STAGE_TRACE_FILE"
           ]
        {
            childError = try touchStageTraceDescriptor(path: tracePath)
        } else {
            childError = tracesTouchStages
                ? try duplicateHigh(STDERR_FILENO)
                : nil
        }
        if let childError {
            createdDescriptors.append(childError)
        }
        var duplicated = [childInput, childOutput, childLifetime, childRuntimeLock]
        if let childError {
            duplicated.append(childError)
        }

        var actions: posix_spawn_file_actions_t?
        let actionResult = posix_spawn_file_actions_init(&actions)
        guard actionResult == 0 else {
            throw HelperSupervisorError.spawnFailed(errno: actionResult)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var operations = [
            posix_spawn_file_actions_adddup2(&actions, childInput, STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&actions, childOutput, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, childLifetime, 3),
            posix_spawn_file_actions_adddup2(&actions, childRuntimeLock, 4),
            posix_spawn_file_actions_addchdir_np(&actions, "/"),
        ]
        if let childError {
            operations.append(
                posix_spawn_file_actions_adddup2(
                    &actions,
                    childError,
                    STDERR_FILENO
                )
            )
        } else {
            operations.append(
                posix_spawn_file_actions_addopen(
                    &actions,
                    STDERR_FILENO,
                    "/dev/null",
                    O_WRONLY,
                    0
                )
            )
        }
        operations += duplicated.map {
            posix_spawn_file_actions_addclose(&actions, $0)
        }
        guard operations.allSatisfy({ $0 == 0 }) else {
            throw HelperSupervisorError.spawnFailed(
                errno: operations.first(where: { $0 != 0 }) ?? EIO
            )
        }

        var attributes: posix_spawnattr_t?
        let attributeResult = posix_spawnattr_init(&attributes)
        guard attributeResult == 0 else {
            throw HelperSupervisorError.spawnFailed(errno: attributeResult)
        }
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)
        let flagResult = posix_spawnattr_setflags(&attributes, flags)
        let groupResult = posix_spawnattr_setpgroup(&attributes, 0)
        guard flagResult == 0, groupResult == 0 else {
            throw HelperSupervisorError.spawnFailed(
                errno: flagResult != 0 ? flagResult : groupResult
            )
        }

        guard let executablePath = canonicalPath(configuration.executablePath) else {
            throw HelperSupervisorError.invalidConfiguration
        }
        let rawArguments = [executablePath] + configuration.arguments
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
        guard spawnResult == 0, pid > 0 else {
            throw HelperSupervisorError.spawnFailed(errno: spawnResult)
        }

        _ = Darwin.close(commandPipe.reader)
        createdDescriptors.removeAll { $0 == commandPipe.reader }
        _ = Darwin.close(eventPipe.writer)
        createdDescriptors.removeAll { $0 == eventPipe.writer }
        _ = Darwin.close(lifetimePipe.reader)
        createdDescriptors.removeAll { $0 == lifetimePipe.reader }

        do {
            let identity = try HelperProcessIdentity.capture(
                pid: pid,
                expectedExecutablePath: executablePath
            )
            let spawned = SpawnedHelper(
                configuration: configuration,
                processIdentity: identity,
                commandWriter: commandPipe.writer,
                eventReader: eventPipe.reader,
                lifetimeWriter: lifetimePipe.writer
            )
            let transferred = Set([
                commandPipe.writer, eventPipe.reader, lifetimePipe.writer,
            ])
            createdDescriptors.removeAll { transferred.contains($0) }
            return spawned
        } catch {
            _ = Darwin.killpg(pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
            throw error
        }
    }

    private static func makePipe() throws -> (reader: Int32, writer: Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else {
            throw HelperSupervisorError.systemCall(
                operation: "pipe-helper",
                errno: errno
            )
        }
        for descriptor in descriptors {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                let failure = errno
                descriptors.forEach { _ = Darwin.close($0) }
                throw HelperSupervisorError.systemCall(
                    operation: "fcntl-helper-cloexec",
                    errno: failure
                )
            }
        }
        return (descriptors[0], descriptors[1])
    }

    private static func duplicateHigh(_ descriptor: Int32) throws -> Int32 {
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 10)
        guard duplicate >= 0 else {
            throw HelperSupervisorError.systemCall(
                operation: "fcntl-helper-duplicate",
                errno: errno
            )
        }
        return duplicate
    }

    private static func touchStageTraceDescriptor(path: String) throws -> Int32 {
        guard path.hasPrefix("/"), path.utf8.count <= 4_096 else {
            throw HelperSupervisorError.invalidConfiguration
        }
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1
        else {
            throw HelperSupervisorError.invalidConfiguration
        }
        let descriptor = Darwin.open(path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw HelperSupervisorError.systemCall(
                operation: "open-touch-stage-trace",
                errno: errno
            )
        }
        defer { _ = Darwin.close(descriptor) }
        return try duplicateHigh(descriptor)
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              let resolved = realpath(path, nil)
        else {
            return nil
        }
        defer { free(resolved) }
        var status = stat()
        guard lstat(resolved, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_mode & mode_t(0o111) != 0
        else {
            return nil
        }
        return String(cString: resolved)
    }
}
