import PulsePhoneHostPaths

public enum PulsePhoneConfigurationKey: String, CaseIterable, Sendable {
    case omniParserEndpoint = "omniparser.endpoint"

    public var summary: String {
        switch self {
        case .omniParserEndpoint:
            "Optional OmniParser service URL. Applies to newly started device runtimes."
        }
    }
}

public enum PulsePhoneConfigurationRegistryError: Error, Equatable, Sendable {
    case unknownKey
    case invalidValue
}

public enum PulsePhoneConfigurationRegistry {
    public static func key(named value: String) -> PulsePhoneConfigurationKey? {
        PulsePhoneConfigurationKey(rawValue: value)
    }

    public static func validate(
        key: PulsePhoneConfigurationKey,
        rawValue: String
    ) throws -> PulsePhoneConfigurationValue {
        switch key {
        case .omniParserEndpoint:
            do {
                _ = try OmniParserEndpointConfiguration(
                    endpointString: rawValue,
                    source: .managedConfiguration
                )
                return .string(rawValue)
            } catch {
                throw PulsePhoneConfigurationRegistryError.invalidValue
            }
        }
    }

    public static func omniParserEndpoint(
        in snapshot: PulsePhoneConfigurationSnapshot
    ) throws -> String? {
        guard let value = snapshot.values[
            PulsePhoneConfigurationKey.omniParserEndpoint.rawValue
        ] else { return nil }
        guard case let .string(endpoint) = value else {
            throw PulsePhoneConfigurationRegistryError.invalidValue
        }
        return endpoint
    }
}
