import Foundation
import XCTest

final class GoPackagingScriptTests: XCTestCase {
    private var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url
    }

    func testPackagingBuildsSanitizedArm64GoProducts() throws {
        let script = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Scripts/package-app"),
            encoding: .utf8
        )
        for required in [
            "def candidate_build_root()",
            "def go_products(build_root: Path)",
            "GoHelpers",
            "GOENV",
            "GOWORK",
            "GOTOOLCHAIN",
            "GOFLAGS",
            "CGO_ENABLED",
            "GOOS",
            "GOARCH",
            "output_root.mkdir(mode=0o700)",
            "GOCACHE",
            "-trimpath",
            "-buildvcs=true",
            "-ldflags=-s -w",
            "PulsePhoneDirectHelper",
            "PulsePhoneCoreDeviceHelper",
            "normalize_macho",
            "verify_deterministic_macho",
            "copy_release_licenses",
            "validate_release_helper_bundle",
            "validate_bundle_mapping",
        ] {
            XCTAssertTrue(script.contains(required), required)
        }
        XCTAssertFalse(script.contains("prepare_python_runtime"))
        XCTAssertFalse(script.contains("install_python_helper"))
        XCTAssertFalse(script.contains("verify-python-runtime"))
        XCTAssertFalse(script.contains("/Users/a"))
    }

    func testGoRegistryOutputIsGeneratedFromContractSource() throws {
        let generator = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Scripts/generate-registries"),
            encoding: .utf8
        )
        for required in [
            "%w[python swift go]",
            "def go_outputs",
            "GoHelpers/internal/protocol/generated",
            "helper-wire.v1.json",
            "facts-probe-wire.v1.json",
        ] {
            XCTAssertTrue(generator.contains(required), required)
        }
    }

    func testPythonRuntimePackagingInputsAndLicensesAreAbsent() {
        let fileManager = FileManager.default
        for relativePath in [
            "Packaging/scripts/build-python",
            "Packaging/scripts/build-python-inventory",
            "Packaging/scripts/verify-python-runtime",
            "Packaging/manifests/native-wheel.manifest.json",
            "Packaging/manifests/python-dependency-inventory.json",
            "Packaging/manifests/python-lock.input.txt",
            "Packaging/manifests/python-lock.json",
            "Packaging/manifests/python-lock.requirements.txt",
            "Packaging/manifests/python-source-inventory.json",
            "Packaging/manifests/wheelhouse.manifest.json",
            "Packaging/licenses/python",
            "Packaging/licenses/runtime",
        ] {
            XCTAssertFalse(
                fileManager.fileExists(atPath: repositoryRoot.appendingPathComponent(relativePath).path),
                relativePath
            )
        }
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: repositoryRoot.appendingPathComponent("Packaging/licenses/NOTICE.txt").path
            )
        )
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: repositoryRoot.appendingPathComponent("Packaging/licenses/go/Go-LICENSE.txt").path
            )
        )
    }

    func testPythonToolingManifestIsNonReleaseAndNetworkFree() throws {
        let url = repositoryRoot.appendingPathComponent("Scripts/python-tooling-manifest.v1.json")
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["releaseIncluded"] as? Bool, false)
        XCTAssertEqual(object["sourcePolicy"] as? String, "host-provisioned-only-no-network-install")
        let interpreter = try XCTUnwrap(object["interpreter"] as? [String: Any])
        XCTAssertEqual(interpreter["path"] as? String, "/usr/bin/python3")
        XCTAssertEqual(interpreter["major"] as? Int, 3)
        XCTAssertEqual(interpreter["minor"] as? Int, 9)
        XCTAssertEqual(interpreter["source"] as? String, "Xcode-provided macOS Python")
        let profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        XCTAssertEqual(
            Set(profiles.compactMap { $0["profileID"] as? String }),
            ["contract-tooling"]
        )
        let contractTooling = try XCTUnwrap(
            profiles.first { ($0["profileID"] as? String) == "contract-tooling" }
        )
        XCTAssertEqual(contractTooling["pythonPath"] as? [String], ["Scripts/lib"])
        let contractDependencies = try XCTUnwrap(contractTooling["dependencies"] as? [[String: Any]])
        XCTAssertEqual(contractDependencies.count, 1)
        XCTAssertEqual(contractDependencies.first?["distribution"] as? String, "Python standard library")
        XCTAssertEqual(contractDependencies.first?["version"] as? String, "interpreter-provided")
        XCTAssertEqual(contractDependencies.first?["source"] as? String, "Xcode-provided macOS Python")
        XCTAssertTrue(profiles.allSatisfy { ($0["releaseIncluded"] as? Bool) == false })
        XCTAssertEqual(
            object["releaseForbidden"] as? [String],
            [
                "Python runtime",
                "Python wheels",
                "Python source",
                "Python-only licenses",
                "legacy helper entrypoints",
            ]
        )
    }
}
