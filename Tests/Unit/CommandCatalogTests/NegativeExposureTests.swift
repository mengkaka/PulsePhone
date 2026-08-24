import XCTest
@testable import PulsePhoneCommandCatalog

final class NegativeExposureTests: XCTestCase {
  func testExcludedAndInternalEntriesAreNotPublic() throws {
    let expected = try CommandMatrixCoverageSupport.loadNegative()
    let catalog = try ExecutionProfileCatalog.load(
      repositoryRoot: CommandMatrixCoverageSupport.repositoryRoot()
    )
    XCTAssertEqual(expected.schemaVersion, 1)
    XCTAssertEqual(Set(expected.excludedEntries), [
      ".app install", "Clipboard Sync", "GUI launch", "GUI uninstall",
      "Hardware Keyboard toggle", "Software Keyboard on/off state API",
      "Touch status toolbar item", "keyboard enable / keyboard disable",
      "live --debug-device-picker", "orientation get/set", "stop --force",
      "video record start/stop",
    ])

    let productIDs = Set(catalog.commandCatalog.productActions.map(\.commandID))
    let cliVariants = Set(catalog.commandCatalog.productActions.compactMap(\.cliVariant))
    let guiIDs = Set(
      catalog.commandCatalog.productActions.filter { $0.guiSurface != nil }.map(\.commandID)
    )
    let featureIDs = Set(catalog.commandCatalog.features.map(\.featureID))
    let publicIDs = productIDs.union(featureIDs)
    for identifier in expected.forbiddenCommandIDs {
      XCTAssertFalse(publicIDs.contains(identifier), identifier)
    }
    for variant in expected.forbiddenCLIVariants {
      XCTAssertFalse(cliVariants.contains(variant), variant)
    }
    for identifier in expected.forbiddenGUISurfaceCommandIDs {
      XCTAssertFalse(guiIDs.contains(identifier), identifier)
    }
    for identifier in expected.internalOnlyIDs {
      XCTAssertFalse(publicIDs.contains(identifier), identifier)
      XCTAssertFalse(cliVariants.contains(identifier), identifier)
      XCTAssertFalse(guiIDs.contains(identifier), identifier)
    }

    let supportingIDs = Set(
      catalog.commandCatalog.supportingActions.map(\.supportingActionID)
    )
    XCTAssertTrue(productIDs.isDisjoint(with: supportingIDs))
    XCTAssertEqual(
      catalog.commandCatalog.productActions.first { $0.commandID == "app.launch" }?.exposures,
      [.cli]
    )
    XCTAssertEqual(
      catalog.commandCatalog.productActions.first { $0.commandID == "app.uninstall" }?.exposures,
      [.cli]
    )
    XCTAssertNotNil(catalog.commandCatalog.productActions.first {
      $0.commandID == "gui.softwareKeyboard.toggle"
    })

    let root = CommandMatrixCoverageSupport.repositoryRoot()
    for relativePath in [
      "Sources/PulsePhoneGUI/ProductionGUIHost.swift",
      "Sources/PulsePhoneGUI/ToolbarBinding.swift",
      "Sources/PulsePhoneRuntimeExecutable/ProductionRuntimeServer.swift",
    ] {
      let source = try String(
        contentsOf: root.appendingPathComponent(relativePath),
        encoding: .utf8
      )
      XCTAssertFalse(source.contains("coredevice.keyboard.option-command-k"), relativePath)
    }
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: root.appendingPathComponent(
        "Schemas/result-schemas/software-keyboard-toggle.v1.schema.json"
      ).path
    ))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: root.appendingPathComponent(
        "Sources/PulsePhoneBackendAdapters/SoftwareKeyboardToggleAction.swift"
      ).path
    ))

    for relativePath in [
      "Fixtures/requirements/T-005/legacy-capability-negative-exposure-l5/expected.v1.json",
      "Fixtures/requirements/T-009/hidden-entry-negative-exposure-l0/expected.v1.json",
    ] {
      let requirementExpected = try CommandMatrixCoverageSupport.loadCanonicalObject(relativePath)
      XCTAssertEqual(requirementExpected["outcome"]?.stringValue, "passed")
      XCTAssertEqual(
        try requirementExpected["residualPublicExposureCount"]?.numberValue?.requireUInt64(),
        0
      )
    }
  }
}
