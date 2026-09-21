import PulsePhoneHostPaths

public enum PulsePhoneConfigurationKey: String, CaseIterable, Sendable {
    case omniParserEndpoint = "omniparser.endpoint"
    case developerImageUseDevCatalog = "developerImage.useDevCatalog"

    public var summary: String {
        switch self {
        case .omniParserEndpoint:
            "Optional OmniParser service URL. Applies to newly started device runtimes."
        case .developerImageUseDevCatalog:
            "Use the developer-image dev catalog for newly started device runtimes."
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
        case .developerImageUseDevCatalog:
            switch rawValue.lowercased() {
            case "true": return .boolean(true)
            case "false": return .boolean(false)
            default: throw PulsePhoneConfigurationRegistryError.invalidValue
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

    public static func developerImageUseDevCatalog(
        in snapshot: PulsePhoneConfigurationSnapshot
    ) throws -> Bool {
        guard let value = snapshot.values[
            PulsePhoneConfigurationKey.developerImageUseDevCatalog.rawValue
        ] else { return false }
        guard case let .boolean(useDevCatalog) = value else {
            throw PulsePhoneConfigurationRegistryError.invalidValue
        }
        return useDevCatalog
    }
}
