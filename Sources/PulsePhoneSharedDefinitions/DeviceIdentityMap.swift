public enum DeviceIdentityMapError: Error, Equatable, Sendable {
    case invalidRawTransportUDID(index: Int, reason: CanonicalUDIDError)
    case canonicalCollision(CanonicalUDID)
}

public struct DeviceIdentityEntry: Hashable, Sendable {
    public let rawTransportUDID: String
    public let canonicalUDID: CanonicalUDID

    public init(rawTransportUDID: String, canonicalUDID: CanonicalUDID) {
        self.rawTransportUDID = rawTransportUDID
        self.canonicalUDID = canonicalUDID
    }
}

public struct DeviceIdentityMap: Sendable {
    public let entries: [DeviceIdentityEntry]

    private let rawToCanonical: [String: CanonicalUDID]
    private let canonicalToRaw: [CanonicalUDID: String]

    public init(rawTransportUDIDs: [String]) throws {
        var entries = [DeviceIdentityEntry]()
        entries.reserveCapacity(rawTransportUDIDs.count)
        var rawToCanonical = [String: CanonicalUDID]()
        var canonicalToRaw = [CanonicalUDID: String]()

        for (index, rawTransportUDID) in rawTransportUDIDs.enumerated() {
            let canonicalUDID: CanonicalUDID
            do {
                canonicalUDID = try CanonicalUDID(
                    rawTransportUDID: rawTransportUDID
                )
            } catch let reason as CanonicalUDIDError {
                throw DeviceIdentityMapError.invalidRawTransportUDID(
                    index: index,
                    reason: reason
                )
            }

            guard rawToCanonical[rawTransportUDID] == nil,
                  canonicalToRaw[canonicalUDID] == nil
            else {
                throw DeviceIdentityMapError.canonicalCollision(canonicalUDID)
            }

            rawToCanonical[rawTransportUDID] = canonicalUDID
            canonicalToRaw[canonicalUDID] = rawTransportUDID
            entries.append(
                DeviceIdentityEntry(
                    rawTransportUDID: rawTransportUDID,
                    canonicalUDID: canonicalUDID
                )
            )
        }

        self.entries = entries.sorted { lhs, rhs in
            lhs.canonicalUDID < rhs.canonicalUDID
        }
        self.rawToCanonical = rawToCanonical
        self.canonicalToRaw = canonicalToRaw
    }

    public var canonicalUDIDs: [CanonicalUDID] {
        entries.map(\.canonicalUDID)
    }

    public func canonicalUDID(
        forRawTransportUDID rawTransportUDID: String
    ) -> CanonicalUDID? {
        rawToCanonical[rawTransportUDID]
    }

    public func rawTransportUDID(for canonicalUDID: CanonicalUDID) -> String? {
        canonicalToRaw[canonicalUDID]
    }
}
