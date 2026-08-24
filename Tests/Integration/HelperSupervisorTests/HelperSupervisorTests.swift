import Darwin
import Foundation
@testable import PulsePhoneRuntimeKernel
import PulsePhoneSharedDefinitions
import XCTest

final class HelperSupervisorTests: XCTestCase {
    func testSpawnUsesExactFDAllowlistAndIndependentProcessGroup() throws {
        let context = try TestContext()
        defer { context.cleanup() }
        var supervisor = context.makeSupervisor()
        let spawned = try supervisor.spawn(
            context.configuration(),
            inheritedRuntimeLockDescriptor: context.lockDescriptor
        )
        defer { spawned.terminateAndReap() }

        let report = try readJSONLine(from: spawned.eventReader)
        XCTAssertEqual(report["fds"] as? [Int], [0, 1, 2, 3, 4])
        XCTAssertEqual(report["pid"] as? Int32, spawned.processIdentity.pid)
        XCTAssertEqual(
            report["pgid"] as? Int32,
            spawned.processIdentity.processGroupID
        )
        XCTAssertEqual(
            spawned.processIdentity.pid,
            spawned.processIdentity.processGroupID
        )
    }

    func testManifestPublishesBeforeDeviceIOAuthorization() throws {
        let context = try TestContext()
        defer { context.cleanup() }
        var supervisor = context.makeSupervisor()
        let configuration = context.configuration()
        let spawned = try supervisor.spawn(
            configuration,
            inheritedRuntimeLockDescriptor: context.lockDescriptor
        )
        defer { spawned.terminateAndReap() }
        _ = try readJSONLine(from: spawned.eventReader)

        XCTAssertNil(supervisor.deviceIOAuthorization(for: configuration.helperID))
        XCTAssertThrowsError(try context.manifestStore.load())

        let wrong = HelperHello(
            runtimeEpoch: context.runtimeEpoch,
            executorGeneration: configuration.executorGeneration,
            helperBuildID: configuration.helperBuildID,
            helperKind: configuration.kind,
            manifestHash: String(repeating: "b", count: 64),
            processStartIdentity: spawned.processIdentity.processStartIdentity.wireValue
        )
        XCTAssertThrowsError(
            try supervisor.acceptHello(wrong, from: configuration.helperID)
        ) { error in
            XCTAssertEqual(error as? HelperSupervisorError, .helloMismatch)
        }
        XCTAssertNil(supervisor.deviceIOAuthorization(for: configuration.helperID))
        XCTAssertThrowsError(try context.manifestStore.load())

        let acceptance = try supervisor.acceptHello(
            context.hello(for: spawned),
            from: configuration.helperID
        )
        let manifest = try context.manifestStore.load()
        XCTAssertEqual(manifest.helpers.count, 1)
        XCTAssertEqual(manifest.helpers[0].helperID, configuration.helperID)
        XCTAssertEqual(
            manifest.helpers[0].processStartIdentity,
            spawned.processIdentity.processStartIdentity
        )
        XCTAssertEqual(
            acceptance.helloAccepted,
            HelperHelloAccepted(
                runtimeEpoch: context.runtimeEpoch,
                executorGeneration: configuration.executorGeneration,
                manifestHash: configuration.helperManifestHash
            )
        )
        XCTAssertEqual(
            supervisor.deviceIOAuthorization(for: configuration.helperID),
            acceptance.deviceIOAuthorization
        )
    }

    func testProcessIdentityRejectsPIDReuseProjection() throws {
        let context = try TestContext()
        defer { context.cleanup() }
        var supervisor = context.makeSupervisor()
        let spawned = try supervisor.spawn(
            context.configuration(),
            inheritedRuntimeLockDescriptor: context.lockDescriptor
        )
        defer { spawned.terminateAndReap() }
        _ = try readJSONLine(from: spawned.eventReader)

        XCTAssertEqual(
            HelperProcessIdentity.currentExecutablePath(
                pid: spawned.processIdentity.pid
            ),
            spawned.processIdentity.executablePath
        )
        let recaptured = try HelperProcessIdentity.capture(
            pid: spawned.processIdentity.pid,
            expectedExecutablePath: spawned.processIdentity.executablePath
        )
        XCTAssertEqual(recaptured, spawned.processIdentity)
        XCTAssertTrue(spawned.processIdentity.matchesCurrentProcess())
        let stale = HelperProcessIdentity(
            pid: spawned.processIdentity.pid,
            processGroupID: spawned.processIdentity.processGroupID,
            processStartIdentity: HelperProcessStartIdentity(
                seconds: spawned.processIdentity.processStartIdentity.seconds,
                microseconds: (
                    spawned.processIdentity.processStartIdentity.microseconds + 1
                ) % 1_000_000
            ),
            executablePath: spawned.processIdentity.executablePath
        )
        XCTAssertFalse(stale.matchesCurrentProcess())
    }

    func testManifestReadRejectsUnknownFieldsAndSymlinkReplacement() throws {
        let context = try TestContext()
        defer { context.cleanup() }
        try context.manifestStore.publish([])

        let current = try HelperManifestStore.loadCurrent(
            canonicalUDID: CanonicalUDID(canonicalString: "TEST-DEVICE"),
            baseDirectoryPath: context.root.path
        )
        XCTAssertEqual(current.runtimeEpoch, context.runtimeEpoch)
        XCTAssertEqual(current.runtimePID, getpid())
        XCTAssertTrue(current.helpers.isEmpty)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: context.manifestStore.path))
            ) as? [String: Any]
        )
        object["unexpected"] = true
        let invalid = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        try invalid.write(to: URL(fileURLWithPath: context.manifestStore.path))
        XCTAssertThrowsError(try context.manifestStore.load()) { error in
            XCTAssertEqual(error as? HelperManifestStoreError, .invalidManifest)
        }

        try FileManager.default.removeItem(atPath: context.manifestStore.path)
        XCTAssertEqual(symlink("/dev/null", context.manifestStore.path), 0)
        XCTAssertThrowsError(try context.manifestStore.load()) { error in
            XCTAssertEqual(error as? HelperManifestStoreError, .unsafePath)
        }
    }

    func testAssetReferencesAreRevisionEntryAndRoleKeyed() throws {
        let first = try DeveloperSupportAssetReference(
            catalogRevision: "catalog-r1",
            catalogEntryID: "ios-17.0-21A000",
            fileRoles: [.personalizedImage, .personalizedTrustCache]
        )
        let second = try DeveloperSupportAssetReference(
            catalogRevision: "catalog-r2",
            catalogEntryID: "ios-17.0-21A000",
            fileRoles: [.personalizedImage]
        )
        XCTAssertNotEqual(first.keys[0], second.keys[0])
        XCTAssertEqual(first.keys.map(\.fileRole), [
            .personalizedImage, .personalizedTrustCache,
        ])
        XCTAssertThrowsError(
            try DeveloperSupportAssetReference(
                catalogRevision: "catalog-r1",
                catalogEntryID: "entry",
                fileRoles: [.classicImage, .classicImage]
            )
        ) { error in
            XCTAssertEqual(error as? HelperSupervisorError, .invalidAssetReference)
        }
    }

    private func readJSONLine(from descriptor: Int32) throws -> [String: Any] {
        var bytes = [UInt8]()
        var byte: UInt8 = 0
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&item, 1, 50)
            if ready == 0 { continue }
            if ready < 0, errno == EINTR { continue }
            guard ready > 0, Darwin.read(descriptor, &byte, 1) == 1 else {
                throw TestError.readFailed
            }
            if byte == 0x0a { break }
            bytes.append(byte)
            guard bytes.count <= 4_096 else { throw TestError.readFailed }
        }
        guard !bytes.isEmpty,
              let object = try JSONSerialization.jsonObject(
                with: Data(bytes)
              ) as? [String: Any]
        else {
            throw TestError.readFailed
        }
        return object
    }
}

private enum TestError: Error {
    case readFailed
}

private final class TestContext {
    let runtimeEpoch: UInt64 = 17
    let root: URL
    let lockDescriptor: Int32
    let manifestStore: HelperManifestStore
    let helperExecutablePath: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pulsephone-helper-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        helperExecutablePath = try Self.compileHelper(in: root)
        let lockPath = root.appendingPathComponent("runtime.lock").path
        lockDescriptor = Darwin.open(
            lockPath,
            O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC,
            mode_t(0o600)
        )
        guard lockDescriptor >= 0 else { throw TestError.readFailed }
        manifestStore = try HelperManifestStore(
            canonicalUDID: CanonicalUDID(canonicalString: "TEST-DEVICE"),
            runtimeEpoch: runtimeEpoch,
            runtimePID: getpid(),
            runtimeProcessStartIdentity: HelperProcessStartIdentity(
                seconds: 1,
                microseconds: 2
            ),
            baseDirectoryPath: root.path
        )
    }

    func makeSupervisor() -> HelperSupervisor {
        HelperSupervisor(
            runtimeEpoch: runtimeEpoch,
            manifestStore: manifestStore
        )
    }

    func configuration() -> HelperLaunchConfiguration {
        return HelperLaunchConfiguration(
            helperID: "helper-1",
            kind: .direct,
            role: "direct",
            executorID: "executor.direct",
            executorGeneration: 3,
            executablePath: helperExecutablePath,
            helperBuildID: "helper-build-1",
            helperManifestHash: String(repeating: "a", count: 64)
        )
    }

    func hello(for spawned: SpawnedHelper) -> HelperHello {
        let configuration = spawned.configuration
        return HelperHello(
            runtimeEpoch: runtimeEpoch,
            executorGeneration: configuration.executorGeneration,
            helperBuildID: configuration.helperBuildID,
            helperKind: configuration.kind,
            manifestHash: configuration.helperManifestHash,
            processStartIdentity: spawned.processIdentity.processStartIdentity.wireValue
        )
    }

    func cleanup() {
        _ = Darwin.close(lockDescriptor)
        try? FileManager.default.removeItem(at: root)
    }

    private static func compileHelper(in root: URL) throws -> String {
        let source = root.appendingPathComponent("helper.c")
        let executable = root.appendingPathComponent("helper")
        let code = """
        #include <errno.h>
        #include <fcntl.h>
        #include <stdio.h>
        #include <unistd.h>
        int main(void) {
          int first = 1;
          printf("{\\\"fds\\\":[");
          for (int fd = 0; fd < 64; fd++) {
            if (fcntl(fd, F_GETFD) >= 0 || errno != EBADF) {
              printf("%s%d", first ? "" : ",", fd);
              first = 0;
            }
          }
          printf("],\\\"pid\\\":%d,\\\"pgid\\\":%d}\\n", getpid(), getpgrp());
          fflush(stdout);
          char byte;
          (void)read(STDIN_FILENO, &byte, 1);
          return 0;
        }
        """
        try code.write(to: source, atomically: true, encoding: .utf8)
        let clang = try runAndRead(
            executablePath: "/usr/bin/xcrun",
            arguments: ["--find", "clang"]
        )
        try run(
            executablePath: clang,
            arguments: [source.path, "-o", executable.path]
        )
        return executable.path
    }

    private static func runAndRead(
        executablePath: String,
        arguments: [String]
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TestError.readFailed }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("/") else { throw TestError.readFailed }
        return value
    }

    private static func run(
        executablePath: String,
        arguments: [String]
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TestError.readFailed }
    }
}
