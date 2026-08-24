import Foundation
import PulsePhoneClientCore

public enum LocalDeviceCommandOutputMode: Sendable {
    case human
    case json
}

enum LocalDeviceCommandRendering {
    static let unknown = "unknown"

    static func json<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func value(_ value: String?) -> String {
        value ?? unknown
    }
}

public struct DevicesCommand: Sendable {
    private let queries: LocalDeviceQueries

    public init(queries: LocalDeviceQueries) {
        self.queries = queries
    }

    public func run(
        outputMode: LocalDeviceCommandOutputMode
    ) throws -> String {
        let result = try queries.devices()
        switch outputMode {
        case .json:
            return try LocalDeviceCommandRendering.json(result)
        case .human:
            let header = "UDID\tNAME\tCLASS\tOS\tBUILD"
            let rows = result.devices.map { device in
                [
                    device.canonicalUDID.rawValue,
                    LocalDeviceCommandRendering.value(device.name),
                    device.deviceClass,
                    device.osVersion,
                    device.osBuild,
                ].joined(separator: "\t")
            }
            return ([header] + rows).joined(separator: "\n")
        }
    }
}
