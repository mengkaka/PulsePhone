import PulsePhoneSharedDefinitions

public enum DeviceTargetSelectionSource: String, Equatable, Sendable {
    case explicit
    case defaultCanonicalFirst
}

public struct SelectedDeviceTarget: Equatable, Sendable {
    public let device: USBDiscoveredDevice
    public let source: DeviceTargetSelectionSource
}

public enum DeviceTargetSelectorError: Error, Equatable, Sendable {
    case noDeviceConnected
    case deviceNotFound(CanonicalUDID)
}

public enum DeviceTargetSelector: Sendable {
    public static func select(
        explicit canonicalUDID: CanonicalUDID? = nil,
        from snapshot: USBDiscoverySnapshot
    ) throws -> SelectedDeviceTarget {
        if let canonicalUDID {
            guard let device = snapshot.device(for: canonicalUDID) else {
                throw DeviceTargetSelectorError.deviceNotFound(canonicalUDID)
            }
            return SelectedDeviceTarget(device: device, source: .explicit)
        }
        guard let device = DeviceEligibility.defaultEligibleDevices(
            in: snapshot
        ).first else {
            throw DeviceTargetSelectorError.noDeviceConnected
        }
        return SelectedDeviceTarget(
            device: device,
            source: .defaultCanonicalFirst
        )
    }
}
