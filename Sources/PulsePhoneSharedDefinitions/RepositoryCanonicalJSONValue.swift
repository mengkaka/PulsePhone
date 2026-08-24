public enum RepositoryCanonicalJSONError: Error, Equatable, Sendable {
    case invalidMaximumByteCount(Int)
    case hardCapExceeded(maximumByteCount: Int, actualByteCount: Int)
    case byteOrderMarkForbidden
    case invalidUTF8
    case unexpectedEnd(byteOffset: Int)
    case invalidSyntax(byteOffset: Int)
    case invalidStringControl(byteOffset: Int)
    case invalidUnicodeEscape(byteOffset: Int)
    case duplicateObjectKey(byteOffset: Int)
    case duplicateConstructedObjectKey
    case unsupportedNumber(byteOffset: Int)
    case negativeZero(byteOffset: Int)
    case signedIntegerOverflow(byteOffset: Int)
    case unsignedIntegerOverflow(byteOffset: Int)
    case topLevelObjectRequired
    case nonCanonicalEncoding
    case integerNotInt64
    case integerNotUInt64
    case invalidCanonicalDecimal
}

public struct RepositoryJSONDecimal: Hashable, Sendable {
    public static let maximumFractionDigits = 9
    public static let maximumTotalDigits = 38

    public let canonicalString: String

    public init(_ canonicalString: String) throws {
        let bytes = Array(canonicalString.utf8)
        guard !bytes.isEmpty, bytes.count <= Self.maximumTotalDigits + 2 else {
            throw RepositoryCanonicalJSONError.invalidCanonicalDecimal
        }
        var index = bytes.first == 0x2d ? 1 : 0
        guard index < bytes.count else {
            throw RepositoryCanonicalJSONError.invalidCanonicalDecimal
        }
        let integerStart = index
        if bytes[index] == 0x30 {
            index += 1
            guard index == bytes.count || bytes[index] == 0x2e else {
                throw RepositoryCanonicalJSONError.invalidCanonicalDecimal
            }
        } else {
            guard (0x31...0x39).contains(bytes[index]) else {
                throw RepositoryCanonicalJSONError.invalidCanonicalDecimal
            }
            repeat { index += 1 }
            while index < bytes.count && (0x30...0x39).contains(bytes[index])
        }
        let integerDigits = index - integerStart
        guard index < bytes.count, bytes[index] == 0x2e else {
            throw RepositoryCanonicalJSONError.invalidCanonicalDecimal
        }
        index += 1
        let fractionStart = index
        while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
            index += 1
        }
        let fractionDigits = index - fractionStart
        guard index == bytes.count,
              (1...Self.maximumFractionDigits).contains(fractionDigits),
              bytes.last != 0x30,
              integerDigits + fractionDigits <= Self.maximumTotalDigits
        else {
            throw RepositoryCanonicalJSONError.invalidCanonicalDecimal
        }
        self.canonicalString = canonicalString
    }
}

public enum RepositoryJSONNumber: Hashable, Sendable {
    case decimal(RepositoryJSONDecimal)
    case int64(Int64)
    case uint64(UInt64)

    public func requireInt64() throws -> Int64 {
        switch self {
        case .decimal:
            throw RepositoryCanonicalJSONError.integerNotInt64
        case .int64(let value):
            return value
        case .uint64(let value):
            guard value <= UInt64(Int64.max) else {
                throw RepositoryCanonicalJSONError.integerNotInt64
            }
            return Int64(value)
        }
    }

    public func requireUInt64() throws -> UInt64 {
        guard case .uint64(let value) = self else {
            throw RepositoryCanonicalJSONError.integerNotUInt64
        }
        return value
    }
}

public struct RepositoryJSONMember: Sendable {
    public let key: String
    public let value: RepositoryJSONValue

    public init(key: String, value: RepositoryJSONValue) {
        self.key = key
        self.value = value
    }
}

public struct RepositoryJSONObject: Sendable {
    public let members: [RepositoryJSONMember]

    public init(members: [RepositoryJSONMember]) throws {
        var keys = Set<[UInt8]>()
        for member in members {
            guard keys.insert(Array(member.key.utf8)).inserted else {
                throw RepositoryCanonicalJSONError.duplicateConstructedObjectKey
            }
        }
        self.members = members
    }

    init(validatedMembers: [RepositoryJSONMember]) {
        self.members = validatedMembers
    }

    public subscript(key: String) -> RepositoryJSONValue? {
        members.first { member in
            member.key.utf8.elementsEqual(key.utf8)
        }?.value
    }
}

public indirect enum RepositoryJSONValue: Sendable {
    case null
    case bool(Bool)
    case string(String)
    case number(RepositoryJSONNumber)
    case array([RepositoryJSONValue])
    case object(RepositoryJSONObject)

    public var objectValue: RepositoryJSONObject? {
        guard case .object(let value) = self else {
            return nil
        }
        return value
    }

    public var arrayValue: [RepositoryJSONValue]? {
        guard case .array(let value) = self else {
            return nil
        }
        return value
    }

    public var stringValue: String? {
        guard case .string(let value) = self else {
            return nil
        }
        return value
    }

    public var numberValue: RepositoryJSONNumber? {
        guard case .number(let value) = self else {
            return nil
        }
        return value
    }
}

public struct RepositoryCanonicalJSONDocument: Sendable {
    public let root: RepositoryJSONObject
    public let exactBytes: [UInt8]

    init(root: RepositoryJSONObject, exactBytes: [UInt8]) {
        self.root = root
        self.exactBytes = exactBytes
    }

    public var sha256Hex: String {
        StableBytes.sha256Hex(exactBytes)
    }

    public func domainSeparatedSHA256Hex(domainID: String) throws -> String {
        try StableBytes.domainSeparatedSHA256Hex(
            domainID: domainID,
            payload: exactBytes
        )
    }
}
