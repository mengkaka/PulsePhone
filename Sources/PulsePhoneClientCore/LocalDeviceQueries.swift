import Foundation
import PulsePhoneSharedDefinitions

public protocol USBDeviceDiscovering: Sendable {
    func discover() throws -> USBDiscoverySnapshot
}

extension USBDeviceDiscovery: USBDeviceDiscovering {}

public enum DeviceFactsProvenance: String, Codable, Equatable, Sendable {
    case factsProbe
    case snapshot
}

public enum DeviceStatusCondition: String, Codable, Equatable, Sendable {
    case available
    case busy
    case disconnected
    case locked
    case unknown
}

public struct DeviceListItem: Codable, Equatable, Sendable {
    public let canonicalUDID: CanonicalUDID
    public let deviceClass: String
    public let name: String?
    public let osBuild: String
    public let osVersion: String
}

public struct DeviceListResult: Codable, Equatable, Sendable {
    public let devices: [DeviceListItem]
    public let truncated: Bool
}

public struct DeviceInfoResult: Codable, Equatable, Sendable {
    public let canonicalUDID: CanonicalUDID
    public let deviceClass: String
    public let name: String?
    public let osBuild: String
    public let osVersion: String
    public let probeProvenance: DeviceFactsProvenance
}

public struct DeviceStatusResult: Codable, Equatable, Sendable {
    public let canonicalUDID: CanonicalUDID
    public let condition: DeviceStatusCondition
    public let name: String?
}

public enum LocalDeviceQueryError: Error, Equatable, Sendable {
    case noDeviceConnected
    case deviceNotFound(CanonicalUDID)
    case invalidProjection(field: String)
}

public struct LocalDeviceQueries: Sendable {
    private enum Source: Sendable {
        case discovery(any USBDeviceDiscovering)
        case snapshot(USBDiscoverySnapshot)
    }

    private let source: Source

    public init(discovery: any USBDeviceDiscovering) {
        self.source = .discovery(discovery)
    }

    public init(snapshot: USBDiscoverySnapshot) {
        self.source = .snapshot(snapshot)
    }

    public func devices() throws -> DeviceListResult {
        let (snapshot, _) = try loadSnapshot()
        let devices = try snapshot.devices.map(Self.listItem)
        return DeviceListResult(devices: devices, truncated: false)
    }

    public func deviceInfo(
        canonicalUDID: CanonicalUDID? = nil
    ) throws -> DeviceInfoResult {
        let (snapshot, provenance) = try loadSnapshot()
        let selected = try select(canonicalUDID, from: snapshot)
        let facts = selected.device.facts
        return DeviceInfoResult(
            canonicalUDID: selected.device.canonicalUDID,
            deviceClass: try Self.required(
                facts.deviceClass,
                field: "deviceClass",
                maximumBytes: 64
            ),
            name: try Self.optionalName(facts.deviceName),
            osBuild: try Self.required(
                facts.buildVersion,
                field: "osBuild",
                maximumBytes: 64
            ),
            osVersion: try Self.required(
                facts.productVersion,
                field: "osVersion",
                maximumBytes: 64
            ),
            probeProvenance: provenance
        )
    }

    public func deviceStatus(
        canonicalUDID: CanonicalUDID? = nil
    ) throws -> DeviceStatusResult {
        let (snapshot, _) = try loadSnapshot()
        let selected = try select(canonicalUDID, from: snapshot)
        return DeviceStatusResult(
            canonicalUDID: selected.device.canonicalUDID,
            condition: Self.statusCondition(selected.device.condition),
            name: try Self.optionalName(selected.device.facts.deviceName)
        )
    }

    private func loadSnapshot() throws -> (
        USBDiscoverySnapshot,
        DeviceFactsProvenance
    ) {
        switch source {
        case let .discovery(discovery):
            return (Self.sorted(try discovery.discover()), .factsProbe)
        case let .snapshot(snapshot):
            return (Self.sorted(snapshot), .snapshot)
        }
    }

    private static func sorted(
        _ snapshot: USBDiscoverySnapshot
    ) -> USBDiscoverySnapshot {
        USBDiscoverySnapshot(
            observedAtMonotonicNanoseconds: snapshot.observedAtMonotonicNanoseconds,
            devices: snapshot.devices.sorted {
                $0.canonicalUDID < $1.canonicalUDID
            }
        )
    }

    private func select(
        _ canonicalUDID: CanonicalUDID?,
        from snapshot: USBDiscoverySnapshot
    ) throws -> SelectedDeviceTarget {
        do {
            return try DeviceTargetSelector.select(
                explicit: canonicalUDID,
                from: snapshot
            )
        } catch DeviceTargetSelectorError.noDeviceConnected {
            throw LocalDeviceQueryError.noDeviceConnected
        } catch let DeviceTargetSelectorError.deviceNotFound(udid) {
            throw LocalDeviceQueryError.deviceNotFound(udid)
        }
    }

    private static func listItem(
        _ device: USBDiscoveredDevice
    ) throws -> DeviceListItem {
        DeviceListItem(
            canonicalUDID: device.canonicalUDID,
            deviceClass: try required(
                device.facts.deviceClass,
                field: "deviceClass",
                maximumBytes: 64
            ),
            name: try optionalName(device.facts.deviceName),
            osBuild: try required(
                device.facts.buildVersion,
                field: "osBuild",
                maximumBytes: 64
            ),
            osVersion: try required(
                device.facts.productVersion,
                field: "osVersion",
                maximumBytes: 64
            )
        )
    }

    private static func statusCondition(
        _ condition: LocalDeviceCondition
    ) -> DeviceStatusCondition {
        guard condition.connected else { return .disconnected }
        guard !condition.locked else { return .locked }
        guard condition.trusted else { return .unknown }
        return .available
    }

    private static func required(
        _ value: String,
        field: String,
        maximumBytes: Int
    ) throws -> String {
        let byteCount = value.utf8.count
        guard (1...maximumBytes).contains(byteCount),
              !value.utf8.contains(0)
        else {
            throw LocalDeviceQueryError.invalidProjection(field: field)
        }
        return value
    }

    private static func optionalName(_ value: String) throws -> String? {
        guard !value.isEmpty else { return nil }
        guard value.utf8.count <= 256, !value.utf8.contains(0) else {
            throw LocalDeviceQueryError.invalidProjection(field: "name")
        }
        return value
    }
}
