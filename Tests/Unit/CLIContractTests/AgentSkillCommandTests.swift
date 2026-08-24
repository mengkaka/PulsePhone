import Foundation
import PulsePhoneCLI
import XCTest

final class AgentSkillCommandTests: XCTestCase {
    func testCustomInstallWritesOnlyPortableSkillAndIsIdempotent() throws {
        let fixture = try Fixture()
        let root = fixture.home + "/opencode/skills"

        let first = try fixture.manager.install(
            agents: [],
            skillRoots: [root],
            force: false
        )
        XCTAssertEqual(fixture.applicationInstaller.calls, 1)
        XCTAssertEqual(first.targets.map(\.disposition), [.installed])
        XCTAssertEqual(first.targets[0].kind, .custom)
        XCTAssertEqual(first.targets[0].files, ["SKILL.md"])
        let skill = root + "/pulsephone/SKILL.md"
        XCTAssertTrue(FileManager.default.fileExists(atPath: skill))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root + "/pulsephone/agents/openai.yaml"
        ))
        XCTAssertTrue(try String(contentsOfFile: skill).contains(
            "pulsephone-managed-source-sha256"
        ))

        let status = try fixture.manager.status(agents: [], skillRoots: [root])
        XCTAssertEqual(status.targets.map(\.disposition), [.installed])
        XCTAssertEqual(status.targets.map(\.current), [true])

        let second = try fixture.manager.install(
            agents: [],
            skillRoots: [root],
            force: false
        )
        XCTAssertEqual(second.targets.map(\.disposition), [.unchanged])
        XCTAssertEqual(fixture.applicationInstaller.calls, 2)
    }

    func testBuiltInTargetsInstallPlatformSpecificPayloadsAndNormalizeName() throws {
        let fixture = try Fixture()
        let result = try fixture.manager.install(
            agents: ["all", "codex"],
            skillRoots: [],
            force: false
        )

        XCTAssertEqual(result.targets.map(\.kind), [.claudeCode, .codex])
        let claude = fixture.home + "/.claude/skills/pulsephone"
        let codex = fixture.home + "/.codex/skills/pulsephone"
        XCTAssertTrue(FileManager.default.fileExists(atPath: claude + "/SKILL.md"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: claude + "/agents/openai.yaml"
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: codex + "/SKILL.md"))
        let metadata = try String(contentsOfFile: codex + "/agents/openai.yaml")
        XCTAssertTrue(metadata.contains("$pulsephone"))
        XCTAssertFalse(metadata.contains("$phlusephone"))
        let source = try String(contentsOfFile: codex + "/SKILL.md")
        XCTAssertTrue(source.hasPrefix("---\nname: pulsephone\n"))
    }

    func testModifiedSkillRequiresForceAndForceRestoresManagedPayload() throws {
        let fixture = try Fixture()
        let root = fixture.home + "/custom/skills"
        _ = try fixture.manager.install(agents: [], skillRoots: [root], force: false)
        let path = root + "/pulsephone/SKILL.md"
        try Data("user modification\n".utf8).write(to: URL(fileURLWithPath: path))

        XCTAssertEqual(
            try fixture.manager.status(agents: [], skillRoots: [root])
                .targets[0].disposition,
            .modified
        )
        XCTAssertThrowsError(
            try fixture.manager.install(agents: [], skillRoots: [root], force: false)
        ) { error in
            guard case .conflict? = error as? AgentSkillError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let repaired = try fixture.manager.install(
            agents: [],
            skillRoots: [root],
            force: true
        )
        XCTAssertEqual(repaired.targets[0].disposition, .updated)
        XCTAssertEqual(
            try fixture.manager.status(agents: [], skillRoots: [root])
                .targets[0].current,
            true
        )
    }

    func testUninstallPreservesUnknownFilesAndNeverInstallsApplication() throws {
        let fixture = try Fixture()
        let root = fixture.home + "/custom/skills"
        _ = try fixture.manager.install(agents: [], skillRoots: [root], force: false)
        let skillPath = root + "/pulsephone"
        try Data("keep\n".utf8).write(
            to: URL(fileURLWithPath: skillPath + "/notes.txt")
        )
        let callsBeforeUninstall = fixture.applicationInstaller.calls

        let result = try fixture.manager.uninstall(
            agents: [],
            skillRoots: [root],
            force: false
        )

        XCTAssertEqual(result.targets[0].disposition, .removed)
        XCTAssertEqual(fixture.applicationInstaller.calls, callsBeforeUninstall)
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillPath + "/SKILL.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillPath + "/notes.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillPath))
    }

    func testDefaultStatusInspectsBothBuiltInTargetsWithoutInstalling() throws {
        let fixture = try Fixture()

        let result = try fixture.manager.status(agents: [], skillRoots: [])

        XCTAssertEqual(result.targets.map(\.kind), [.claudeCode, .codex])
        XCTAssertEqual(result.targets.map(\.disposition), [.notInstalled, .notInstalled])
        XCTAssertEqual(fixture.applicationInstaller.calls, 0)
    }

    func testSymlinkAncestorAndNoncanonicalRootFailClosed() throws {
        let fixture = try Fixture()
        let destination = fixture.home + "/destination"
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: false)
        let link = fixture.home + "/linked"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: destination)

        XCTAssertThrowsError(
            try fixture.manager.status(agents: [], skillRoots: [link])
        ) { error in
            guard case .unsafeHostPath? = error as? AgentSkillError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(
            try fixture.manager.status(
                agents: [],
                skillRoots: [fixture.home + "/destination/../destination"]
            )
        ) { error in
            guard case .invalidArgument? = error as? AgentSkillError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testDispatcherPassesRepeatableTargetsAndRendersJSON() throws {
        let recorder = RecordingAgentSkillManager()
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeAgentSkillManager: { recorder },
            makeQueries: { throw CLIProductionBackendError.standard(code: "internalFailure") }
        )
        let output = process.run(arguments: [
            "skill", "install",
            "--agent", "codex",
            "--agent", "claude-code",
            "--skill-root", "/Users/example/.opencode/skills",
            "--json",
        ])

        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(recorder.installAgents, ["codex", "claude-code"])
        XCTAssertEqual(recorder.installRoots, ["/Users/example/.opencode/skills"])
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(output.chunk.stdout[0].utf8))
                as? [String: Any]
        )
        XCTAssertEqual(envelope["commandID"] as? String, "skill.install")
        XCTAssertEqual((envelope["target"] as? [String: Any])?["scope"] as? String, "global")
    }

    private static func staticSurface() throws -> CLIStaticSurface {
        try CLIStaticSurface.loading(repositoryRoot: repositoryRoot)
    }

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var calls: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private struct Fixture {
    let applicationInstaller = InvocationCounter()
    let home: String
    let manager: ProductionAgentSkillManager
    private let root: URL

    init() throws {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        guard let canonicalTemporaryPath = realpath(temporaryPath, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(canonicalTemporaryPath) }
        let base = URL(fileURLWithPath: String(cString: canonicalTemporaryPath))
        root = base.appendingPathComponent("PulsePhone-AgentSkill-\(UUID().uuidString)")
        home = root.appendingPathComponent("Home").path
        let resources = root.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: home),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let portable = resources.appendingPathComponent(
            "AgentSkills/portable/pulsephone/SKILL.md"
        )
        let codex = resources.appendingPathComponent(
            "AgentSkills/codex/pulsephone/agents/openai.yaml"
        )
        try FileManager.default.createDirectory(
            at: portable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: codex.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try FileManager.default.copyItem(
            at: repositoryRoot.appendingPathComponent("skills/pulsephone/SKILL.md"),
            to: portable
        )
        try FileManager.default.copyItem(
            at: repositoryRoot.appendingPathComponent(
                "skills/pulsephone/agents/openai.yaml"
            ),
            to: codex
        )
        let counter = applicationInstaller
        let homePath = home
        let resourcesPath = resources.path
        manager = ProductionAgentSkillManager(
            applicationInstaller: {
                counter.increment()
                return SelfInstallResult(
                    applicationPath: homePath + "/Applications/PulsePhone.app",
                    build: "1",
                    disposition: .alreadyCurrent,
                    launcherChanged: false,
                    launcherPath: homePath + "/.local/bin/PulsePhone",
                    terminatedProcessCount: 0,
                    version: "0.1.0"
                )
            },
            resourcesPath: { resourcesPath },
            trustedUser: {
                SelfInstallTrustedUser(
                    effectiveUserID: geteuid(),
                    homeDirectory: homePath
                )
            }
        )
    }
}

private final class RecordingAgentSkillManager: AgentSkillManaging, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var installAgents = [String]()
    private(set) var installRoots = [String]()

    func install(
        agents: [String],
        skillRoots: [String],
        force: Bool
    ) throws -> AgentSkillInstallResult {
        lock.withLock {
            installAgents = agents
            installRoots = skillRoots
        }
        return AgentSkillInstallResult(
            applicationInstall: SelfInstallResult(
                applicationPath: "/Users/example/Applications/PulsePhone.app",
                build: "1",
                disposition: .alreadyCurrent,
                launcherChanged: false,
                launcherPath: "/Users/example/.local/bin/PulsePhone",
                terminatedProcessCount: 0,
                version: "0.1.0"
            ),
            targets: [AgentSkillInstallTargetResult(
                disposition: .installed,
                files: ["SKILL.md"],
                kind: .custom,
                rootPath: "/Users/example/.opencode/skills",
                skillPath: "/Users/example/.opencode/skills/pulsephone"
            )]
        )
    }

    func status(
        agents: [String],
        skillRoots: [String]
    ) throws -> AgentSkillStatusResult {
        AgentSkillStatusResult(targets: [])
    }

    func uninstall(
        agents: [String],
        skillRoots: [String],
        force: Bool
    ) throws -> AgentSkillUninstallResult {
        AgentSkillUninstallResult(targets: [])
    }
}
