import Darwin
import XCTest
@testable import PulsePhoneHostPaths
@testable import PulsePhoneSharedDefinitions

final class HostPathLayoutTests: XCTestCase {
    private struct LayoutInput: Decodable {
        let appPath: String
        let effectiveUserID: UInt32
        let home: String
        let udid: String
    }

    private struct LayoutExpected: Decodable {
        let temporaryBasePath: String
    }

    private struct PathLengthInput: Decodable {
        let effectiveUserID: UInt32
    }

    private struct PathLengthExpected: Decodable {
        let guiSocketBytes: Int
        let runtimeSocketBytes: Int
        let sunPathCapacity: Int
    }

    func testFrozenLayoutUsesCanonicalHashesAndLifecycleRoots() throws {
        let fixture = try fixture("T-016/host-path-layout-l1")
        XCTAssertEqual(fixture.manifest.level, "L1")
        let input = try fixture.decodeInput(LayoutInput.self)
        let expected = try fixture.decodeExpected(LayoutExpected.self)
        let layout = try HostPathLayoutV1(
            effectiveUserID: uid_t(input.effectiveUserID),
            trustedHomeDirectory: input.home
        )
        let udid = try CanonicalUDID(canonicalString: input.udid)
        let app = try CanonicalAppPath(
            canonicalBundlePath: input.appPath
        )
        let epoch = try CanonicalUUID(
            "123e4567-e89b-12d3-a456-426614174000"
        )
        let hash = udid.domainSeparatedHash

        XCTAssertEqual(layout.temporaryBasePath, expected.temporaryBasePath)
        XCTAssertEqual(
            try layout.runtimeSocketPath(for: udid),
            "/tmp/pulsephone-501/\(hash).sock",
            fixture.manifest.caseKey
        )
        XCTAssertEqual(
            layout.runtimeBootstrapLockPath(for: udid),
            "/tmp/pulsephone-501/\(hash).bootstrap.lock"
        )
        XCTAssertEqual(
            layout.runtimeLockPath(for: udid),
            "/tmp/pulsephone-501/\(hash).runtime.lock"
        )
        XCTAssertEqual(
            layout.helperStatePath(for: udid),
            "/tmp/pulsephone-501/\(hash).helpers.v1.json"
        )
        XCTAssertEqual(
            try layout.guiHostSocketPath(for: app),
            "/tmp/pulsephone-501/gui-\(app.guiHostHash).sock"
        )
        XCTAssertEqual(
            layout.screenshotDirectory(for: udid, runtimeEpoch: epoch),
            "/tmp/pulsephone-501/scratch/\(hash)/\(epoch)/screenshots"
        )
        XCTAssertEqual(
            layout.traceDirectory(for: udid),
            "/tmp/pulsephone-501/artifacts/\(hash)/traces"
        )
        XCTAssertEqual(
            layout.diagnosticsDirectory(for: udid),
            "/tmp/pulsephone-501/artifacts/\(hash)/diagnostics"
        )
        XCTAssertEqual(
            layout.persistentHistoryDirectory,
            "/Users/test/Library/Application Support/PulsePhone/ActionLogs"
        )
        XCTAssertEqual(
            layout.developerImageStoreDirectory,
            "/Users/test/Library/Application Support/PulsePhone/DeveloperImages"
        )
        XCTAssertEqual(
            layout.configurationDirectory,
            "/Users/test/Library/Application Support/PulsePhone/Configuration"
        )
        XCTAssertEqual(
            layout.configurationFilePath,
            "/Users/test/Library/Application Support/PulsePhone/Configuration/"
                + "configuration.v1.json"
        )
        XCTAssertEqual(
            layout.videoSourceMappingsDirectory,
            "/Users/test/Library/Application Support/PulsePhone/VideoSourceMappings"
        )
        XCTAssertEqual(
            layout.videoSourceMappingPath(for: udid),
            "/Users/test/Library/Application Support/PulsePhone/VideoSourceMappings/"
                + "\(VideoSourceMappingPathV1.targetPathKey(for: udid)).v2.json"
        )
        XCTAssertEqual(
            layout.legacyVideoSourceMappingPath(for: udid),
            "/Users/test/Library/Application Support/PulsePhone/VideoSourceMappings/"
                + "\(VideoSourceMappingPathV1.targetPathKey(for: udid)).v1.json"
        )
    }

    func testMaximumEUIDSocketPathsFitDarwinSunPathIncludingNUL() throws {
        let fixture = try fixture("T-016/path-length-l1")
        XCTAssertEqual(fixture.manifest.caseClass, "boundary")
        let input = try fixture.decodeInput(PathLengthInput.self)
        let expected = try fixture.decodeExpected(PathLengthExpected.self)
        let layout = try HostPathLayoutV1(
            effectiveUserID: uid_t(input.effectiveUserID),
            trustedHomeDirectory: "/Users/test"
        )
        let udid = try CanonicalUDID(canonicalString: "MAXIMUM")
        let app = try CanonicalAppPath(
            canonicalBundlePath: "/Applications/PulsePhone.app"
        )
        let runtime = try layout.runtimeSocketPath(for: udid)
        let gui = try layout.guiHostSocketPath(for: app)

        XCTAssertEqual(runtime.utf8.count, expected.runtimeSocketBytes, fixture.manifest.caseKey)
        XCTAssertEqual(gui.utf8.count, expected.guiSocketBytes, fixture.manifest.caseKey)
        XCTAssertEqual(HostPathLayoutV1.unixDomainSocketPathCapacity, expected.sunPathCapacity)
        XCTAssertLessThanOrEqual(
            runtime.utf8.count + 1,
            HostPathLayoutV1.unixDomainSocketPathCapacity
        )
        XCTAssertLessThanOrEqual(
            gui.utf8.count + 1,
            HostPathLayoutV1.unixDomainSocketPathCapacity
        )
    }

    func testPrivateTmpAndOversizedSocketPathsAreRejected() {
        XCTAssertThrowsError(
            try HostPathLayoutV1.validateUnixDomainSocketPath(
                "/private/tmp/pulsephone-501/value.sock"
            )
        ) { error in
            XCTAssertEqual(
                error as? HostPathLayoutError,
                .privateTemporaryPathForbidden
            )
        }

        let path = "/tmp/" + String(repeating: "x", count: 99)
        XCTAssertThrowsError(
            try HostPathLayoutV1.validateUnixDomainSocketPath(path)
        ) { error in
            XCTAssertEqual(
                error as? HostPathLayoutError,
                .unixDomainSocketPathTooLong(
                    actualByteCountIncludingNUL: path.utf8.count + 1
                )
            )
        }
    }

    private func fixture(_ requirementID: String) throws -> FixtureCaseBundleV1 {
        try FixtureCaseLoaderV1.load(
            requirementID: requirementID,
            repositoryRoot: FixtureCaseLoaderV1.repositoryRoot(containing: #filePath)
        )
    }
}
