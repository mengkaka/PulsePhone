import Foundation

public enum OmniParserEndpointSource: String, Equatable, Sendable {
    case environment
    case managedConfiguration
}

public enum OmniParserEndpointNetworkScope: String, Equatable, Sendable {
    case loopback
    case configured
}

public struct OmniParserEndpointConfiguration: Equatable, Sendable {
    public static let environmentKey = "PULSEPHONE_OMNIPARSER_ENDPOINT"
    public static let maximumEndpointBytes = 2_048

    public let endpoint: URL
    public let networkScope: OmniParserEndpointNetworkScope
    public let probeEndpoint: URL
    public let redactedHost: String
    public let source: OmniParserEndpointSource
    public let usesTLS: Bool

    public var diagnostics: OmniParserEndpointDiagnostics {
        OmniParserEndpointDiagnostics(
            networkScope: networkScope,
            redactedHost: redactedHost,
            source: source,
            usesTLS: usesTLS
        )
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        managedEndpoint: String?
    ) throws -> Self? {
        if let environmentEndpoint = environment[Self.environmentKey] {
            return try Self(
                endpointString: environmentEndpoint,
                source: .environment
            )
        }
        guard let managedEndpoint else { return nil }
        return try Self(
            endpointString: managedEndpoint,
            source: .managedConfiguration
        )
    }

    public init(
        endpointString: String,
        source: OmniParserEndpointSource
    ) throws {
        guard !endpointString.isEmpty,
              endpointString.utf8.count <= Self.maximumEndpointBytes,
              !endpointString.utf8.contains(0),
              endpointString == endpointString.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              let components = URLComponents(string: endpointString),
              ["http", "https"].contains(components.scheme?.lowercased()),
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let endpoint = components.url,
              let probeEndpoint = Self.probeEndpoint(from: components)
        else {
            throw ElementAnalyzerError.invalidEndpoint
        }
        let scheme = components.scheme!.lowercased()
        let networkScope: OmniParserEndpointNetworkScope = Self.isLoopback(host)
            ? .loopback : .configured
        self.endpoint = endpoint
        self.networkScope = networkScope
        self.probeEndpoint = probeEndpoint
        let diagnosticHost = host.contains(":") && !host.hasPrefix("[")
            ? "[\(host)]" : host
        self.redactedHost = components.port.map {
            "\(diagnosticHost):\($0)"
        } ?? diagnosticHost
        self.source = source
        self.usesTLS = scheme == "https"
    }

    private static func isLoopback(_ host: String) -> Bool {
        let normalized = normalizedAddressHost(host)
        if normalized == "localhost" || normalized.hasSuffix(".localhost")
            || normalized == "::1"
        {
            return true
        }
        guard let octets = ipv4Octets(normalized) else { return false }
        return octets[0] == 127
    }

    private static func ipv4Octets(_ host: String) -> [UInt8]? {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return nil }
        var octets = [UInt8]()
        for component in components {
            guard !component.isEmpty,
                  component.count <= 3,
                  component.allSatisfy(\.isNumber),
                  (component.count == 1 || component.first != "0"),
                  let octet = UInt8(component)
            else { return nil }
            octets.append(octet)
        }
        return octets
    }

    private static func normalizedAddressHost(_ host: String) -> String {
        let normalized = host.lowercased()
        guard normalized.hasPrefix("["), normalized.hasSuffix("]") else {
            return normalized
        }
        return String(normalized.dropFirst().dropLast())
    }

    private static func probeEndpoint(from components: URLComponents) -> URL? {
        var probe = components
        var segments = probe.path.split(separator: "/", omittingEmptySubsequences: true)
        guard !segments.isEmpty else { return nil }
        segments.removeLast()
        segments.append("probe")
        probe.path = "/" + segments.joined(separator: "/") + "/"
        return probe.url
    }
}

public struct OmniParserEndpointDiagnostics: Equatable, Sendable {
    public let networkScope: OmniParserEndpointNetworkScope
    public let redactedHost: String
    public let source: OmniParserEndpointSource
    public let usesTLS: Bool

    public init(
        networkScope: OmniParserEndpointNetworkScope,
        redactedHost: String,
        source: OmniParserEndpointSource,
        usesTLS: Bool
    ) {
        self.networkScope = networkScope
        self.redactedHost = redactedHost
        self.source = source
        self.usesTLS = usesTLS
    }
}
