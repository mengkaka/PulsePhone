import Darwin
import Foundation
import XCTest
@testable import PulsePhoneSharedDefinitions

final class WireRegistryTests: XCTestCase {
    private static let registryFiles = [
        "facts-probe-wire.v1.json",
        "guihost-wire.v1.json",
        "helper-wire.v1.json",
        "runtime-operations.v1.json",
        "runtime-wire-messages.v1.json",
    ]

    private static let schemaFiles = [
        "facts-probe-wire.v1.schema.json",
        "guihost-wire.v1.schema.json",
        "helper-wire.v1.schema.json",
        "runtime-operations.v1.schema.json",
        "runtime-wire.v1.schema.json",
    ]

    private static let runtimeMessageTypes: [String: UInt64] = [
        "AggregateResponse": 0x0108,
        "ArtifactFD": 0x0107,
        "BootstrapRequestV1": 0x0010,
        "BootstrapResponseV1": 0x0011,
        "Hello": 0x0001,
        "HelloAck": 0x0002,
        "HelloReject": 0x0003,
        "ObservationStreamReset": 0x0105,
        "Progress": 0x0103,
        "ProtocolError": 0x0004,
        "Request": 0x0100,
        "Response": 0x0101,
        "RuntimeEvent": 0x0102,
        "RuntimeObservation": 0x0104,
        "StreamFrame": 0x0106,
    ]

    private static let runtimeOperationIDs: Set<String> = [
        "command.submit",
        "runtime.attachLive",
        "runtime.cancelOwnedPendingWork",
        "runtime.clearActionLogs",
        "runtime.detachLive",
        "runtime.getAvailabilitySnapshot",
        "runtime.health",
        "runtime.markLiveCaptureReady",
        "runtime.prepareCapabilities",
        "runtime.recordLocalAction",
        "runtime.runtimeStatus",
        "runtime.startDiagnostics",
        "runtime.startReplayTrace",
        "runtime.stopDiagnostics",
        "runtime.stopIfIdle",
        "runtime.stopReplayTrace",
        "stream.cancel",
        "stream.close",
        "stream.open",
    ]

    func testRegistryHeadersEntriesAndReferencesAreExact() throws {
        let expectedIDs: [String: String] = [
            "facts-probe-wire.v1.json": "factsProbeWire",
            "guihost-wire.v1.json": "guiHostWire",
            "helper-wire.v1.json": "helperWire",
            "runtime-operations.v1.json": "runtimeOperations",
            "runtime-wire-messages.v1.json": "runtimeWireMessages",
        ]
        let expectedCounts: [String: Int] = [
            "facts-probe-wire.v1.json": 2,
            "guihost-wire.v1.json": 6,
            "helper-wire.v1.json": 17,
            "runtime-operations.v1.json": 19,
            "runtime-wire-messages.v1.json": 15,
        ]
        let allowedEntryKeys: Set<String> = [
            "allowedConnectionStates", "allowedErrorCodes",
            "allowedEventKinds", "association", "direction", "fdPolicy",
            "id", "numericMessageType", "payloadLimitClass",
            "requestSchemaID", "responseSchemaID", "terminalPolicy",
        ]
        let standardCodes = try standardErrorCodes()

        for fileName in Self.registryFiles {
            let registry = try loadCanonicalObject(registryURL(fileName))
            XCTAssertEqual(try string(registry, "registryID"), expectedIDs[fileName])
            XCTAssertEqual(try string(registry, "revision"), "wire-registry.v9-20260822")
            XCTAssertEqual(try uint64(registry, "protocolMajor"), 1)
            XCTAssertEqual(try uint64(registry, "registryVersion"), 2)

            let entries = try array(registry, "entries").map(requiredObject)
            XCTAssertEqual(entries.count, expectedCounts[fileName])
            let ids = try entries.map { try string($0, "id") }
            XCTAssertEqual(ids, ids.sorted(by: asciiLessThan))
            XCTAssertEqual(Set(ids).count, ids.count)

            for entry in entries {
                let entryID = try string(entry, "id")
                XCTAssertTrue(Set(entry.members.map(\.key)).isSubset(of: allowedEntryKeys))
                for requiredKey in [
                    "allowedConnectionStates", "allowedErrorCodes",
                    "allowedEventKinds", "association", "direction", "fdPolicy",
                    "id", "payloadLimitClass", "terminalPolicy",
                ] {
                    XCTAssertNotNil(entry[requiredKey], "\(fileName):\(entryID)")
                }
                try assertSortedUniqueStrings(entry, key: "allowedConnectionStates")
                try assertSortedUniqueStrings(entry, key: "allowedErrorCodes")
                try assertSortedUniqueStrings(entry, key: "allowedEventKinds")
                for code in try strings(entry, "allowedErrorCodes") {
                    XCTAssertTrue(standardCodes.contains(code), "\(fileName):\(code)")
                }
            }
        }
    }

    func testRuntimeMessagesOperationsAndPreparationAuthority() throws {
        let messages = try entries("runtime-wire-messages.v1.json")
        let messagesByID = try byID(messages)
        XCTAssertEqual(Set(messagesByID.keys), Set(Self.runtimeMessageTypes.keys))
        for (id, numericType) in Self.runtimeMessageTypes {
            XCTAssertEqual(try uint64(XCTUnwrap(messagesByID[id]), "numericMessageType"), numericType)
        }
        XCTAssertEqual(try string(XCTUnwrap(messagesByID["ArtifactFD"]), "fdPolicy"), "exactlyOneReadOnlyPNG")
        XCTAssertEqual(try string(XCTUnwrap(messagesByID["StreamFrame"]), "terminalPolicy"), "oneWay")
        XCTAssertEqual(try string(XCTUnwrap(messagesByID["StreamFrame"]), "payloadLimitClass"), "streamFrame8KiB")
        XCTAssertEqual(try strings(XCTUnwrap(messagesByID["AggregateResponse"]), "allowedConnectionStates"), [])
        XCTAssertEqual(try string(XCTUnwrap(messagesByID["AggregateResponse"]), "direction"), "none")
        XCTAssertEqual(
            Set(try strings(XCTUnwrap(messagesByID["RuntimeEvent"]), "allowedEventKinds")),
            [
                "availabilityInvalidated", "deviceDisconnected",
                "operationAccepted", "operationQueued", "operationStarted",
                "preparationStarted", "runtimeFatal", "streamClosed",
            ]
        )

        let operations = try entries("runtime-operations.v1.json")
        let operationsByID = try byID(operations)
        XCTAssertEqual(Set(operationsByID.keys), Self.runtimeOperationIDs)
        let recordLocal = try XCTUnwrap(operationsByID["runtime.recordLocalAction"])
        XCTAssertEqual(try string(recordLocal, "terminalPolicy"), "oneWay")
        XCTAssertNil(recordLocal["responseSchemaID"])
        XCTAssertEqual(try strings(recordLocal, "allowedErrorCodes"), [])

        let prepareEntry = try XCTUnwrap(operationsByID["runtime.prepareCapabilities"])
        XCTAssertEqual(try string(prepareEntry, "requestSchemaID"), "prepareCapabilitiesRequest.v1")
        XCTAssertEqual(try string(prepareEntry, "responseSchemaID"), "preparationResult.v1")
        XCTAssertEqual(try strings(prepareEntry, "allowedEventKinds"), ["preparationStarted"])
        XCTAssertTrue(
            try strings(prepareEntry, "allowedErrorCodes").contains(
                "capabilityPreparing"
            )
        )

        let definitions = try schemaDefinitions()
        let geometryFields: Set<String> = [
            "connectionEpoch", "geometryRevision", "logicalHeight",
            "logicalWidth", "orientation",
        ]
        let captureReady = try XCTUnwrap(
            definitions["markLiveCaptureReadyResult.v1"]
        )
        XCTAssertEqual(
            Set(try objectValue(captureReady, "properties").members.map(\.key)),
            geometryFields.union([
                "captureProvenance", "disposition",
                "newExecutorGeneration", "oldExecutorGeneration",
            ])
        )
        XCTAssertEqual(
            Set(try strings(captureReady, "required")),
            ["captureProvenance", "connectionEpoch", "disposition"]
        )
        let streamOpen = try XCTUnwrap(definitions["streamOpenResult.v1"])
        XCTAssertEqual(
            Set(try objectValue(streamOpen, "properties").members.map(\.key)),
            geometryFields.union([
                "actionID", "executorGeneration", "interactionID",
                "openedAtMonotonicNs", "sessionID",
            ])
        )
        XCTAssertEqual(
            Set(try strings(streamOpen, "required")),
            [
                "actionID", "executorGeneration", "interactionID",
                "openedAtMonotonicNs", "sessionID",
            ]
        )
        let prepare = try XCTUnwrap(definitions["prepareCapabilitiesRequest.v1"])
        XCTAssertEqual(
            Set(try objectValue(prepare, "properties").members.map(\.key)),
            ["actionContext", "canonicalUDID", "mode"]
        )
        XCTAssertEqual(try strings(prepare, "required"), ["canonicalUDID"])
        XCTAssertEqual(
            try strings(prepare, "x-pulsephone-forbiddenClientFields"),
            ["group", "internalReason", "path", "preparationGroupID", "reason", "source", "url"]
        )

        let progress = try XCTUnwrap(definitions["preparationProgress.v1"])
        XCTAssertEqual(
            Set(try objectValue(progress, "properties").members.map(\.key)),
            [
                "completedBytes", "fraction", "phase", "phaseSequence",
                "preparationAttemptID", "preparationGroupID", "retryAfterMs",
                "sharedAcquisition", "sourceKind", "stateRevision", "totalBytes",
            ]
        )
        let result = try XCTUnwrap(definitions["preparationResult.v1"])
        XCTAssertEqual(
            Set(try objectValue(result, "properties").members.map(\.key)),
            [
                "assetDisposition", "capabilityIDs", "connectionEpoch",
                "disposition", "executorGeneration", "mountDisposition",
                "preparationAttemptID", "preparationGroupID", "provenance",
                "serviceDisposition",
            ]
        )
        XCTAssertTrue(try bool(result, "x-pulsephone-successValueOnly"))
        let status = try XCTUnwrap(definitions["preparationStatus.v1"])
        XCTAssertEqual(
            Set(try objectValue(status, "properties").members.map(\.key)),
            [
                "capabilityIDs", "connectionEpoch", "lastError", "phase",
                "preparationAttemptID", "preparationGroupID", "progress",
                "state", "truncated",
            ]
        )
    }

    func testGUIHostBootstrapHelperAndFactsProbeBoundaries() throws {
        let messages = try byID(entries("runtime-wire-messages.v1.json"))
        XCTAssertEqual(
            try strings(XCTUnwrap(messages["BootstrapResponseV1"]), "allowedErrorCodes"),
            [
                "incompatibleRuntimeBusy", "noActiveTrace", "runtimeFailed",
                "traceWriteFailed", "unsupportedBootstrapOperation",
            ]
        )

        let gui = try byID(entries("guihost-wire.v1.json"))
        XCTAssertEqual(Set(gui.keys), ["Hello", "HelloAck", "HelloReject", "OpenLive", "OpenLiveResult", "ProtocolError"])
        XCTAssertEqual(
            try strings(XCTUnwrap(gui["OpenLiveResult"]), "allowedErrorCodes"),
            ["guiHostBusy", "liveAlreadyOpen", "windowCreateFailed"]
        )
        XCTAssertEqual(try string(XCTUnwrap(gui["OpenLive"]), "payloadLimitClass"), "guiHostPayload16KiB")
        XCTAssertEqual(try string(XCTUnwrap(gui["OpenLiveResult"]), "payloadLimitClass"), "guiHostPayload16KiB")
        XCTAssertEqual(try string(XCTUnwrap(gui["OpenLive"]), "requestSchemaID"), "openLive.v2")
        XCTAssertEqual(try string(XCTUnwrap(gui["OpenLiveResult"]), "responseSchemaID"), "openLiveResult.v2")
        XCTAssertFalse(try strings(XCTUnwrap(gui["HelloReject"]), "allowedConnectionStates").contains("bootstrapOnly"))

        let helper = try byID(entries("helper-wire.v1.json"))
        XCTAssertEqual(
            Set(helper.keys),
            [
                "Accepted", "Cancel", "Close", "Committed", "DeviceDisconnected",
                "Frame", "FrameAccepted", "Hello", "HelloAccepted", "Progress",
                "ProtocolError", "Ready", "Request", "Result", "Shutdown",
                "Started", "StreamOpen",
            ]
        )
        XCTAssertEqual(try string(XCTUnwrap(helper["Frame"]), "terminalPolicy"), "perFrameAck")
        XCTAssertEqual(try string(XCTUnwrap(helper["Frame"]), "payloadLimitClass"), "streamFrame8KiB")
        XCTAssertEqual(try string(XCTUnwrap(helper["Progress"]), "payloadLimitClass"), "progress16KiB")
        XCTAssertEqual(try string(XCTUnwrap(helper["Request"]), "payloadLimitClass"), "helperMessage512KiB")
        XCTAssertEqual(try string(XCTUnwrap(helper["Result"]), "payloadLimitClass"), "helperResult256KiB")
        XCTAssertEqual(try strings(XCTUnwrap(helper["Hello"]), "allowedConnectionStates"), ["preAccepted"])
        XCTAssertEqual(try strings(XCTUnwrap(helper["Ready"]), "allowedConnectionStates"), ["accepted"])

        let facts = try byID(entries("facts-probe-wire.v1.json"))
        XCTAssertEqual(Set(facts.keys), ["enumerate", "probe"])
        for entry in facts.values {
            XCTAssertEqual(try string(entry, "terminalPolicy"), "exactlyOneResponse")
            XCTAssertEqual(try strings(entry, "allowedConnectionStates"), ["singleRequest"])
            XCTAssertEqual(
                try string(entry, "payloadLimitClass"),
                "factsProbeRequest16KiBResponse256KiB"
            )
        }

        let definitions = try schemaDefinitions()
        let developerSupport = try XCTUnwrap(definitions["developerSupportRequest.v1"])
        XCTAssertEqual(
            Set(try objectValue(developerSupport, "properties").members.map(\.key)),
            [
                "assetContentManifestSHA256", "catalogCanonicalSHA256",
                "catalogRevision", "deviceContext", "fileRoles", "operation",
                "preparationAttemptID", "preparationGroupID",
            ]
        )
        let roleSchema = try objectValue(try objectValue(developerSupport, "properties"), "fileRoles")
        let roleItems = try objectValue(roleSchema, "items")
        XCTAssertEqual(
            try strings(roleItems, "enum"),
            [
                "classic.image", "classic.signature", "personalized.buildManifest",
                "personalized.image", "personalized.trustCache",
            ]
        )
        for forbidden in ["absolutePath", "clientPath", "ecid", "nonce", "path", "sourceURL", "ticket", "url"] {
            XCTAssertNil(try objectValue(developerSupport, "properties")[forbidden])
        }

        for id in [
            "factsProbeEnumerateRequest.v1", "factsProbeEnumerateResponse.v1",
            "factsProbeProbeRequest.v1", "factsProbeProbeResponse.v1",
        ] {
            let properties = try objectValue(XCTUnwrap(definitions[id]), "properties")
            for forbidden in ["actionID", "executorGeneration", "runtimeEpoch", "runtimeState"] {
                XCTAssertNil(properties[forbidden], "\(id):\(forbidden)")
            }
        }

        let runtimeHello = try objectValue(XCTUnwrap(definitions["runtimeHello.v1"]), "properties")
        let guiHello = try objectValue(XCTUnwrap(definitions["guiHostHello.v1"]), "properties")
        XCTAssertNil(runtimeHello["canonicalAppPathHash"])
        XCTAssertNil(runtimeHello["developerImageCatalogHash"])
        XCTAssertNil(runtimeHello["developerImageCatalogRevision"])
        XCTAssertNil(guiHello["canonicalUDID"])
        XCTAssertNil(guiHello["developerImageCatalogHash"])
        XCTAssertEqual(try uint64(XCTUnwrap(definitions["streamFrame.v1"]), "x-pulsephone-maxEncodedBytes"), 8_192)
        XCTAssertEqual(try uint64(XCTUnwrap(definitions["helperProgress.v1"]), "x-pulsephone-maxEncodedBytes"), 16_384)
        XCTAssertEqual(try uint64(XCTUnwrap(definitions["helperRequest.v1"]), "x-pulsephone-maxEncodedBytes"), 524_288)
        XCTAssertEqual(try uint64(XCTUnwrap(definitions["helperResult.v1"]), "x-pulsephone-maxEncodedBytes"), 262_144)
    }

    func testSchemaSetsAreClosedUniqueAndReferenceComplete() throws {
        let directoryFiles = try FileManager.default.contentsOfDirectory(
            at: schemaDirectoryURL(),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }.map(\.lastPathComponent).sorted(by: asciiLessThan)
        XCTAssertEqual(directoryFiles, Self.schemaFiles)

        let definitions = try schemaDefinitions()
        XCTAssertEqual(definitions.count, 90)
        let rootIDs: Set<String> = [
            "factsProbeWireSchemaSet.v1", "guiHostWireSchemaSet.v1",
            "helperWireSchemaSet.v1", "runtimeOperationsSchemaSet.v1",
            "runtimeWireSchemaSet.v1",
        ]
        for (id, definition) in definitions {
            XCTAssertFalse(try bool(definition, "additionalProperties"), id)
            XCTAssertEqual(try string(definition, "$id"), id)
        }

        var references = Set<String>()
        for fileName in Self.registryFiles {
            for entry in try entries(fileName) {
                for key in ["requestSchemaID", "responseSchemaID"] {
                    if let value = entry[key]?.stringValue {
                        references.insert(value)
                    }
                }
            }
        }
        var metadataReferences = Set<String>()
        for definition in definitions.values {
            collectSchemaReferences(from: .object(definition), into: &metadataReferences)
        }
        references.formUnion(metadataReferences)
        let localReferences = references.filter { definitions[$0] != nil }
        XCTAssertEqual(Set(definitions.keys).subtracting(localReferences), rootIDs)
        XCTAssertEqual(references.subtracting(definitions.keys), ["runtimeCompatibility.v1"])

        for uniqueID in ["preparationProgress.v1", "preparationResult.v1", "preparationStatus.v1"] {
            XCTAssertNotNil(definitions[uniqueID])
            XCTAssertEqual(definitions.keys.filter { $0 == uniqueID }.count, 1)
        }

        let event = try XCTUnwrap(definitions["runtimeEvent.v1"])
        let associationRules = try objectValue(event, "x-pulsephone-associationRules")
        XCTAssertEqual(
            Set(associationRules.members.map(\.key)),
            [
                "availabilityInvalidated", "deviceDisconnected",
                "operationAccepted", "operationQueued", "operationStarted",
                "preparationStarted", "runtimeFatal", "streamClosed",
            ]
        )
    }

    func testArtifactSetIdentityAndTreeNodeSafety() throws {
        let paths = Self.registryFiles.map { "Registries/\($0)" }
            + Self.schemaFiles.map { "Schemas/wire/\($0)" }
        let sortedPaths = paths.sorted(by: asciiLessThan)
        XCTAssertEqual(sortedPaths.count, 10)

        var identities = Set<String>()
        var artifactEntries = [RepositoryJSONValue]()
        for relativePath in sortedPaths {
            let url = packageRootURL().appendingPathComponent(relativePath)
            var status = stat()
            XCTAssertEqual(lstat(url.path, &status), 0, relativePath)
            XCTAssertEqual(status.st_mode & mode_t(S_IFMT), mode_t(S_IFREG))
            XCTAssertEqual(status.st_nlink, 1, relativePath)
            XCTAssertTrue(identities.insert("\(status.st_dev):\(status.st_ino)").inserted)

            let bytes = [UInt8](try Data(contentsOf: url))
            _ = try RepositoryCanonicalJSON.validateCanonicalDocument(
                bytes,
                maximumByteCount: 1 << 20
            )
            let entry = try RepositoryJSONObject(
                members: [
                    RepositoryJSONMember(key: "relativePath", value: .string(relativePath)),
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
                    value: .string("wire-registry.v9-20260822")
                ),
                RepositoryJSONMember(key: "schemaVersion", value: .number(.uint64(1))),
                RepositoryJSONMember(key: "setID", value: .string("wireRegistry")),
            ]
        )
        let bytes = RepositoryCanonicalJSON.encodeDocument(artifactSet)
        XCTAssertEqual(
            StableBytes.sha256Hex(bytes),
            "126acc151ce42642c901f73cd733d6af7ce00e28cb81f22c3a3b079528370606"
        )
        XCTAssertEqual(
            try StableBytes.domainSeparatedSHA256Hex(
                domainID: "pulsephone.wire-registry-set.v1",
                payload: bytes
            ),
            "85414363f1e84a4c9f8fe863319355beab20d2845aded1fb382f6d33094762dd"
        )
    }

    private func entries(_ fileName: String) throws -> [RepositoryJSONObject] {
        try array(loadCanonicalObject(registryURL(fileName)), "entries").map(requiredObject)
    }

    private func byID(
        _ entries: [RepositoryJSONObject]
    ) throws -> [String: RepositoryJSONObject] {
        try Dictionary(uniqueKeysWithValues: entries.map { (try string($0, "id"), $0) })
    }

    private func schemaDefinitions() throws -> [String: RepositoryJSONObject] {
        var definitions = [String: RepositoryJSONObject]()
        for fileName in Self.schemaFiles {
            collectDefinitions(
                from: .object(try loadCanonicalObject(schemaDirectoryURL().appendingPathComponent(fileName))),
                into: &definitions
            )
        }
        return definitions
    }

    private func collectDefinitions(
        from value: RepositoryJSONValue,
        into definitions: inout [String: RepositoryJSONObject]
    ) {
        switch value {
        case .object(let object):
            if let id = object["$id"]?.stringValue {
                XCTAssertNil(definitions.updateValue(object, forKey: id), id)
            }
            for member in object.members {
                collectDefinitions(from: member.value, into: &definitions)
            }
        case .array(let values):
            for child in values {
                collectDefinitions(from: child, into: &definitions)
            }
        case .bool, .null, .number, .string:
            break
        }
    }

    private func collectSchemaReferences(
        from value: RepositoryJSONValue,
        into references: inout Set<String>
    ) {
        switch value {
        case .object(let object):
            for member in object.members {
                if (member.key.hasSuffix("SchemaID") || member.key.hasSuffix("SchemaId")),
                   let reference = member.value.stringValue,
                   reference.hasSuffix(".v1") {
                    references.insert(reference)
                }
                if member.key.hasSuffix("SchemaIDs") || member.key == "x-pulsephone-schemaRefs" {
                    for child in member.value.arrayValue ?? [] {
                        if let reference = child.stringValue, reference.hasSuffix(".v1") {
                            references.insert(reference)
                        }
                    }
                }
                collectSchemaReferences(from: member.value, into: &references)
            }
        case .array(let values):
            for child in values {
                collectSchemaReferences(from: child, into: &references)
            }
        case .bool, .null, .number, .string:
            break
        }
    }

    private func standardErrorCodes() throws -> Set<String> {
        let registry = try loadCanonicalObject(
            packageRootURL().appendingPathComponent("Registries/standard-errors.v1.json")
        )
        return Set(
            try array(registry, "entries").map(requiredObject).map {
                try string($0, "code")
            }
        )
    }

    private func registryURL(_ fileName: String) -> URL {
        packageRootURL().appendingPathComponent("Registries/\(fileName)")
    }

    private func schemaDirectoryURL() -> URL {
        packageRootURL().appendingPathComponent("Schemas/wire")
    }

    private func packageRootURL() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 {
            root.deleteLastPathComponent()
        }
        return root
    }

    private func loadCanonicalObject(_ url: URL) throws -> RepositoryJSONObject {
        let bytes = [UInt8](try Data(contentsOf: url))
        return try RepositoryCanonicalJSON.validateCanonicalDocument(
            bytes,
            maximumByteCount: 1 << 20
        ).root
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

    private func assertSortedUniqueStrings(
        _ object: RepositoryJSONObject,
        key: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let values = try strings(object, key)
        XCTAssertEqual(values, values.sorted(by: asciiLessThan), file: file, line: line)
        XCTAssertEqual(Set(values).count, values.count, file: file, line: line)
    }

    private func asciiLessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}
