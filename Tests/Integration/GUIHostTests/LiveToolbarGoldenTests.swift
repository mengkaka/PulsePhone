import Foundation
@testable import PulsePhoneGUI
import PulsePhoneSharedDefinitions
import XCTest

final class LiveToolbarGoldenTests: XCTestCase {
    func testTwelveSlotCatalogOrderControlAndStateGolden() throws {
        let input = try load(FixtureInput.self, "input.v1.json")
        let expected = try load(FixtureExpected.self, "expected.v1.json")
        var toolbar = try ToolbarBinding.freeze(
            repositoryRoot: repositoryRoot(),
            compatibilityByCommand: Dictionary(
                uniqueKeysWithValues: input.entries.map {
                    ($0.commandID, compatibility($0.compatibility))
                }
            ),
            availabilityByCommand: Dictionary(
                uniqueKeysWithValues: input.entries.map {
                    ($0.commandID, availability($0.availability))
                }
            )
        )

        XCTAssertEqual(toolbar.commandIDs, expected.commandIDs)
        XCTAssertEqual(toolbar.slots.map(\.order), expected.orders)
        XCTAssertEqual(
            toolbar.slots.map(\.controlKind.rawValue),
            expected.controlKinds
        )
        XCTAssertEqual(toolbar.slots.count, 12)
        XCTAssertEqual(
            toolbar.slots.first(where: {
                $0.commandID == "gui.softwareKeyboard.toggle"
            })?.controlKind,
            .momentaryButton
        )
        XCTAssertEqual(
            toolbar.slots.first(where: {
                $0.commandID == input.unknownCommandID
            })?.presentation,
            .loading(reason: "factsUnknown")
        )

        let originalShape = toolbar.slots.map {
            "\($0.commandID)|\($0.order)|\($0.controlKind.rawValue)"
        }
        try toolbar.applyRuntimeSnapshot(
            revision: 2,
            updates: [
                LiveToolbarRuntimeUpdate(
                    commandID: "screenshot.gui",
                    presentation: .enabled
                ),
                LiveToolbarRuntimeUpdate(
                    commandID: "app.install",
                    presentation: .disabled(reason: "resourceBusy")
                ),
            ]
        )
        XCTAssertEqual(
            toolbar.slots.map {
                "\($0.commandID)|\($0.order)|\($0.controlKind.rawValue)"
            },
            originalShape
        )
        XCTAssertEqual(
            toolbar.slots.first(where: { $0.commandID == "app.install" })?
                .presentation,
            .enabled
        )
        try toolbar.setLocalToggle(
            commandID: "gui.keyboardCapture.toggle",
            selected: true
        )
        XCTAssertEqual(
            toolbar.slots.first(where: {
                $0.commandID == "gui.keyboardCapture.toggle"
            })?.selected,
            true
        )
    }

    func testIncompatibleIsOmittedWhileUnknownKeepsFrozenSlot() throws {
        let input = try load(FixtureInput.self, "input.v1.json")
        var compatibilityMap: [String: ToolbarCompatibilityProjection] = Dictionary(
            uniqueKeysWithValues: input.entries.map {
                ($0.commandID, compatibility($0.compatibility))
            }
        )
        compatibilityMap["app.install"] = .incompatible(
            reason: "unsupportedOSVersion"
        )
        compatibilityMap["screenshot.gui"] = .unknown
        let toolbar = try ToolbarBinding.freeze(
            repositoryRoot: repositoryRoot(),
            compatibilityByCommand: compatibilityMap,
            availabilityByCommand: Dictionary(
                uniqueKeysWithValues: input.entries.map {
                    ($0.commandID, availability($0.availability))
                }
            )
        )
        XCTAssertFalse(toolbar.commandIDs.contains("app.install"))
        XCTAssertTrue(toolbar.commandIDs.contains("screenshot.gui"))
        XCTAssertEqual(toolbar.slots.count, 11)
    }

    func testLegacyAvailabilityOmitsKeyboardCaptureWithModernControls() throws {
        let commands = [
            "button.home", "button.appSwitcher", "button.lock",
            "button.volumeUp", "button.volumeDown", "button.mute",
            "device.rotate", "screenshot.gui", "gui.keyboardCapture.toggle",
            "gui.softwareKeyboard.toggle", "gui.previewAudioMute.toggle",
            "app.install",
        ]
        let unsupportedCommands: Set<String> = [
            "button.home", "button.appSwitcher", "button.lock",
            "button.volumeUp", "button.volumeDown", "button.mute",
            "device.rotate", "gui.keyboardCapture.toggle",
            "gui.softwareKeyboard.toggle",
        ]
        let availability = try RepositoryJSONObject(members: [
            RepositoryJSONMember(
                key: "commands",
                value: .array(try commands.map { commandID in
                    let unsupported = unsupportedCommands.contains(commandID)
                    var members = [
                        RepositoryJSONMember(
                            key: "commandID",
                            value: .string(commandID)
                        ),
                        RepositoryJSONMember(
                            key: "state",
                            value: .string(unsupported ? "disabled" : "enabled")
                        ),
                    ]
                    if unsupported {
                        members.append(RepositoryJSONMember(
                            key: "reasonCode",
                            value: .string("unsupportedOSVersion")
                        ))
                    }
                    return .object(try RepositoryJSONObject(members: members))
                })
            ),
        ])

        let toolbar = try ProductionGUIHostToolbarProjection.make(
            availability: availability,
            repositoryRoot: repositoryRoot()
        )
        XCTAssertEqual(toolbar.commandIDs, [
            "screenshot.gui", "gui.previewAudioMute.toggle", "app.install",
        ])
        XCTAssertFalse(toolbar.commandIDs.contains("gui.keyboardCapture.toggle"))
        XCTAssertFalse(toolbar.commandIDs.contains("gui.softwareKeyboard.toggle"))
    }

    func testRuntimeCannotAddSlotRegressRevisionOrToggleMomentary() throws {
        var toolbar = try allCompatibleToolbar()
        XCTAssertThrowsError(try toolbar.applyRuntimeSnapshot(
            revision: 1,
            updates: [LiveToolbarRuntimeUpdate(
                commandID: "app.launch",
                presentation: .enabled
            )]
        )) { error in
            XCTAssertEqual(error as? LiveToolbarError, .unknownFrozenSlot)
        }
        try toolbar.applyRuntimeSnapshot(revision: 3, updates: [])
        XCTAssertThrowsError(try toolbar.applyRuntimeSnapshot(
            revision: 2,
            updates: []
        )) { error in
            XCTAssertEqual(error as? LiveToolbarError, .nonMonotonicRevision)
        }
        XCTAssertThrowsError(try toolbar.setLocalToggle(
            commandID: "screenshot.gui",
            selected: true
        )) { error in
            XCTAssertEqual(error as? LiveToolbarError, .invalidLocalToggle)
        }
    }

    func testPickerAndDropOnlyProduceValidatedInstallParameter() throws {
        XCTAssertEqual(try ToolbarPicker.resolve(selectedPath: nil), .cancelled)
        XCTAssertThrowsError(try ToolbarPicker.resolve(
            selectedPath: "relative/App.ipa"
        ))
        XCTAssertThrowsError(try ToolbarPicker.resolve(
            selectedPath: "/tmp/../tmp/App.ipa"
        ))
        XCTAssertThrowsError(try ToolbarPicker.resolve(
            selectedPath: "/tmp/App.ipa",
            isRegularFile: false
        ))
        XCTAssertEqual(
            try ToolbarPicker.resolve(selectedPath: "/tmp/App.ipa"),
            .accepted(ToolbarInstallParameter(absoluteIPAPath: "/tmp/App.ipa"))
        )
        XCTAssertEqual(
            try ToolbarDropTarget.resolve(candidates: [ToolbarDropCandidate(
                path: "/tmp/Drop.ipa",
                isRegularFile: true
            )]),
            ToolbarInstallParameter(absoluteIPAPath: "/tmp/Drop.ipa")
        )
        XCTAssertThrowsError(try ToolbarDropTarget.resolve(candidates: []))
        XCTAssertThrowsError(try ToolbarDropTarget.resolve(candidates: [
            ToolbarDropCandidate(path: "/tmp/A.ipa", isRegularFile: true),
            ToolbarDropCandidate(path: "/tmp/B.ipa", isRegularFile: true),
        ]))
        XCTAssertThrowsError(try ToolbarDropTarget.resolve(candidates: [
            ToolbarDropCandidate(path: "/tmp/folder.ipa", isRegularFile: false),
        ]))
    }

    private func allCompatibleToolbar() throws -> LiveToolbar {
        let input = try load(FixtureInput.self, "input.v1.json")
        return try ToolbarBinding.freeze(
            repositoryRoot: repositoryRoot(),
            compatibilityByCommand: Dictionary(
                uniqueKeysWithValues: input.entries.map {
                    ($0.commandID, ToolbarCompatibilityProjection.compatible)
                }
            ),
            availabilityByCommand: Dictionary(
                uniqueKeysWithValues: input.entries.map {
                    ($0.commandID, availability($0.availability))
                }
            )
        )
    }

    private func compatibility(
        _ value: String
    ) -> ToolbarCompatibilityProjection {
        switch value {
        case "compatible": .compatible
        case "unknown": .unknown
        default: .incompatible(reason: value)
        }
    }

    private func availability(
        _ value: String
    ) -> ToolbarAvailabilityProjection {
        switch value {
        case "available": .available
        case "preparing": .loading(reason: "capabilityPreparing")
        case "unknown": .unknown(reason: "runtimeStateUnknown")
        default: .unavailable(reason: value)
        }
    }

    private func load<Value: Decodable>(
        _ type: Value.Type,
        _ name: String
    ) throws -> Value {
        try JSONDecoder().decode(
            type,
            from: Data(contentsOf: fixtureRoot().appendingPathComponent(name))
        )
    }

    private func fixtureRoot() -> URL {
        repositoryRoot().appendingPathComponent(
            "Fixtures/product-actions/live-toolbar"
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct FixtureInput: Decodable {
    let entries: [FixtureEntry]
    let unknownCommandID: String
}

private struct FixtureEntry: Decodable {
    let availability: String
    let commandID: String
    let compatibility: String
}

private struct FixtureExpected: Decodable {
    let commandIDs: [String]
    let controlKinds: [String]
    let orders: [UInt64]
}
