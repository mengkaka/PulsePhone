import Darwin
import Dispatch
import Foundation
import XCTest
@testable import PulsePhoneHostPaths
@testable import PulsePhoneRuntimeKernel
import PulsePhoneSharedDefinitions

final class RuntimeSocketWatchTests: XCTestCase {
    private struct FixtureInput: Decodable {
        let scenarios: [String]
    }

    private struct FixtureExpected: Decodable {
        let expectedRemovalFailureCount: Int
        let foreignNodeMutationAllowed: Bool
        let identityUnknownSignalAllowed: Bool
        let otherTargetEventFails: Bool
        let pidReuseSignalAllowed: Bool
        let socketReplacementTriggersFailStop: Bool
        let stableLockNodeRemoved: Bool
        let verifiedOrphanRecoveryRequired: Bool
    }

    func testListenerBindsListensAndExpectedShutdownRemovesOnlySocket() throws {
        let requirement = try requirementFixture()
        let input = try requirement.decodeInput(FixtureInput.self)
        let expected = try requirement.decodeExpected(FixtureExpected.self)
        XCTAssertEqual(
            input.scenarios,
            [
                "expectedRemoval",
                "foreignNode",
                "orphanHelpers",
                "otherTargetEvent",
                "pidReuseIdentityMismatch",
                "socketDelete",
                "socketReplace",
                "watcherInvalidation",
            ]
        )
        XCTAssertFalse(expected.foreignNodeMutationAllowed)
        XCTAssertFalse(expected.identityUnknownSignalAllowed)
        XCTAssertFalse(expected.pidReuseSignalAllowed)
        XCTAssertFalse(expected.stableLockNodeRemoved)
        XCTAssertTrue(expected.verifiedOrphanRecoveryRequired)

        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.basePath) }
        let listener = try fixture.bind { _ in
            XCTFail("expected shutdown must not fail watch")
        }
        try connect(to: fixture.socketPath)
        XCTAssertEqual(nodeMode(at: fixture.socketPath), 0o600)
        XCTAssertNotEqual(listener.socketIdentity.inode, 0)

        try listener.shutdownExpected()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.runtimeLock.path))
        XCTAssertEqual(expected.expectedRemovalFailureCount, 0)
    }

    func testForeignNodeFailsClosedWithoutMutation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.basePath) }
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: fixture.socketPath,
                contents: Data("foreign".utf8)
            )
        )
        XCTAssertEqual(chmod(fixture.socketPath, 0o600), 0)

        XCTAssertThrowsError(try fixture.bind { _ in }) { error in
            XCTAssertEqual(
                error as? RuntimeListenerError,
                .unsafeSocketNode
            )
        }
        XCTAssertEqual(
            try String(contentsOfFile: fixture.socketPath, encoding: .utf8),
            "foreign"
        )
    }

    func testSocketDeletionTriggersFailStopSignal() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.basePath) }
        let failure = expectation(description: "socket deletion")
        let listener = try fixture.bind { value in
            XCTAssertEqual(value, .socketMissing)
            failure.fulfill()
        }
        XCTAssertEqual(unlink(fixture.socketPath), 0)
        wait(for: [failure], timeout: 2)
        _ = listener
    }

    func testSocketReplacementTriggersFailStopAndIsNotDeleted() throws {
        let requirement = try requirementFixture()
        let expected = try requirement.decodeExpected(FixtureExpected.self)
        XCTAssertTrue(expected.socketReplacementTriggersFailStop)
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.basePath) }
        let failure = expectation(description: "socket replacement")
        let listener = try fixture.bind { value in
            XCTAssertEqual(value, .socketReplaced)
            failure.fulfill()
        }
        let original = listener.socketIdentity
        let replacementPath = fixture.basePath + "/replacement.sock"
        let replacement = try bindRawSocket(at: replacementPath)
        defer { _ = Darwin.close(replacement) }
        XCTAssertEqual(chmod(replacementPath, 0o600), 0)
        XCTAssertEqual(rename(replacementPath, fixture.socketPath), 0)
        wait(for: [failure], timeout: 2)

        XCTAssertThrowsError(try listener.shutdownExpected()) { error in
            XCTAssertEqual(
                error as? RuntimeListenerError,
                .socketIdentityMismatch
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.socketPath))
        XCTAssertNotEqual(identity(at: fixture.socketPath), original)
    }

    func testOtherTargetDirectoryEventOnlyRevalidatesExpectedSocket() throws {
        let requirement = try requirementFixture()
        let expected = try requirement.decodeExpected(FixtureExpected.self)
        XCTAssertFalse(expected.otherTargetEventFails)
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.basePath) }
        let noFailure = expectation(description: "other target ignored")
        noFailure.isInverted = true
        let listener = try fixture.bind { _ in noFailure.fulfill() }
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: fixture.basePath + "/other-target",
                contents: Data()
            )
        )
        wait(for: [noFailure], timeout: 0.25)
        try listener.shutdownExpected()
    }

    func testWatcherInvalidationIsDeliveredExactlyOnce() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.basePath) }
        let failure = expectation(description: "watch invalidated")
        failure.expectedFulfillmentCount = 1
        let listener = try fixture.bind { value in
            XCTAssertEqual(value, .watcherInvalidated)
            failure.fulfill()
        }
        listener.simulateWatcherInvalidationForTesting()
        listener.simulateWatcherInvalidationForTesting()
        wait(for: [failure], timeout: 1)
        try listener.shutdownExpected()
    }

    func testTrustedStaleSocketIsRemovedOnlyWhileRuntimeLockHeld() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.basePath) }
        let staleDescriptor = try bindRawSocket(at: fixture.socketPath)
        let staleIdentity = identity(at: fixture.socketPath)
        XCTAssertEqual(chmod(fixture.socketPath, 0o600), 0)
        _ = Darwin.close(staleDescriptor)

        let listener = try fixture.bind { _ in }
        XCTAssertNotEqual(listener.socketIdentity, staleIdentity)
        try listener.shutdownExpected()
    }

    private struct Fixture {
        let basePath: String
        let anchor: AnchoredDirectory
        let target: CanonicalUDID
        let runtimeLock: RuntimeLock
        let socketPath: String
        let component: String
        let queue: DispatchQueue

        func bind(
            onFailure: @escaping @Sendable (RuntimeSocketWatchFailure) -> Void
        ) throws -> RuntimeListener {
            try RuntimeListener.bind(
                for: target,
                whileHolding: runtimeLock,
                socketPath: socketPath,
                component: component,
                baseDirectoryPath: basePath,
                watchQueue: queue,
                onWatchFailure: onFailure
            )
        }
    }

    private func makeFixture() throws -> Fixture {
        let template = "/tmp/pp-l.XXXXXX"
        var bytes = Array(template.utf8CString)
        guard let result = mkdtemp(&bytes) else {
            throw POSIXError(.EIO)
        }
        let basePath = String(cString: result)
        XCTAssertEqual(chmod(basePath, 0o700), 0)
        let anchor = try AnchoredFileSystem().openDirectory(
            atPath: basePath,
            expecting: HostNodeExpectation(
                owner: geteuid(),
                kind: .directory,
                mode: 0o700
            )
        )
        let target = try CanonicalUDID(canonicalString: "SOCKET-WATCH")
        let runtimeLock = try RuntimeLock.acquire(
            for: target,
            baseDirectory: anchor
        )
        let component = target.domainSeparatedHash + ".sock"
        return Fixture(
            basePath: basePath,
            anchor: anchor,
            target: target,
            runtimeLock: runtimeLock,
            socketPath: basePath + "/" + component,
            component: component,
            queue: DispatchQueue(label: "runtime-socket-watch-tests")
        )
    }

    private func connect(to path: String) throws {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { _ = Darwin.close(descriptor) }
        var address = try makeAddress(path: path)
        let addressLength = socklen_t(address.sun_len)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, addressLength)
            }
        }
        XCTAssertEqual(result, 0)
    }

    private func bindRawSocket(at path: String) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = try makeAddress(path: path)
        let addressLength = socklen_t(address.sun_len)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, addressLength)
            }
        }
        guard result == 0 else {
            _ = Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return descriptor
    }

    private func makeAddress(path: String) throws -> sockaddr_un {
        let pathBytes = Array(path.utf8)
        let offset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)!
        let length = offset + pathBytes.count + 1
        guard length <= MemoryLayout<sockaddr_un>.size else {
            throw POSIXError(.ENAMETOOLONG)
        }
        var address = sockaddr_un()
        address.sun_len = UInt8(length)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        return address
    }

    private func identity(at path: String) -> RuntimeSocketIdentity {
        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0)
        return RuntimeSocketIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            owner: status.st_uid,
            mode: status.st_mode & mode_t(0o7777)
        )
    }

    private func nodeMode(at path: String) -> mode_t {
        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0)
        return status.st_mode & mode_t(0o7777)
    }

    private func requirementFixture() throws -> FixtureCaseBundleV1 {
        try FixtureCaseLoaderV1.load(
            requirementID: "T-007/runtime-singleton-orphan-pid-reuse-l3",
            repositoryRoot: FixtureCaseLoaderV1.repositoryRoot(containing: #filePath)
        )
    }
}
