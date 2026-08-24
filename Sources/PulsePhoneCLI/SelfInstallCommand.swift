import Darwin
import Foundation
import PulsePhoneHostPaths
import PulsePhoneSharedDefinitions

public enum SelfInstallDisposition: String, Codable, Equatable, Sendable {
    case alreadyCurrent
    case installed
    case repaired
    case updated
}

public struct SelfInstallResult: Codable, Equatable, Sendable {
    public let applicationPath: String
    public let build: String
    public let disposition: SelfInstallDisposition
    public let launcherChanged: Bool
    public let launcherPath: String
    public let terminatedProcessCount: Int
    public let version: String

    public init(
        applicationPath: String,
        build: String,
        disposition: SelfInstallDisposition,
        launcherChanged: Bool,
        launcherPath: String,
        terminatedProcessCount: Int,
        version: String
    ) {
        self.applicationPath = applicationPath
        self.build = build
        self.disposition = disposition
        self.launcherChanged = launcherChanged
        self.launcherPath = launcherPath
        self.terminatedProcessCount = terminatedProcessCount
        self.version = version
    }

    public var humanSummary: String {
        let action: String
        switch disposition {
        case .alreadyCurrent:
            action = "already current"
        case .installed:
            action = "installed"
        case .repaired:
            action = "repaired"
        case .updated:
            action = "updated"
        }
        return "PulsePhone \(version) (\(build)) \(action) at \(applicationPath)\n"
            + "Launcher: \(launcherPath)\n"
            + "Terminated processes: \(terminatedProcessCount)"
    }
}

public enum SelfInstallError: Error, Equatable, Sendable,
    CustomStringConvertible
{
    case invalidSource(String)
    case localWrite(String)
    case processTerminationTimedOut
    case rollbackFailed
    case unsafeHostPath(String)
    case verificationFailed(String)

    public var description: String {
        switch self {
        case .invalidSource(let reason):
            return "Invalid source PulsePhone.app: \(reason)"
        case .localWrite(let reason):
            return "Self-install write failed: \(reason)"
        case .processTerminationTimedOut:
            return "PulsePhone processes did not exit before the install deadline."
        case .rollbackFailed:
            return "Self-install failed and the previous installation could not be fully restored."
        case .unsafeHostPath(let reason):
            return "Unsafe self-install path: \(reason)"
        case .verificationFailed(let reason):
            return "Installed PulsePhone verification failed: \(reason)"
        }
    }

    public var cliCode: String {
        switch self {
        case .unsafeHostPath:
            return "unsafeHostPath"
        case .processTerminationTimedOut:
            return "timedOut"
        case .localWrite:
            return "localWriteFailed"
        case .invalidSource, .rollbackFailed, .verificationFailed:
            return "internalFailure"
        }
    }
}

public protocol SelfInstallApplicationValidating: Sendable {
    func validate(
        applicationPath: String,
        requirement: SelfInstallApplicationValidationRequirement
    ) throws -> PulsePhoneProductVersion
}

public enum SelfInstallApplicationValidationRequirement: Sendable {
    case currentSource
    case existingDestination
}

public protocol SelfInstallProcessTerminating: Sendable {
    func terminate(
        bundlePaths: Set<String>,
        effectiveUserID: uid_t,
        excludingPID: pid_t
    ) throws -> Int
}

public protocol SelfInstallEntrypointVerifying: Sendable {
    func verify(
        applicationPath: String,
        launcherPath: String,
        expectedVersion: PulsePhoneProductVersion
    ) throws
}

public struct SelfInstallTrustedUser: Equatable, Sendable {
    public let effectiveUserID: uid_t
    public let homeDirectory: String

    public init(effectiveUserID: uid_t, homeDirectory: String) {
        self.effectiveUserID = effectiveUserID
        self.homeDirectory = homeDirectory
    }
}

public struct ProductionSelfInstaller: Sendable {
    public typealias SourceApplicationPath = @Sendable () throws -> String
    public typealias TrustedUser = @Sendable () throws -> SelfInstallTrustedUser

    private struct ApplicationPublication {
        let createdDestination: Bool
        let rollbackPath: String?
    }

    private struct LauncherPublication {
        let changed: Bool
        let createdDestination: Bool
        let rollbackPath: String?
    }

    private enum DestinationState {
        case invalid
        case missing
        case valid(PulsePhoneProductVersion)
    }

    private let applicationValidator: any SelfInstallApplicationValidating
    private let entrypointVerifier: any SelfInstallEntrypointVerifying
    private let processTerminator: any SelfInstallProcessTerminating
    private let sourceApplicationPath: SourceApplicationPath
    private let trustedUser: TrustedUser

    public init(
        sourceApplicationPath: @escaping SourceApplicationPath = {
            try CanonicalAppPath.resolveCurrentExecutable().bundlePath
        },
        trustedUser: @escaping TrustedUser = {
            let system = POSIXHostPathSystem()
            return SelfInstallTrustedUser(
                effectiveUserID: system.effectiveUserID,
                homeDirectory: try system.trustedHomeDirectory()
            )
        },
        applicationValidator: any SelfInstallApplicationValidating =
            ProductionSelfInstallApplicationValidator(),
        processTerminator: any SelfInstallProcessTerminating =
            VerifiedSelfInstallProcessTerminator(),
        entrypointVerifier: any SelfInstallEntrypointVerifying =
            ProductionSelfInstallEntrypointVerifier()
    ) {
        self.sourceApplicationPath = sourceApplicationPath
        self.trustedUser = trustedUser
        self.applicationValidator = applicationValidator
        self.processTerminator = processTerminator
        self.entrypointVerifier = entrypointVerifier
    }

    public func install() throws -> SelfInstallResult {
        let user = try trustedUser()
        guard Self.isCanonicalAbsolutePath(user.homeDirectory) else {
            throw SelfInstallError.unsafeHostPath("invalid login home")
        }
        try validateOwnedDirectory(
            user.homeDirectory,
            effectiveUserID: user.effectiveUserID
        )

        let sourcePath = try sourceApplicationPath()
        let sourceVersion: PulsePhoneProductVersion
        do {
            sourceVersion = try applicationValidator.validate(
                applicationPath: sourcePath,
                requirement: .currentSource
            )
        } catch {
            throw SelfInstallError.invalidSource(String(describing: error))
        }

        let applicationsDirectory = user.homeDirectory + "/Applications"
        let localDirectory = user.homeDirectory + "/.local"
        let launcherDirectory = localDirectory + "/bin"
        try ensureOwnedDirectory(
            applicationsDirectory,
            parentPath: user.homeDirectory,
            effectiveUserID: user.effectiveUserID,
            mode: 0o755
        )
        try ensureOwnedDirectory(
            localDirectory,
            parentPath: user.homeDirectory,
            effectiveUserID: user.effectiveUserID,
            mode: 0o700
        )
        try ensureOwnedDirectory(
            launcherDirectory,
            parentPath: localDirectory,
            effectiveUserID: user.effectiveUserID,
            mode: 0o755
        )

        let applicationPath = applicationsDirectory + "/PulsePhone.app"
        let launcherPath = launcherDirectory + "/PulsePhone"
        let launcherTarget = applicationPath + "/Contents/MacOS/PulsePhone"

        let destination = try destinationState(
            applicationPath,
            effectiveUserID: user.effectiveUserID
        )
        try validateLauncherForPublication(
            launcherPath,
            effectiveUserID: user.effectiveUserID
        )
        let disposition: SelfInstallDisposition
        let requiresApplicationPublish: Bool
        switch destination {
        case .missing:
            disposition = .installed
            requiresApplicationPublish = true
        case .invalid:
            disposition = .repaired
            requiresApplicationPublish = true
        case .valid(let version):
            if version == sourceVersion {
                disposition = .alreadyCurrent
                requiresApplicationPublish = false
            } else {
                disposition = .updated
                requiresApplicationPublish = true
            }
        }

        var stagingPath: String?
        if requiresApplicationPublish {
            let path = applicationsDirectory
                + "/.PulsePhone.app.install-\(UUID().uuidString).staging"
            do {
                try FileManager.default.copyItem(atPath: sourcePath, toPath: path)
                let stagedVersion = try applicationValidator.validate(
                    applicationPath: path,
                    requirement: .currentSource
                )
                guard stagedVersion == sourceVersion else {
                    throw SelfInstallError.localWrite("staged version mismatch")
                }
                try validateOwnedNode(path, effectiveUserID: user.effectiveUserID)
                stagingPath = path
            } catch let error as SelfInstallError {
                try? removeIfPresent(path)
                throw error
            } catch {
                try? removeIfPresent(path)
                throw SelfInstallError.localWrite(String(describing: error))
            }
        }

        var applicationPublication: ApplicationPublication?
        var launcherPublication: LauncherPublication?
        var committed = false
        defer {
            if !committed, let stagingPath {
                try? removeIfPresent(stagingPath)
            }
        }

        do {
            let terminated: Int
            if let stagingPath {
                terminated = try processTerminator.terminate(
                    bundlePaths: [sourcePath, applicationPath],
                    effectiveUserID: user.effectiveUserID,
                    excludingPID: getpid()
                )
                applicationPublication = try publishApplication(
                    stagingPath: stagingPath,
                    destinationPath: applicationPath,
                    effectiveUserID: user.effectiveUserID
                )
            } else {
                terminated = 0
            }

            launcherPublication = try publishLauncher(
                launcherPath: launcherPath,
                targetPath: launcherTarget,
                effectiveUserID: user.effectiveUserID
            )
            try entrypointVerifier.verify(
                applicationPath: applicationPath,
                launcherPath: launcherPath,
                expectedVersion: sourceVersion
            )
            commit(
                application: applicationPublication,
                launcher: launcherPublication
            )
            committed = true
            return SelfInstallResult(
                applicationPath: applicationPath,
                build: sourceVersion.build,
                disposition: disposition,
                launcherChanged: launcherPublication?.changed ?? false,
                launcherPath: launcherPath,
                terminatedProcessCount: terminated,
                version: sourceVersion.version
            )
        } catch {
            do {
                try rollback(
                    applicationPath: applicationPath,
                    application: applicationPublication,
                    launcherPath: launcherPath,
                    launcher: launcherPublication
                )
            } catch {
                throw SelfInstallError.rollbackFailed
            }
            throw error
        }
    }

    private func destinationState(
        _ path: String,
        effectiveUserID: uid_t
    ) throws -> DestinationState {
        guard let metadata = try nodeMetadata(path) else { return .missing }
        guard metadata.owner == effectiveUserID else {
            throw SelfInstallError.unsafeHostPath("foreign destination owner")
        }
        guard [.directory, .regularFile, .symbolicLink].contains(metadata.kind) else {
            throw SelfInstallError.unsafeHostPath("unsupported destination node")
        }
        guard metadata.kind == .directory else { return .invalid }
        do {
            return .valid(try applicationValidator.validate(
                applicationPath: path,
                requirement: .existingDestination
            ))
        } catch {
            return .invalid
        }
    }

    private func publishApplication(
        stagingPath: String,
        destinationPath: String,
        effectiveUserID: uid_t
    ) throws -> ApplicationPublication {
        try validateOwnedNode(stagingPath, effectiveUserID: effectiveUserID)
        if try nodeMetadata(destinationPath) == nil {
            try rename(stagingPath, destinationPath)
            return ApplicationPublication(
                createdDestination: true,
                rollbackPath: nil
            )
        }
        try validateOwnedNode(destinationPath, effectiveUserID: effectiveUserID)
        try swap(stagingPath, destinationPath)
        return ApplicationPublication(
            createdDestination: false,
            rollbackPath: stagingPath
        )
    }

    private func publishLauncher(
        launcherPath: String,
        targetPath: String,
        effectiveUserID: uid_t
    ) throws -> LauncherPublication {
        let existing = try nodeMetadata(launcherPath)
        if let existing {
            guard existing.owner == effectiveUserID else {
                throw SelfInstallError.unsafeHostPath("foreign launcher owner")
            }
            switch existing.kind {
            case .symbolicLink:
                if try symbolicLinkTarget(launcherPath) == targetPath {
                    return LauncherPublication(
                        changed: false,
                        createdDestination: false,
                        rollbackPath: nil
                    )
                }
            case .regularFile:
                break
            case .directory:
                throw SelfInstallError.unsafeHostPath("launcher path is a directory")
            case .other, .socket:
                throw SelfInstallError.unsafeHostPath("unsupported launcher node")
            }
        }

        let temporary = launcherPath + ".install-\(UUID().uuidString).staging"
        guard symlink(targetPath, temporary) == 0 else {
            throw SelfInstallError.localWrite("symlink errno=\(errno)")
        }
        do {
            if existing == nil {
                try rename(temporary, launcherPath)
                return LauncherPublication(
                    changed: true,
                    createdDestination: true,
                    rollbackPath: nil
                )
            }
            try swap(temporary, launcherPath)
            return LauncherPublication(
                changed: true,
                createdDestination: false,
                rollbackPath: temporary
            )
        } catch {
            try? removeIfPresent(temporary)
            throw error
        }
    }

    private func validateLauncherForPublication(
        _ launcherPath: String,
        effectiveUserID: uid_t
    ) throws {
        guard let metadata = try nodeMetadata(launcherPath) else { return }
        guard metadata.owner == effectiveUserID else {
            throw SelfInstallError.unsafeHostPath("foreign launcher owner")
        }
        guard metadata.kind == .symbolicLink || metadata.kind == .regularFile else {
            let reason = metadata.kind == .directory
                ? "launcher path is a directory"
                : "unsupported launcher node"
            throw SelfInstallError.unsafeHostPath(reason)
        }
    }

    private func commit(
        application: ApplicationPublication?,
        launcher: LauncherPublication?
    ) {
        if let path = launcher?.rollbackPath {
            try? removeIfPresent(path)
        }
        if let path = application?.rollbackPath {
            try? removeIfPresent(path)
        }
    }

    private func rollback(
        applicationPath: String,
        application: ApplicationPublication?,
        launcherPath: String,
        launcher: LauncherPublication?
    ) throws {
        if let launcher, launcher.changed {
            if let rollbackPath = launcher.rollbackPath {
                try swap(rollbackPath, launcherPath)
                try removeIfPresent(rollbackPath)
            } else if launcher.createdDestination {
                try removeIfPresent(launcherPath)
            }
        }
        if let application {
            if let rollbackPath = application.rollbackPath {
                try swap(rollbackPath, applicationPath)
                try removeIfPresent(rollbackPath)
            } else if application.createdDestination {
                try removeIfPresent(applicationPath)
            }
        }
    }

    private func ensureOwnedDirectory(
        _ path: String,
        parentPath: String,
        effectiveUserID: uid_t,
        mode: mode_t
    ) throws {
        try validateOwnedDirectory(parentPath, effectiveUserID: effectiveUserID)
        if try nodeMetadata(path) == nil, mkdir(path, mode) != 0, errno != EEXIST {
            throw SelfInstallError.localWrite("mkdir errno=\(errno)")
        }
        try validateOwnedDirectory(path, effectiveUserID: effectiveUserID)
    }

    private func validateOwnedDirectory(
        _ path: String,
        effectiveUserID: uid_t
    ) throws {
        guard let metadata = try nodeMetadata(path),
              metadata.owner == effectiveUserID,
              metadata.kind == .directory
        else {
            throw SelfInstallError.unsafeHostPath("expected owned directory: \(path)")
        }
    }

    private func validateOwnedNode(
        _ path: String,
        effectiveUserID: uid_t
    ) throws {
        guard let metadata = try nodeMetadata(path),
              metadata.owner == effectiveUserID,
              [.directory, .regularFile, .symbolicLink].contains(metadata.kind)
        else {
            throw SelfInstallError.unsafeHostPath("unsafe node: \(path)")
        }
    }

    private func rename(_ source: String, _ destination: String) throws {
        guard Darwin.rename(source, destination) == 0 else {
            throw SelfInstallError.localWrite("rename errno=\(errno)")
        }
    }

    private func swap(_ lhs: String, _ rhs: String) throws {
        guard renameatx_np(
            AT_FDCWD,
            lhs,
            AT_FDCWD,
            rhs,
            UInt32(RENAME_SWAP)
        ) == 0 else {
            throw SelfInstallError.localWrite("rename swap errno=\(errno)")
        }
    }

    private func removeIfPresent(_ path: String) throws {
        guard try nodeMetadata(path) != nil else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw SelfInstallError.localWrite(String(describing: error))
        }
    }

    private func symbolicLinkTarget(_ path: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: 4097)
        let count = buffer.withUnsafeMutableBufferPointer { pointer in
            readlink(path, pointer.baseAddress, pointer.count - 1)
        }
        guard count >= 0, count < buffer.count else {
            throw SelfInstallError.unsafeHostPath("invalid launcher symlink")
        }
        return String(decoding: buffer[..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func nodeMetadata(_ path: String) throws -> NodeMetadata? {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            if errno == ENOENT { return nil }
            throw SelfInstallError.unsafeHostPath("lstat errno=\(errno): \(path)")
        }
        let kind: NodeKind
        switch status.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR):
            kind = .directory
        case mode_t(S_IFREG):
            kind = .regularFile
        case mode_t(S_IFLNK):
            kind = .symbolicLink
        case mode_t(S_IFSOCK):
            kind = .socket
        default:
            kind = .other
        }
        return NodeMetadata(kind: kind, owner: status.st_uid)
    }

    private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return path.utf8.first == 0x2f
            && path.utf8.count > 1
            && path.utf8.last != 0x2f
            && !path.utf8.contains(0)
            && components.first?.isEmpty == true
            && components.dropFirst().allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    private enum NodeKind: Equatable {
        case directory
        case other
        case regularFile
        case socket
        case symbolicLink
    }

    private struct NodeMetadata {
        let kind: NodeKind
        let owner: uid_t
    }
}

public protocol SelfInstallSubprocessRunning: Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        currentDirectoryPath: String,
        timeoutSeconds: TimeInterval
    ) throws -> SelfInstallSubprocessResult
}

public struct SelfInstallSubprocessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stderr: String
    public let stdout: String

    public init(exitCode: Int32, stderr: String, stdout: String) {
        self.exitCode = exitCode
        self.stderr = stderr
        self.stdout = stdout
    }
}

public struct ProductionSelfInstallSubprocessRunner:
    SelfInstallSubprocessRunning, Sendable
{
    public init() {}

    public func run(
        executablePath: String,
        arguments: [String],
        currentDirectoryPath: String,
        timeoutSeconds: TimeInterval
    ) throws -> SelfInstallSubprocessResult {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(
            fileURLWithPath: currentDirectoryPath,
            isDirectory: true
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw SelfInstallError.verificationFailed(String(describing: error))
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var timedOut = false
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            timedOut = true
            process.terminate()
            let graceful = Date().addingTimeInterval(1)
            while process.isRunning, Date() < graceful {
                usleep(10_000)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        let stdout = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let stderr = String(
            decoding: errors.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard !timedOut else {
            throw SelfInstallError.verificationFailed("subprocess timeout")
        }
        return SelfInstallSubprocessResult(
            exitCode: process.terminationStatus,
            stderr: stderr,
            stdout: stdout
        )
    }
}

public struct ProductionSelfInstallApplicationValidator:
    SelfInstallApplicationValidating, Sendable
{
    private let subprocess: any SelfInstallSubprocessRunning

    public init(
        subprocess: any SelfInstallSubprocessRunning =
            ProductionSelfInstallSubprocessRunner()
    ) {
        self.subprocess = subprocess
    }

    public func validate(
        applicationPath: String,
        requirement: SelfInstallApplicationValidationRequirement
    ) throws -> PulsePhoneProductVersion {
        try requireNode(applicationPath, kind: mode_t(S_IFDIR))
        let contents = applicationPath + "/Contents"
        let infoPath = contents + "/Info.plist"
        let executablePath = contents + "/MacOS/PulsePhone"
        try requireNode(infoPath, kind: mode_t(S_IFREG))
        try requireExecutable(executablePath)
        for path in [
            contents + "/Helpers/PulsePhoneRuntime",
            contents + "/Resources/AgentSkills/portable/pulsephone/SKILL.md",
            contents + "/Resources/AgentSkills/codex/pulsephone/agents/openai.yaml",
            contents + "/Resources/Registries/command-catalog.v1.json",
            contents + "/Resources/Registries/preparation-groups.v1.json",
            contents + "/Resources/Schemas/command-catalog.v1.schema.json",
            contents + "/_CodeSignature/CodeResources",
        ] {
            try requireNode(path, kind: mode_t(S_IFREG))
        }
        try requireExecutable(contents + "/Helpers/PulsePhoneDirectHelper")
        try requireExecutable(contents + "/Helpers/PulsePhoneCoreDeviceHelper")
        for forbidden in [
            contents + "/Resources/Python",
            contents + "/Resources/Helpers",
        ] {
            guard !FileManager.default.fileExists(atPath: forbidden) else {
                throw SelfInstallError.invalidSource("forbidden Python bundle node")
            }
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: infoPath))
        guard let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == "com.pulsephone.PulsePhone",
              plist["CFBundleExecutable"] as? String == "PulsePhone",
              let version = plist["CFBundleShortVersionString"] as? String,
              let build = plist["CFBundleVersion"] as? String,
              let productVersion = PulsePhoneProductVersion(
                version: version,
                build: build
              )
        else {
            throw SelfInstallError.invalidSource("invalid Info.plist")
        }

        if case .currentSource = requirement {
            _ = try CLIStaticSurface.loading(
                repositoryRoot: URL(
                    fileURLWithPath: contents + "/Resources",
                    isDirectory: true
                )
            )
        }
        let signature = try subprocess.run(
            executablePath: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", applicationPath],
            currentDirectoryPath: "/",
            timeoutSeconds: 20
        )
        guard signature.exitCode == 0 else {
            throw SelfInstallError.invalidSource("code signature verification failed")
        }
        return productVersion
    }

    private func requireExecutable(_ path: String) throws {
        var status = stat()
        guard lstat(path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_mode & 0o111 != 0
        else {
            throw SelfInstallError.invalidSource("invalid executable")
        }
    }

    private func requireNode(_ path: String, kind: mode_t) throws {
        var status = stat()
        guard lstat(path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == kind
        else {
            throw SelfInstallError.invalidSource("missing required bundle node")
        }
    }
}

public struct ProductionSelfInstallEntrypointVerifier:
    SelfInstallEntrypointVerifying, Sendable
{
    private let subprocess: any SelfInstallSubprocessRunning

    public init(
        subprocess: any SelfInstallSubprocessRunning =
            ProductionSelfInstallSubprocessRunner()
    ) {
        self.subprocess = subprocess
    }

    public func verify(
        applicationPath: String,
        launcherPath: String,
        expectedVersion: PulsePhoneProductVersion
    ) throws {
        let direct = applicationPath + "/Contents/MacOS/PulsePhone"
        for executable in [direct, launcherPath] {
            let help = try subprocess.run(
                executablePath: executable,
                arguments: ["--help"],
                currentDirectoryPath: "/",
                timeoutSeconds: 10
            )
            guard help.exitCode == 0,
                  help.stderr.isEmpty,
                  help.stdout.contains("self install")
            else {
                throw SelfInstallError.verificationFailed("help entrypoint")
            }
            let version = try subprocess.run(
                executablePath: executable,
                arguments: ["version", "--json"],
                currentDirectoryPath: "/",
                timeoutSeconds: 10
            )
            guard version.exitCode == 0,
                  version.stderr.isEmpty,
                  let data = version.stdout.data(using: .utf8),
                  let envelope = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  envelope["ok"] as? Bool == true,
                  envelope["commandID"] as? String == "product.version",
                  let result = envelope["result"] as? [String: String],
                  result == [
                    "build": expectedVersion.build,
                    "version": expectedVersion.version,
                  ]
            else {
                throw SelfInstallError.verificationFailed("version entrypoint")
            }
        }
    }
}

public struct SelfInstallProcessIdentity: Equatable, Hashable, Sendable {
    public let executablePath: String
    public let microseconds: UInt64
    public let pid: pid_t
    public let seconds: UInt64
    public let userID: uid_t

    public init(
        executablePath: String,
        microseconds: UInt64,
        pid: pid_t,
        seconds: UInt64,
        userID: uid_t
    ) {
        self.executablePath = executablePath
        self.microseconds = microseconds
        self.pid = pid
        self.seconds = seconds
        self.userID = userID
    }
}

public enum SelfInstallProcessObservation: Equatable, Sendable {
    case gone
    case identityMismatch
    case verified
}

public protocol SelfInstallProcessSystem: Sendable {
    func enumerate(
        executablePaths: Set<String>,
        effectiveUserID: uid_t,
        excludingPID: pid_t
    ) throws -> [SelfInstallProcessIdentity]
    func observe(_ identity: SelfInstallProcessIdentity) -> SelfInstallProcessObservation
    func signal(_ identity: SelfInstallProcessIdentity, signal: Int32) throws
}

public protocol SelfInstallProcessPolling: Sendable {
    func waitUntil(
        timeoutNanoseconds: UInt64,
        condition: () throws -> Bool
    ) throws -> Bool
}

public struct SystemSelfInstallProcessPoller:
    SelfInstallProcessPolling, Sendable
{
    public init() {}

    public func waitUntil(
        timeoutNanoseconds: UInt64,
        condition: () throws -> Bool
    ) throws -> Bool {
        let start = DispatchTime.now().uptimeNanoseconds
        repeat {
            if try condition() { return true }
            usleep(10_000)
        } while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds
        return try condition()
    }
}

public struct VerifiedSelfInstallProcessTerminator:
    SelfInstallProcessTerminating, Sendable
{
    public static let forcedTimeoutNanoseconds: UInt64 = 2_000_000_000
    public static let gracefulTimeoutNanoseconds: UInt64 = 5_000_000_000

    private let poller: any SelfInstallProcessPolling
    private let processSystem: any SelfInstallProcessSystem
    private let forcedTimeoutNanoseconds: UInt64
    private let gracefulTimeoutNanoseconds: UInt64

    public init(
        processSystem: any SelfInstallProcessSystem =
            POSIXSelfInstallProcessSystem(),
        poller: any SelfInstallProcessPolling =
            SystemSelfInstallProcessPoller()
    ) {
        self.processSystem = processSystem
        self.poller = poller
        forcedTimeoutNanoseconds = Self.forcedTimeoutNanoseconds
        gracefulTimeoutNanoseconds = Self.gracefulTimeoutNanoseconds
    }

    public init(
        processSystem: any SelfInstallProcessSystem,
        poller: any SelfInstallProcessPolling,
        gracefulTimeoutNanoseconds: UInt64,
        forcedTimeoutNanoseconds: UInt64
    ) {
        self.processSystem = processSystem
        self.poller = poller
        self.gracefulTimeoutNanoseconds = gracefulTimeoutNanoseconds
        self.forcedTimeoutNanoseconds = forcedTimeoutNanoseconds
    }

    public func terminate(
        bundlePaths: Set<String>,
        effectiveUserID: uid_t,
        excludingPID: pid_t
    ) throws -> Int {
        let relativeRoles = [
            "/Contents/Helpers/PulsePhoneRuntime",
            "/Contents/Helpers/PulsePhoneDirectHelper",
            "/Contents/Helpers/PulsePhoneCoreDeviceHelper",
            "/Contents/MacOS/PulsePhone",
        ]
        let executablePaths = Set(bundlePaths.flatMap { bundle in
            relativeRoles.map { bundle + $0 }
        })
        let identities = try processSystem.enumerate(
            executablePaths: executablePaths,
            effectiveUserID: effectiveUserID,
            excludingPID: excludingPID
        ).sorted { $0.pid < $1.pid }
        var signaled = [SelfInstallProcessIdentity]()
        for identity in identities {
            guard processSystem.observe(identity) == .verified else { continue }
            try processSystem.signal(identity, signal: SIGTERM)
            signaled.append(identity)
        }
        let graceful = try poller.waitUntil(
            timeoutNanoseconds: gracefulTimeoutNanoseconds
        ) {
            verifiedSurvivors(signaled).isEmpty
        }
        if graceful { return signaled.count }

        let survivors = verifiedSurvivors(signaled)
        for identity in survivors {
            guard processSystem.observe(identity) == .verified else { continue }
            try processSystem.signal(identity, signal: SIGKILL)
        }
        let forced = try poller.waitUntil(
            timeoutNanoseconds: forcedTimeoutNanoseconds
        ) {
            verifiedSurvivors(survivors).isEmpty
        }
        guard forced else {
            throw SelfInstallError.processTerminationTimedOut
        }
        return signaled.count
    }

    private func verifiedSurvivors(
        _ identities: [SelfInstallProcessIdentity]
    ) -> [SelfInstallProcessIdentity] {
        identities.filter { processSystem.observe($0) == .verified }
    }
}

public struct POSIXSelfInstallProcessSystem:
    SelfInstallProcessSystem, Sendable
{
    public init() {}

    public func enumerate(
        executablePaths: Set<String>,
        effectiveUserID: uid_t,
        excludingPID: pid_t
    ) throws -> [SelfInstallProcessIdentity] {
        let capacity = max(64, Int(proc_listallpids(nil, 0)) + 64)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBufferPointer { pointer in
            proc_listallpids(
                pointer.baseAddress,
                Int32(pointer.count * MemoryLayout<pid_t>.stride)
            )
        }
        guard count >= 0 else {
            throw SelfInstallError.localWrite("process enumeration failed")
        }
        return pids.prefix(Int(count)).compactMap { pid in
            guard pid > 0, pid != excludingPID,
                  let identity = capture(pid: pid),
                  identity.userID == effectiveUserID,
                  executablePaths.contains(identity.executablePath)
            else {
                return nil
            }
            return identity
        }
    }

    public func observe(
        _ identity: SelfInstallProcessIdentity
    ) -> SelfInstallProcessObservation {
        if Darwin.kill(identity.pid, 0) != 0, errno == ESRCH { return .gone }
        guard capture(pid: identity.pid) == identity else {
            return .identityMismatch
        }
        return .verified
    }

    public func signal(
        _ identity: SelfInstallProcessIdentity,
        signal: Int32
    ) throws {
        guard signal == SIGTERM || signal == SIGKILL,
              observe(identity) == .verified,
              Darwin.kill(identity.pid, signal) == 0
        else {
            throw SelfInstallError.localWrite("verified process signal failed")
        }
    }

    private func capture(pid: pid_t) -> SelfInstallProcessIdentity? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(size))
        }
        guard result == Int32(size),
              info.pbi_pid == UInt32(pid),
              info.pbi_start_tvusec < 1_000_000,
              let path = executablePath(pid: pid)
        else {
            return nil
        }
        return SelfInstallProcessIdentity(
            executablePath: path,
            microseconds: info.pbi_start_tvusec,
            pid: pid,
            seconds: info.pbi_start_tvsec,
            userID: info.pbi_uid
        )
    }

    private func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard count > 0 else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        let path = String(
            decoding: buffer[..<end].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
