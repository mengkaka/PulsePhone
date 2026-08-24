import Darwin
import Foundation
import PulsePhoneHostPaths
import PulsePhoneSharedDefinitions

public enum AgentSkillTargetKind: String, Codable, Equatable, Sendable {
    case claudeCode = "claude-code"
    case codex
    case custom
}

public enum AgentSkillInstallDisposition: String, Codable, Equatable, Sendable {
    case installed
    case unchanged
    case updated
}

public enum AgentSkillStatusDisposition: String, Codable, Equatable, Sendable {
    case incomplete
    case installed
    case modified
    case notInstalled
}

public enum AgentSkillUninstallDisposition: String, Codable, Equatable, Sendable {
    case notInstalled
    case removed
}

public struct AgentSkillInstallTargetResult: Codable, Equatable, Sendable {
    public let disposition: AgentSkillInstallDisposition
    public let files: [String]
    public let kind: AgentSkillTargetKind
    public let rootPath: String
    public let skillPath: String

    public init(
        disposition: AgentSkillInstallDisposition,
        files: [String],
        kind: AgentSkillTargetKind,
        rootPath: String,
        skillPath: String
    ) {
        self.disposition = disposition
        self.files = files
        self.kind = kind
        self.rootPath = rootPath
        self.skillPath = skillPath
    }
}

public struct AgentSkillStatusTargetResult: Codable, Equatable, Sendable {
    public let current: Bool
    public let disposition: AgentSkillStatusDisposition
    public let files: [String]
    public let kind: AgentSkillTargetKind
    public let rootPath: String
    public let skillPath: String

    public init(
        current: Bool,
        disposition: AgentSkillStatusDisposition,
        files: [String],
        kind: AgentSkillTargetKind,
        rootPath: String,
        skillPath: String
    ) {
        self.current = current
        self.disposition = disposition
        self.files = files
        self.kind = kind
        self.rootPath = rootPath
        self.skillPath = skillPath
    }
}

public struct AgentSkillUninstallTargetResult: Codable, Equatable, Sendable {
    public let disposition: AgentSkillUninstallDisposition
    public let files: [String]
    public let kind: AgentSkillTargetKind
    public let rootPath: String
    public let skillPath: String

    public init(
        disposition: AgentSkillUninstallDisposition,
        files: [String],
        kind: AgentSkillTargetKind,
        rootPath: String,
        skillPath: String
    ) {
        self.disposition = disposition
        self.files = files
        self.kind = kind
        self.rootPath = rootPath
        self.skillPath = skillPath
    }
}

public struct AgentSkillInstallResult: Codable, Equatable, Sendable {
    public let applicationInstall: SelfInstallResult
    public let targets: [AgentSkillInstallTargetResult]

    public init(
        applicationInstall: SelfInstallResult,
        targets: [AgentSkillInstallTargetResult]
    ) {
        self.applicationInstall = applicationInstall
        self.targets = targets
    }

    public var humanSummary: String {
        ([applicationInstall.humanSummary] + targets.map {
            "Skill \($0.kind.rawValue): \($0.disposition.rawValue) at \($0.skillPath)"
        }).joined(separator: "\n")
    }
}

public struct AgentSkillStatusResult: Codable, Equatable, Sendable {
    public let targets: [AgentSkillStatusTargetResult]

    public init(targets: [AgentSkillStatusTargetResult]) {
        self.targets = targets
    }

    public var humanSummary: String {
        targets.map {
            let suffix = $0.disposition == .installed
                ? ($0.current ? "current" : "update available")
                : $0.disposition.rawValue
            return "Skill \($0.kind.rawValue): \(suffix) at \($0.skillPath)"
        }.joined(separator: "\n")
    }
}

public struct AgentSkillUninstallResult: Codable, Equatable, Sendable {
    public let targets: [AgentSkillUninstallTargetResult]

    public init(targets: [AgentSkillUninstallTargetResult]) {
        self.targets = targets
    }

    public var humanSummary: String {
        targets.map {
            "Skill \($0.kind.rawValue): \($0.disposition.rawValue) at \($0.skillPath)"
        }.joined(separator: "\n")
    }
}

public enum AgentSkillError: Error, Equatable, Sendable, CustomStringConvertible {
    case conflict(String)
    case invalidArgument(String)
    case invalidPayload(String)
    case localWrite(String)
    case rollbackFailed
    case unsafeHostPath(String)

    public var description: String {
        switch self {
        case .conflict(let path):
            return "Agent Skill target contains modified or unmanaged content: \(path)"
        case .invalidArgument(let reason):
            return "Invalid Agent Skill argument: \(reason)"
        case .invalidPayload(let reason):
            return "Invalid bundled Agent Skill payload: \(reason)"
        case .localWrite(let reason):
            return "Agent Skill write failed: \(reason)"
        case .rollbackFailed:
            return "Agent Skill transaction failed and could not be fully restored."
        case .unsafeHostPath(let reason):
            return "Unsafe Agent Skill path: \(reason)"
        }
    }

    public var cliCode: String {
        switch self {
        case .conflict:
            return "outputExists"
        case .invalidArgument:
            return "invalidArgument"
        case .localWrite:
            return "localWriteFailed"
        case .unsafeHostPath:
            return "unsafeHostPath"
        case .invalidPayload, .rollbackFailed:
            return "internalFailure"
        }
    }
}

public protocol AgentSkillManaging: Sendable {
    func install(
        agents: [String],
        skillRoots: [String],
        force: Bool
    ) throws -> AgentSkillInstallResult

    func status(
        agents: [String],
        skillRoots: [String]
    ) throws -> AgentSkillStatusResult

    func uninstall(
        agents: [String],
        skillRoots: [String],
        force: Bool
    ) throws -> AgentSkillUninstallResult
}

public struct ProductionAgentSkillManager: AgentSkillManaging, Sendable {
    public typealias ApplicationInstaller = @Sendable () throws -> SelfInstallResult
    public typealias ResourcesPath = @Sendable () throws -> String
    public typealias TrustedUser = @Sendable () throws -> SelfInstallTrustedUser

    private struct PayloadFile: Sendable {
        let bytes: Data
        let relativePath: String
    }

    private struct Target: Sendable {
        let files: [PayloadFile]
        let kind: AgentSkillTargetKind
        let rootPath: String
        let skillPath: String
    }

    private struct Inspection: Sendable {
        let current: Bool
        let disposition: AgentSkillStatusDisposition
        let existing: [String: Data]
    }

    private struct PublishedFile {
        let destination: String
        let previous: Data?
    }

    private let applicationInstaller: ApplicationInstaller
    private let resourcesPath: ResourcesPath
    private let trustedUser: TrustedUser

    public init(
        applicationInstaller: @escaping ApplicationInstaller = {
            try ProductionSelfInstaller().install()
        },
        resourcesPath: @escaping ResourcesPath = {
            try CanonicalAppPath.resolveCurrentExecutable().resourcesURL.path
        },
        trustedUser: @escaping TrustedUser = {
            let system = POSIXHostPathSystem()
            return SelfInstallTrustedUser(
                effectiveUserID: system.effectiveUserID,
                homeDirectory: try system.trustedHomeDirectory()
            )
        }
    ) {
        self.applicationInstaller = applicationInstaller
        self.resourcesPath = resourcesPath
        self.trustedUser = trustedUser
    }

    public func install(
        agents: [String],
        skillRoots: [String],
        force: Bool
    ) throws -> AgentSkillInstallResult {
        guard !agents.isEmpty || !skillRoots.isEmpty else {
            throw AgentSkillError.invalidArgument(
                "skill install requires --agent or --skill-root"
            )
        }
        let context = try context(
            agents: agents,
            skillRoots: skillRoots,
            defaultAgents: false
        )
        let application = try applicationInstaller()
        var inspections = [(Target, Inspection)]()
        for target in context.targets {
            let inspection = try inspect(target, effectiveUserID: context.user.effectiveUserID)
            if !force, inspection.disposition == .modified {
                throw AgentSkillError.conflict(target.skillPath)
            }
            inspections.append((target, inspection))
        }

        var createdDirectories = [String]()
        var staged = [(destination: String, stage: String, bytes: Data)]()
        do {
            for (target, inspection) in inspections where !inspection.current {
                for file in target.files {
                    let destination = target.skillPath + "/" + file.relativePath
                    let parent = URL(fileURLWithPath: destination).deletingLastPathComponent().path
                    try ensureDirectory(
                        parent,
                        effectiveUserID: context.user.effectiveUserID,
                        created: &createdDirectories
                    )
                    let bytes = managedBytes(file)
                    let stage = destination + ".pulsephone-install-\(UUID().uuidString).staging"
                    try writeNewFile(bytes, path: stage)
                    guard try Data(contentsOf: URL(fileURLWithPath: stage)) == bytes else {
                        throw AgentSkillError.localWrite("staging verification")
                    }
                    staged.append((destination, stage, bytes))
                }
            }
        } catch {
            for item in staged { try? removeRegularFile(item.stage) }
            pruneCreatedDirectories(createdDirectories)
            throw error
        }

        var published = [PublishedFile]()
        do {
            for item in staged {
                let previous = try regularFileDataIfPresent(
                    item.destination,
                    effectiveUserID: context.user.effectiveUserID
                )
                guard Darwin.rename(item.stage, item.destination) == 0 else {
                    throw AgentSkillError.localWrite("rename errno=\(errno)")
                }
                published.append(PublishedFile(
                    destination: item.destination,
                    previous: previous
                ))
            }
            for item in staged {
                guard try Data(contentsOf: URL(fileURLWithPath: item.destination))
                        == item.bytes
                else {
                    throw AgentSkillError.localWrite("published verification")
                }
            }
        } catch {
            do {
                try rollback(published)
            } catch {
                throw AgentSkillError.rollbackFailed
            }
            for item in staged { try? removeRegularFile(item.stage) }
            pruneCreatedDirectories(createdDirectories)
            throw error
        }

        return AgentSkillInstallResult(
            applicationInstall: application,
            targets: inspections.map { target, inspection in
                let disposition: AgentSkillInstallDisposition
                if inspection.current {
                    disposition = .unchanged
                } else if inspection.disposition == .notInstalled {
                    disposition = .installed
                } else {
                    disposition = .updated
                }
                return AgentSkillInstallTargetResult(
                    disposition: disposition,
                    files: target.files.map(\.relativePath),
                    kind: target.kind,
                    rootPath: target.rootPath,
                    skillPath: target.skillPath
                )
            }
        )
    }

    public func status(
        agents: [String],
        skillRoots: [String]
    ) throws -> AgentSkillStatusResult {
        let context = try context(
            agents: agents,
            skillRoots: skillRoots,
            defaultAgents: agents.isEmpty && skillRoots.isEmpty
        )
        return AgentSkillStatusResult(targets: try context.targets.map { target in
            let inspection = try inspect(
                target,
                effectiveUserID: context.user.effectiveUserID
            )
            return AgentSkillStatusTargetResult(
                current: inspection.current,
                disposition: inspection.disposition,
                files: target.files.map(\.relativePath),
                kind: target.kind,
                rootPath: target.rootPath,
                skillPath: target.skillPath
            )
        })
    }

    public func uninstall(
        agents: [String],
        skillRoots: [String],
        force: Bool
    ) throws -> AgentSkillUninstallResult {
        guard !agents.isEmpty || !skillRoots.isEmpty else {
            throw AgentSkillError.invalidArgument(
                "skill uninstall requires --agent or --skill-root"
            )
        }
        let context = try context(
            agents: agents,
            skillRoots: skillRoots,
            defaultAgents: false
        )
        var inspections = [(Target, Inspection)]()
        for target in context.targets {
            let inspection = try inspect(target, effectiveUserID: context.user.effectiveUserID)
            if !force, [.modified, .incomplete].contains(inspection.disposition) {
                throw AgentSkillError.conflict(target.skillPath)
            }
            inspections.append((target, inspection))
        }

        var removed = [PublishedFile]()
        do {
            for (target, inspection) in inspections {
                guard inspection.disposition != .notInstalled else { continue }
                for file in target.files {
                    let path = target.skillPath + "/" + file.relativePath
                    guard let bytes = try regularFileDataIfPresent(
                        path,
                        effectiveUserID: context.user.effectiveUserID
                    ) else { continue }
                    guard unlink(path) == 0 else {
                        throw AgentSkillError.localWrite("unlink errno=\(errno)")
                    }
                    removed.append(PublishedFile(destination: path, previous: bytes))
                }
            }
        } catch {
            do {
                try rollback(removed)
            } catch {
                throw AgentSkillError.rollbackFailed
            }
            throw error
        }

        for (target, _) in inspections {
            pruneIfEmpty(target.skillPath + "/agents")
            pruneIfEmpty(target.skillPath)
        }
        return AgentSkillUninstallResult(targets: inspections.map { target, inspection in
            AgentSkillUninstallTargetResult(
                disposition: inspection.disposition == .notInstalled
                    ? .notInstalled : .removed,
                files: target.files.map(\.relativePath),
                kind: target.kind,
                rootPath: target.rootPath,
                skillPath: target.skillPath
            )
        })
    }

    private func context(
        agents: [String],
        skillRoots: [String],
        defaultAgents: Bool
    ) throws -> (user: SelfInstallTrustedUser, targets: [Target]) {
        let user = try trustedUser()
        try validateTrustedHome(user)
        let portable = try loadPayload(
            relativePath: "AgentSkills/portable/pulsephone/SKILL.md",
            installedRelativePath: "SKILL.md",
            maximumBytes: 128 * 1_024
        )
        let codexMetadata = try loadPayload(
            relativePath: "AgentSkills/codex/pulsephone/agents/openai.yaml",
            installedRelativePath: "agents/openai.yaml",
            maximumBytes: 16 * 1_024
        )
        try validatePortableSkill(portable.bytes)
        try validateCodexMetadata(codexMetadata.bytes)

        var selectedAgents = defaultAgents ? ["codex", "claude-code"] : agents
        if selectedAgents.contains("all") {
            selectedAgents.removeAll { $0 == "all" }
            selectedAgents += ["codex", "claude-code"]
        }
        var targets = [Target]()
        for agent in selectedAgents {
            let kind: AgentSkillTargetKind
            let root: String
            switch agent {
            case "codex":
                kind = .codex
                root = user.homeDirectory + "/.codex/skills"
            case "claude-code":
                kind = .claudeCode
                root = user.homeDirectory + "/.claude/skills"
            default:
                throw AgentSkillError.invalidArgument("unsupported agent \(agent)")
            }
            targets.append(Target(
                files: kind == .codex ? [portable, codexMetadata] : [portable],
                kind: kind,
                rootPath: root,
                skillPath: root + "/pulsephone"
            ))
        }
        for root in skillRoots {
            try validateCanonicalAbsolutePath(root)
            targets.append(Target(
                files: [portable],
                kind: .custom,
                rootPath: root,
                skillPath: root + "/pulsephone"
            ))
        }
        guard targets.count <= 64 else {
            throw AgentSkillError.invalidArgument("at most 64 skill targets")
        }
        targets.sort { lhs, rhs in
            lhs.skillPath.utf8.lexicographicallyPrecedes(rhs.skillPath.utf8)
        }
        var unique = [Target]()
        for target in targets {
            if let previous = unique.last, previous.skillPath == target.skillPath {
                guard previous.kind == target.kind else {
                    throw AgentSkillError.invalidArgument(
                        "one skill root cannot have multiple platform kinds"
                    )
                }
                continue
            }
            unique.append(target)
        }
        guard !unique.isEmpty else {
            throw AgentSkillError.invalidArgument("no skill target selected")
        }
        return (user, unique)
    }

    private func loadPayload(
        relativePath: String,
        installedRelativePath: String,
        maximumBytes: Int
    ) throws -> PayloadFile {
        let path = try resourcesPath() + "/" + relativePath
        guard let metadata = try metadata(path),
              metadata.kind == .regular,
              metadata.links == 1,
              metadata.size > 0,
              metadata.size <= maximumBytes
        else {
            throw AgentSkillError.invalidPayload(relativePath)
        }
        return PayloadFile(
            bytes: try Data(contentsOf: URL(fileURLWithPath: path)),
            relativePath: installedRelativePath
        )
    }

    private func validatePortableSkill(_ data: Data) throws {
        guard let source = String(data: data, encoding: .utf8),
              source.hasPrefix("---\nname: pulsephone\n"),
              source.contains("PulsePhone version --json"),
              !source.contains("bin/PulsePhone.app"),
              !source.contains("self install")
        else {
            throw AgentSkillError.invalidPayload("portable SKILL.md contract")
        }
    }

    private func validateCodexMetadata(_ data: Data) throws {
        guard let source = String(data: data, encoding: .utf8),
              source.contains("display_name: \"PulsePhone\""),
              source.contains("$pulsephone"),
              !source.contains("$phlusephone")
        else {
            throw AgentSkillError.invalidPayload("Codex metadata contract")
        }
    }

    private func inspect(
        _ target: Target,
        effectiveUserID: uid_t
    ) throws -> Inspection {
        try validatePathAncestors(target.rootPath)
        if let root = try metadata(target.rootPath) {
            guard root.kind == .directory, root.owner == effectiveUserID else {
                throw AgentSkillError.unsafeHostPath("invalid skill root")
            }
        } else {
            return Inspection(current: false, disposition: .notInstalled, existing: [:])
        }
        guard let skill = try metadata(target.skillPath) else {
            return Inspection(current: false, disposition: .notInstalled, existing: [:])
        }
        guard skill.kind == .directory, skill.owner == effectiveUserID else {
            throw AgentSkillError.unsafeHostPath("invalid pulsephone skill directory")
        }

        var existing = [String: Data]()
        var validManagedCount = 0
        var currentCount = 0
        for file in target.files {
            let path = target.skillPath + "/" + file.relativePath
            try validatePathAncestors(URL(fileURLWithPath: path).deletingLastPathComponent().path)
            guard let data = try regularFileDataIfPresent(
                path,
                effectiveUserID: effectiveUserID
            ) else { continue }
            existing[file.relativePath] = data
            if managedSourceBytes(data, relativePath: file.relativePath) != nil {
                validManagedCount += 1
            }
            if data == managedBytes(file) {
                currentCount += 1
            }
        }
        if existing.isEmpty {
            return Inspection(current: false, disposition: .notInstalled, existing: existing)
        }
        if validManagedCount != existing.count {
            return Inspection(current: false, disposition: .modified, existing: existing)
        }
        if existing.count != target.files.count {
            return Inspection(current: false, disposition: .incomplete, existing: existing)
        }
        return Inspection(
            current: currentCount == target.files.count,
            disposition: .installed,
            existing: existing
        )
    }

    private func managedBytes(_ file: PayloadFile) -> Data {
        var result = file.bytes
        if result.last != 0x0a { result.append(0x0a) }
        let hash = StableBytes.sha256Hex(result)
        let marker = file.relativePath.hasSuffix(".md")
            ? "<!-- pulsephone-managed-source-sha256: \(hash) -->\n"
            : "# pulsephone-managed-source-sha256: \(hash)\n"
        result.append(contentsOf: marker.utf8)
        return result
    }

    private func managedSourceBytes(_ data: Data, relativePath: String) -> Data? {
        guard let source = String(data: data, encoding: .utf8) else { return nil }
        let prefix = relativePath.hasSuffix(".md")
            ? "<!-- pulsephone-managed-source-sha256: "
            : "# pulsephone-managed-source-sha256: "
        let suffix = relativePath.hasSuffix(".md") ? " -->\n" : "\n"
        guard source.hasSuffix(suffix),
              let markerStart = source.range(of: prefix, options: .backwards),
              markerStart.lowerBound > source.startIndex
        else { return nil }
        let hashStart = markerStart.upperBound
        let hashEnd = source.index(hashStart, offsetBy: 64, limitedBy: source.endIndex)
        guard let hashEnd,
              source[hashEnd...].hasPrefix(suffix),
              source.index(hashEnd, offsetBy: suffix.count) == source.endIndex
        else { return nil }
        let hash = String(source[hashStart..<hashEnd])
        let payload = Data(source[..<markerStart.lowerBound].utf8)
        guard StableBytes.isLowercaseHex(hash, byteCount: 32),
              StableBytes.sha256Hex(payload) == hash
        else { return nil }
        return payload
    }

    private func validateTrustedHome(_ user: SelfInstallTrustedUser) throws {
        try validateCanonicalAbsolutePath(user.homeDirectory)
        try validatePathAncestors(user.homeDirectory)
        guard let node = try metadata(user.homeDirectory),
              node.kind == .directory,
              node.owner == user.effectiveUserID
        else {
            throw AgentSkillError.unsafeHostPath("invalid login home")
        }
    }

    private func validateCanonicalAbsolutePath(_ path: String) throws {
        let components = path.utf8.dropFirst().split(
            separator: 0x2f,
            omittingEmptySubsequences: false
        )
        guard path.utf8.count > 1,
              path.utf8.count <= 4096,
              path.first == "/",
              !path.contains("\0"),
              components.allSatisfy({ component in
                  !component.isEmpty
                      && !(component.count == 1 && component.first == 0x2e)
                      && !(component.count == 2 && component.allSatisfy { $0 == 0x2e })
              })
        else {
            throw AgentSkillError.invalidArgument("noncanonical absolute skill root")
        }
    }

    private func validatePathAncestors(_ path: String) throws {
        try validateCanonicalAbsolutePath(path)
        var current = ""
        var missing = false
        for component in path.split(separator: "/") {
            current += "/" + component
            if missing { continue }
            guard let node = try metadata(current) else {
                missing = true
                continue
            }
            guard node.kind == .directory else {
                throw AgentSkillError.unsafeHostPath("non-directory ancestor \(current)")
            }
        }
    }

    private func ensureDirectory(
        _ path: String,
        effectiveUserID: uid_t,
        created: inout [String]
    ) throws {
        try validateCanonicalAbsolutePath(path)
        var current = ""
        var nearestExistingOwner: uid_t?
        for component in path.split(separator: "/") {
            current += "/" + component
            if let node = try metadata(current) {
                guard node.kind == .directory else {
                    throw AgentSkillError.unsafeHostPath("non-directory ancestor \(current)")
                }
                nearestExistingOwner = node.owner
                continue
            }
            guard nearestExistingOwner == effectiveUserID else {
                throw AgentSkillError.unsafeHostPath("foreign writable ancestor")
            }
            guard mkdir(current, 0o755) == 0 else {
                throw AgentSkillError.localWrite("mkdir errno=\(errno)")
            }
            created.append(current)
            nearestExistingOwner = effectiveUserID
        }
        guard let node = try metadata(path), node.owner == effectiveUserID else {
            throw AgentSkillError.unsafeHostPath("foreign skill directory")
        }
    }

    private func regularFileDataIfPresent(
        _ path: String,
        effectiveUserID: uid_t
    ) throws -> Data? {
        guard let node = try metadata(path) else { return nil }
        guard node.kind == .regular,
              node.owner == effectiveUserID,
              node.links == 1,
              node.size <= 256 * 1_024
        else {
            throw AgentSkillError.unsafeHostPath("invalid managed file \(path)")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    private func writeNewFile(_ data: Data, path: String) throws {
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
            guard chmod(path, 0o644) == 0 else {
                throw AgentSkillError.localWrite("chmod errno=\(errno)")
            }
        } catch let error as AgentSkillError {
            try? removeRegularFile(path)
            throw error
        } catch {
            try? removeRegularFile(path)
            throw AgentSkillError.localWrite(String(describing: error))
        }
    }

    private func rollback(_ files: [PublishedFile]) throws {
        for file in files.reversed() {
            if let previous = file.previous {
                let stage = file.destination + ".pulsephone-rollback-\(UUID().uuidString)"
                try writeNewFile(previous, path: stage)
                guard Darwin.rename(stage, file.destination) == 0 else {
                    try? removeRegularFile(stage)
                    throw AgentSkillError.rollbackFailed
                }
            } else if unlink(file.destination) != 0, errno != ENOENT {
                throw AgentSkillError.rollbackFailed
            }
        }
    }

    private func removeRegularFile(_ path: String) throws {
        guard let node = try metadata(path) else { return }
        guard node.kind == .regular else {
            throw AgentSkillError.unsafeHostPath("refusing to remove non-file")
        }
        guard unlink(path) == 0 else {
            throw AgentSkillError.localWrite("unlink errno=\(errno)")
        }
    }

    private func pruneCreatedDirectories(_ paths: [String]) {
        for path in paths.reversed() { pruneIfEmpty(path) }
    }

    private func pruneIfEmpty(_ path: String) {
        guard rmdir(path) == 0 || [ENOENT, ENOTEMPTY].contains(errno) else { return }
    }

    private enum NodeKind {
        case directory
        case regular
        case other
    }

    private struct NodeMetadata {
        let kind: NodeKind
        let links: UInt64
        let owner: uid_t
        let size: Int
    }

    private func metadata(_ path: String) throws -> NodeMetadata? {
        var value = stat()
        guard lstat(path, &value) == 0 else {
            if errno == ENOENT { return nil }
            throw AgentSkillError.unsafeHostPath("lstat errno=\(errno)")
        }
        let type = value.st_mode & mode_t(S_IFMT)
        let kind: NodeKind
        switch type {
        case mode_t(S_IFDIR): kind = .directory
        case mode_t(S_IFREG): kind = .regular
        default: kind = .other
        }
        return NodeMetadata(
            kind: kind,
            links: UInt64(value.st_nlink),
            owner: value.st_uid,
            size: Int(value.st_size)
        )
    }
}
