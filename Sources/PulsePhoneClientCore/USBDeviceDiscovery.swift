import PulsePhoneSharedDefinitions

public protocol LocalDeviceFactsProviding: Sendable {
    func enumerate() throws -> RawDiscoverySnapshot
    func probe(
        deviceID: UInt64,
        rawTransportUDID: String
    ) throws -> LocalDeviceFactsResult
}

extension LocalDeviceFactsProbe: LocalDeviceFactsProviding {}

public enum USBDeviceDiscoveryError: Error, Equatable, Sendable {
    case snapshotLimitExceeded(actual: Int, limit: Int)
    case duplicateDeviceID(UInt64)
    case invalidIdentity(DeviceIdentityMapError)
    case probeIdentityMismatch(deviceID: UInt64)
}

public struct USBDiscoveredDevice: Equatable, Sendable {
    public let deviceID: UInt64
    public let rawTransportUDID: String
    public let canonicalUDID: CanonicalUDID
    public let facts: LocalDeviceFacts
    public let condition: LocalDeviceCondition
}

public struct USBDiscoverySnapshot: Equatable, Sendable {
    public let observedAtMonotonicNanoseconds: UInt64
    public let devices: [USBDiscoveredDevice]

    public var canonicalUDIDs: [CanonicalUDID] {
        devices.map(\.canonicalUDID)
    }

    public func device(for canonicalUDID: CanonicalUDID) -> USBDiscoveredDevice? {
        devices.first { $0.canonicalUDID == canonicalUDID }
    }
}

public struct USBDeviceDiscovery: Sendable {
    private let factsProvider: any LocalDeviceFactsProviding

    public init(factsProvider: any LocalDeviceFactsProviding) {
        self.factsProvider = factsProvider
    }

    public func discover() throws -> USBDiscoverySnapshot {
        let rawSnapshot = try factsProvider.enumerate()
        return try Self.materialize(rawSnapshot) { device in
            try factsProvider.probe(
                deviceID: device.deviceID,
                rawTransportUDID: device.rawTransportUDID
            )
        }
    }

    static func materialize(
        _ rawSnapshot: RawDiscoverySnapshot,
        probe: (RawDiscoveredDevice) throws -> LocalDeviceFactsResult
    ) throws -> USBDiscoverySnapshot {
        guard rawSnapshot.devices.count <= LocalDeviceFactsProbe.deviceLimit else {
            throw USBDeviceDiscoveryError.snapshotLimitExceeded(
                actual: rawSnapshot.devices.count,
                limit: LocalDeviceFactsProbe.deviceLimit
            )
        }
        let usbDevices = rawSnapshot.devices.filter { $0.transport == .usb }
        let uniqueDeviceIDs = Set(usbDevices.map(\.deviceID))
        guard uniqueDeviceIDs.count == usbDevices.count else {
            let duplicate = Dictionary(grouping: usbDevices, by: \.deviceID)
                .first { $0.value.count > 1 }!
                .key
            throw USBDeviceDiscoveryError.duplicateDeviceID(duplicate)
        }

        let identityMap: DeviceIdentityMap
        do {
            identityMap = try DeviceIdentityMap(
                rawTransportUDIDs: usbDevices.map(\.rawTransportUDID)
            )
        } catch let error as DeviceIdentityMapError {
            throw USBDeviceDiscoveryError.invalidIdentity(error)
        }

        var materialized = [USBDiscoveredDevice]()
        materialized.reserveCapacity(usbDevices.count)
        for device in usbDevices {
            let result = try probe(device)
            guard result.facts.uniqueDeviceID == device.rawTransportUDID,
                  let canonicalUDID = identityMap.canonicalUDID(
                    forRawTransportUDID: device.rawTransportUDID
                  )
            else {
                throw USBDeviceDiscoveryError.probeIdentityMismatch(
                    deviceID: device.deviceID
                )
            }
            materialized.append(
                USBDiscoveredDevice(
                    deviceID: device.deviceID,
                    rawTransportUDID: device.rawTransportUDID,
                    canonicalUDID: canonicalUDID,
                    facts: result.facts,
                    condition: result.condition
                )
            )
        }
        materialized.sort { $0.canonicalUDID < $1.canonicalUDID }
        return USBDiscoverySnapshot(
            observedAtMonotonicNanoseconds: rawSnapshot.observedAtMonotonicNanoseconds,
            devices: materialized
        )
    }
}
