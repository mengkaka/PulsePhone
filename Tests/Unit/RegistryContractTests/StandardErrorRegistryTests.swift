import Darwin
import Foundation
import XCTest
@testable import PulsePhoneSharedDefinitions

final class StandardErrorRegistryTests: XCTestCase {
    private static let familyCodes: [String: [String]] = [
        "internal": [
            "internalFailure", "preparationFailed", "cleanupTimeout",
        ],
        "argument": [
            "invalidArgument", "argumentTooLarge", "planTooLarge",
            "invalidCoordinate", "invalidDuration", "invalidBundleID",
            "invalidIPAPath", "invalidOutputPath", "invalidUDID",
        ],
        "targetCompatibility": [
            "noDeviceConnected", "deviceNotFound", "duplicateCanonicalUDID",
            "unsupportedDeviceClass", "unsupportedOSVersion",
            "unsupportedTransport",
        ],
        "runtimeProtocol": [
            "runtimeNotRunning", "runtimeFailed", "runtimeStartupTimeout",
            "incompatibleRuntime", "unsupportedBootstrapOperation",
            "protocolViolation", "transportFailure", "guiHostUnavailable",
            "guiIPCFailure", "unsafeHostPath",
        ],
        "admissionBusy": [
            "queueFull", "resourceBusy", "admissionCapacityExceeded",
            "aggregateTargetLimitExceeded", "capabilityPreparing",
            "runtimeStopping", "controlBusy", "incompatibleRuntimeBusy",
            "orphanHelperGenerationBusy", "liveAlreadyOpen",
            "liveOwnerConflict", "guiHostBusy", "traceAlreadyActive",
            "diagnosticsAlreadyActive", "keyboardInteractionBackpressure",
        ],
        "knownCommandFailure": [
            "capabilityUnavailable", "deviceNotTrusted", "deviceLocked",
            "deviceDisconnected", "deviceEnumerationLimitExceeded",
            "executionTimeout", "backendFailed", "artifactValidationFailed",
            "artifactTooLarge", "unsupportedScreenshotFormat",
            "partialFailure", "probeUnavailable", "windowCreateFailed",
            "localOpenSettingsFailed", "traceWriteFailed", "noActiveTrace",
            "diagnosticWriteFailed", "noActiveDiagnostics", "invalidIPA",
            "installFailed", "uninstallFailed", "appNotInstalled",
            "appLaunchFailed", "developerSupportUnavailable",
            "developerImageCandidateIncompatible", "developerImageCatalogMismatch",
            "developerImageCatalogUnavailable", "matchingDDIUnavailable",
            "unsupportedPreparationGroup",
            "developerImageDownloadFailed", "developerImageIntegrityFailed",
            "developerImageCacheCapacityExceeded", "developerModeRequired",
            "personalizationServiceUnavailable", "developerImageMountFailed",
            "developerServicesUnavailable", "preparationTimeout",
            "outputExists", "localWriteFailed", "timedOut",
        ],
        "unknownOutcome": ["outcomeUnknown", "guiLaunchOutcomeUnknown"],
        "interrupted": ["interrupted", "cancellationUnknown"],
    ]

    private static let familyExitCodes: [String: UInt64] = [
        "internal": 1,
        "argument": 2,
        "targetCompatibility": 3,
        "runtimeProtocol": 4,
        "admissionBusy": 5,
        "knownCommandFailure": 6,
        "unknownOutcome": 7,
        "interrupted": 130,
    ]

    private static let requiredRetryable: Set<String> = [
        "noDeviceConnected", "runtimeStartupTimeout", "transportFailure",
        "runtimeNotRunning", "runtimeFailed", "developerImageDownloadFailed",
        "developerImageCandidateIncompatible", "developerImageCatalogUnavailable",
        "matchingDDIUnavailable",
        "personalizationServiceUnavailable", "preparationTimeout",
        "deviceDisconnected", "probeUnavailable",
    ]

    private static let requiredNonRetryable: Set<String> = [
        "unsupportedDeviceClass", "unsupportedOSVersion",
        "incompatibleRuntime", "unsupportedBootstrapOperation",
        "protocolViolation", "unsafeHostPath", "artifactValidationFailed",
        "developerImageCatalogMismatch", "developerImageIntegrityFailed",
        "unsupportedScreenshotFormat", "invalidIPA", "outputExists",
    ]

    func testRegistryHasExactCodesFamiliesAndRequiredFields() throws {
        let registry = try loadCanonicalObject(registryURL())
        XCTAssertEqual(try string(registry, "setID"), "standardErrorRegistry")
        XCTAssertEqual(
            try string(registry, "revision"),
            "standard-errors.v3-20260822"
        )
        XCTAssertEqual(try uint64(registry, "schemaVersion"), 1)

        let entries = try array(registry, "entries").map(requiredObject)
        XCTAssertEqual(entries.count, 87)
        let expected = Dictionary(
            uniqueKeysWithValues: Self.familyCodes.flatMap { family, codes in
                codes.map { ($0, family) }
            }
        )
        XCTAssertEqual(expected.count, 87)

        let allowedEntryKeys: Set<String> = [
            "allowedCommitStates", "allowedLifecyclePhases", "allowedOutcomes",
            "clientContinuationProjectionPolicy", "code", "defaultCLIExit",
            "defaultMessage", "detailsSchemaID", "family", "retryable",
            "visibility",
        ]
        var actualCodes = [String]()
        for entry in entries {
            XCTAssertEqual(Set(entry.members.map(\.key)), allowedEntryKeys)
            let code = try string(entry, "code")
            let family = try string(entry, "family")
            actualCodes.append(code)
            XCTAssertEqual(family, expected[code], code)
            XCTAssertEqual(
                try uint64(entry, "defaultCLIExit"),
                Self.familyExitCodes[family],
                code
            )
            XCTAssertFalse(try string(entry, "defaultMessage").isEmpty, code)
            XCTAssertTrue(["public", "internal"].contains(try string(entry, "visibility")))
            _ = try bool(entry, "retryable")
            try assertSortedUniqueStrings(entry, key: "allowedCommitStates")
            try assertSortedUniqueStrings(entry, key: "allowedLifecyclePhases")
            try assertSortedUniqueStrings(entry, key: "allowedOutcomes")
        }

        XCTAssertEqual(actualCodes, actualCodes.sorted(by: asciiLessThan))
        XCTAssertEqual(Set(actualCodes), Set(expected.keys))
    }

    func testRetryDetailsOutcomeAndContinuationRules() throws {
        let entries = try array(
            loadCanonicalObject(registryURL()),
            "entries"
        ).map(requiredObject)
        let byCode = Dictionary(
            uniqueKeysWithValues: try entries.map { entry in
                (try string(entry, "code"), entry)
            }
        )

        for code in Self.requiredRetryable {
            XCTAssertTrue(try bool(XCTUnwrap(byCode[code]), "retryable"), code)
        }
        for code in Self.requiredNonRetryable {
            XCTAssertFalse(try bool(XCTUnwrap(byCode[code]), "retryable"), code)
        }
        for code in Self.familyCodes["admissionBusy"]! {
            XCTAssertTrue(try bool(XCTUnwrap(byCode[code]), "retryable"), code)
        }
        for family in ["argument", "interrupted", "unknownOutcome"] {
            for code in Self.familyCodes[family]! {
                XCTAssertFalse(
                    try bool(XCTUnwrap(byCode[code]), "retryable"),
                    code
                )
            }
        }

        XCTAssertEqual(
            try string(XCTUnwrap(byCode["partialFailure"]), "detailsSchemaID"),
            "aggregatePartial.v1"
        )
        XCTAssertEqual(
            try strings(XCTUnwrap(byCode["partialFailure"]), "allowedOutcomes"),
            ["partial"]
        )
        XCTAssertEqual(
            try string(XCTUnwrap(byCode["outcomeUnknown"]), "detailsSchemaID"),
            "unknownOutcome.v1"
        )
        XCTAssertEqual(
            try strings(XCTUnwrap(byCode["outcomeUnknown"]), "allowedOutcomes"),
            ["outcomeUnknown"]
        )
        XCTAssertEqual(
            try string(XCTUnwrap(byCode["unsafeHostPath"]), "detailsSchemaID"),
            "hostPath.v1"
        )
        XCTAssertEqual(
            try string(
                XCTUnwrap(byCode["developerImageIntegrityFailed"]),
                "detailsSchemaID"
            ),
            "developerSupport.v1"
        )

        let policies = Set(try strings(loadCanonicalObject(registryURL()), "clientContinuationProjectionPolicies"))
        for entry in entries {
            XCTAssertTrue(
                policies.contains(try string(entry, "clientContinuationProjectionPolicy"))
            )
        }
    }

    func testDetailsSchemasAreExactClosedAndPrivacyBounded() throws {
        let registry = try loadCanonicalObject(registryURL())
        let referenced = Set(
            try array(registry, "entries").map(requiredObject).map {
                try string($0, "detailsSchemaID")
            }
        )
        let expectedIDs: Set<String> = [
            "aggregatePartial.v1", "argument.v1", "artifact.v1",
            "backendStage.v1", "capability.v1", "developerSupport.v1",
            "guiHost.v1", "hostPath.v1", "limit.v1", "none.v1", "probe.v1",
            "runtimeCompatibility.v1", "stopBlockers.v1", "target.v1",
            "unknownOutcome.v1",
        ]
        XCTAssertEqual(referenced, expectedIDs)

        let schemaFiles = try FileManager.default.contentsOfDirectory(
            at: detailsDirectoryURL(),
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ).filter { $0.pathExtension == "json" }
        XCTAssertEqual(schemaFiles.count, 15)

        var schemaIDs = Set<String>()
        for url in schemaFiles {
            let schema = try loadCanonicalObject(url)
            let schemaID = try string(schema, "$id")
            XCTAssertTrue(schemaIDs.insert(schemaID).inserted)
            XCTAssertEqual(
                try string(schema, "$schema"),
                "https://json-schema.org/draft/2020-12/schema"
            )
            if schemaID == "none.v1" {
                XCTAssertEqual(try uint64(schema, "x-pulsephone-maxEncodedBytes"), 0)
            } else {
                XCTAssertFalse(try bool(schema, "additionalProperties"))
                XCTAssertGreaterThan(
                    try uint64(schema, "x-pulsephone-maxEncodedBytes"),
                    0
                )
            }
        }
        XCTAssertEqual(schemaIDs, expectedIDs)

        let hostPath = try loadSchema(id: "hostPath.v1")
        let hostProperties = try objectValue(hostPath, "properties")
        XCTAssertEqual(
            Set(try enumStrings(try objectValue(hostProperties, "pathClass"))),
            [
                "actionLog", "developerImageStore", "diagnostics",
                "helperManifest", "lock", "screenshotReservation", "socket",
                "tempAnchor", "tempBase", "trace",
            ]
        )
        XCTAssertEqual(
            Set(try enumStrings(try objectValue(hostProperties, "reason"))),
            [
                "anchorInvalid", "inodeMismatch", "modeMismatch",
                "outsideBase", "ownerMismatch", "symlink", "typeMismatch",
            ]
        )

        let developerSupport = try loadSchema(id: "developerSupport.v1")
        let developerProperties = Set(
            try objectValue(developerSupport, "properties").members.map(\.key)
        )
        for forbidden in [
            "url", "path", "hash", "ecid", "nonce", "ticket", "rawException",
        ] {
            XCTAssertFalse(developerProperties.contains(forbidden))
        }
    }

    func testArtifactSetIdentityAndTreeNodeSafety() throws {
        let schemaPaths = try FileManager.default.contentsOfDirectory(
                at: detailsDirectoryURL(),
                includingPropertiesForKeys: nil
            )
            .filter { $0.pathExtension == "json" }
            .map { "Schemas/details-schemas/\($0.lastPathComponent)" }
        let paths = ["Registries/standard-errors.v1.json"] + schemaPaths
        let sortedPaths = paths.sorted(by: asciiLessThan)
        XCTAssertEqual(sortedPaths.count, 16)

        var identities = Set<String>()
        var artifactEntries = [RepositoryJSONValue]()
        for relativePath in sortedPaths {
            let url = packageRootURL().appendingPathComponent(relativePath)
            var status = stat()
            XCTAssertEqual(lstat(url.path, &status), 0, relativePath)
            XCTAssertEqual(status.st_mode & mode_t(S_IFMT), mode_t(S_IFREG))
            XCTAssertEqual(status.st_nlink, 1, relativePath)
            XCTAssertTrue(
                identities.insert("\(status.st_dev):\(status.st_ino)").inserted
            )

            let bytes = [UInt8](try Data(contentsOf: url))
            _ = try RepositoryCanonicalJSON.validateCanonicalDocument(
                bytes,
                maximumByteCount: 1 << 20
            )
            let entry = try RepositoryJSONObject(
                members: [
                    RepositoryJSONMember(
                        key: "relativePath",
                        value: .string(relativePath)
                    ),
                    RepositoryJSONMember(
                        key: "sha256",
                        value: .string(StableBytes.sha256Hex(bytes))
                    ),
                ]
            )
            artifactEntries.append(.object(entry))
        }

        let artifactSet = try RepositoryJSONObject(
            members: [
                RepositoryJSONMember(key: "entries", value: .array(artifactEntries)),
                RepositoryJSONMember(
                    key: "revision",
                    value: .string("standard-errors.v3-20260822")
                ),
                RepositoryJSONMember(
                    key: "schemaVersion",
                    value: .number(.uint64(1))
                ),
                RepositoryJSONMember(
                    key: "setID",
                    value: .string("standardErrorRegistry")
                ),
            ]
        )
        let bytes = RepositoryCanonicalJSON.encodeDocument(artifactSet)
        XCTAssertEqual(
            StableBytes.sha256Hex(bytes),
            "753bbbbde92f2a9220f94000ad9e1d8546731e14e76e55f8be69fec600f44db8"
        )
        XCTAssertEqual(
            try StableBytes.domainSeparatedSHA256Hex(
                domainID: "pulsephone.standard-error-registry-set.v1",
                payload: bytes
            ),
            "0e9cdbee93d04400aa6dee3edc3e24f3e613d5eba77a3ecf0d825429bfe7dbde"
        )
    }

    private func loadSchema(id: String) throws -> RepositoryJSONObject {
        let fileName = id + ".schema.json"
        return try loadCanonicalObject(detailsDirectoryURL().appendingPathComponent(fileName))
    }

    private func loadCanonicalObject(_ url: URL) throws -> RepositoryJSONObject {
        let bytes = [UInt8](try Data(contentsOf: url))
        return try RepositoryCanonicalJSON.validateCanonicalDocument(
            bytes,
            maximumByteCount: 1 << 20
        ).root
    }

    private func registryURL() -> URL {
        packageRootURL().appendingPathComponent("Registries/standard-errors.v1.json")
    }

    private func detailsDirectoryURL() -> URL {
        packageRootURL().appendingPathComponent("Schemas/details-schemas")
    }

    private func packageRootURL() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 {
            root.deleteLastPathComponent()
        }
        return root
    }

    private func requiredObject(
        _ value: RepositoryJSONValue
    ) throws -> RepositoryJSONObject {
        try XCTUnwrap(value.objectValue)
    }

    private func objectValue(
        _ object: RepositoryJSONObject,
        _ key: String
    ) throws -> RepositoryJSONObject {
        try requiredObject(XCTUnwrap(object[key]))
    }

    private func array(
        _ object: RepositoryJSONObject,
        _ key: String
    ) throws -> [RepositoryJSONValue] {
        try XCTUnwrap(object[key]?.arrayValue)
    }

    private func string(
        _ object: RepositoryJSONObject,
        _ key: String
    ) throws -> String {
        try XCTUnwrap(object[key]?.stringValue)
    }

    private func strings(
        _ object: RepositoryJSONObject,
        _ key: String
    ) throws -> [String] {
        try array(object, key).map { try XCTUnwrap($0.stringValue) }
    }

    private func uint64(
        _ object: RepositoryJSONObject,
        _ key: String
    ) throws -> UInt64 {
        try XCTUnwrap(object[key]?.numberValue).requireUInt64()
    }

    private func bool(
        _ object: RepositoryJSONObject,
        _ key: String
    ) throws -> Bool {
        guard case .bool(let value) = try XCTUnwrap(object[key]) else {
            throw RepositoryCanonicalJSONError.invalidSyntax(byteOffset: 0)
        }
        return value
    }

    private func enumStrings(_ schema: RepositoryJSONObject) throws -> [String] {
        try strings(schema, "enum")
    }

    private func assertSortedUniqueStrings(
        _ object: RepositoryJSONObject,
        key: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let values = try strings(object, key)
        XCTAssertEqual(
            values,
            values.sorted(by: asciiLessThan),
            file: file,
            line: line
        )
        XCTAssertEqual(Set(values).count, values.count, file: file, line: line)
    }

    private func asciiLessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}
