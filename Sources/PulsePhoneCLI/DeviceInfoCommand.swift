import PulsePhoneClientCore
import PulsePhoneSharedDefinitions

public struct DeviceInfoCommand: Sendable {
    private let queries: LocalDeviceQueries

    public init(queries: LocalDeviceQueries) {
        self.queries = queries
    }

    public func run(
        canonicalUDID: CanonicalUDID? = nil,
        outputMode: LocalDeviceCommandOutputMode
    ) throws -> String {
        let result = try queries.deviceInfo(canonicalUDID: canonicalUDID)
        switch outputMode {
        case .json:
            return try LocalDeviceCommandRendering.json(result)
        case .human:
            return [
                "UDID: \(result.canonicalUDID.rawValue)",
                "Name: \(LocalDeviceCommandRendering.value(result.name))",
                "Class: \(result.deviceClass)",
                "OS: \(result.osVersion)",
                "Build: \(result.osBuild)",
                "Probe provenance: \(result.probeProvenance.rawValue)",
            ].joined(separator: "\n")
        }
    }
}
