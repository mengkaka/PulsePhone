public enum LiveToolbarControlKind: String, Equatable, Sendable {
    case checkedToggle
    case installButtonAndDrop
    case momentaryButton
}

public enum LiveToolbarPresentationState: Equatable, Sendable {
    case disabled(reason: String)
    case enabled
    case loading(reason: String)
}

public struct LiveToolbarSlot: Equatable, Sendable {
    public let commandID: String
    public let controlKind: LiveToolbarControlKind
    public let order: UInt64
    public private(set) var presentation: LiveToolbarPresentationState
    public private(set) var selected: Bool?

    public init(
        commandID: String,
        controlKind: LiveToolbarControlKind,
        order: UInt64,
        presentation: LiveToolbarPresentationState,
        selected: Bool?
    ) {
        self.commandID = commandID
        self.controlKind = controlKind
        self.order = order
        self.presentation = presentation
        self.selected = selected
    }

    fileprivate mutating func update(
        presentation: LiveToolbarPresentationState
    ) {
        self.presentation = presentation
    }

    fileprivate mutating func setSelected(_ selected: Bool) {
        self.selected = selected
    }
}

public struct LiveToolbarRuntimeUpdate: Equatable, Sendable {
    public let commandID: String
    public let presentation: LiveToolbarPresentationState

    public init(
        commandID: String,
        presentation: LiveToolbarPresentationState
    ) {
        self.commandID = commandID
        self.presentation = presentation
    }
}

public enum LiveToolbarError: Error, Equatable, Sendable {
    case duplicateCommandID
    case duplicateOrder
    case invalidLocalToggle
    case nonMonotonicRevision
    case unknownFrozenSlot
}

public struct LiveToolbar: Equatable, Sendable {
    public private(set) var revision: UInt64
    public private(set) var slots: [LiveToolbarSlot]

    public init(slots: [LiveToolbarSlot], revision: UInt64 = 0) throws {
        guard Set(slots.map(\.commandID)).count == slots.count else {
            throw LiveToolbarError.duplicateCommandID
        }
        guard Set(slots.map(\.order)).count == slots.count else {
            throw LiveToolbarError.duplicateOrder
        }
        self.slots = slots.sorted { $0.order < $1.order }
        self.revision = revision
    }

    public var commandIDs: [String] { slots.map(\.commandID) }

    public mutating func applyRuntimeSnapshot(
        revision: UInt64,
        updates: [LiveToolbarRuntimeUpdate]
    ) throws {
        guard revision >= self.revision else {
            throw LiveToolbarError.nonMonotonicRevision
        }
        guard Set(updates.map(\.commandID)).count == updates.count else {
            throw LiveToolbarError.duplicateCommandID
        }
        var next = slots
        for update in updates {
            guard let index = next.firstIndex(where: {
                $0.commandID == update.commandID
            }) else {
                throw LiveToolbarError.unknownFrozenSlot
            }
            if Self.transientCompetition(update.presentation) {
                continue
            }
            next[index].update(presentation: update.presentation)
        }
        slots = next
        self.revision = revision
    }

    public mutating func setLocalToggle(
        commandID: String,
        selected: Bool
    ) throws {
        guard let index = slots.firstIndex(where: {
            $0.commandID == commandID
        }) else {
            throw LiveToolbarError.unknownFrozenSlot
        }
        guard slots[index].controlKind == .checkedToggle else {
            throw LiveToolbarError.invalidLocalToggle
        }
        slots[index].setSelected(selected)
    }

    public mutating func setLocalPresentation(
        commandID: String,
        presentation: LiveToolbarPresentationState
    ) throws {
        guard let index = slots.firstIndex(where: {
            $0.commandID == commandID
        }) else {
            throw LiveToolbarError.unknownFrozenSlot
        }
        guard slots[index].controlKind == .checkedToggle else {
            throw LiveToolbarError.invalidLocalToggle
        }
        slots[index].update(presentation: presentation)
    }

    private static func transientCompetition(
        _ presentation: LiveToolbarPresentationState
    ) -> Bool {
        guard case .disabled(let reason) = presentation else { return false }
        return [
            "admissionCapacityExceeded", "queueFull", "resourceBusy",
        ].contains(reason)
    }
}
