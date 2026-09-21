import Foundation
@testable import PulsePhoneCLI
@testable import PulsePhoneHostPaths
import PulsePhoneSharedDefinitions
import XCTest

final class PulsePhoneConfigCommandTests: XCTestCase {
    func testConfigSetGetClearUseWhitelistedManagedStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhoneCLI-OmniParser-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PulsePhoneConfigurationStore(rootURL: root)
        let adapter = CLIOutputAdapter(mode: .json)

        let set = try XCTUnwrap(PulsePhoneConfigCommand.dispatch(
            arguments: ["config", "set", "omniparser.endpoint", "https://omni.example.test/parse/", "--json"],
            adapter: adapter,
            store: store
        ))
        XCTAssertEqual(set.exitCode, 0)
        XCTAssertTrue(set.chunk.stdout[0].contains("\"effectiveAt\":\"newRuntime\""))
        XCTAssertEqual(
            try store.load().values["omniparser.endpoint"],
            .string("https://omni.example.test/parse/")
        )

        let show = try XCTUnwrap(PulsePhoneConfigCommand.dispatch(
            arguments: ["config", "get", "omniparser.endpoint", "--json"],
            adapter: adapter,
            store: store
        ))
        XCTAssertTrue(show.chunk.stdout[0].contains("\"state\":\"configured\""))

        let clear = try XCTUnwrap(PulsePhoneConfigCommand.dispatch(
            arguments: ["config", "clear", "omniparser.endpoint", "--json"],
            adapter: adapter,
            store: store
        ))
        XCTAssertEqual(clear.exitCode, 0)
        XCTAssertTrue(clear.chunk.stdout[0].contains("\"effectiveAt\":\"newRuntime\""))
        XCTAssertNil(try store.load().values["omniparser.endpoint"])
    }

    func testInvalidValueUsesPublicArgumentFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhoneCLI-Config-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try XCTUnwrap(PulsePhoneConfigCommand.dispatch(
            arguments: ["config", "set", "omniparser.endpoint", "not-a-url", "--json"],
            adapter: CLIOutputAdapter(mode: .json),
            store: PulsePhoneConfigurationStore(rootURL: root)
        ))
        XCTAssertEqual(output.exitCode, ErrorFamily.argument.exitCode)
        XCTAssertTrue(output.chunk.stdout[0].contains("\"commandID\":\"config.set\""))
        XCTAssertTrue(output.chunk.stdout[0].contains("\"code\":\"invalidArgument\""))
    }

    func testDeveloperImageDevCatalogUsesStrictBooleanConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhoneCLI-DeveloperImage-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PulsePhoneConfigurationStore(rootURL: root)
        let adapter = CLIOutputAdapter(mode: .json)

        let set = try XCTUnwrap(PulsePhoneConfigCommand.dispatch(
            arguments: ["config", "set", "developerImage.useDevCatalog", "TrUe", "--json"],
            adapter: adapter,
            store: store
        ))
        XCTAssertEqual(set.exitCode, 0)
        XCTAssertEqual(
            try store.load().values["developerImage.useDevCatalog"],
            .boolean(true)
        )

        let invalid = try XCTUnwrap(PulsePhoneConfigCommand.dispatch(
            arguments: ["config", "set", "developerImage.useDevCatalog", "yes", "--json"],
            adapter: adapter,
            store: store
        ))
        XCTAssertEqual(invalid.exitCode, ErrorFamily.argument.exitCode)
        XCTAssertTrue(invalid.chunk.stdout[0].contains("\"code\":\"invalidArgument\""))
    }

    func testHelpConfigUsesConfigurationHelp() throws {
        let output = try XCTUnwrap(PulsePhoneConfigCommand.dispatch(
            arguments: ["help", "config"],
            adapter: CLIOutputAdapter(mode: .human)
        ))

        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.chunk.stdout, [PulsePhoneConfigCommand.help])
    }
}
