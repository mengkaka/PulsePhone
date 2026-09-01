import Foundation
import PulsePhoneCLI
import PulsePhoneClientCore
import PulsePhoneSharedDefinitions
import XCTest

final class CLIStaticHelpTests: XCTestCase {
    func testCatalogBuildsExactlyFortyFourPublicVariantsAndSelectors() throws {
        let surface = try Self.staticSurface()
        XCTAssertEqual(surface.variants.count, 44)
        XCTAssertEqual(Set(surface.variants.map(\.commandID)).count, 44)
        XCTAssertEqual(
            try surface.resolveVariant(
                commandPath: "self install",
                arguments: []
            ).commandID,
            "self.install"
        )
        let apps = try surface.resolveVariant(commandPath: "apps", arguments: [])
        XCTAssertEqual(apps.commandID, "app.list")
        XCTAssertEqual(apps.options.map(\.spelling), ["--udid"])
        XCTAssertEqual(
            try surface.resolveVariant(
                commandPath: "runtime status",
                arguments: []
            ).commandID,
            "runtime.status.global"
        )
        XCTAssertEqual(
            try surface.resolveVariant(
                commandPath: "runtime status",
                arguments: ["--udid", "AAAA"]
            ).commandID,
            "runtime.status.device"
        )
        XCTAssertEqual(
            try surface.resolveVariant(
                commandPath: "logs clear",
                arguments: ["--all"]
            ).commandID,
            "logs.clear.all"
        )
        XCTAssertEqual(
            try surface.resolveVariant(
                commandPath: "logs clear",
                arguments: ["--udid", "AAAA"]
            ).commandID,
            "logs.clear.device"
        )
        let live = try surface.resolveVariant(
            commandPath: "live",
            arguments: ["--select-source", "--udid", "AAAA"]
        )
        XCTAssertEqual(live.commandID, "live.launch")
        XCTAssertEqual(
            live.options.map(\.spelling),
            ["--select-source", "--udid"]
        )
        XCTAssertEqual(
            try surface.resolveVariant(
                commandPath: "text key",
                arguments: ["--key", "a", "--command", "--repeat", "2"]
            ).commandID,
            "text.key"
        )
        XCTAssertEqual(
            try surface.resolveVariant(
                commandPath: "text input-source next",
                arguments: []
            ).commandID,
            "text.inputSource.next"
        )
    }

    func testEveryHelpPathAndCommandsAreStaticAndSideEffectFree() throws {
        let surface = try Self.staticSurface()
        let recorder = SideEffectRecorder()
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: { surface },
            makeQueries: {
                recorder.record("device")
                throw CLIProcessError.helperUnavailable
            },
            makeActionLogMaintenance: {
                recorder.record("logs")
                throw CLIProductionBackendError.standard(code: "internalFailure")
            },
            runtimeRequest: { _, _, _, _, _ in
                recorder.record("runtime")
                throw CLIProductionBackendError.standard(code: "runtimeFailed")
            },
            screenshotRequest: { _, _, _, _ in
                recorder.record("screenshot")
                throw CLIProductionBackendError.standard(code: "runtimeFailed")
            },
            liveOpen: { _, _, _ in
                recorder.record("gui")
                throw CLIProductionBackendError.standard(code: "guiHostUnavailable")
            }
        )

        for arguments in [["--help"], ["help"]] {
            let output = process.run(arguments: arguments)
            XCTAssertEqual(output.exitCode, 0)
            XCTAssertTrue(output.chunk.stderr.isEmpty)
            XCTAssertTrue(output.chunk.stdout[0].contains("Commands:"))
            XCTAssertTrue(output.chunk.stdout[0].contains("Configuration:"))
            XCTAssertTrue(output.chunk.stdout[0].contains("PulsePhone config --help"))
        }
        let paths = Set(surface.variants.map(\.commandPath))
        for path in paths {
            let output = process.run(arguments: path.split(separator: " ").map(String.init) + [
                "--help",
            ])
            XCTAssertEqual(output.exitCode, 0, path)
            XCTAssertTrue(output.chunk.stderr.isEmpty, path)
            XCTAssertTrue(output.chunk.stdout[0].contains("PulsePhone \(path)"), path)
        }

        let commands = process.run(arguments: ["commands", "--json"])
        XCTAssertEqual(commands.exitCode, 0)
        let envelope = try XCTUnwrap(try json(commands.chunk.stdout[0]))
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["catalogSchemaVersion"] as? Int, 1)
        XCTAssertEqual((result["commands"] as? [[String: Any]])?.count, 44)
        XCTAssertEqual(recorder.calls, [])
    }

    func testTextKeyHelpRendersTheCompleteAllowlistByCategory() throws {
        let help = try CLIHelpRenderer(surface: Self.staticSurface()).render(
            .commandPath("text key")
        )

        XCTAssertTrue(help.contains("Allowed values:"))
        let expected = Set(
            "abcdefghijklmnopqrstuvwxyz".map(String.init)
                + "0123456789".map(String.init)
                + [
                    "return", "escape", "backspace", "delete-forward", "tab",
                    "space", "minus", "equal", "left-bracket", "right-bracket",
                    "backslash", "semicolon", "quote", "grave", "comma", "period",
                    "slash", "home", "end", "page-up", "page-down", "left", "right",
                    "up", "down", "caps-lock",
                ]
        )
        XCTAssertEqual(textKeyAllowedValues(in: help), expected)
        XCTAssertFalse(help.contains("documented Text key allowlist"))
    }

    func testSharedSkillMutationOptionsStayNeutralForUninstall() throws {
        let help = try CLIHelpRenderer(surface: Self.staticSurface()).render(
            .commandPath("skill uninstall")
        )

        XCTAssertTrue(help.contains("Select this supported agent Skill target."))
        XCTAssertTrue(help.contains(
            "Allow updating or removing modified managed Skill files at selected targets."
        ))
        XCTAssertTrue(help.contains(
            "Select the portable PulsePhone skill under this custom root."
        ))
        XCTAssertFalse(help.contains("Install the PulsePhone skill"))
        XCTAssertFalse(help.contains("Install the portable PulsePhone skill"))
    }

    func testCompatibilityTextProjectsChangedStructuredFacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-CLIHelp-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(
            at: Self.repositoryRoot.appendingPathComponent("Registries"),
            to: root.appendingPathComponent("Registries")
        )
        try FileManager.default.copyItem(
            at: Self.repositoryRoot.appendingPathComponent("Schemas"),
            to: root.appendingPathComponent("Schemas")
        )
        let catalogURL = root.appendingPathComponent("Registries/command-catalog.v1.json")
        var catalog = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL))
                as? [String: Any]
        )
        var rules = try XCTUnwrap(catalog["compatibilityRules"] as? [[String: Any]])
        for index in rules.indices {
            let ruleID = rules[index]["ruleID"] as? String
            guard ruleID == "compat.product.diagnostics.start.v1"
                    || ruleID == "compat.preparation.legacy-developer.v2"
            else { continue }
            var parameters = try XCTUnwrap(rules[index]["parameters"] as? [String: Any])
            if ruleID == "compat.product.diagnostics.start.v1" {
                parameters["minimumOSMajor"] = 18
                parameters["maximumOSMajorExclusive"] = 20
                parameters["transportIDs"] = ["usb"]
            } else {
                parameters["minimumOSMajor"] = 15
            }
            rules[index]["parameters"] = parameters
        }
        catalog["compatibilityRules"] = rules
        try JSONSerialization.data(
            withJSONObject: catalog,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ).write(to: catalogURL)

        let renderer = CLIHelpRenderer(surface: try CLIStaticSurface.loading(
            repositoryRoot: root
        ))
        XCTAssertTrue(
            try renderer.render(.commandPath("diagnostics start"))
                .contains("iOS 18-19; USB iPhone")
        )
        let launch = try renderer.render(.commandPath("launch"))
        XCTAssertTrue(launch.contains("iOS 15-16; USB iPhone; classic Developer Support"))
    }

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func staticSurface() throws -> CLIStaticSurface {
        try CLIStaticSurface.loading(repositoryRoot: repositoryRoot)
    }

    private func json(_ value: String) throws -> [String: Any]? {
        try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any]
    }

    private func textKeyAllowedValues(in help: String) -> Set<String> {
        let lines = help.split(separator: "\n", omittingEmptySubsequences: false)
        guard let header = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "Allowed values:"
        }) else {
            return []
        }
        var values = [String]()
        for line in lines.dropFirst(header + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("--") { break }
            let content = trimmed.split(separator: ":", maxSplits: 1).last ?? ""
            values += content.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        }
        return Set(values)
    }
}

private final class SideEffectRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [String]()

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
