import Darwin
import Foundation
import PulsePhoneCLI
import PulsePhoneSharedDefinitions
import XCTest

final class SelfInstallCommandTests: XCTestCase {
    func testInvalidSourceDoesNotCreateInstallDirectories() throws {
        let fixture = try Fixture()

        XCTAssertThrowsError(try fixture.installer().install()) { error in
            guard case .invalidSource? = error as? SelfInstallError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home + "/Applications"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home + "/.local"))
        XCTAssertTrue(fixture.terminator.calls.isEmpty)
    }

    func testStagingValidationFailurePreservesExistingInstallation() throws {
        let fixture = try Fixture()
        try fixture.makeApplication(
            at: fixture.sourcePath,
            version: "2.0.0",
            build: "2",
            payload: "new"
        )
        try fixture.makeApplication(
            at: fixture.applicationPath,
            version: "1.0.0",
            build: "1",
            payload: "old"
        )
        fixture.validator.rejectStaging = true

        XCTAssertThrowsError(try fixture.installer().install())
        XCTAssertEqual(try fixture.version(at: fixture.applicationPath), "1.0.0|1")
        XCTAssertEqual(try fixture.payload(at: fixture.applicationPath), "old")
        XCTAssertTrue(fixture.terminator.calls.isEmpty)
        try fixture.assertNoTransactionNodes()
    }

    func testFreshInstallPublishesAppLauncherAndResult() throws {
        let fixture = try Fixture()
        try fixture.makeApplication(
            at: fixture.sourcePath,
            version: "1.2.3",
            build: "45",
            payload: "new"
        )
        fixture.terminator.result = 2

        let result = try fixture.installer().install()

        XCTAssertEqual(result.disposition, .installed)
        XCTAssertEqual(result.terminatedProcessCount, 2)
        XCTAssertTrue(result.launcherChanged)
        XCTAssertEqual(try fixture.version(at: fixture.applicationPath), "1.2.3|45")
        XCTAssertEqual(try fixture.payload(at: fixture.applicationPath), "new")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: fixture.launcherPath
            ),
            fixture.applicationPath + "/Contents/MacOS/PulsePhone"
        )
        XCTAssertEqual(fixture.terminator.calls.count, 1)
        XCTAssertEqual(fixture.verifier.calls.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourcePath))
        try fixture.assertNoTransactionNodes()
    }

    func testMatchingDestinationSkipsCopyAndProcessesButRepairsLauncher() throws {
        let fixture = try Fixture()
        try fixture.makeApplication(
            at: fixture.sourcePath,
            version: "1.2.3",
            build: "45",
            payload: "source"
        )
        try fixture.makeApplication(
            at: fixture.applicationPath,
            version: "1.2.3",
            build: "45",
            payload: "destination"
        )
        try fixture.ensureLauncherDirectory()
        try Data("old launcher".utf8).write(
            to: URL(fileURLWithPath: fixture.launcherPath)
        )

        let first = try fixture.installer().install()
        XCTAssertEqual(first.disposition, .alreadyCurrent)
        XCTAssertTrue(first.launcherChanged)
        XCTAssertEqual(first.terminatedProcessCount, 0)
        XCTAssertEqual(try fixture.payload(at: fixture.applicationPath), "destination")
        XCTAssertTrue(fixture.terminator.calls.isEmpty)

        let second = try fixture.installer().install()
        XCTAssertEqual(second.disposition, .alreadyCurrent)
        XCTAssertFalse(second.launcherChanged)
        XCTAssertTrue(fixture.terminator.calls.isEmpty)
    }

    func testVersionMismatchUpdatesAndInvalidDestinationRepairs() throws {
        let updated = try Fixture()
        try updated.makeApplication(
            at: updated.sourcePath,
            version: "2.0.0",
            build: "2",
            payload: "new"
        )
        try updated.makeApplication(
            at: updated.applicationPath,
            version: "1.0.0",
            build: "1",
            payload: "old"
        )
        XCTAssertEqual(try updated.installer().install().disposition, .updated)
        XCTAssertEqual(try updated.payload(at: updated.applicationPath), "new")

        let repaired = try Fixture()
        try repaired.makeApplication(
            at: repaired.sourcePath,
            version: "2.0.0",
            build: "2",
            payload: "new"
        )
        try FileManager.default.createDirectory(
            atPath: repaired.applicationPath,
            withIntermediateDirectories: true
        )
        try Data("invalid".utf8).write(
            to: URL(fileURLWithPath: repaired.applicationPath + "/payload.txt")
        )
        XCTAssertEqual(try repaired.installer().install().disposition, .repaired)
        XCTAssertEqual(try repaired.payload(at: repaired.applicationPath), "new")
    }

    func testPostPublishFailureRestoresAppAndLauncher() throws {
        let fixture = try Fixture()
        try fixture.makeApplication(
            at: fixture.sourcePath,
            version: "2.0.0",
            build: "2",
            payload: "new"
        )
        try fixture.makeApplication(
            at: fixture.applicationPath,
            version: "1.0.0",
            build: "1",
            payload: "old"
        )
        try fixture.ensureLauncherDirectory()
        try Data("old launcher".utf8).write(
            to: URL(fileURLWithPath: fixture.launcherPath)
        )
        fixture.verifier.error = .verificationFailed("injected")

        XCTAssertThrowsError(try fixture.installer().install()) { error in
            XCTAssertEqual(error as? SelfInstallError, .verificationFailed("injected"))
        }
        XCTAssertEqual(try fixture.version(at: fixture.applicationPath), "1.0.0|1")
        XCTAssertEqual(try fixture.payload(at: fixture.applicationPath), "old")
        XCTAssertEqual(
            try String(contentsOfFile: fixture.launcherPath, encoding: .utf8),
            "old launcher"
        )
        try fixture.assertNoTransactionNodes()
    }

    func testLauncherDirectoryFailsBeforeCopyOrProcessTermination() throws {
        let fixture = try Fixture()
        try fixture.makeApplication(
            at: fixture.sourcePath,
            version: "1.0.0",
            build: "1",
            payload: "new"
        )
        try fixture.ensureLauncherDirectory()
        try FileManager.default.createDirectory(
            atPath: fixture.launcherPath,
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(try fixture.installer().install()) { error in
            guard case .unsafeHostPath? = error as? SelfInstallError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.applicationPath))
        XCTAssertTrue(fixture.terminator.calls.isEmpty)
        try fixture.assertNoTransactionNodes()
    }

    func testDispatcherRendersSelfInstallWithoutOtherBackends() throws {
        let fixture = try Fixture()
        let expected = SelfInstallResult(
            applicationPath: fixture.applicationPath,
            build: "45",
            disposition: .updated,
            launcherChanged: true,
            launcherPath: fixture.launcherPath,
            terminatedProcessCount: 3,
            version: "1.2.3"
        )
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            selfInstall: { expected },
            makeQueries: {
                throw CLIProductionBackendError.standard(code: "probeUnavailable")
            },
            makeActionLogMaintenance: {
                throw CLIProductionBackendError.standard(code: "unsafeHostPath")
            }
        )

        let human = process.run(arguments: ["self", "install"])
        XCTAssertEqual(human.exitCode, 0)
        XCTAssertEqual(human.chunk.stdout, [expected.humanSummary])
        XCTAssertTrue(human.chunk.stderr.isEmpty)

        let machine = process.run(arguments: ["self", "install", "--json"])
        XCTAssertEqual(machine.exitCode, 0)
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(machine.chunk.stdout[0].utf8)
            ) as? [String: Any]
        )
        XCTAssertEqual(envelope["commandID"] as? String, "self.install")
        XCTAssertEqual(
            (envelope["target"] as? [String: String])?["scope"],
            "global"
        )
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["disposition"] as? String, "updated")
        XCTAssertEqual(result["terminatedProcessCount"] as? Int, 3)
    }

    func testVerifiedTerminatorRechecksAndEscalatesOnlySurvivors() throws {
        let system = FakeProcessSystem()
        let first = SelfInstallProcessIdentity(
            executablePath: "/source/PulsePhone.app/Contents/MacOS/PulsePhone",
            microseconds: 1,
            pid: 100,
            seconds: 1,
            userID: 501
        )
        let second = SelfInstallProcessIdentity(
            executablePath: "/source/PulsePhone.app/Contents/Helpers/PulsePhoneRuntime",
            microseconds: 2,
            pid: 101,
            seconds: 1,
            userID: 501
        )
        let stale = SelfInstallProcessIdentity(
            executablePath: "/source/PulsePhone.app/Contents/MacOS/PulsePhone",
            microseconds: 3,
            pid: 102,
            seconds: 1,
            userID: 501
        )
        system.identities = [first, second, stale]
        system.states = [100: .verified, 101: .verified, 102: .identityMismatch]
        system.exitAfterTerm.insert(100)
        system.exitAfterKill.insert(101)
        let terminator = VerifiedSelfInstallProcessTerminator(
            processSystem: system,
            poller: ImmediatePoller(),
            gracefulTimeoutNanoseconds: 1,
            forcedTimeoutNanoseconds: 1
        )

        let count = try terminator.terminate(
            bundlePaths: ["/source/PulsePhone.app"],
            effectiveUserID: 501,
            excludingPID: 99
        )

        XCTAssertEqual(count, 2)
        XCTAssertEqual(system.signals, [
            Signal(pid: 100, value: SIGTERM),
            Signal(pid: 101, value: SIGTERM),
            Signal(pid: 101, value: SIGKILL),
        ])
        XCTAssertEqual(system.excludingPID, 99)
    }

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func staticSurface() throws -> CLIStaticSurface {
        try CLIStaticSurface.loading(repositoryRoot: repositoryRoot)
    }
}

private final class Fixture {
    let root: String
    let home: String
    let sourcePath: String
    let applicationPath: String
    let launcherPath: String
    let validator = FixtureApplicationValidator()
    let terminator = FixtureProcessTerminator()
    let verifier = FixtureEntrypointVerifier()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulsePhone-SelfInstall-\(UUID().uuidString)")
            .path
        home = root + "/Home"
        sourcePath = root + "/Source/PulsePhone.app"
        applicationPath = home + "/Applications/PulsePhone.app"
        launcherPath = home + "/.local/bin/PulsePhone"
        try FileManager.default.createDirectory(
            atPath: home,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    func installer() -> ProductionSelfInstaller {
        ProductionSelfInstaller(
            sourceApplicationPath: { [sourcePath] in sourcePath },
            trustedUser: { [home] in
                SelfInstallTrustedUser(
                    effectiveUserID: geteuid(),
                    homeDirectory: home
                )
            },
            applicationValidator: validator,
            processTerminator: terminator,
            entrypointVerifier: verifier
        )
    }

    func makeApplication(
        at path: String,
        version: String,
        build: String,
        payload: String
    ) throws {
        try FileManager.default.createDirectory(
            atPath: path + "/Contents/MacOS",
            withIntermediateDirectories: true
        )
        try Data("\(version)|\(build)".utf8).write(
            to: URL(fileURLWithPath: path + "/version.txt")
        )
        try Data(payload.utf8).write(
            to: URL(fileURLWithPath: path + "/payload.txt")
        )
        try Data("binary".utf8).write(
            to: URL(fileURLWithPath: path + "/Contents/MacOS/PulsePhone")
        )
    }

    func ensureLauncherDirectory() throws {
        try FileManager.default.createDirectory(
            atPath: home + "/.local/bin",
            withIntermediateDirectories: true
        )
    }

    func version(at path: String) throws -> String {
        try String(contentsOfFile: path + "/version.txt", encoding: .utf8)
    }

    func payload(at path: String) throws -> String {
        try String(contentsOfFile: path + "/payload.txt", encoding: .utf8)
    }

    func assertNoTransactionNodes() throws {
        for directory in [home + "/Applications", home + "/.local/bin"] {
            guard FileManager.default.fileExists(atPath: directory) else { continue }
            let names = try FileManager.default.contentsOfDirectory(atPath: directory)
            XCTAssertFalse(names.contains { $0.contains(".install-") }, names.joined(separator: ","))
        }
    }
}

private final class FixtureApplicationValidator:
    SelfInstallApplicationValidating, @unchecked Sendable
{
    var rejectStaging = false

    func validate(
        applicationPath: String,
        requirement: SelfInstallApplicationValidationRequirement
    ) throws -> PulsePhoneProductVersion {
        if rejectStaging, applicationPath.hasSuffix(".staging") {
            throw SelfInstallError.invalidSource("rejected staging")
        }
        let value = try String(
            contentsOfFile: applicationPath + "/version.txt",
            encoding: .utf8
        ).split(separator: "|", omittingEmptySubsequences: false)
        guard value.count == 2,
              let version = PulsePhoneProductVersion(
                version: String(value[0]),
                build: String(value[1])
              )
        else {
            throw SelfInstallError.invalidSource("fixture metadata")
        }
        return version
    }
}

private final class FixtureProcessTerminator:
    SelfInstallProcessTerminating, @unchecked Sendable
{
    struct Call {
        let bundlePaths: Set<String>
        let effectiveUserID: uid_t
        let excludingPID: pid_t
    }

    var calls = [Call]()
    var result = 0

    func terminate(
        bundlePaths: Set<String>,
        effectiveUserID: uid_t,
        excludingPID: pid_t
    ) throws -> Int {
        calls.append(Call(
            bundlePaths: bundlePaths,
            effectiveUserID: effectiveUserID,
            excludingPID: excludingPID
        ))
        return result
    }
}

private final class FixtureEntrypointVerifier:
    SelfInstallEntrypointVerifying, @unchecked Sendable
{
    struct Call {
        let applicationPath: String
        let launcherPath: String
        let version: PulsePhoneProductVersion
    }

    var calls = [Call]()
    var error: SelfInstallError?

    func verify(
        applicationPath: String,
        launcherPath: String,
        expectedVersion: PulsePhoneProductVersion
    ) throws {
        calls.append(Call(
            applicationPath: applicationPath,
            launcherPath: launcherPath,
            version: expectedVersion
        ))
        if let error { throw error }
        let target = try FileManager.default.destinationOfSymbolicLink(
            atPath: launcherPath
        )
        guard target == applicationPath + "/Contents/MacOS/PulsePhone" else {
            throw SelfInstallError.verificationFailed("fixture launcher")
        }
        let value = try String(
            contentsOfFile: applicationPath + "/version.txt",
            encoding: .utf8
        )
        guard value == "\(expectedVersion.version)|\(expectedVersion.build)" else {
            throw SelfInstallError.verificationFailed("fixture version")
        }
    }
}

private struct Signal: Equatable {
    let pid: pid_t
    let value: Int32
}

private final class FakeProcessSystem:
    SelfInstallProcessSystem, @unchecked Sendable
{
    var identities = [SelfInstallProcessIdentity]()
    var states = [pid_t: SelfInstallProcessObservation]()
    var signals = [Signal]()
    var exitAfterTerm = Set<pid_t>()
    var exitAfterKill = Set<pid_t>()
    var excludingPID: pid_t?

    func enumerate(
        executablePaths: Set<String>,
        effectiveUserID: uid_t,
        excludingPID: pid_t
    ) throws -> [SelfInstallProcessIdentity] {
        self.excludingPID = excludingPID
        return identities
    }

    func observe(
        _ identity: SelfInstallProcessIdentity
    ) -> SelfInstallProcessObservation {
        states[identity.pid] ?? .gone
    }

    func signal(
        _ identity: SelfInstallProcessIdentity,
        signal: Int32
    ) throws {
        signals.append(Signal(pid: identity.pid, value: signal))
        if signal == SIGTERM, exitAfterTerm.contains(identity.pid) {
            states[identity.pid] = .gone
        }
        if signal == SIGKILL, exitAfterKill.contains(identity.pid) {
            states[identity.pid] = .gone
        }
    }
}

private struct ImmediatePoller: SelfInstallProcessPolling {
    func waitUntil(
        timeoutNanoseconds: UInt64,
        condition: () throws -> Bool
    ) throws -> Bool {
        try condition()
    }
}
