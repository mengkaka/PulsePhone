import Foundation
import PulsePhoneSharedDefinitions
import XCTest

@testable import PulsePhoneCommandCatalog

final class CommandProfileExpansionTests: XCTestCase {
  func testExecutionAndLoggingProfilesAreExact() throws {
    let catalog = try loadCatalog()
    XCTAssertEqual(
      catalog.executionProfiles,
      [
        ExecutionProfileDescriptor(
          acceptedWorkPolicy: .controlTerminal,
          automaticRetryPolicy: .never,
          executionProfileID: "P-C0",
          executionShape: .control,
          planningAuthority: .runtime,
          preparationWaitPolicy: .notApplicable,
          resultOwner: .runtime,
          schedulerPolicy: .none
        ),
        ExecutionProfileDescriptor(
          acceptedWorkPolicy: .controlTerminal,
          automaticRetryPolicy: .never,
          executionProfileID: "P-C1",
          executionShape: .control,
          planningAuthority: .runtime,
          preparationWaitPolicy: .wait,
          resultOwner: .runtime,
          schedulerPolicy: .none
        ),
        ExecutionProfileDescriptor(
          acceptedWorkPolicy: .clientAggregate,
          automaticRetryPolicy: .notApplicable,
          executionProfileID: "P-H0",
          executionShape: .hybrid,
          planningAuthority: .client,
          preparationWaitPolicy: .notApplicable,
          resultOwner: .client,
          schedulerPolicy: .none
        ),
        ExecutionProfileDescriptor(
          acceptedWorkPolicy: .localImmediate,
          automaticRetryPolicy: .notApplicable,
          executionProfileID: "P-L0",
          executionShape: .local,
          planningAuthority: .client,
          preparationWaitPolicy: .notApplicable,
          resultOwner: .client,
          schedulerPolicy: .none
        ),
        ExecutionProfileDescriptor(
          acceptedWorkPolicy: .localImmediate,
          automaticRetryPolicy: .notApplicable,
          executionProfileID: "P-L1",
          executionShape: .local,
          planningAuthority: .client,
          preparationWaitPolicy: .notApplicable,
          resultOwner: .client,
          schedulerPolicy: .none
        ),
        ExecutionProfileDescriptor(
          acceptedWorkPolicy: .continueAfterClientEOF,
          automaticRetryPolicy: .never,
          executionProfileID: "P-O0",
          executionShape: .oneShot,
          planningAuthority: .runtime,
          preparationWaitPolicy: .wait,
          resultOwner: .runtime,
          schedulerPolicy: .oneShotAdmission
        ),
        ExecutionProfileDescriptor(
          acceptedWorkPolicy: .ownerBound,
          automaticRetryPolicy: .never,
          executionProfileID: "P-S0",
          executionShape: .stream,
          planningAuthority: .runtime,
          preparationWaitPolicy: .failFast,
          resultOwner: .runtime,
          schedulerPolicy: .streamLease
        ),
      ])
    XCTAssertEqual(
      catalog.loggingProfiles,
      [
        LoggingProfileDescriptor(
          actionLogPolicy: .none,
          loggingProfileID: "L0",
          redactionPolicyID: "redaction.standard.v1",
          replayTracePolicy: .none
        ),
        LoggingProfileDescriptor(
          actionLogPolicy: .existingRuntimeBestEffort,
          loggingProfileID: "L1",
          redactionPolicyID: "redaction.standard.v1",
          replayTracePolicy: .none
        ),
        LoggingProfileDescriptor(
          actionLogPolicy: .runtimeAppendOnce,
          loggingProfileID: "L2",
          redactionPolicyID: "redaction.semantic.v1",
          replayTracePolicy: .semantic
        ),
        LoggingProfileDescriptor(
          actionLogPolicy: .runtimeAppendOnce,
          loggingProfileID: "L3",
          redactionPolicyID: "redaction.stream-payload.v1",
          replayTracePolicy: .semantic
        ),
        LoggingProfileDescriptor(
          actionLogPolicy: .clientHybridAppendOnce,
          loggingProfileID: "L4",
          redactionPolicyID: "redaction.standard.v1",
          replayTracePolicy: .semantic
        ),
      ])
    XCTAssertEqual(catalog.expandedProductActions.count, 52)
    XCTAssertEqual(catalog.expandedSupportingActions.count, 21)
    XCTAssertEqual(catalog.compatibilityRules.count, 76)
    XCTAssertEqual(catalog.resourceClaimTemplates.count, 26)

    let profiles = Dictionary(
      uniqueKeysWithValues: catalog.executionProfiles.map { ($0.executionProfileID, $0) }
    )
    XCTAssertEqual(profiles["P-C1"]?.executionShape, .control)
    XCTAssertEqual(profiles["P-C1"]?.preparationWaitPolicy, .wait)
    XCTAssertEqual(profiles["P-C1"]?.schedulerPolicy, SchedulerPolicy.none)
    XCTAssertEqual(profiles["P-O0"]?.acceptedWorkPolicy, .continueAfterClientEOF)
    XCTAssertEqual(profiles["P-O0"]?.schedulerPolicy, .oneShotAdmission)
    XCTAssertEqual(profiles["P-S0"]?.acceptedWorkPolicy, .ownerBound)
    XCTAssertEqual(profiles["P-S0"]?.preparationWaitPolicy, .failFast)
    XCTAssertEqual(profiles["P-H0"]?.planningAuthority, .client)
    XCTAssertEqual(profiles["P-H0"]?.resultOwner, .client)

    let logging = Dictionary(
      uniqueKeysWithValues: catalog.loggingProfiles.map { ($0.loggingProfileID, $0) }
    )
    XCTAssertEqual(logging["L0"]?.actionLogPolicy, ActionLogPolicy.none)
    XCTAssertEqual(logging["L1"]?.actionLogPolicy, .existingRuntimeBestEffort)
    XCTAssertEqual(logging["L2"]?.actionLogPolicy, .runtimeAppendOnce)
    XCTAssertEqual(logging["L3"]?.redactionPolicyID, "redaction.stream-payload.v1")
    XCTAssertEqual(logging["L4"]?.actionLogPolicy, .clientHybridAppendOnce)
  }

  func testProductRowsExpandWithoutDefaultsAndPreservePolicyDifferences() throws {
    let catalog = try loadCatalog()
    let rows = Dictionary(
      uniqueKeysWithValues: catalog.expandedProductActions.map { ($0.command.commandID, $0) }
    )
    XCTAssertEqual(rows["trace.start"]?.command.executionProfileID, "P-C0")
    XCTAssertEqual(rows["trace.start"]?.command.loggingProfileID, "L2")
    XCTAssertEqual(
      rows["trace.start"]?.policyBindings.runtimeActivationPolicyID,
      "activation.ensure-running.v1"
    )
    XCTAssertEqual(
      rows["trace.stop"]?.policyBindings.runtimeActivationPolicyID,
      "activation.existing-or-bootstrap.v1"
    )
    XCTAssertEqual(
      rows["diagnostics.stop"]?.policyBindings.runtimeActivationPolicyID,
      "activation.existing-compatible.v1"
    )

    XCTAssertEqual(
      rows["catalog.commands"]?.policyBindings.deadlinePolicyID, "deadline.local.1s.v1")
    XCTAssertEqual(
      rows["gui.cameraAuthorization.openSettings"]?.policyBindings.deadlinePolicyID,
      "deadline.local.5s.v1"
    )
    XCTAssertEqual(
      rows["logs.prune"]?.policyBindings.deadlinePolicyID, "deadline.log-maintenance.30s.v1")
    XCTAssertEqual(
      rows["self.install"]?.policyBindings.deadlinePolicyID,
      "deadline.self-install.120s.v1"
    )
    XCTAssertEqual(
      rows["skill.install"]?.policyBindings.deadlinePolicyID,
      "deadline.skill-install.125s.v1"
    )
    XCTAssertEqual(
      rows["skill.status"]?.policyBindings.deadlinePolicyID,
      "deadline.local.5s.v1"
    )
    XCTAssertEqual(
      rows["skill.uninstall"]?.policyBindings.deadlinePolicyID,
      "deadline.local.5s.v1"
    )
    XCTAssertEqual(rows["app.install"]?.policyBindings.deadlinePolicyID, "deadline.install.30m.v1")
    XCTAssertEqual(rows["app.list"]?.policyBindings.deadlinePolicyID, "deadline.app-list.30s.v1")
    XCTAssertEqual(
      rows["app.list"]?.policyBindings.candidateOrderIDs,
      ["direct.installationProxy.browse"]
    )
    XCTAssertEqual(
      rows["app.uninstall"]?.policyBindings.deadlinePolicyID, "deadline.uninstall.5m.v1")
    XCTAssertEqual(
      rows["app.launch"]?.policyBindings.deadlinePolicyID, "deadline.app-launch.60s.v1")
    XCTAssertEqual(
      rows["app.launch"]?.policyBindings.candidateOrderIDs,
      ["coredevice.appLaunch", "legacy.dvtLaunch"]
    )

    XCTAssertEqual(rows["runtime.status.global"]?.command.loggingProfileID, "L0")
    XCTAssertEqual(rows["runtime.status.device"]?.command.loggingProfileID, "L0")
    for commandID in [
      "live.close", "logs.clear.all", "logs.clear.device", "runtime.stop",
      "screenshot.cli", "screenshot.gui",
    ] {
      XCTAssertEqual(rows[commandID]?.command.loggingProfileID, "L4", commandID)
    }
    XCTAssertEqual(rows["device.prepare"]?.command.releaseScope, .productGate)
    XCTAssertEqual(rows["device.prepare"]?.command.executionProfileID, "P-C1")
    XCTAssertEqual(rows["device.prepare"]?.command.loggingProfileID, "L2")
  }

  func testResourceClaimsAreExplicitAndPhaseScoped() throws {
    let catalog = try loadCatalog()
    let rows = Dictionary(
      uniqueKeysWithValues: catalog.expandedProductActions.map { ($0.command.commandID, $0) }
    )
    XCTAssertEqual(
      claimKeys(try XCTUnwrap(rows["touch.tap"]?.resourceClaimTemplate)),
      [
        "running|exclusive|device.input.touch",
        "running|shared|device.app-state",
        "running|shared|device.display-geometry",
      ]
    )
    XCTAssertEqual(
      claimKeys(try XCTUnwrap(rows["app.uninstall"]?.resourceClaimTemplate)),
      [
        "running|exclusive|device.app-lifecycle.{bundleID}",
        "running|exclusive|device.app-management",
        "running|exclusive|service.installation",
        "running|shared|device.app-state",
      ]
    )
    XCTAssertEqual(
      claimKeys(try XCTUnwrap(rows["app.list"]?.resourceClaimTemplate)),
      [
        "running|exclusive|service.installation",
        "running|shared|device.app-state",
      ]
    )
    XCTAssertEqual(
      claimKeys(try XCTUnwrap(rows["gui.pointer.interaction"]?.resourceClaimTemplate)),
      [
        "stream|exclusive|device.input.touch",
        "stream|exclusive|executor.coredevice.input-channel",
        "stream|shared|device.app-state",
        "stream|shared|device.display-geometry",
      ]
    )
    XCTAssertTrue(try XCTUnwrap(rows["device.prepare"]?.resourceClaimTemplate).claims.isEmpty)
  }

  func testPreparationGroupsDefaultsRoutesAndBindingsAreExact() throws {
    let catalog = try loadCatalog()
    let groups = Dictionary(
      uniqueKeysWithValues: catalog.preparationGroups.map { ($0.preparationGroupID, $0) }
    )
    XCTAssertEqual(
      Set(groups.keys),
      [
        "prep.coredevice.v2", "prep.direct.lockdown.v1", "prep.legacy.developer.v2",
      ])
    XCTAssertEqual(groups["prep.coredevice.v2"]?.route, .personalized)
    XCTAssertEqual(groups["prep.coredevice.v2"]?.targetDefaultOSProfileIDs, [.modernRSD])
    XCTAssertEqual(groups["prep.direct.lockdown.v1"]?.route, PreparationRoute.none)
    XCTAssertEqual(groups["prep.direct.lockdown.v1"]?.targetDefaultOSProfileIDs, [])
    XCTAssertEqual(groups["prep.legacy.developer.v2"]?.route, .classic)
    XCTAssertEqual(groups["prep.legacy.developer.v2"]?.targetDefaultOSProfileIDs, [.legacyClassic])
    XCTAssertEqual(
      groups["prep.coredevice.v2"]?.phaseClaimBindings.map(\.phaseID),
      [.alreadyMountedGeneration, .mountGeneration, .queryMountedState]
    )
    XCTAssertTrue(try XCTUnwrap(groups["prep.direct.lockdown.v1"]).phaseClaimBindings.isEmpty)

    let products = Dictionary(
      uniqueKeysWithValues: catalog.expandedProductActions.map { ($0.command.commandID, $0) }
    )
    XCTAssertEqual(
      products["device.prepare"]?.policyBindings.preparationGroupIDs,
      ["prep.coredevice.v2", "prep.direct.lockdown.v1", "prep.legacy.developer.v2"]
    )
    XCTAssertEqual(
      products["app.install"]?.policyBindings.preparationGroupIDs,
      ["prep.direct.lockdown.v1"]
    )
    XCTAssertEqual(
      products["app.list"]?.policyBindings.preparationGroupIDs,
      ["prep.direct.lockdown.v1"]
    )
    XCTAssertEqual(
      products["app.launch"]?.policyBindings.preparationGroupIDs,
      ["prep.coredevice.v2", "prep.legacy.developer.v2"]
    )
    let supporting = Dictionary(
      uniqueKeysWithValues: catalog.expandedSupportingActions.map {
        ($0.action.supportingActionID, $0)
      }
    )
    XCTAssertEqual(
      supporting["device.screenshot"]?.policyBindings.preparationGroupIDs,
      ["prep.coredevice.v2", "prep.legacy.developer.v2"]
    )
    XCTAssertEqual(
      supporting["runtime.attachLive"]?.policyBindings.preparationGroupIDs,
      ["prep.coredevice.v2"]
    )
  }

  func testPreparationSchemaAndRegistriesAreCanonicalAndClosed() throws {
    let root = repositoryRoot()
    for relativePath in [
      CommandCatalog.registryRelativePath,
      ExecutionProfileCatalog.preparationRegistryRelativePath,
      ExecutionProfileCatalog.preparationSchemaRelativePath,
    ] {
      let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
      _ = try RepositoryCanonicalJSON.validateCanonicalDocument(
        [UInt8](data),
        maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
      )
      XCTAssertNotEqual(data.last, 0x0a, relativePath)
    }
    let schemaData = try Data(
      contentsOf: root.appendingPathComponent(
        ExecutionProfileCatalog.preparationSchemaRelativePath
      )
    )
    let schema = try RepositoryCanonicalJSON.validateCanonicalDocument(
      [UInt8](schemaData),
      maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
    ).root
    XCTAssertEqual(schema["$id"]?.stringValue, "preparationGroup.v1")
    guard case .bool(false)? = schema["additionalProperties"] else {
      return XCTFail("preparation schema must be closed")
    }
    let properties = try XCTUnwrap(schema["properties"]?.objectValue)
    XCTAssertNotNil(properties["matrixRevision"])
    XCTAssertNotNil(properties["preparationGroups"])
    XCTAssertNotNil(properties["schemaVersion"])
  }

  func testMissingMixedAndUnknownReferencesFailClosed() throws {
    let missingBindingRoot = try copiedContractRoot()
    try replace(
      in: missingBindingRoot,
      relativePath: CommandCatalog.registryRelativePath,
      target: "\"policyBindings\":{",
      replacement: "\"removedPolicyBindings\":{",
      firstOnly: true
    )
    XCTAssertThrowsError(try ExecutionProfileCatalog.load(repositoryRoot: missingBindingRoot))

    let unknownRuleRoot = try copiedContractRoot()
    try replace(
      in: unknownRuleRoot,
      relativePath: CommandCatalog.registryRelativePath,
      target: "\"compatibilityRuleID\":\"compat.product.app.install.v1\"",
      replacement: "\"compatibilityRuleID\":\"compat.product.unknown.v1\"",
      firstOnly: true
    )
    XCTAssertThrowsError(try ExecutionProfileCatalog.load(repositoryRoot: unknownRuleRoot))

    let unknownGroupRoot = try copiedContractRoot()
    try replace(
      in: unknownGroupRoot,
      relativePath: CommandCatalog.registryRelativePath,
      target: "\"prep.direct.lockdown.v1\"",
      replacement: "\"prep.unknown.v1\"",
      firstOnly: true
    )
    XCTAssertThrowsError(try ExecutionProfileCatalog.load(repositoryRoot: unknownGroupRoot))

    let unusedDefinitionRoot = try copiedContractRoot()
    try replace(
      in: unusedDefinitionRoot,
      relativePath: CommandCatalog.registryRelativePath,
      target: "}],\"executionProfiles\"",
      replacement:
        "},{\"parameters\":{},\"ruleID\":\"compat.zzz.unused.v1\",\"ruleVersion\":1}],\"executionProfiles\"",
      firstOnly: true
    )
    XCTAssertThrowsError(try ExecutionProfileCatalog.load(repositoryRoot: unusedDefinitionRoot))

    let duplicateDefaultRoot = try copiedContractRoot()
    try replace(
      in: duplicateDefaultRoot,
      relativePath: ExecutionProfileCatalog.preparationRegistryRelativePath,
      target: "\"targetDefaultOSProfileIDs\":[]",
      replacement: "\"targetDefaultOSProfileIDs\":[\"modernRSD\"]",
      firstOnly: true
    )
    XCTAssertThrowsError(try ExecutionProfileCatalog.load(repositoryRoot: duplicateDefaultRoot))
  }

  func testCanonicalAndUnsafePreparationInputsFailClosed() throws {
    let newlineRoot = try copiedContractRoot()
    let registry = newlineRoot.appendingPathComponent(
      ExecutionProfileCatalog.preparationRegistryRelativePath
    )
    var bytes = try Data(contentsOf: registry)
    bytes.append(0x0a)
    try bytes.write(to: registry)
    XCTAssertThrowsError(try ExecutionProfileCatalog.load(repositoryRoot: newlineRoot))

    let hardlinkRoot = try copiedContractRoot()
    try FileManager.default.linkItem(
      at: hardlinkRoot.appendingPathComponent(
        ExecutionProfileCatalog.preparationRegistryRelativePath
      ),
      to: hardlinkRoot.appendingPathComponent(
        "Registries/preparation-groups-hardlink.v1.json"
      )
    )
    XCTAssertThrowsError(try ExecutionProfileCatalog.load(repositoryRoot: hardlinkRoot))

    let missingSchemaRoot = try copiedContractRoot()
    try FileManager.default.removeItem(
      at: missingSchemaRoot.appendingPathComponent(
        ExecutionProfileCatalog.preparationSchemaRelativePath
      )
    )
    XCTAssertThrowsError(try ExecutionProfileCatalog.load(repositoryRoot: missingSchemaRoot))
  }

  private func loadCatalog() throws -> ExecutionProfileCatalogV1 {
    try ExecutionProfileCatalog.load(repositoryRoot: repositoryRoot())
  }

  private func claimKeys(_ template: ResourceClaimTemplateDescriptor) -> [String] {
    template.claims.map {
      "\($0.phase.rawValue)|\($0.accessMode.rawValue)|\($0.resourceIDTemplate)"
    }
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
    for directory in [
      "Registries", "Schemas/developer-support", "Schemas/result-schemas",
    ] {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(directory),
        withIntermediateDirectories: true
      )
    }
    for relativePath in [
      CommandCatalog.registryRelativePath,
      ExecutionProfileCatalog.preparationRegistryRelativePath,
      ExecutionProfileCatalog.preparationSchemaRelativePath,
      ExecutionProfileCatalog.standardErrorRegistryRelativePath,
    ] {
      try FileManager.default.copyItem(
        at: repositoryRoot().appendingPathComponent(relativePath),
        to: root.appendingPathComponent(relativePath)
      )
    }
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
    relativePath: String,
    target: String,
    replacement: String,
    firstOnly: Bool
  ) throws {
    let url = root.appendingPathComponent(relativePath)
    let original = try String(contentsOf: url, encoding: .utf8)
    let range = try XCTUnwrap(original.range(of: target))
    let changed: String
    if firstOnly {
      changed = original.replacingCharacters(in: range, with: replacement)
    } else {
      changed = original.replacingOccurrences(of: target, with: replacement)
    }
    try Data(changed.utf8).write(to: url)
  }
}
