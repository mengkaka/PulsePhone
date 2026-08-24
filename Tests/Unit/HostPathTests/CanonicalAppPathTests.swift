import Darwin
import Foundation
import XCTest
@testable import PulsePhoneHostPaths
@testable import PulsePhoneSharedDefinitions

final class CanonicalAppPathTests: XCTestCase {
    private struct SyntaxValidInput: Decodable {
        let path: String
    }

    private struct SyntaxValidExpected: Decodable {
        let guiHostHash: String
    }

    private struct SyntaxInvalidInput: Decodable {
        let paths: [String]
    }

    private struct ResolverValidInput: Decodable {
        let bundleSuffix: String
    }

    private struct ResolverInvalidInput: Decodable {
        let wrongSuffix: String
    }

    func testCanonicalSyntaxPreservesFilesystemBytesAndHash() throws {
        let fixture = try fixture("T-016/canonical-app-path-syntax-valid-l1")
        XCTAssertEqual(fixture.manifest.level, "L1")
        let input = try fixture.decodeInput(SyntaxValidInput.self)
        let expected = try fixture.decodeExpected(SyntaxValidExpected.self)
        let canonical = try CanonicalAppPath(canonicalBundlePath: input.path)

        XCTAssertEqual(canonical.bundlePath, input.path, fixture.manifest.caseKey)
        XCTAssertEqual(
            canonical.guiHostHash,
            expected.guiHostHash
        )
    }

    func testCanonicalSyntaxRejectsUntrustedShapes() throws {
        let fixture = try fixture("T-016/canonical-app-path-syntax-invalid-l1")
        XCTAssertEqual(fixture.manifest.caseClass, "negative")
        for path in try fixture.decodeInput(SyntaxInvalidInput.self).paths {
            XCTAssertThrowsError(
                try CanonicalAppPath(canonicalBundlePath: path),
                "\(fixture.manifest.caseKey): \(path)"
            ) { error in
                XCTAssertEqual(error as? CanonicalAppPathError, .invalidSyntax)
            }
        }
    }

    func testResolverUsesFilesystemPathAndExactBundleSuffix() throws {
        let fixtureCase = try fixture("T-016/canonical-app-path-resolver-valid-l2")
        XCTAssertEqual(fixtureCase.manifest.level, "L2")
        let input = try fixtureCase.decodeInput(ResolverValidInput.self)
        let filesystemFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: filesystemFixture.root) }
        XCTAssertTrue(filesystemFixture.executable.hasSuffix(input.bundleSuffix))

        let canonical = try CanonicalAppPath.resolve(
            executablePath: filesystemFixture.executable
        )

        XCTAssertEqual(
            canonical.bundlePath,
            filesystemFixture.bundle,
            fixtureCase.manifest.caseKey
        )
        XCTAssertEqual(canonical.bundleURL.path, filesystemFixture.bundle)
        XCTAssertEqual(
            canonical.resourcesURL.path,
            filesystemFixture.bundle + "/Contents/Resources"
        )
    }

    func testResolverDerivesBundleResourcesFromSymlinkTarget() throws {
        let filesystemFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: filesystemFixture.root) }
        let link = filesystemFixture.root + "/PulsePhone"
        XCTAssertEqual(symlink(filesystemFixture.executable, link), 0)

        let canonical = try CanonicalAppPath.resolve(executablePath: link)

        XCTAssertEqual(canonical.bundlePath, filesystemFixture.bundle)
        XCTAssertEqual(
            canonical.resourcesURL.path,
            filesystemFixture.bundle + "/Contents/Resources"
        )
    }

    func testCurrentExecutableLookupDoesNotUseCallerEnvironment() throws {
        let system = POSIXHostPathSystem()
        let expected = try system.currentExecutablePath()
        let oldPath = getenv("PATH").map { String(cString: $0) }
        let oldWorkingDirectory = getenv("PWD").map { String(cString: $0) }
        defer {
            restoreEnvironment("PATH", oldPath)
            restoreEnvironment("PWD", oldWorkingDirectory)
        }
        setenv("PATH", "/nonexistent", 1)
        setenv("PWD", "/private/tmp", 1)

        XCTAssertTrue(expected.hasPrefix("/"))
        XCTAssertEqual(try system.currentExecutablePath(), expected)
    }

    func testResolverRejectsWrongSuffixDirectoryAndSymlink() throws {
        let fixtureCase = try fixture("T-016/canonical-app-path-resolver-invalid-l2")
        XCTAssertEqual(fixtureCase.manifest.caseClass, "negative")
        let input = try fixtureCase.decodeInput(ResolverInvalidInput.self)
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let wrong = root + input.wrongSuffix
        try FileManager.default.createDirectory(
            atPath: (wrong as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: wrong, contents: Data()))
        XCTAssertThrowsError(try CanonicalAppPath.resolve(executablePath: wrong)) {
            error in
            XCTAssertEqual(
                error as? CanonicalAppPathError,
                .bundleSuffixMismatch,
                fixtureCase.manifest.caseKey
            )
        }

        let directory = root + "/PulsePhone.app/Contents/MacOS/PulsePhone"
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        XCTAssertThrowsError(try CanonicalAppPath.resolve(executablePath: directory)) {
            error in
            XCTAssertEqual(
                error as? CanonicalAppPathError,
                .executableNotRegularFile
            )
        }

        let link = root + "/link"
        XCTAssertEqual(symlink(wrong, link), 0)
        XCTAssertThrowsError(try CanonicalAppPath.resolve(executablePath: link)) {
            error in
            XCTAssertEqual(error as? CanonicalAppPathError, .bundleSuffixMismatch)
        }
    }

    private func makeFixture() throws -> (root: String, bundle: String, executable: String) {
        let root = try makeTemporaryDirectory()
        let bundle = root + "/Moved Path/PulsePhone.app"
        let executable = bundle + "/Contents/MacOS/PulsePhone"
        try FileManager.default.createDirectory(
            atPath: (executable as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        XCTAssertTrue(
            FileManager.default.createFile(atPath: executable, contents: Data([0x01]))
        )
        return (root, bundle, executable)
    }

    private func makeTemporaryDirectory() throws -> String {
        let template = "/private/tmp/pulsephone-canonical.XXXXXX"
        var bytes = Array(template.utf8CString)
        guard let result = mkdtemp(&bytes) else {
            throw POSIXError(.EIO)
        }
        return String(cString: result)
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
