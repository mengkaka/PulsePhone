import Foundation

public enum CanonicalUDIDError: Error, Equatable, Sendable {
    case empty
    case tooLong(actualByteCount: Int)
    case invalidCharacter(byteOffset: Int)
    case nonCanonical
}

public struct CanonicalUDID: Hashable, Comparable, Codable, Sendable,
    CustomStringConvertible
{
    public static let maximumByteCount = 128
    public static let hashDomainID = "pulsephone.udid.v1"

    public let rawValue: String

    public init(rawTransportUDID: String) throws {
        self.rawValue = try Self.normalize(rawTransportUDID)
    }

    public init(canonicalString: String) throws {
        let normalized = try Self.normalize(canonicalString)
        guard normalized == canonicalString else {
            throw CanonicalUDIDError.nonCanonical
        }
        self.rawValue = canonicalString
    }

    public var description: String {
        rawValue
    }

    public var domainSeparatedHash: String {
        do {
            return try StableBytes.domainSeparatedSHA256Hex(
                domainID: Self.hashDomainID,
                payload: rawValue.utf8
            )
        } catch {
            preconditionFailure("Canonical UDID hash domain must remain valid ASCII")
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        do {
            try self.init(canonicalString: string)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected canonicalUDID.v1 bytes"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func normalize(_ input: String) throws -> String {
        let bytes = Array(input.utf8)
        var lowerBound = 0
        var upperBound = bytes.count

        while lowerBound < upperBound, isASCIIWhitespace(bytes[lowerBound]) {
            lowerBound += 1
        }
        while upperBound > lowerBound, isASCIIWhitespace(bytes[upperBound - 1]) {
            upperBound -= 1
        }

        let normalizedByteCount = upperBound - lowerBound
        guard normalizedByteCount > 0 else {
            throw CanonicalUDIDError.empty
        }
        guard normalizedByteCount <= maximumByteCount else {
            throw CanonicalUDIDError.tooLong(actualByteCount: normalizedByteCount)
        }

        var normalized = [UInt8]()
        normalized.reserveCapacity(normalizedByteCount)
        for offset in lowerBound..<upperBound {
            let byte = bytes[offset]
            switch byte {
            case 0x61...0x7a:
                normalized.append(byte - 0x20)
            case 0x41...0x5a, 0x30...0x39, 0x2d:
                normalized.append(byte)
            default:
                throw CanonicalUDIDError.invalidCharacter(
                    byteOffset: offset - lowerBound
                )
            }
        }

        return String(decoding: normalized, as: UTF8.self)
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (0x09...0x0d).contains(byte)
    }
}
