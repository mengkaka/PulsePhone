import PulsePhoneSharedDefinitions

public enum RuntimeSocketPathError: Error, Equatable, Sendable {
    case layoutMismatch
}

public struct RuntimeSocketPath: Hashable, Sendable {
    public let canonicalUDID: CanonicalUDID
    public let component: String
    public let path: String

    public init(
        canonicalUDID: CanonicalUDID,
        layout: HostPathLayoutV1
    ) throws {
        let component = canonicalUDID.domainSeparatedHash + ".sock"
        let path = try layout.runtimeSocketPath(for: canonicalUDID)
        guard path == layout.temporaryBasePath + "/" + component else {
            throw RuntimeSocketPathError.layoutMismatch
        }
        try HostPathLayoutV1.validateUnixDomainSocketPath(path)
        self.canonicalUDID = canonicalUDID
        self.component = component
        self.path = path
    }

    public static func current(
        for canonicalUDID: CanonicalUDID,
        system: POSIXHostPathSystem = POSIXHostPathSystem()
    ) throws -> RuntimeSocketPath {
        let component = canonicalUDID.domainSeparatedHash + ".sock"
        let path = "/tmp/pulsephone-\(system.effectiveUserID)/\(component)"
        try HostPathLayoutV1.validateUnixDomainSocketPath(path)
        return RuntimeSocketPath(
            canonicalUDID: canonicalUDID,
            component: component,
            path: path
        )
    }

    private init(canonicalUDID: CanonicalUDID, component: String, path: String) {
        self.canonicalUDID = canonicalUDID
        self.component = component
        self.path = path
    }
}
