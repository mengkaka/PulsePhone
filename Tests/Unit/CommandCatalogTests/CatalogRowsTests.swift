import Foundation
import XCTest
@testable import PulsePhoneCommandCatalog
import PulsePhoneSharedDefinitions

final class CatalogRowsTests: XCTestCase {
    private static let productIDs: Set<String> = [
        "app.install", "app.launch", "app.list", "app.uninstall", "button.appSwitcher",
        "button.home", "button.lock", "button.mute", "button.volumeDown",
        "button.volumeUp", "catalog.commands", "device.info", "device.list",
        "developerImage.check", "developerImage.list",
        "device.prepare", "device.rotate", "device.status",
        "diagnostics.start", "diagnostics.stop", "element.snapshot",
        "gui.cameraAuthorization.openSettings", "gui.keyboard.interaction",
        "gui.keyboardCapture.toggle", "gui.pointer.interaction",
        "gui.previewAudioMute.toggle", "gui.softwareKeyboard.toggle",
        "live.close", "live.launch", "logs.clear.all", "logs.clear.device",
        "logs.prune", "product.version", "runtime.status.device", "runtime.status.global",
        "runtime.stop", "screenshot.cli", "screenshot.gui", "self.install",
        "skill.install", "skill.status", "skill.uninstall", "text.type",
        "text.clear", "text.cursor", "text.inputSource.next", "text.key",
        "touch.drag", "touch.swipe", "touch.tap", "trace.start", "trace.stop",
    ]

    private static let supportingIDs: Set<String> = [
        "BootstrapControlV1.probeRuntimeLite",
        "BootstrapControlV1.retireIfIdle",
        "BootstrapControlV1.stopReplayTraceAndFinalize",
        "LocalDeviceFactsProbe.enumerate", "LocalDeviceFactsProbe.probe",
        "device.screenshot", "guiHost.openLive", "runtime.attachLive",
        "runtime.cancelOwnedPendingWork", "runtime.clearActionLogs",
        "runtime.detachLive", "runtime.getAvailabilitySnapshot",
        "runtime.health", "runtime.prepareCapabilities",
        "runtime.recordLocalAction", "runtime.runtimeStatus",
        "runtime.startDiagnostics", "runtime.startReplayTrace",
        "runtime.stopDiagnostics", "runtime.stopIfIdle",
        "runtime.stopReplayTrace",
    ]

    private static let featureIDs: Set<String> = [
        "developerSupport.transparentPreparation", "live.audioPreview",
        "live.identityPlaceholderBlindControl", "live.inputObservationOverlay",
        "live.targetBindingSafety", "live.videoPreview",
    ]

    func testExactIdentityCountsProfilesAndOrdering() throws {
        let catalog = try loadCatalog()
        XCTAssertEqual(catalog.schemaVersion, 1)
        XCTAssertEqual(catalog.matrixRevision, CommandCatalog.matrixRevision)
        XCTAssertEqual(Set(catalog.productActions.map(\.commandID)), Self.productIDs)
        XCTAssertEqual(
            Set(catalog.supportingActions.map(\.supportingActionID)),
            Self.supportingIDs
        )
        XCTAssertEqual(Set(catalog.features.map(\.featureID)), Self.featureIDs)
        XCTAssertEqual(catalog.productActions.count, 52)
        XCTAssertEqual(catalog.supportingActions.count, 21)
        XCTAssertEqual(catalog.features.count, 6)
        XCTAssertEqual(
            catalog.productActions.map(\.commandID),
            catalog.productActions.map(\.commandID).sorted(by: CommandCatalog.asciiLessThan)
        )

        XCTAssertEqual(count(catalog, category: .local), 16)
        XCTAssertEqual(count(catalog, category: .control), 5)
        XCTAssertEqual(count(catalog, category: .oneShot), 20)
        XCTAssertEqual(count(catalog, category: .stream), 2)
        XCTAssertEqual(count(catalog, category: .hybrid), 9)
        XCTAssertEqual(count(catalog, loggingProfileID: "L0"), 12)
        XCTAssertEqual(count(catalog, loggingProfileID: "L1"), 6)
        XCTAssertEqual(count(catalog, loggingProfileID: "L2"), 25)
        XCTAssertEqual(count(catalog, loggingProfileID: "L3"), 2)
        XCTAssertEqual(count(catalog, loggingProfileID: "L4"), 7)
        XCTAssertEqual(count(catalog, executionProfileID: "P-C0"), 4)
        XCTAssertEqual(count(catalog, executionProfileID: "P-C1"), 1)
        XCTAssertEqual(count(catalog, executionProfileID: "P-H0"), 9)
        XCTAssertEqual(count(catalog, executionProfileID: "P-L0"), 10)
        XCTAssertEqual(count(catalog, executionProfileID: "P-L1"), 6)
        XCTAssertEqual(count(catalog, executionProfileID: "P-O0"), 20)
        XCTAssertEqual(count(catalog, executionProfileID: "P-S0"), 2)
        assertTransitionBindingState(catalog)

        for descriptor in catalog.productActions {
            let expectedProfile: String
            switch descriptor.category {
            case .local:
                expectedProfile = [
                    "catalog.commands", "gui.cameraAuthorization.openSettings",
                    "gui.keyboardCapture.toggle", "gui.previewAudioMute.toggle",
                    "logs.prune", "product.version", "self.install",
                    "skill.install", "skill.status", "skill.uninstall",
                ].contains(descriptor.commandID)
                    ? "P-L0" : "P-L1"
            case .control:
                expectedProfile = descriptor.commandID == "device.prepare" ? "P-C1" : "P-C0"
            case .oneShot:
                expectedProfile = "P-O0"
            case .stream:
                expectedProfile = "P-S0"
            case .hybrid:
                expectedProfile = "P-H0"
            }
            XCTAssertEqual(descriptor.executionProfileID, expectedProfile, descriptor.commandID)
        }
    }

    func testExposureCountsToolbarOrderAndReleaseScope() throws {
        let catalog = try loadCatalog()
        XCTAssertEqual(catalog.productActions.filter { $0.exposures.contains(.cli) }.count, 44)
        XCTAssertEqual(
            catalog.productActions.filter {
                $0.guiSurface.map { [.toolbar, .window].contains($0.kind) } ?? false
            }.count,
            14
        )
        XCTAssertEqual(
            catalog.productActions.filter {
                $0.guiSurface?.kind == .ownerBoundInteraction
            }.count,
            2
        )
        let toolbar = Dictionary(
            uniqueKeysWithValues: catalog.productActions.compactMap { descriptor in
                descriptor.guiSurface?.kind == .toolbar
                    ? (descriptor.commandID, descriptor.guiSurface!.order!) : nil
            }
        )
        XCTAssertEqual(toolbar, [
            "app.install": 120, "button.appSwitcher": 20, "button.home": 10,
            "button.lock": 30, "button.mute": 60, "button.volumeDown": 50,
            "button.volumeUp": 40, "device.rotate": 70,
            "gui.keyboardCapture.toggle": 90,
            "gui.previewAudioMute.toggle": 110,
            "gui.softwareKeyboard.toggle": 100, "screenshot.gui": 80,
        ])
        let productGate = Set(
            catalog.productActions.filter { $0.releaseScope == .productGate }.map(\.commandID)
        )
        XCTAssertEqual(productGate, [
            "catalog.commands", "developerImage.check", "developerImage.list",
            "device.info", "device.list", "device.prepare",
            "device.status",
            "gui.pointer.interaction", "live.close", "live.launch",
            "logs.clear.all", "logs.clear.device", "logs.prune",
            "product.version", "self.install", "skill.install", "skill.status",
            "skill.uninstall",
            "runtime.status.device", "runtime.status.global", "runtime.stop",
            "touch.drag", "touch.swipe", "touch.tap",
        ])

        let expanded = try ExecutionProfileCatalog.load(
            repositoryRoot: repositoryRoot()
        )
        let keyboardToggle = try XCTUnwrap(
            expanded.expandedProductActions.first {
                $0.command.commandID == "gui.keyboardCapture.toggle"
            }
        )
        XCTAssertEqual(
            keyboardToggle.compatibilityRule.parameters["deviceRequired"],
            .bool(true)
        )
        XCTAssertEqual(
            keyboardToggle.compatibilityRule.parameters["minimumOSMajor"],
            .uint64(17)
        )
        XCTAssertEqual(
            keyboardToggle.compatibilityRule.parameters["transportIDs"],
            .strings(["rsd", "usb"])
        )
        let softwareKeyboard = try XCTUnwrap(
            expanded.expandedProductActions.first {
                $0.command.commandID == "gui.softwareKeyboard.toggle"
            }
        )
        XCTAssertEqual(
            softwareKeyboard.policyBindings.candidateOrderIDs,
            ["coredevice.softwareKeyboardToggle"]
        )
        XCTAssertEqual(
            softwareKeyboard.policyBindings.queuePolicyID,
            "queue.fail-fast.v1"
        )
        XCTAssertEqual(
            softwareKeyboard.resourceClaimTemplate.claims.map {
                "\($0.phase.rawValue)|\($0.accessMode.rawValue)|\($0.resourceIDTemplate)"
            },
            [
                "running|exclusive|device.input.keyboard",
                "running|shared|device.app-state",
            ]
        )
    }

    func testSupportingParentsAndResultSchemaCoverage() throws {
        let catalog = try loadCatalog()
        let productIDs = Set(catalog.productActions.map(\.commandID))
        for descriptor in catalog.supportingActions {
            XCTAssertFalse(descriptor.callerIDs.isEmpty, descriptor.supportingActionID)
            XCTAssertTrue(
                Set(descriptor.parentCommandIDs).isSubset(of: productIDs),
                descriptor.supportingActionID
            )
        }
        let resultReferences = Set(
            catalog.productActions.map(\.resultSchemaRef)
                + catalog.supportingActions.map(\.resultSchemaRef)
                + catalog.retainedResultSchemaRefs
        )
        let actual = try FileManager.default.contentsOfDirectory(
            at: repositoryRoot().appendingPathComponent(CommandCatalog.resultSchemaDirectory),
            includingPropertiesForKeys: nil
        ).map { "\(CommandCatalog.resultSchemaDirectory)/\($0.lastPathComponent)" }
        XCTAssertEqual(resultReferences, Set(actual))

        let recordLocal = try XCTUnwrap(
            catalog.supportingActions.first {
                $0.supportingActionID == "runtime.recordLocalAction"
            }
        )
        let expectedLoggingParents = Set(
            catalog.productActions.filter {
                ["L1", "L4"].contains($0.loggingProfileID)
            }.map(\.commandID)
        )
        XCTAssertEqual(Set(recordLocal.parentCommandIDs), expectedLoggingParents)
    }

    func testCanonicalAndMissingSchemaInputsFailClosed() throws {
        let root = try copiedContractRoot()
        let registry = root.appendingPathComponent(CommandCatalog.registryRelativePath)
        var bytes = try Data(contentsOf: registry)
        bytes.append(0x0a)
        try bytes.write(to: registry)
        XCTAssertThrowsError(try CommandCatalog.load(repositoryRoot: root))

        let missingRoot = try copiedContractRoot()
        try FileManager.default.removeItem(
            at: missingRoot.appendingPathComponent(
                "Schemas/result-schemas/action-ack.v1.schema.json"
            )
        )
        XCTAssertThrowsError(try CommandCatalog.load(repositoryRoot: missingRoot))

        let partialPolicyRoot = try copiedContractRoot()
        let partialPolicyRegistry = partialPolicyRoot.appendingPathComponent(
            CommandCatalog.registryRelativePath
        )
        let original = try String(
            contentsOf: partialPolicyRegistry,
            encoding: .utf8
        )
        let partial: String
        if original.contains("\"policyBindings\":") {
            let range = try XCTUnwrap(original.range(of: "\"allowedErrorCodes\":"))
            partial = original.replacingCharacters(
                in: range,
                with: "\"removedAllowedErrorCodes\":"
            )
        } else {
            partial = original.replacingOccurrences(
                of: "\"loggingProfileID\":\"L2\",\"releaseScope\"",
                with: "\"loggingProfileID\":\"L2\",\"policyBindings\":{},\"releaseScope\""
            )
        }
        XCTAssertNotEqual(original, partial)
        try Data(partial.utf8).write(to: partialPolicyRegistry)
        XCTAssertThrowsError(try CommandCatalog.load(repositoryRoot: partialPolicyRoot))
    }

    func testContractArtifactSetAndCatalogSchemaAreCanonicalAndClosed() throws {
        let catalog = try loadCatalog()
        let resultReferences = Set(
            catalog.productActions.map(\.resultSchemaRef)
                + catalog.supportingActions.map(\.resultSchemaRef)
                + catalog.retainedResultSchemaRefs
        )
        let relativePaths = ([
            CommandCatalog.registryRelativePath,
            CommandCatalog.schemaRelativePath,
        ] + Array(resultReferences)).sorted(by: CommandCatalog.asciiLessThan)
        let artifactSet = try RepositoryContractResolver.resolve(
            repositoryRoot: repositoryRoot(),
            setID: "commandCatalogPartial",
            revision: CommandCatalog.matrixRevision,
            relativePaths: relativePaths
        )
        XCTAssertEqual(artifactSet.entries.count, 2 + resultReferences.count)

        let data = try Data(
            contentsOf: repositoryRoot().appendingPathComponent(
                CommandCatalog.schemaRelativePath
            )
        )
        let schema = try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](data),
            maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
        ).root
        XCTAssertEqual(schema["$id"]?.stringValue, "commandCatalog.v1")
        XCTAssertEqual(
            schema["$schema"]?.stringValue,
            "https://json-schema.org/draft/2020-12/schema"
        )
        guard case .bool(false)? = schema["additionalProperties"] else {
            return XCTFail("catalog schema must be closed")
        }
        let definitions = try XCTUnwrap(schema["$defs"]?.objectValue)
        let properties = try XCTUnwrap(schema["properties"]?.objectValue)
        for key in [
            "commandPolicyBindings", "compatibilityRule", "executionProfile",
            "loggingProfile", "resourceClaim", "resourceClaimTemplate",
        ] {
            XCTAssertNotNil(definitions[key], key)
        }
        for key in [
            "compatibilityRules", "executionProfiles", "loggingProfiles",
            "resourceClaimTemplates",
        ] {
            XCTAssertNotNil(properties[key], key)
        }
    }

    func testOrderedPolicyArraysPreserveDeclarationOrderAndRejectDuplicates() throws {
        let reorderedRoot = try copiedContractRoot()
        try replace(
            in: reorderedRoot,
            target: "[\"coredevice.appLaunch\",\"legacy.dvtLaunch\"]",
            replacement: "[\"legacy.dvtLaunch\",\"coredevice.appLaunch\"]"
        )
        try replace(
            in: reorderedRoot,
            target: "[\"prep.coredevice.v2\",\"prep.legacy.developer.v2\"]",
            replacement: "[\"prep.legacy.developer.v2\",\"prep.coredevice.v2\"]"
        )
        let reordered = try CommandCatalog.load(repositoryRoot: reorderedRoot)
        let appLaunch = try XCTUnwrap(
            reordered.productActions.first { $0.commandID == "app.launch" }
        )
        XCTAssertEqual(
            appLaunch.policyBindings?.candidateOrderIDs,
            ["legacy.dvtLaunch", "coredevice.appLaunch"]
        )
        XCTAssertEqual(
            appLaunch.policyBindings?.preparationGroupIDs,
            ["prep.legacy.developer.v2", "prep.coredevice.v2"]
        )

        let duplicateCandidateRoot = try copiedContractRoot()
        try replace(
            in: duplicateCandidateRoot,
            target: "[\"coredevice.appLaunch\",\"legacy.dvtLaunch\"]",
            replacement: "[\"coredevice.appLaunch\",\"coredevice.appLaunch\"]"
        )
        XCTAssertThrowsError(try CommandCatalog.load(repositoryRoot: duplicateCandidateRoot)) {
            XCTAssertEqual(
                $0 as? CommandCatalogError,
                .duplicateID("candidateOrderIDs: app.launch")
            )
        }

        let duplicateGroupRoot = try copiedContractRoot()
        try replace(
            in: duplicateGroupRoot,
            target: "[\"prep.coredevice.v2\",\"prep.legacy.developer.v2\"]",
            replacement: "[\"prep.coredevice.v2\",\"prep.coredevice.v2\"]"
        )
        XCTAssertThrowsError(try CommandCatalog.load(repositoryRoot: duplicateGroupRoot)) {
            XCTAssertEqual(
                $0 as? CommandCatalogError,
                .duplicateID("preparationGroupIDs: app.launch")
            )
        }
    }

    func testExtraAndHardlinkedResultSchemasFailClosed() throws {
        let extraRoot = try copiedContractRoot()
        try FileManager.default.copyItem(
            at: extraRoot.appendingPathComponent(
                "Schemas/result-schemas/action-ack.v1.schema.json"
            ),
            to: extraRoot.appendingPathComponent(
                "Schemas/result-schemas/extra.v1.schema.json"
            )
        )
        XCTAssertThrowsError(try CommandCatalog.load(repositoryRoot: extraRoot))

        let hardlinkRoot = try copiedContractRoot()
        try FileManager.default.linkItem(
            at: hardlinkRoot.appendingPathComponent(
                "Schemas/result-schemas/action-ack.v1.schema.json"
            ),
            to: hardlinkRoot.appendingPathComponent(
                "Schemas/result-schemas/hardlink.v1.schema.json"
            )
        )
        XCTAssertThrowsError(try CommandCatalog.load(repositoryRoot: hardlinkRoot))
    }

    private func loadCatalog() throws -> CommandCatalogV1 {
        try CommandCatalog.load(repositoryRoot: repositoryRoot())
    }

    private func count(_ catalog: CommandCatalogV1, category: CommandCategory) -> Int {
        catalog.productActions.filter { $0.category == category }.count
    }

    private func count(_ catalog: CommandCatalogV1, loggingProfileID: String) -> Int {
        catalog.productActions.filter { $0.loggingProfileID == loggingProfileID }.count
    }

    private func count(_ catalog: CommandCatalogV1, executionProfileID: String) -> Int {
        catalog.productActions.filter { $0.executionProfileID == executionProfileID }.count
    }

    private func assertTransitionBindingState(_ catalog: CommandCatalogV1) {
        let bindings = catalog.productActions.map(\.policyBindings)
            + catalog.supportingActions.map(\.policyBindings)
        let materializedCount = bindings.compactMap { $0 }.count
        XCTAssertTrue(
            materializedCount == 0 || materializedCount == bindings.count,
            "policy bindings must be entirely absent or entirely materialized"
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func copiedContractRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Registries"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Schemas/result-schemas"),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: repositoryRoot().appendingPathComponent(CommandCatalog.registryRelativePath),
            to: root.appendingPathComponent(CommandCatalog.registryRelativePath)
        )
        for url in try FileManager.default.contentsOfDirectory(
            at: repositoryRoot().appendingPathComponent(CommandCatalog.resultSchemaDirectory),
            includingPropertiesForKeys: nil
        ) {
            try FileManager.default.copyItem(
                at: url,
                to: root.appendingPathComponent(CommandCatalog.resultSchemaDirectory)
                    .appendingPathComponent(url.lastPathComponent)
            )
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func replace(
        in root: URL,
        target: String,
        replacement: String
    ) throws {
        let registry = root.appendingPathComponent(CommandCatalog.registryRelativePath)
        let original = try String(contentsOf: registry, encoding: .utf8)
        let range = try XCTUnwrap(original.range(of: target))
        let changed = original.replacingCharacters(in: range, with: replacement)
        XCTAssertNotEqual(changed, original)
        try Data(changed.utf8).write(to: registry)
    }
}
