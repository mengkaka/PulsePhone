import Foundation
import PulsePhoneBackendAdapters
import PulsePhoneCLI
import PulsePhoneCommandCatalog
import PulsePhoneCommandPlanner
import PulsePhoneSharedDefinitions
import XCTest

final class ProductActionTests: XCTestCase {
    func testBundledPublicSurfaceUsesProductionRoutes() throws {
        let package = Process()
        package.executableURL = Self.repositoryRoot.appendingPathComponent(
            "Scripts/package-app"
        )
        package.arguments = ["--objects-root", "build/evidence/objects"]
        package.currentDirectoryURL = Self.repositoryRoot
        let packageOutput = Pipe()
        package.standardOutput = packageOutput
        package.standardError = packageOutput
        try package.run()
        package.waitUntilExit()
        let packageText = String(
            decoding: packageOutput.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(package.terminationStatus, 0, packageText)

        let smoke = Process()
        smoke.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        smoke.arguments = [
            Self.repositoryRoot.appendingPathComponent(
                "Tests/Integration/ProductMatrixTests/product_matrix.py"
            ).path,
            "--smoke-bundle",
            Self.repositoryRoot.appendingPathComponent(
                "build/staging/PulsePhone.app"
            ).path,
        ]
        smoke.currentDirectoryURL = Self.repositoryRoot
        let smokeOutput = Pipe()
        smoke.standardOutput = smokeOutput
        smoke.standardError = smokeOutput
        try smoke.run()
        smoke.waitUntilExit()
        let smokeText = String(
            decoding: smokeOutput.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(smoke.terminationStatus, 0, smokeText)
        XCTAssertEqual(
            smokeText,
            "pulsephone-bundled-public-surface.v1 state=passed variants=44\n"
        )
    }

    func testGeneratedPublicProjectionAndReadmeAreCurrent() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            Self.repositoryRoot
                .appendingPathComponent(
                    "Tests/Integration/ProductMatrixTests/product_matrix.py"
                ).path,
            "--check",
        ]
        process.currentDirectoryURL = Self.repositoryRoot
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertEqual(
            text,
            "pulsephone-product-matrix.v1 state=passed files=29\n"
        )
    }

    func testCatalogCLIAndGUISurfaceProjection() throws {
        let fixture = try object("Fixtures/product-matrix/public-surface.v1.json")
        let catalog = try CommandCatalog.load(repositoryRoot: Self.repositoryRoot)
        let counts = try dictionary(fixture, key: "counts")
        XCTAssertEqual(try integer(counts, key: "productActions"), 52)
        XCTAssertEqual(try integer(counts, key: "supportingActions"), 21)
        XCTAssertEqual(try integer(counts, key: "features"), 6)
        XCTAssertEqual(try integer(counts, key: "publicCLIVariants"), 44)
        XCTAssertEqual(try integer(counts, key: "guiToolbarWindow"), 14)
        XCTAssertEqual(try integer(counts, key: "ownerBoundInteractions"), 2)
        XCTAssertEqual(catalog.productActions.count, 52)
        XCTAssertEqual(catalog.supportingActions.count, 21)
        XCTAssertEqual(catalog.features.count, 6)

        let cliRows = try dictionaries(fixture, key: "cliRows")
        XCTAssertEqual(
            cliRows.map { $0["commandID"] as? String },
            catalog.productActions
                .filter { $0.exposures.contains(.cli) }
                .map(\.commandID)
        )
        for row in cliRows {
            let invocation = try string(row, key: "invocation")
                .split(separator: " ").map(String.init)
            let parsed = try CLIArgumentPreflight.parse(
                invocation,
                surface: try CLIStaticSurface.loading(repositoryRoot: Self.repositoryRoot)
            )
            XCTAssertEqual(parsed.commandToken, try string(row, key: "commandToken"))
        }

        let guiRows = try dictionaries(fixture, key: "guiRows")
        XCTAssertEqual(guiRows.count, 16)
        XCTAssertEqual(
            guiRows.filter { $0["kind"] as? String == "toolbar" }.count,
            12
        )
        XCTAssertEqual(
            guiRows.filter { $0["kind"] as? String == "window" }.count,
            2
        )
        XCTAssertEqual(
            guiRows.filter {
                $0["kind"] as? String == "ownerBoundInteraction"
            }.count,
            2
        )
    }

    func testCommandCapsAndNoRetryProjection() throws {
        let fixture = try object("Fixtures/product-matrix/behavior-matrix.v1.json")
        let caps = try dictionary(fixture, key: "parameterCaps")
        XCTAssertEqual(
            try integer(caps, key: "afcChunkBytes"),
            AFCUploadAction.maximumChunkBytes
        )
        XCTAssertEqual(
            try integer(caps, key: "textUTF8Bytes"),
            TextTypeAction.maximumUTF8Bytes
        )
        XCTAssertEqual(
            try integer(caps, key: "textKeyboardCount"),
            Int(TextKeyboardContract.maximumRepeatCount)
        )
        XCTAssertEqual(
            try integer(caps, key: "linearGestureFrameIntervalMilliseconds"),
            Int(LinearGesturePlanner.productionLimits.frameIntervalMilliseconds)
        )
        XCTAssertEqual(
            try integer(caps, key: "linearGestureMaximumFrames"),
            LinearGesturePlanner.productionLimits.maximumFrames
        )
        XCTAssertEqual(
            try integer(caps, key: "linearGestureMaximumPayloadBytes"),
            LinearGesturePlanner.productionLimits.maximumPayloadBytes
        )
        XCTAssertNoThrow(try ArgumentNormalizer.normalize(
            schemaID: "linearGesture.v1",
            raw: ["durationMs": "30000", "from": "0,0", "to": "1,1"]
        ))
        XCTAssertThrowsError(try ArgumentNormalizer.normalize(
            schemaID: "linearGesture.v1",
            raw: ["durationMs": "30001", "from": "0,0", "to": "1,1"]
        ))

        let catalog = try ExecutionProfileCatalog.load(
            repositoryRoot: Self.repositoryRoot
        )
        let retryRows = try dictionaries(fixture, key: "automaticRetryRows")
        let expected = Dictionary(uniqueKeysWithValues: retryRows.map {
            (try! string($0, key: "commandID"),
             try! string($0, key: "automaticRetryPolicy"))
        })
        XCTAssertEqual(expected.count, 19)
        for row in catalog.expandedProductActions where expected[row.command.commandID] != nil {
            XCTAssertEqual(
                row.executionProfile.automaticRetryPolicy.rawValue,
                expected[row.command.commandID]
            )
        }
        XCTAssertTrue(expected.values.allSatisfy { $0 == "never" })
    }

    func testDeviceCommandOracleProjection() throws {
        let fixture = try object("Fixtures/product-matrix/behavior-matrix.v1.json")
        let expected = try dictionaries(fixture, key: "deviceCommandOracleRows")
        let catalog = try ExecutionProfileCatalog.load(
            repositoryRoot: Self.repositoryRoot
        )
        let actual: [[String: Any]] = catalog.expandedProductActions.compactMap { row in
            guard !row.policyBindings.candidateOrderIDs.isEmpty else { return nil }
            return [
                "candidateOrderIDs": row.policyBindings.candidateOrderIDs,
                "commandID": row.command.commandID,
                "fallbackPolicyID": row.policyBindings.fallbackPolicyID,
                "preparationGroupIDs": row.policyBindings.preparationGroupIDs,
            ]
        }
        XCTAssertEqual(
            try canonicalData(actual),
            try canonicalData(expected)
        )
    }

    func testPublicCLIHumanJSONProjection() throws {
        let fixture = try object("Fixtures/product-matrix/public-surface.v1.json")
        for row in try dictionaries(fixture, key: "cliRows") {
            let commandID = try string(row, key: "commandID")
            let human = try CLIOutputAdapter(mode: .human).success(
                commandID: commandID,
                target: .global,
                result: MatrixResult(disposition: "verified"),
                human: "verified"
            )
            XCTAssertEqual(human.exitCode, 0)
            XCTAssertEqual(human.chunk.stdout, ["verified"])
            XCTAssertTrue(human.chunk.stderr.isEmpty)

            let json = try CLIOutputAdapter(mode: .json).success(
                commandID: commandID,
                target: .global,
                result: MatrixResult(disposition: "verified"),
                human: "ignored"
            )
            XCTAssertEqual(json.exitCode, 0)
            XCTAssertEqual(json.chunk.stdout.count, 1)
            XCTAssertTrue(json.chunk.stderr.isEmpty)
            let envelope = try JSONSerialization.jsonObject(
                with: Data(json.chunk.stdout[0].utf8)
            ) as? [String: Any]
            XCTAssertEqual(envelope?["commandID"] as? String, commandID)
            XCTAssertEqual(envelope?["ok"] as? Bool, true)
            XCTAssertEqual(envelope?["schemaVersion"] as? Int, 1)
        }
    }

    func testIntegrationCoverageAnchorsAndRequirementFixtures() throws {
        let coverage = try object(
            "Fixtures/product-matrix/integration-coverage.v1.json"
        )
        let criteria = try dictionaries(coverage, key: "criteria")
        XCTAssertEqual(criteria.map { $0["criterionID"] as? String }, [
            "contract", "targetSafety", "gui", "cli", "lifecycle",
        ])
        for criterion in criteria {
            for path in try strings(criterion, key: "anchorPaths") {
                XCTAssertTrue(
                    FileManager.default.fileExists(
                        atPath: Self.repositoryRoot.appendingPathComponent(path).path
                    ),
                    path
                )
            }
        }
        for requirementID in Self.requirementIDs {
            let root = "Fixtures/requirements/\(requirementID)"
            _ = try object("\(root)/case.v1.json")
            _ = try object("\(root)/expected.v1.json")
            _ = try object("\(root)/input/input.v1.json")
        }
    }

    private struct MatrixResult: Codable {
        let disposition: String
    }

    private static let requirementIDs = [
        "T-005/legacy-basic-command-matrix-l4",
        "T-006/command-parameter-cap-mapping-matrix-l1",
        "T-006/device-command-oracle-matrix-l4",
        "T-006/mutating-command-no-automatic-retry-l3",
        "T-006/text-ipa-bounded-streaming-l4",
        "T-009/gui-help-docs-catalog-projection-l5",
        "T-012/public-command-human-json-result-l5",
    ]

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func object(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(
            contentsOf: Self.repositoryRoot.appendingPathComponent(relativePath)
        )
        _ = try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](data),
            maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
        )
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func dictionary(
        _ object: [String: Any],
        key: String
    ) throws -> [String: Any] {
        try XCTUnwrap(object[key] as? [String: Any])
    }

    private func dictionaries(
        _ object: [String: Any],
        key: String
    ) throws -> [[String: Any]] {
        try XCTUnwrap(object[key] as? [[String: Any]])
    }

    private func strings(
        _ object: [String: Any],
        key: String
    ) throws -> [String] {
        try XCTUnwrap(object[key] as? [String])
    }

    private func string(
        _ object: [String: Any],
        key: String
    ) throws -> String {
        try XCTUnwrap(object[key] as? String)
    }

    private func integer(
        _ object: [String: Any],
        key: String
    ) throws -> Int {
        try XCTUnwrap(object[key] as? Int)
    }

    private func canonicalData(_ value: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}
