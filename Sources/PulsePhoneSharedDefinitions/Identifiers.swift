import Foundation

public enum SharedPrimitiveError: Error, Equatable, Sendable {
    case invalidCanonicalUUID
    case invalidASCII
    case invalidLowercaseHex
    case invalidDomainID
    case integerOverflow
    case nonMonotonicOrder
    case invalidTimebase
}

public struct CanonicalUUID: Hashable, Comparable, Codable, Sendable,
    CustomStringConvertible
{
    public let value: UUID
    public let canonicalString: String

    public init(_ canonicalString: String) throws {
        guard Self.isCanonical(canonicalString),
              let value = UUID(uuidString: canonicalString)
        else {
            throw SharedPrimitiveError.invalidCanonicalUUID
        }

        self.value = value
        self.canonicalString = canonicalString
    }

    public init(value: UUID) {
        self.value = value
        self.canonicalString = value.uuidString.lowercased()
    }

    public var description: String {
        canonicalString
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.canonicalString.utf8.lexicographicallyPrecedes(rhs.canonicalString.utf8)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        do {
            try self.init(string)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected lowercase canonical UUID"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(canonicalString)
    }

    private static func isCanonical(_ string: String) -> Bool {
        let bytes = Array(string.utf8)
        guard bytes.count == 36 else {
            return false
        }

        let hyphenIndexes: Set<Int> = [8, 13, 18, 23]
        for (index, byte) in bytes.enumerated() {
            if hyphenIndexes.contains(index) {
                guard byte == 0x2d else {
                    return false
                }
            } else {
                let isDigit = (0x30...0x39).contains(byte)
                let isLowerHex = (0x61...0x66).contains(byte)
                guard isDigit || isLowerHex else {
                    return false
                }
            }
        }

        return true
    }
}

public struct TaggedUUID<Tag>: Hashable, Comparable, Codable, Sendable,
    CustomStringConvertible
{
    public let rawValue: CanonicalUUID

    public init(rawValue: CanonicalUUID) {
        self.rawValue = rawValue
    }

    public init(_ canonicalString: String) throws {
        self.rawValue = try CanonicalUUID(canonicalString)
    }

    public var description: String {
        rawValue.description
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        self.rawValue = try CanonicalUUID(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try rawValue.encode(to: encoder)
    }
}
