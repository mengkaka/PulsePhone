import Darwin
import Foundation
import XCTest
@testable import PulsePhoneClientCore
@testable import PulsePhoneHostPaths
import PulsePhoneSharedDefinitions

final class RuntimeBootstrapCoordinatorTests: XCTestCase {
    func testClassifierCoversAllGenerationStates() {
        let cases: [(RuntimeGenerationSnapshot, RuntimeGenerationClassification)] = [
            (
                snapshot(socket: .absent, lock: .free),
                .absent
            ),
            (
                snapshot(socket: .trusted, lock: .busy),
                .alive
            ),
            (
                snapshot(
                    socket: .absent,
                    lock: .busy,
                    runtime: .alive
                ),
                .exiting
            ),
            (
                snapshot(
                    socket: .absent,
                    lock: .busy,
                    runtime: .gone,
                    helpers: .alive
                ),
                .orphanHelpers
            ),
            (
                snapshot(socket: .untrusted, lock: .busy),
                .identityUnknown
            ),
            (
                snapshot(socket: .trusted, lock: .free),
                .identityUnknown
            ),
            (
                snapshot(
                    socket: .absent,
                    lock: .busy,
                    runtime: .gone,
                    helpers: .none
                ),
                .identityUnknown
            ),
        ]

        for (input, expected) in cases {
            XCTAssertEqual(RuntimeGenerationClassifier.classify(input), expected)
        }
    }

    func testExistingRuntimeDoesNotResolveOrSpawnExecutable() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let target = try CanonicalUDID(canonicalString: "BOOTSTRAP-EXISTING")
        let lock = try fixture.bootstrapLock(for: target)
        let coordinator = RuntimeBootstrapCoordinator(
            generationObserver: FixedObserver(.alive),
            startupDeadline: MonotonicDuration(nanoseconds: 100_000_000)
        )
        let missingApp = try CanonicalAppPath(
            canonicalBundlePath: fixture.root + "/Missing/PulsePhone.app"
        )

        XCTAssertEqual(
            try coordinator.ensureRunning(
                for: target,
                from: missingApp,
                whileHolding: lock
            ),
            .existing
        )
    }

    func testBusyGenerationsNeverSpawn() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let target = try CanonicalUDID(canonicalString: "BOOTSTRAP-BUSY")
        let lock = try fixture.bootstrapLock(for: target)
        let missingApp = try CanonicalAppPath(
            canonicalBundlePath: fixture.root + "/Missing/PulsePhone.app"
        )

        for classification in [
            RuntimeGenerationClassification.exiting,
            .orphanHelpers,
            .identityUnknown,
        ] {
            let coordinator = RuntimeBootstrapCoordinator(
                generationObserver: FixedObserver(classification),
                startupDeadline: MonotonicDuration(nanoseconds: 100_000_000)
            )
            XCTAssertThrowsError(
                try coordinator.ensureRunning(
                    for: target,
                    from: missingApp,
                    whileHolding: lock
                )
            ) { error in
                XCTAssertEqual(
                    error as? RuntimeBootstrapCoordinatorError,
                    .generationBusy(classification)
                )
            }
        }
    }

    func testExitingGenerationCanSettleBeforeReplacementSpawns() throws {
        let fixture = try makeFixture(
            scriptBody: """
            /usr/bin/printf '{"pid":%s,"runtimeEpoch":"01234567-89ab-cdef-0123-456789abcdef","schemaVersion":1,"state":"ready"}' "$$" >&3
            exec 3>&-
            exec /bin/sleep 30
            """
        )
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let target = try CanonicalUDID(canonicalString: "BOOTSTRAP-SETTLING")
        let lock = try fixture.bootstrapLock(for: target)
        let coordinator = RuntimeBootstrapCoordinator(
            generationObserver: SequencedObserver([.exiting, .absent]),
            startupDeadline: MonotonicDuration(nanoseconds: 1_000_000_000),
            waitForGenerationTransition: {}
        )

        let result = try coordinator.ensureRunning(
            for: target,
            from: fixture.appPath,
            whileHolding: lock
        )
        guard case .launched(let generation) = result else {
            return XCTFail("expected replacement generation")
        }
        XCTAssertGreaterThan(generation.pid, 0)
        _ = Darwin.kill(generation.pid, SIGKILL)
        var status: Int32 = 0
        while Darwin.waitpid(generation.pid, &status, 0) == -1, errno == EINTR {}
    }

    func testUnavailableSocketWaitsForAliveGenerationToSettleBeforeReplacement() throws {
        let fixture = try makeFixture(
            scriptBody: """
            /usr/bin/printf '{"pid":%s,"runtimeEpoch":"01234567-89ab-cdef-0123-456789abcdef","schemaVersion":1,"state":"ready"}' "$$" >&3
            exec 3>&-
            exec /bin/sleep 30
            """
        )
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let target = try CanonicalUDID(canonicalString: "BOOTSTRAP-UNAVAILABLE")
        let lock = try fixture.bootstrapLock(for: target)
        let coordinator = RuntimeBootstrapCoordinator(
            generationObserver: SequencedObserver([.alive, .exiting, .absent]),
            startupDeadline: MonotonicDuration(nanoseconds: 1_000_000_000),
            waitForGenerationTransition: {}
        )

        let result = try coordinator.ensureRunning(
            for: target,
            from: fixture.appPath,
            whileHolding: lock,
            waitingForExistingGenerationToSettle: true
        )
        guard case .launched(let generation) = result else {
            return XCTFail("expected replacement generation")
        }
        _ = Darwin.kill(generation.pid, SIGKILL)
        var status: Int32 = 0
        while Darwin.waitpid(generation.pid, &status, 0) == -1, errno == EINTR {}
    }

    func testVerifiedDeadGenerationRecoverySpawnsReplacement() throws {
        let fixture = try makeFixture(
            scriptBody: """
            /usr/bin/printf '{"pid":%s,"runtimeEpoch":"01234567-89ab-cdef-0123-456789abcdef","schemaVersion":1,"state":"ready"}' "$$" >&3
            exec 3>&-
            exec /bin/sleep 30
            """
        )
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let target = try CanonicalUDID(
            canonicalString: "BOOTSTRAP-DEAD-RECOVERY"
        )
        let lock = try fixture.bootstrapLock(for: target)
        let coordinator = RuntimeBootstrapCoordinator(
            generationObserver: FixedObserver(.identityUnknown),
            deadGenerationRecoverer: FixedDeadGenerationRecoverer(
                recovered: true
            ),
            startupDeadline: MonotonicDuration(nanoseconds: 1_000_000_000)
        )

        let result = try coordinator.ensureRunning(
            for: target,
            from: fixture.appPath,
            whileHolding: lock
        )
        guard case .launched(let generation) = result else {
            return XCTFail("expected replacement generation")
        }
        defer {
            _ = Darwin.kill(generation.pid, SIGKILL)
            var status: Int32 = 0
            while Darwin.waitpid(generation.pid, &status, 0) == -1,
                  errno == EINTR {}
        }
        XCTAssertEqual(generation.executablePath, fixture.runtimePath)
    }

    func testNativeSpawnPublishesReadyWithExactTargetAndRootCWD() throws {
        let fixture = try makeFixture(
            scriptBody: """
            if [ "$PWD" != "/" ]; then
              /usr/bin/printf '{"error":{"code":"internalFailure"},"schemaVersion":1,"state":"failed"}' >&3
              exec 3>&-
              exit 1
            fi
            /usr/bin/printf '{"pid":%s,"runtimeEpoch":"01234567-89ab-cdef-0123-456789abcdef","schemaVersion":1,"state":"ready"}' "$$" >&3
            exec 3>&-
            exec /bin/sleep 30
            """
        )
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let target = try CanonicalUDID(canonicalString: "BOOTSTRAP-READY")
        let lock = try fixture.bootstrapLock(for: target)
        let coordinator = RuntimeBootstrapCoordinator(
            generationObserver: FixedObserver(.absent),
            startupDeadline: MonotonicDuration(nanoseconds: 1_000_000_000)
        )

        let result = try coordinator.ensureRunning(
            for: target,
            from: fixture.appPath,
            whileHolding: lock
        )
        guard case .launched(let generation) = result else {
            return XCTFail("expected launched generation")
        }
        defer {
            _ = Darwin.kill(generation.pid, SIGKILL)
            var status: Int32 = 0
            _ = Darwin.waitpid(generation.pid, &status, 0)
        }
        XCTAssertGreaterThan(generation.pid, 0)
        XCTAssertEqual(
            generation.runtimeEpoch.canonicalString,
            "01234567-89ab-cdef-0123-456789abcdef"
        )
        XCTAssertEqual(generation.executablePath, fixture.runtimePath)
        XCTAssertGreaterThan(generation.processStartIdentity.seconds, 0)
    }

    func testLaunchedRuntimeIsReapedAfterNormalExit() throws {
        let fixture = try makeFixture(
            scriptBody: """
            /usr/bin/printf '{"pid":%s,"runtimeEpoch":"01234567-89ab-cdef-0123-456789abcdef","schemaVersion":1,"state":"ready"}' "$$" >&3
            exec 3>&-
            /bin/sleep 0.1
            exit 0
            """
        )
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let target = try CanonicalUDID(canonicalString: "BOOTSTRAP-REAP")
        let lock = try fixture.bootstrapLock(for: target)
        let coordinator = RuntimeBootstrapCoordinator(
            generationObserver: FixedObserver(.absent),
            startupDeadline: MonotonicDuration(nanoseconds: 1_000_000_000)
        )

        let result = try coordinator.ensureRunning(
            for: target,
            from: fixture.appPath,
            whileHolding: lock
        )
        guard case .launched(let generation) = result else {
            return XCTFail("expected launched generation")
        }

        for _ in 0..<200 {
            errno = 0
            if Darwin.kill(generation.pid, 0) == -1, errno == ESRCH {
                return
            }
            usleep(10_000)
        }
        XCTFail("launched Runtime was not reaped after normal exit")
    }

    func testFailedReadinessIsTypedAndChildIsReaped() throws {
        let pidEnvironmentKey = "PULSEPHONE_TEST_FAILED_PID_FILE"
        let fixture = try makeFixture(
            scriptBody: """
            /usr/bin/printf '%s' "$$" > "$\(pidEnvironmentKey)"
            /usr/bin/printf '{"error":{"code":"invalidArgument"},"schemaVersion":1,"state":"failed"}' >&3
            exec 3>&-
            exit 64
            """
        )
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let pidFile = fixture.root + "/failed.pid"
        setenv(pidEnvironmentKey, pidFile, 1)
        defer { unsetenv(pidEnvironmentKey) }
        let target = try CanonicalUDID(canonicalString: "BOOTSTRAP-FAILED")
        let lock = try fixture.bootstrapLock(for: target)
        let coordinator = RuntimeBootstrapCoordinator(
            generationObserver: FixedObserver(.absent),
            startupDeadline: MonotonicDuration(nanoseconds: 1_000_000_000)
        )

        XCTAssertThrowsError(
            try coordinator.ensureRunning(
                for: target,
                from: fixture.appPath,
                whileHolding: lock
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeBootstrapCoordinatorError,
                .runtimeFailed(code: "invalidArgument")
            )
        }
        try assertChildReaped(pidFile: pidFile)
    }

    func testReadinessTimeoutTerminatesOnlySpawnedChild() throws {
        let pidEnvironmentKey = "PULSEPHONE_TEST_TIMEOUT_PID_FILE"
        let fixture = try makeFixture(
            scriptBody: """
            /usr/bin/printf '%s' "$$" > "$\(pidEnvironmentKey)"
            exec /bin/sleep 30
            """
        )
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let pidFile = fixture.root + "/timeout.pid"
        setenv(pidEnvironmentKey, pidFile, 1)
        defer { unsetenv(pidEnvironmentKey) }
        let target = try CanonicalUDID(canonicalString: "BOOTSTRAP-TIMEOUT")
        let lock = try fixture.bootstrapLock(for: target)
        let coordinator = RuntimeBootstrapCoordinator(
            generationObserver: FixedObserver(.absent),
            startupDeadline: MonotonicDuration(nanoseconds: 250_000_000)
        )

        XCTAssertThrowsError(
            try coordinator.ensureRunning(
                for: target,
                from: fixture.appPath,
                whileHolding: lock
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeBootstrapCoordinatorError,
                .readinessTimeout
            )
        }
        try assertChildReaped(pidFile: pidFile)
    }

    func testMalformedAndPIDMismatchFramesFailClosed() throws {
        for frame in [
            "{\"schemaVersion\":1,\"state\":\"ready\"}",
            "{\"pid\":1,\"runtimeEpoch\":\"01234567-89ab-cdef-0123-456789abcdef\",\"schemaVersion\":1,\"state\":\"ready\"}",
        ] {
            let fixture = try makeFixture(
                scriptBody: """
                /usr/bin/printf '%s' '\(frame)' >&3
                exec 3>&-
                exec /bin/sleep 30
                """
            )
            defer { try? FileManager.default.removeItem(atPath: fixture.root) }
            let target = try CanonicalUDID(canonicalString: "BOOTSTRAP-MALFORMED")
            let lock = try fixture.bootstrapLock(for: target)
            let coordinator = RuntimeBootstrapCoordinator(
                generationObserver: FixedObserver(.absent),
                startupDeadline: MonotonicDuration(nanoseconds: 1_000_000_000)
            )
            XCTAssertThrowsError(
                try coordinator.ensureRunning(
                    for: target,
                    from: fixture.appPath,
                    whileHolding: lock
                )
            ) { error in
                XCTAssertEqual(
                    error as? RuntimeBootstrapCoordinatorError,
                    .invalidReadinessFrame
                )
            }
        }
    }

    func testRuntimeExecutableMustBeExactRegularNonSymlink() throws {
        let fixture = try makeFixture(scriptBody: "exit 0")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        XCTAssertEqual(unlink(fixture.runtimePath), 0)
        XCTAssertEqual(symlink("/bin/true", fixture.runtimePath), 0)
        let target = try CanonicalUDID(canonicalString: "BOOTSTRAP-SYMLINK")
        let lock = try fixture.bootstrapLock(for: target)
        let coordinator = RuntimeBootstrapCoordinator(
            generationObserver: FixedObserver(.absent),
            startupDeadline: MonotonicDuration(nanoseconds: 100_000_000)
        )

        XCTAssertThrowsError(
            try coordinator.ensureRunning(
                for: target,
                from: fixture.appPath,
                whileHolding: lock
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeBootstrapCoordinatorError,
                .invalidRuntimeExecutable
            )
        }
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: fixture.runtimePath
            ),
            "/bin/true"
        )
    }

    private struct FixedObserver: RuntimeGenerationObserving {
        let value: RuntimeGenerationClassification

        init(_ value: RuntimeGenerationClassification) {
            self.value = value
        }

        func classification(
            for canonicalUDID: CanonicalUDID,
            whileHolding bootstrapLock: BootstrapLock
        ) throws -> RuntimeGenerationClassification {
            XCTAssertEqual(bootstrapLock.canonicalUDID, canonicalUDID)
            return value
        }
    }

    private final class SequencedObserver: RuntimeGenerationObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [RuntimeGenerationClassification]

        init(_ values: [RuntimeGenerationClassification]) {
            self.values = values
        }

        func classification(
            for canonicalUDID: CanonicalUDID,
            whileHolding bootstrapLock: BootstrapLock
        ) throws -> RuntimeGenerationClassification {
            XCTAssertEqual(bootstrapLock.canonicalUDID, canonicalUDID)
            return lock.withLock {
                guard !values.isEmpty else { return .absent }
                return values.removeFirst()
            }
        }
    }

    private struct FixedDeadGenerationRecoverer:
        RuntimeDeadGenerationRecovering
    {
        let recovered: Bool

        func recover(
            canonicalUDID: CanonicalUDID,
            runtimeExecutablePath: String,
            whileHolding bootstrapLock: BootstrapLock
        ) throws -> Bool {
            XCTAssertEqual(bootstrapLock.canonicalUDID, canonicalUDID)
            XCTAssertTrue(runtimeExecutablePath.hasSuffix(
                "/Contents/Helpers/PulsePhoneRuntime"
            ))
            return recovered
        }
    }

    private struct Fixture {
        let root: String
        let anchor: AnchoredDirectory
        let appPath: CanonicalAppPath
        let runtimePath: String

        func bootstrapLock(for target: CanonicalUDID) throws -> BootstrapLock {
            try BootstrapLock.acquire(
                for: target,
                baseDirectory: anchor,
                acquisition: .nonBlocking
            )
        }
    }

    private func snapshot(
        socket: RuntimeSocketObservation,
        lock: RuntimeLockObservation,
        runtime: VerifiedRuntimeProcessObservation = .identityUnknown,
        helpers: VerifiedHelperProcessObservation = .identityUnknown
    ) -> RuntimeGenerationSnapshot {
        RuntimeGenerationSnapshot(
            socket: socket,
            runtimeLock: lock,
            runtimeProcess: runtime,
            helperProcesses: helpers
        )
    }

    private func makeFixture(
        scriptBody: String? = nil
    ) throws -> Fixture {
        let template = "/private/tmp/pulsephone-bootstrap.XXXXXX"
        var bytes = Array(template.utf8CString)
        guard let result = mkdtemp(&bytes) else {
            throw POSIXError(.EIO)
        }
        let root = String(cString: result)
        XCTAssertEqual(chmod(root, 0o700), 0)
        let anchor = try AnchoredFileSystem().openDirectory(
            atPath: root,
            expecting: HostNodeExpectation(
                owner: geteuid(),
                kind: .directory,
                mode: 0o700
            )
        )
        let bundle = root + "/PulsePhone.app"
        let helpers = bundle + "/Contents/Helpers"
        try FileManager.default.createDirectory(
            atPath: helpers,
            withIntermediateDirectories: true
        )
        let runtimePath = helpers + "/PulsePhoneRuntime"
        if let scriptBody {
            let script = "#!/bin/sh\n" + scriptBody + "\n"
            XCTAssertTrue(
                FileManager.default.createFile(
                    atPath: runtimePath,
                    contents: Data(script.utf8)
                )
            )
            XCTAssertEqual(chmod(runtimePath, 0o700), 0)
        }
        return Fixture(
            root: root,
            anchor: anchor,
            appPath: try CanonicalAppPath(canonicalBundlePath: bundle),
            runtimePath: runtimePath
        )
    }

    private func assertChildReaped(pidFile: String) throws {
        let value = try String(contentsOfFile: pidFile, encoding: .utf8)
        let pid = try XCTUnwrap(pid_t(value))
        var status: Int32 = 0
        errno = 0
        XCTAssertEqual(Darwin.waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
        errno = 0
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}
