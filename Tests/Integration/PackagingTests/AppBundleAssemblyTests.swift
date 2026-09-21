import CryptoKit
import Foundation
import XCTest

final class AppBundleAssemblyTests: XCTestCase {
    private var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 {
            url.deleteLastPathComponent()
        }
        return url
    }

    func testBundleMappingIsCanonicalClosedAndMatchesTRDLayout() throws {
        let data = try file("Packaging/manifests/AppBundleContentManifest.mapping.v1.json")
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let canonical = try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        XCTAssertEqual(data, canonical)
        XCTAssertEqual(value["schemaVersion"] as? Int, 1)
        XCTAssertEqual(value["bundleRoot"] as? String, "PulsePhone.app")
        let rows = try XCTUnwrap(value["mappings"] as? [[String: Any]])
        let destinations = Set(rows.compactMap { $0["destination"] as? String })
        XCTAssertEqual(destinations, [
            "Contents/Helpers/PulsePhoneCoreDeviceHelper",
            "Contents/Helpers/PulsePhoneDirectHelper",
            "Contents/Helpers/PulsePhoneRuntime",
            "Contents/Info.plist",
            "Contents/MacOS/PulsePhone",
            "Contents/Resources/AgentSkills/codex/pulsephone/agents/openai.yaml",
            "Contents/Resources/AgentSkills/portable/pulsephone/SKILL.md",
            "Contents/Resources/Licenses/",
            "Contents/Resources/Registries/",
            "Contents/Resources/Schemas/",
        ])
        let sources = rows.compactMap { $0["source"] as? String }
        XCTAssertFalse(sources.contains { $0.hasPrefix("Verification/") })
        XCTAssertFalse(sources.contains { $0.hasPrefix("Fixtures/") })
        XCTAssertFalse(sources.contains { $0.hasPrefix("Tests/") })
        XCTAssertFalse(sources.contains { $0.hasPrefix("dist/") })
        let helpers = rows.filter { $0["kind"] as? String == "goProduct" }
        XCTAssertEqual(helpers.count, 2)
        XCTAssertEqual(
            Set(helpers.compactMap { $0["source"] as? String }),
            [
                "build/go/release/PulsePhoneCoreDeviceHelper",
                "build/go/release/PulsePhoneDirectHelper",
            ]
        )
    }

    func testReleaseCandidateConfigurationFreezesDevelopmentIdentityAndFiniteCeiling() throws {
        let data = try file("Packaging/manifests/ReleaseCandidateInput.configuration.v1.json")
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            data,
            try JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        )
        XCTAssertEqual(value["schemaVersion"] as? Int, 1)
        XCTAssertEqual(value["appVersion"] as? String, "0.2.2")
        XCTAssertEqual(value["buildID"] as? String, "1")
        XCTAssertEqual(value["deviceClass"] as? String, "iPhone")
        XCTAssertEqual(value["deviceOSMinimumInclusive"] as? String, "14.0.0")
        XCTAssertEqual(value["deviceOSMaximumExclusive"] as? String, "27.0.0")
        XCTAssertNil(value["pythonRuntimeExcludedRelativePaths"])
        let info = try XCTUnwrap(value["infoPlist"] as? [String: Any])
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "PulsePhone")
        XCTAssertEqual(info["LSMinimumSystemVersion"] as? String, "14.0")
        XCTAssertEqual(info["NSCameraUseContinuityCameraDeviceType"] as? Bool, true)
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, value["appVersion"] as? String)
        XCTAssertEqual(info["CFBundleVersion"] as? String, value["buildID"] as? String)
    }

    func testPackageAppSelfTestClosesSafeNodeAndManifestBoundaries() throws {
        let process = Process()
        process.executableURL = repositoryRoot.appendingPathComponent("Scripts/package-app")
        process.arguments = ["--self-test"]
        process.currentDirectoryURL = repositoryRoot
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(data: errorData, encoding: .utf8) ?? ""
        )
        let resultData = output.fileHandleForReading.readDataToEndOfFile()
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: resultData) as? [String: Any])
        XCTAssertEqual(result["schemaVersion"] as? Int, 1)
        XCTAssertEqual(result["outcome"] as? String, "passed")
        XCTAssertEqual(result["tests"] as? Int, 32)
    }

    func testReleaseAppSelfTestValidatesReleaseOnlyBoundaries() throws {
        let process = Process()
        process.executableURL = repositoryRoot.appendingPathComponent("Scripts/release-app")
        process.arguments = ["--self-test"]
        process.currentDirectoryURL = repositoryRoot
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(data: errorData, encoding: .utf8) ?? ""
        )
        let resultData = output.fileHandleForReading.readDataToEndOfFile()
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: resultData) as? [String: Any])
        XCTAssertEqual(result["schemaVersion"] as? Int, 1)
        XCTAssertEqual(result["outcome"] as? String, "passed")
        XCTAssertEqual(result["tests"] as? Int, 7)
    }

    func testDevRebuildLiveSelfTestClosesProcessSelectionAndTargetPaths() throws {
        let process = Process()
        process.executableURL = repositoryRoot.appendingPathComponent(
            "Scripts/dev-rebuild-live"
        )
        process.arguments = ["--self-test"]
        process.currentDirectoryURL = repositoryRoot
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(data: errorData, encoding: .utf8) ?? ""
        )
        let resultData = output.fileHandleForReading.readDataToEndOfFile()
        let result = try XCTUnwrap(
            JSONSerialization.jsonObject(with: resultData) as? [String: Any]
        )
        XCTAssertEqual(result["schemaVersion"] as? Int, 1)
        XCTAssertEqual(result["outcome"] as? String, "passed")
        XCTAssertEqual(result["tests"] as? Int, 6)
    }

    func testPackageAppSourceFreezesDomainsCapsAndCleanProducerRules() throws {
        let data = try file("Scripts/package-app")
        let source = try XCTUnwrap(String(data: data, encoding: .utf8))
        for required in [
            "pulsephone.app-bundle-content.v1\\0",
            "pulsephone.release-candidate-input.v1\\0",
            "pulsephone.artifact-path-key.v1\\0",
            "developmentCandidateInput",
            "MAX_ENTRIES = 65_536",
            "MAX_MANIFEST_BYTES = 32 * 1024 * 1024",
            "package-app requires a clean worktree",
            "hardlinked bundle file",
            "outside symlink target",
            "GoHelpers/go.mod",
            "go_products",
            "CGO_ENABLED",
            "Contents/Helpers/PulsePhoneDirectHelper",
            "Contents/Helpers/PulsePhoneCoreDeviceHelper",
            "-buildvcs=true",
            "-debug-info-format",
            "--jobs",
            "-no-whole-module-optimization",
            "-num-threads",
            "package-app-cold",
            "GOCACHE",
            "component_code_directory_hashes",
            "verify_cold_reproducibility",
            "--verify-cold-reproducibility",
            "content-derived Mach-O UUID",
            "--timestamp=none",
            "PULSEPHONE_DEVELOPMENT_SIGNING_IDENTITY",
            ".pulsephone-local/development-signing.json",
            "development signing identity must be a 40-character SHA-1 fingerprint",
            "expected exactly one LC_UUID",
            "path-bearing Mach-O symbols",
            "candidateKind\": \"developmentAssembly",
            "active staging process prevents publication",
            "before_publish",
            "Scripts/dev-rebuild-live",
            "skills/pulsephone/SKILL.md",
            "Contents/Resources/AgentSkills",
            "AgentSkills/portable/pulsephone/SKILL.md",
            "AgentSkills/codex/pulsephone/agents/openai.yaml",
            "validate_agent_skill_resources",
        ] {
            XCTAssertTrue(source.contains(required), required)
        }
        XCTAssertFalse(source.contains("/Users/a"))
        XCTAssertFalse(source.contains("scan latest"))
    }

    func testPortableAgentSkillUsesNormalizedIdentityAndGlobalCLIOnly() throws {
        let data = try file("skills/pulsephone/SKILL.md")
        let source = try XCTUnwrap(String(data: data, encoding: .utf8))
        for required in [
            "name: pulsephone",
            "globally installed `PulsePhone` CLI",
            "PulsePhone version --json",
            "reinstall this skill from a complete\nPulsePhone.app with `skill install`",
            "PulsePhone devices --json",
            "PulsePhone element snapshot --udid <UDID>",
            "center.normalized.x",
            "does not install WebDriver or\nan XCTest Runner",
            "PulsePhone tap --x <NORMALIZED_X> --y <NORMALIZED_Y>",
            "`--force` only permits an\natomic replacement",
        ] {
            XCTAssertTrue(source.contains(required), required)
        }
        for forbidden in [
            "node scripts/cli.js",
            "element find",
            "element click",
            "screen parse",
            "action tap",
            "name: phlusephone",
            "bin/PulsePhone.app",
            "self install",
        ] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }

    func testPackageAppSealsCompleteBundleBeforeManifestAndVerifiesNestedCode() throws {
        let data = try file("Scripts/package-app")
        let source = try XCTUnwrap(String(data: data, encoding: .utf8))
        let packageStart = try XCTUnwrap(source.range(of: "def package_app("))
        let packageEnd = try XCTUnwrap(
            source.range(of: "\ndef inspect_tree", range: packageStart.upperBound..<source.endIndex)
        )
        let packageSource = String(source[packageStart.lowerBound..<packageEnd.lowerBound])

        let assembly = try index("app = assemble_app", in: packageSource)
        let candidateBuild = try index("build_root = candidate_build_root()", in: packageSource)
        let goBuild = try index("products.update(go_products(build_root))", in: packageSource)
        let outerSeal = try index("seal_app_bundle(app, configuration, signing_identity)", in: packageSource)
        let cliEntryPoints = try index("verify_cli_entrypoints(app, configuration)", in: packageSource)
        let manifest = try index("manifest = content_manifest(app)", in: packageSource)
        XCTAssertLessThan(candidateBuild, goBuild)
        XCTAssertLessThan(goBuild, assembly)
        XCTAssertLessThan(assembly, outerSeal)
        XCTAssertLessThan(outerSeal, cliEntryPoints)
        XCTAssertLessThan(cliEntryPoints, manifest)

        let stagingPublish = try index("publish_staging(app)", in: packageSource)
        XCTAssertLessThan(manifest, stagingPublish)

        for required in [
            "def seal_app_bundle(",
            "def verify_cli_entrypoints(",
            "launcher.symlink_to(executable)",
            "cli_output(launcher, [\"--help\"])",
            "cli_output(launcher, [\"version\", \"--json\"])",
            "bundle_identifier = configuration.get(\"bundleIdentifier\")",
            "def bundle_codesign_arguments(",
            "\"--options\", \"runtime\"",
            "hardened runtime signing options",
            "bundle_codesign_arguments(signing_identity, bundle_identifier, app)",
            "Contents/_CodeSignature/CodeResources",
            "PulsePhoneDirectHelper", "PulsePhoneCoreDeviceHelper",
            "\"--verify\", \"--strict\", str(runtime)",
            "\"--verify\", \"--deep\", \"--strict\", str(app)",
        ] {
            XCTAssertTrue(source.contains(required), required)
        }
    }

    private func file(_ path: String) throws -> Data {
        try Data(contentsOf: repositoryRoot.appendingPathComponent(path))
    }

    private func index(_ needle: String, in haystack: String) throws -> String.Index {
        try XCTUnwrap(haystack.range(of: needle)?.lowerBound, needle)
    }
}
