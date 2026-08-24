public enum DeviceEligibility: Sendable {
    public static func isDefaultEligible(
        _ device: USBDiscoveredDevice
    ) -> Bool {
        device.facts.deviceClass == "iPhone"
    }

    public static func defaultEligibleDevices(
        in snapshot: USBDiscoverySnapshot
    ) -> [USBDiscoveredDevice] {
        snapshot.devices.filter(isDefaultEligible)
    }
}
