import PulsePhoneClientCore
import PulsePhoneSharedDefinitions

public struct DeviceStatusCommand: Sendable {
    private let queries: LocalDeviceQueries

    public init(queries: LocalDeviceQueries) {
        self.queries = queries
    }

    public func run(
        canonicalUDID: CanonicalUDID? = nil,
        outputMode: LocalDeviceCommandOutputMode
    ) throws -> String {
        let result = try queries.deviceStatus(canonicalUDID: canonicalUDID)
        switch outputMode {
        case .json:
            return try LocalDeviceCommandRendering.json(result)
        case .human:
            return [
                "UDID: \(result.canonicalUDID.rawValue)",
                "Name: \(LocalDeviceCommandRendering.value(result.name))",
                "Condition: \(result.condition.rawValue)",
            ].joined(separator: "\n")
        }
    }
}
