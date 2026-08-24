import Darwin
import Foundation
import XCTest
@testable import PulsePhoneHostPaths
@testable import PulsePhoneSharedDefinitions

final class AnchoredFileSystemTests: XCTestCase {
    private struct HomeInput: Decodable {
        let forgedEnvironmentKeys: [String]
    }

    private struct TempInput: Decodable {
        let logicalPrefix: String
    }

    private struct TempExpected: Decodable {
        let filesystemPrefix: String
    }

    private struct ForeignInput: Decodable {
        let cases: [String]
    }

    private struct ForeignExpected: Decodable {
        let repairAllowed: Bool
    }

    func testHomeAnchorIgnoresForgedEnvironment() throws {
        let fixture = try fixture("T-016/home-anchor-l2")
        XCTAssertEqual(fixture.manifest.level, "L2")
        let input = try fixture.decodeInput(HomeInput.self)
        XCTAssertEqual(input.forgedEnvironmentKeys, ["HOME", "TMPDIR", "UID"])
        let system = POSIXHostPathSystem()
        let expected = try system.trustedHomeDirectory()
        let oldHome = getenv("HOME").map { String(cString: $0) }
        let oldTemporary = getenv("TMPDIR").map { String(cString: $0) }
        let oldUserID = getenv("UID").map { String(cString: $0) }
        defer {
            restoreEnvironment("HOME", oldHome)
            restoreEnvironment("TMPDIR", oldTemporary)
            restoreEnvironment("UID", oldUserID)
        }
        setenv("HOME", "/private/tmp/forged-home", 1)
        setenv("TMPDIR", "/private/tmp/forged-tmp", 1)
        setenv("UID", "4294967295", 1)

        let anchor = try system.openHomeAnchor()
        let layout = try system.makeHostPathLayout()

        XCTAssertEqual(anchor.logicalPath, expected, fixture.manifest.caseKey)
        XCTAssertEqual(layout.homeDirectory, expected, fixture.manifest.caseKey)
        XCTAssertEqual(layout.effectiveUserID, geteuid())
    }

    func testSystemTemporaryAliasAndOwnedBaseAreValidated() throws {
        let fixture = try fixture("T-016/temp-anchor-l2")
        XCTAssertEqual(fixture.manifest.caseClass, "boundary")
        let input = try fixture.decodeInput(TempInput.self)
        let expected = try fixture.decodeExpected(TempExpected.self)
        let system = POSIXHostPathSystem()
        let anchor = try system.openTemporaryBaseAnchor()

        XCTAssertEqual(
            anchor.logicalPath,
            "\(expected.filesystemPrefix)\(geteuid())",
            fixture.manifest.caseKey
        )
        XCTAssertEqual(
            try system.makeHostPathLayout().temporaryBasePath,
            "\(input.logicalPrefix)\(geteuid())"
        )
    }

    func testForeignModeTypeSymlinkAndIdentityFailWithoutRepair() throws {
        let fixtureCase = try fixture("T-016/foreign-node-l2")
        XCTAssertEqual(fixtureCase.manifest.caseClass, "negative")
        let input = try fixtureCase.decodeInput(ForeignInput.self)
        let expected = try fixtureCase.decodeExpected(ForeignExpected.self)
        XCTAssertEqual(
            input.cases,
            ["wrongMode", "wrongOwner", "wrongKind", "symbolicLink", "identityMismatch"]
        )
        XCTAssertFalse(expected.repairAllowed)
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: fixture) }
        let fileSystem = AnchoredFileSystem()
        let root = try fileSystem.openDirectory(
            atPath: fixture,
            expecting: HostNodeExpectation(
                owner: geteuid(),
                kind: .directory,
                mode: 0o700
            )
        )

        let wrongMode = fixture + "/wrong-mode"
        XCTAssertEqual(mkdir(wrongMode, 0o755), 0)
        XCTAssertThrowsError(
            try fileSystem.openDirectory(
                named: "wrong-mode",
                relativeTo: root,
                expecting: HostNodeExpectation(
                    owner: geteuid(),
                    kind: .directory,
                    mode: 0o700
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? AnchoredFileSystemError,
                .unsafeNode(reason: .wrongMode(expected: 0o700, actual: 0o755)),
                fixtureCase.manifest.caseKey
            )
        }
        XCTAssertEqual(permissions(at: wrongMode), 0o755)

        XCTAssertThrowsError(
            try fileSystem.openDirectory(
                named: "wrong-mode",
                relativeTo: root,
                expecting: HostNodeExpectation(
                    owner: geteuid() &+ 1,
                    kind: .directory,
                    mode: 0o755
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? AnchoredFileSystemError,
                .unsafeNode(
                    reason: .wrongOwner(
                        expected: geteuid() &+ 1,
                        actual: geteuid()
                    )
                )
            )
        }

        let regular = fixture + "/regular"
        XCTAssertTrue(FileManager.default.createFile(atPath: regular, contents: Data()))
        XCTAssertThrowsError(
            try fileSystem.openDirectory(
                named: "regular",
                relativeTo: root,
                expecting: HostNodeExpectation(
                    owner: geteuid(),
                    kind: .directory,
                    mode: 0o700
                )
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: regular))

        let target = fixture + "/target"
        XCTAssertEqual(mkdir(target, 0o700), 0)
        let link = fixture + "/link"
        XCTAssertEqual(symlink(target, link), 0)
        XCTAssertThrowsError(
            try fileSystem.openDirectory(
                named: "link",
                relativeTo: root,
                expecting: HostNodeExpectation(
                    owner: geteuid(),
                    kind: .directory,
                    mode: 0o700
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? AnchoredFileSystemError,
                .unsafeNode(reason: .symbolicLink)
            )
        }
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link),
            target
        )

        let metadata = try fileSystem.validateNode(
            named: "target",
            relativeTo: root,
            expecting: HostNodeExpectation(
                owner: geteuid(),
                kind: .directory,
                mode: 0o700
            )
        )
        XCTAssertThrowsError(
            try fileSystem.validateNode(
                named: "target",
                relativeTo: root,
                expecting: HostNodeExpectation(
                    owner: geteuid(),
                    kind: .directory,
                    mode: 0o700
                ),
                identity: HostNodeIdentity(
                    device: metadata.identity.device,
                    inode: metadata.identity.inode &+ 1
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? AnchoredFileSystemError,
                .unsafeNode(reason: .identityMismatch)
            )
        }
    }

    func testComponentsCannotEscapeAnchorAndEnsureDoesNotRepair() throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: fixture) }
        let fileSystem = AnchoredFileSystem()
        let root = try fileSystem.openDirectory(
            atPath: fixture,
            expecting: HostNodeExpectation(
                owner: geteuid(),
                kind: .directory,
                mode: 0o700
            )
        )

        for component in ["", ".", "..", "a/b", "a\0b"] {
            XCTAssertThrowsError(
                try fileSystem.ensureDirectory(
                    named: component,
                    relativeTo: root,
                    owner: geteuid()
                )
            ) { error in
                XCTAssertEqual(
                    error as? AnchoredFileSystemError,
                    .unsafeNode(reason: .invalidPathComponent)
                )
            }
        }

        XCTAssertEqual(mkdir(fixture + "/foreign", 0o755), 0)
        XCTAssertThrowsError(
            try fileSystem.ensureDirectory(
                named: "foreign",
                relativeTo: root,
                owner: geteuid(),
                mode: 0o700
            )
        )
        XCTAssertEqual(permissions(at: fixture + "/foreign"), 0o755)
    }

    func testExclusiveRegularFileCreationAndReopenAreIdentityAnchored() throws {
        let fixture = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: fixture) }
        let fileSystem = AnchoredFileSystem()
        let root = try fileSystem.openDirectory(
            atPath: fixture,
            expecting: HostNodeExpectation(
                owner: geteuid(),
                kind: .directory,
                mode: 0o700
            )
        )

        let created = try fileSystem.createExclusiveRegularFile(
            named: "reservation",
            relativeTo: root,
            owner: geteuid()
        )
        let written = created.withUnsafeFileDescriptor { descriptor in
            "ok".withCString { pointer in
                Darwin.write(descriptor, pointer, 2)
            }
        }
        XCTAssertEqual(written, 2)
        XCTAssertEqual(permissions(at: fixture + "/reservation"), 0o600)

        let reopened = try fileSystem.openRegularFile(
            named: "reservation",
            relativeTo: root,
            owner: geteuid(),
            access: .readOnly
        )
        XCTAssertEqual(reopened.identity, created.identity)
        XCTAssertThrowsError(
            try fileSystem.createExclusiveRegularFile(
                named: "reservation",
                relativeTo: root,
                owner: geteuid()
            )
        ) { error in
            XCTAssertEqual(
                error as? AnchoredFileSystemError,
                .systemCall(operation: "openat-create-exclusive", errno: EEXIST)
            )
        }
    }

    private func makeTemporaryDirectory() throws -> String {
        let template = "/private/tmp/pulsephone-anchor.XXXXXX"
        var bytes = Array(template.utf8CString)
        guard let result = mkdtemp(&bytes) else {
            throw POSIXError(.EIO)
        }
        let path = String(cString: result)
        XCTAssertEqual(chmod(path, 0o700), 0)
        return path
    }

    private func permissions(at path: String) -> mode_t {
        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0)
        return status.st_mode & mode_t(0o7777)
    }

    private func restoreEnvironment(_ name: String, _ value: String?) {
        if let value {
            setenv(name, value, 1)
        } else {
            unsetenv(name)
        }
    }

    private func fixture(_ requirementID: String) throws -> FixtureCaseBundleV1 {
        try FixtureCaseLoaderV1.load(
            requirementID: requirementID,
            repositoryRoot: FixtureCaseLoaderV1.repositoryRoot(containing: #filePath)
        )
    }
}
