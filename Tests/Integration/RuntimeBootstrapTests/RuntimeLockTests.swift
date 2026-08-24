import Darwin
import Foundation
import XCTest
@testable import PulsePhoneHostPaths
@testable import PulsePhoneSharedDefinitions

final class RuntimeLockTests: XCTestCase {
    func testStableLockFilesPersistAcrossAcquireRelease() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.path) }
        let target = try CanonicalUDID(canonicalString: "LOCK-STABLE")

        var bootstrap: BootstrapLock? = try BootstrapLock.acquire(
            for: target,
            baseDirectory: fixture.anchor,
            acquisition: .nonBlocking
        )
        let bootstrapIdentity = try XCTUnwrap(bootstrap).identity
        let bootstrapPath = try XCTUnwrap(bootstrap).path
        bootstrap = nil
        let bootstrapAgain = try BootstrapLock.acquire(
            for: target,
            baseDirectory: fixture.anchor,
            acquisition: .nonBlocking
        )
        XCTAssertEqual(bootstrapAgain.identity, bootstrapIdentity)
        XCTAssertEqual(permissions(at: bootstrapPath), 0o600)

        var runtime: RuntimeLock? = try RuntimeLock.acquire(
            for: target,
            baseDirectory: fixture.anchor
        )
        let runtimeIdentity = try XCTUnwrap(runtime).identity
        let runtimePath = try XCTUnwrap(runtime).path
        runtime = nil
        let runtimeAgain = try RuntimeLock.acquire(
            for: target,
            baseDirectory: fixture.anchor
        )
        XCTAssertEqual(runtimeAgain.identity, runtimeIdentity)
        XCTAssertEqual(permissions(at: runtimePath), 0o600)
    }

    func testBootstrapThenRuntimeProbeDefinesCoordinatorLockOrder() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.path) }
        let target = try CanonicalUDID(canonicalString: "LOCK-ORDER")
        let bootstrap = try BootstrapLock.acquire(
            for: target,
            baseDirectory: fixture.anchor,
            acquisition: .nonBlocking
        )
        let runtimeProbe = try RuntimeLock.probe(whileHolding: bootstrap)
        XCTAssertEqual(
            runtimeProbe.path,
            fixture.path + "/" + target.domainSeparatedHash + ".runtime.lock"
        )

        XCTAssertThrowsError(
            try RuntimeLock.acquire(
                for: target,
                baseDirectory: fixture.anchor
            )
        ) { error in
            XCTAssertEqual(
                error as? PerUDIDHostLockError,
                .busy(lock: .runtime)
            )
        }
        try bootstrap.validateStablePathIdentity()
        try runtimeProbe.validateStablePathIdentity()
    }

    func testNonBlockingLockContentionIsTyped() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.path) }
        let target = try CanonicalUDID(canonicalString: "LOCK-CONTENTION")
        let first = try BootstrapLock.acquire(
            for: target,
            baseDirectory: fixture.anchor,
            acquisition: .nonBlocking
        )
        XCTAssertNotEqual(first.identity.inode, 0)

        XCTAssertThrowsError(
            try BootstrapLock.acquire(
                for: target,
                baseDirectory: fixture.anchor,
                acquisition: .nonBlocking
            )
        ) { error in
            XCTAssertEqual(
                error as? PerUDIDHostLockError,
                .busy(lock: .bootstrap)
            )
        }
    }

    func testInheritedDescriptorKeepsRuntimeLockBusy() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.path) }
        let target = try CanonicalUDID(canonicalString: "LOCK-INHERIT")
        var runtime: RuntimeLock? = try RuntimeLock.acquire(
            for: target,
            baseDirectory: fixture.anchor
        )
        let inherited = try XCTUnwrap(runtime).duplicateForChildInheritance()
        defer { _ = Darwin.close(inherited) }
        runtime = nil

        XCTAssertThrowsError(
            try RuntimeLock.acquire(
                for: target,
                baseDirectory: fixture.anchor
            )
        ) { error in
            XCTAssertEqual(
                error as? PerUDIDHostLockError,
                .busy(lock: .runtime)
            )
        }
    }

    func testForeignLockNodesFailClosedWithoutRepair() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.path) }

        let wrongMode = try CanonicalUDID(canonicalString: "LOCK-WRONG-MODE")
        let wrongModePath = fixture.path + "/" + wrongMode.domainSeparatedHash
            + ".runtime.lock"
        XCTAssertTrue(FileManager.default.createFile(atPath: wrongModePath, contents: Data()))
        XCTAssertEqual(chmod(wrongModePath, 0o644), 0)
        XCTAssertThrowsError(
            try RuntimeLock.acquire(
                for: wrongMode,
                baseDirectory: fixture.anchor
            )
        )
        XCTAssertEqual(permissions(at: wrongModePath), 0o644)

        let wrongKind = try CanonicalUDID(canonicalString: "LOCK-WRONG-KIND")
        let wrongKindPath = fixture.path + "/" + wrongKind.domainSeparatedHash
            + ".runtime.lock"
        XCTAssertEqual(mkdir(wrongKindPath, 0o600), 0)
        XCTAssertThrowsError(
            try RuntimeLock.acquire(
                for: wrongKind,
                baseDirectory: fixture.anchor
            )
        )
        var status = stat()
        XCTAssertEqual(lstat(wrongKindPath, &status), 0)
        XCTAssertEqual(status.st_mode & mode_t(S_IFMT), mode_t(S_IFDIR))

        let symbolic = try CanonicalUDID(canonicalString: "LOCK-SYMLINK")
        let symbolicPath = fixture.path + "/" + symbolic.domainSeparatedHash
            + ".bootstrap.lock"
        XCTAssertEqual(symlink(wrongModePath, symbolicPath), 0)
        XCTAssertThrowsError(
            try BootstrapLock.acquire(
                for: symbolic,
                baseDirectory: fixture.anchor,
                acquisition: .nonBlocking
            )
        ) { error in
            XCTAssertEqual(
                error as? AnchoredFileSystemError,
                .unsafeNode(reason: .symbolicLink)
            )
        }
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: symbolicPath),
            wrongModePath
        )
    }

    func testPathReplacementIsDetectedAndNeverRemoved() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.path) }
        let target = try CanonicalUDID(canonicalString: "LOCK-REPLACED")
        let runtime = try RuntimeLock.acquire(
            for: target,
            baseDirectory: fixture.anchor
        )
        let originalIdentity = runtime.identity

        XCTAssertEqual(unlink(runtime.path), 0)
        XCTAssertTrue(FileManager.default.createFile(atPath: runtime.path, contents: Data()))
        XCTAssertEqual(chmod(runtime.path, 0o600), 0)
        XCTAssertThrowsError(try runtime.validateStablePathIdentity()) { error in
            XCTAssertEqual(
                error as? AnchoredFileSystemError,
                .unsafeNode(reason: .identityMismatch)
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.path))
        XCTAssertNotEqual(identity(at: runtime.path), originalIdentity)
    }

    func testRuntimeSocketPathUsesOnlyCanonicalTargetAndFrozenLayout() throws {
        let layout = try HostPathLayoutV1(
            effectiveUserID: uid_t(UInt32.max),
            trustedHomeDirectory: "/Users/test"
        )
        let target = try CanonicalUDID(canonicalString: "SOCKET-PATH")
        let socket = try RuntimeSocketPath(canonicalUDID: target, layout: layout)

        XCTAssertEqual(socket.component, target.domainSeparatedHash + ".sock")
        XCTAssertEqual(socket.path, layout.temporaryBasePath + "/" + socket.component)
        XCTAssertLessThanOrEqual(
            socket.path.utf8.count + 1,
            HostPathLayoutV1.unixDomainSocketPathCapacity
        )
        XCTAssertFalse(socket.path.hasPrefix("/private/tmp/"))
    }

    private func makeFixture() throws -> (path: String, anchor: AnchoredDirectory) {
        let template = "/private/tmp/pulsephone-runtime-lock.XXXXXX"
        var bytes = Array(template.utf8CString)
        guard let result = mkdtemp(&bytes) else {
            throw POSIXError(.EIO)
        }
        let path = String(cString: result)
        XCTAssertEqual(chmod(path, 0o700), 0)
        let anchor = try AnchoredFileSystem().openDirectory(
            atPath: path,
            expecting: HostNodeExpectation(
                owner: geteuid(),
                kind: .directory,
                mode: 0o700
            )
        )
        return (path, anchor)
    }

    private func permissions(at path: String) -> mode_t {
        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0)
        return status.st_mode & mode_t(0o7777)
    }

    private func identity(at path: String) -> HostNodeIdentity {
        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0)
        return HostNodeIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
    }
}
