import PulsePhoneCLI
import XCTest

final class ArgumentPreflightTests: XCTestCase {
    func testJSONIsDetectedBeforeMalformedCommandParsing() throws {
        let surface = try Self.staticSurface()
        XCTAssertEqual(
            CLIArgumentPreflight.outputMode(in: ["unknown", "--json"]),
            .json
        )
        XCTAssertThrowsError(
            try CLIArgumentPreflight.parse(["unknown", "--json"], surface: surface)
        )
    }

    func testPublicCommandTokensAreResolvedWithoutConsumingArguments() throws {
        let surface = try Self.staticSurface()
        let invocation = try CLIArgumentPreflight.parse([
            "device", "prepare", "--udid", "AAAA", "--json",
        ], surface: surface)
        XCTAssertEqual(invocation.outputMode, .json)
        XCTAssertEqual(invocation.commandID, "device.prepare")
        XCTAssertEqual(invocation.commandToken, "device prepare")
        XCTAssertEqual(invocation.arguments, ["--udid", "AAAA"])
    }

    func testDuplicateJSONAndVerboseFailAsArguments() throws {
        let surface = try Self.staticSurface()
        XCTAssertThrowsError(
            try CLIArgumentPreflight.parse(
                ["devices", "--json", "--json"],
                surface: surface
            )
        ) { error in
            XCTAssertEqual(
                error as? CLIArgumentPreflightError,
                .duplicateJSONFlag
            )
        }
        XCTAssertThrowsError(
            try CLIArgumentPreflight.parse(["devices", "--verbose"], surface: surface)
        ) { error in
            XCTAssertEqual(
                error as? CLIArgumentPreflightError,
                .verboseUnsupported
            )
        }
    }

    private static func staticSurface() throws -> CLIStaticSurface {
        try CLIStaticSurface.loading(
            repositoryRoot: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        )
    }
}
