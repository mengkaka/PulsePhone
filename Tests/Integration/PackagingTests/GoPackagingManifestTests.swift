import Foundation
import XCTest

final class GoPackagingManifestTests: XCTestCase {
    private var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url
    }

    func testReleaseConfigurationHasNoEmbeddedPythonContract() throws {
        let value = try object("Packaging/manifests/ReleaseCandidateInput.configuration.v1.json")
        XCTAssertEqual(value["schemaVersion"] as? Int, 1)
        XCTAssertNil(value["pythonRuntimeExcludedRelativePaths"])
    }

    func testBundleManifestMapsOnlySignedGoHelpers() throws {
        let value = try object("Packaging/manifests/AppBundleContentManifest.mapping.v1.json")
        let rows = try XCTUnwrap(value["mappings"] as? [[String: Any]])
        let goRows = rows.filter { $0["kind"] as? String == "goProduct" }
        XCTAssertEqual(goRows.count, 2)
        XCTAssertEqual(
            Set(goRows.compactMap { $0["destination"] as? String }),
            [
                "Contents/Helpers/PulsePhoneCoreDeviceHelper",
                "Contents/Helpers/PulsePhoneDirectHelper",
            ]
        )
        XCTAssertFalse(rows.contains { ($0["destination"] as? String)?.contains("Python") == true })
        XCTAssertFalse(rows.contains { ($0["destination"] as? String)?.hasSuffix(".py") == true })
    }

    func testGoModuleUsesThePinnedToolchainWithoutExternalModules() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("GoHelpers/go.mod"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("go 1.26.0"))
        XCTAssertTrue(source.contains("toolchain go1.26.2"))
        XCTAssertFalse(source.contains("require ("))
        XCTAssertFalse(source.contains("require "))
    }

    private func object(_ path: String) throws -> [String: Any] {
        let url = repositoryRoot.appendingPathComponent(path)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}
