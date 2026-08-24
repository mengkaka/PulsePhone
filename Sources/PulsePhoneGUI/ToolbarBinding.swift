import Foundation
import PulsePhoneAvailability
import PulsePhoneCommandCatalog
import PulsePhoneCommandPlanner

public enum ToolbarCompatibilityProjection: Equatable, Sendable {
    case compatible
    case incompatible(reason: String)
    case unknown
}

public enum ToolbarAvailabilityProjection: Equatable, Sendable {
    case available
    case loading(reason: String)
    case unavailable(reason: String)
    case unknown(reason: String)
}

public enum ToolbarBindingError: Error, Equatable, Sendable {
    case duplicateProjection
    case missingProjection(String)
    case unsupportedToolbarCommand(String)
}

public enum ToolbarBinding {
    public static func freeze(
        catalog: CommandCatalogV1,
        compatibility: CompatibleCommandList,
        availability: EffectiveCommandAvailability
    ) throws -> LiveToolbar {
        var compatibilityProjection = [
            String: ToolbarCompatibilityProjection
        ]()
        for entry in compatibility.entries {
            guard compatibilityProjection.updateValue(
                project(entry.disposition),
                forKey: entry.commandID
            ) == nil else {
                throw ToolbarBindingError.duplicateProjection
            }
        }
        var availabilityProjection = [String: ToolbarAvailabilityProjection]()
        for entry in availability.entries {
            guard availabilityProjection.updateValue(
                project(entry.state),
                forKey: entry.commandID
            ) == nil else {
                throw ToolbarBindingError.duplicateProjection
            }
        }
        return try freeze(
            catalog: catalog,
            compatibilityByCommand: compatibilityProjection,
            availabilityByCommand: availabilityProjection
        )
    }

    public static func freeze(
        repositoryRoot: URL,
        compatibilityByCommand: [String: ToolbarCompatibilityProjection],
        availabilityByCommand: [String: ToolbarAvailabilityProjection]
    ) throws -> LiveToolbar {
        try freeze(
            catalog: CommandCatalog.load(repositoryRoot: repositoryRoot),
            compatibilityByCommand: compatibilityByCommand,
            availabilityByCommand: availabilityByCommand
        )
    }

    public static func freeze(
        catalog: CommandCatalogV1,
        compatibilityByCommand: [String: ToolbarCompatibilityProjection],
        availabilityByCommand: [String: ToolbarAvailabilityProjection]
    ) throws -> LiveToolbar {
        let toolbarRows = catalog.productActions.filter { descriptor in
            descriptor.guiSurface?.kind == .toolbar
        }
        let toolbar = toolbarRows.sorted { lhs, rhs in
            lhs.guiSurface!.order! < rhs.guiSurface!.order!
        }
        var slots = [LiveToolbarSlot]()
        slots.reserveCapacity(toolbar.count)
        for descriptor in toolbar {
            guard let compatibility = compatibilityByCommand[
                descriptor.commandID
            ] else {
                throw ToolbarBindingError.missingProjection(
                    descriptor.commandID
                )
            }
            switch compatibility {
            case .incompatible:
                continue
            case .unknown:
                slots.append(try slot(
                    descriptor: descriptor,
                    presentation: .loading(reason: "factsUnknown")
                ))
            case .compatible:
                guard let availability = availabilityByCommand[
                    descriptor.commandID
                ] else {
                    throw ToolbarBindingError.missingProjection(
                        descriptor.commandID
                    )
                }
                slots.append(try slot(
                    descriptor: descriptor,
                    presentation: presentation(availability)
                ))
            }
        }
        return try LiveToolbar(slots: slots)
    }

    private static func slot(
        descriptor: ProductCommandDescriptor,
        presentation: LiveToolbarPresentationState
    ) throws -> LiveToolbarSlot {
        guard let order = descriptor.guiSurface?.order else {
            throw ToolbarBindingError.unsupportedToolbarCommand(
                descriptor.commandID
            )
        }
        let kind: LiveToolbarControlKind
        let selected: Bool?
        switch descriptor.commandID {
        case "gui.keyboardCapture.toggle", "gui.previewAudioMute.toggle":
            kind = .checkedToggle
            selected = false
        case "app.install":
            kind = .installButtonAndDrop
            selected = nil
        case "button.appSwitcher", "button.home", "button.lock",
             "button.mute", "button.volumeDown", "button.volumeUp",
             "device.rotate", "gui.softwareKeyboard.toggle", "screenshot.gui":
            kind = .momentaryButton
            selected = nil
        default:
            throw ToolbarBindingError.unsupportedToolbarCommand(
                descriptor.commandID
            )
        }
        return LiveToolbarSlot(
            commandID: descriptor.commandID,
            controlKind: kind,
            order: order,
            presentation: presentation,
            selected: selected
        )
    }

    private static func presentation(
        _ availability: ToolbarAvailabilityProjection
    ) -> LiveToolbarPresentationState {
        switch availability {
        case .available:
            .enabled
        case .loading(let reason), .unknown(let reason):
            .loading(reason: reason)
        case .unavailable(let reason):
            .disabled(reason: reason)
        }
    }

    private static func project(
        _ disposition: CompatibilityDisposition
    ) -> ToolbarCompatibilityProjection {
        switch disposition {
        case .compatible:
            .compatible
        case .incompatible(let reason):
            .incompatible(reason: reason)
        case .unknown:
            .unknown
        }
    }

    private static func project(
        _ availability: PlanningAvailability
    ) -> ToolbarAvailabilityProjection {
        switch availability {
        case .available:
            .available
        case .preparable:
            .loading(reason: "capabilityPreparing")
        case .unavailable(let reason):
            .unavailable(reason: reason)
        case .unknown(let reason):
            .unknown(reason: reason)
        }
    }
}
