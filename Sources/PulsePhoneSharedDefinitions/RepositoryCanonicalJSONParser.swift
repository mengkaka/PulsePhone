import Foundation

public enum RepositoryCanonicalJSON {
    public static func parseDocument(
        _ bytes: [UInt8],
        maximumByteCount: Int
    ) throws -> RepositoryJSONObject {
        try validateInputEnvelope(bytes, maximumByteCount: maximumByteCount)
        var parser = Parser(bytes: bytes)
        return try parser.parseDocument()
    }

    public static func validateCanonicalDocument(
        _ bytes: [UInt8],
        maximumByteCount: Int
    ) throws -> RepositoryCanonicalJSONDocument {
        let root = try parseDocument(bytes, maximumByteCount: maximumByteCount)
        let encoded = encodeDocument(root)
        guard encoded == bytes else {
            throw RepositoryCanonicalJSONError.nonCanonicalEncoding
        }
        return RepositoryCanonicalJSONDocument(root: root, exactBytes: bytes)
    }

    private static func validateInputEnvelope(
        _ bytes: [UInt8],
        maximumByteCount: Int
    ) throws {
        guard maximumByteCount >= 0 else {
            throw RepositoryCanonicalJSONError.invalidMaximumByteCount(
                maximumByteCount
            )
        }
        guard bytes.count <= maximumByteCount else {
            throw RepositoryCanonicalJSONError.hardCapExceeded(
                maximumByteCount: maximumByteCount,
                actualByteCount: bytes.count
            )
        }
        guard !bytes.starts(with: [0xef, 0xbb, 0xbf]) else {
            throw RepositoryCanonicalJSONError.byteOrderMarkForbidden
        }
        guard String(bytes: bytes, encoding: .utf8) != nil else {
            throw RepositoryCanonicalJSONError.invalidUTF8
        }
    }
}

private struct Parser {
    let bytes: [UInt8]
    var index = 0

    mutating func parseDocument() throws -> RepositoryJSONObject {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else {
            throw RepositoryCanonicalJSONError.invalidSyntax(byteOffset: index)
        }
        guard case .object(let object) = value else {
            throw RepositoryCanonicalJSONError.topLevelObjectRequired
        }
        return object
    }

    private mutating func parseValue() throws -> RepositoryJSONValue {
        guard index < bytes.count else {
            throw RepositoryCanonicalJSONError.unexpectedEnd(byteOffset: index)
        }

        switch bytes[index] {
        case 0x7b:
            return .object(try parseObject())
        case 0x5b:
            return .array(try parseArray())
        case 0x22:
            return .string(try parseString())
        case 0x74:
            try consumeLiteral("true")
            return .bool(true)
        case 0x66:
            try consumeLiteral("false")
            return .bool(false)
        case 0x6e:
            try consumeLiteral("null")
            return .null
        case 0x2d, 0x30...0x39:
            return .number(try parseNumber())
        default:
            throw RepositoryCanonicalJSONError.invalidSyntax(byteOffset: index)
        }
    }

    private mutating func parseObject() throws -> RepositoryJSONObject {
        index += 1
        skipWhitespace()
        if consumeIfPresent(0x7d) {
            return RepositoryJSONObject(validatedMembers: [])
        }

        var members = [RepositoryJSONMember]()
        var keys = Set<[UInt8]>()
        while true {
            guard index < bytes.count else {
                throw RepositoryCanonicalJSONError.unexpectedEnd(byteOffset: index)
            }
            guard bytes[index] == 0x22 else {
                throw RepositoryCanonicalJSONError.invalidSyntax(byteOffset: index)
            }
            let keyOffset = index
            let key = try parseString()
            guard keys.insert(Array(key.utf8)).inserted else {
                throw RepositoryCanonicalJSONError.duplicateObjectKey(
                    byteOffset: keyOffset
                )
            }
            skipWhitespace()
            try consumeRequired(0x3a)
            skipWhitespace()
            let value = try parseValue()
            members.append(RepositoryJSONMember(key: key, value: value))
            skipWhitespace()
            if consumeIfPresent(0x7d) {
                return RepositoryJSONObject(validatedMembers: members)
            }
            try consumeRequired(0x2c)
            skipWhitespace()
        }
    }

    private mutating func parseArray() throws -> [RepositoryJSONValue] {
        index += 1
        skipWhitespace()
        if consumeIfPresent(0x5d) {
            return []
        }

        var values = [RepositoryJSONValue]()
        while true {
            values.append(try parseValue())
            skipWhitespace()
            if consumeIfPresent(0x5d) {
                return values
            }
            try consumeRequired(0x2c)
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        let openingOffset = index
        try consumeRequired(0x22)
        var result = String()
        var segmentStart = index

        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                try appendRawStringSegment(
                    from: segmentStart,
                    to: index,
                    into: &result
                )
                index += 1
                return result
            }
            if byte == 0x5c {
                try appendRawStringSegment(
                    from: segmentStart,
                    to: index,
                    into: &result
                )
                let escapeOffset = index
                index += 1
                try parseEscape(into: &result, escapeOffset: escapeOffset)
                segmentStart = index
                continue
            }
            guard byte >= 0x20 else {
                throw RepositoryCanonicalJSONError.invalidStringControl(
                    byteOffset: index
                )
            }
            index += 1
        }

        throw RepositoryCanonicalJSONError.unexpectedEnd(
            byteOffset: openingOffset
        )
    }

    private mutating func parseEscape(
        into result: inout String,
        escapeOffset: Int
    ) throws {
        guard index < bytes.count else {
            throw RepositoryCanonicalJSONError.unexpectedEnd(byteOffset: index)
        }
        let byte = bytes[index]
        index += 1
        switch byte {
        case 0x22:
            result.append("\"")
        case 0x5c:
            result.append("\\")
        case 0x2f:
            result.append("/")
        case 0x62:
            result.append("\u{0008}")
        case 0x66:
            result.append("\u{000c}")
        case 0x6e:
            result.append("\n")
        case 0x72:
            result.append("\r")
        case 0x74:
            result.append("\t")
        case 0x75:
            try parseUnicodeEscape(into: &result, escapeOffset: escapeOffset)
        default:
            throw RepositoryCanonicalJSONError.invalidUnicodeEscape(
                byteOffset: escapeOffset
            )
        }
    }

    private mutating func parseUnicodeEscape(
        into result: inout String,
        escapeOffset: Int
    ) throws {
        let first = try parseHexQuad(escapeOffset: escapeOffset)
        let scalarValue: UInt32
        if (0xd800...0xdbff).contains(first) {
            guard index + 2 <= bytes.count,
                  bytes[index] == 0x5c,
                  bytes[index + 1] == 0x75
            else {
                throw RepositoryCanonicalJSONError.invalidUnicodeEscape(
                    byteOffset: escapeOffset
                )
            }
            index += 2
            let second = try parseHexQuad(escapeOffset: escapeOffset)
            guard (0xdc00...0xdfff).contains(second) else {
                throw RepositoryCanonicalJSONError.invalidUnicodeEscape(
                    byteOffset: escapeOffset
                )
            }
            scalarValue = 0x10000
                + (UInt32(first - 0xd800) << 10)
                + UInt32(second - 0xdc00)
        } else {
            guard !(0xdc00...0xdfff).contains(first) else {
                throw RepositoryCanonicalJSONError.invalidUnicodeEscape(
                    byteOffset: escapeOffset
                )
            }
            scalarValue = UInt32(first)
        }

        guard let scalar = UnicodeScalar(scalarValue) else {
            throw RepositoryCanonicalJSONError.invalidUnicodeEscape(
                byteOffset: escapeOffset
            )
        }
        result.unicodeScalars.append(scalar)
    }

    private mutating func parseHexQuad(escapeOffset: Int) throws -> UInt16 {
        guard index + 4 <= bytes.count else {
            throw RepositoryCanonicalJSONError.unexpectedEnd(byteOffset: index)
        }
        var value: UInt16 = 0
        for _ in 0..<4 {
            guard let nibble = hexNibble(bytes[index]) else {
                throw RepositoryCanonicalJSONError.invalidUnicodeEscape(
                    byteOffset: escapeOffset
                )
            }
            value = (value << 4) | UInt16(nibble)
            index += 1
        }
        return value
    }

    private mutating func parseNumber() throws -> RepositoryJSONNumber {
        let start = index
        let isNegative = consumeIfPresent(0x2d)
        guard index < bytes.count else {
            throw RepositoryCanonicalJSONError.unexpectedEnd(byteOffset: index)
        }

        if bytes[index] == 0x30 {
            index += 1
            if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                throw RepositoryCanonicalJSONError.invalidSyntax(byteOffset: index)
            }
        } else {
            guard (0x31...0x39).contains(bytes[index]) else {
                throw RepositoryCanonicalJSONError.invalidSyntax(byteOffset: index)
            }
            repeat {
                index += 1
            } while index < bytes.count && (0x30...0x39).contains(bytes[index])
        }

        if index < bytes.count, bytes[index] == 0x2e {
            index += 1
            let fractionStart = index
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                index += 1
            }
            guard index > fractionStart,
                  bytes[index - 1] != 0x30,
                  index - fractionStart
                    <= RepositoryJSONDecimal.maximumFractionDigits,
                  index - start - (isNegative ? 2 : 1)
                    <= RepositoryJSONDecimal.maximumTotalDigits,
                  index == bytes.count
                    || (bytes[index] != 0x65 && bytes[index] != 0x45)
            else {
                throw RepositoryCanonicalJSONError.unsupportedNumber(
                    byteOffset: start
                )
            }
            let token = String(decoding: bytes[start..<index], as: UTF8.self)
            guard let decimal = try? RepositoryJSONDecimal(token) else {
                throw RepositoryCanonicalJSONError.unsupportedNumber(
                    byteOffset: start
                )
            }
            return .decimal(decimal)
        }

        if index < bytes.count,
           bytes[index] == 0x65 || bytes[index] == 0x45
        {
            throw RepositoryCanonicalJSONError.unsupportedNumber(byteOffset: start)
        }

        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        if isNegative {
            guard token != "-0" else {
                throw RepositoryCanonicalJSONError.negativeZero(byteOffset: start)
            }
            guard let value = Int64(token) else {
                throw RepositoryCanonicalJSONError.signedIntegerOverflow(
                    byteOffset: start
                )
            }
            return .int64(value)
        }

        guard let value = UInt64(token) else {
            throw RepositoryCanonicalJSONError.unsignedIntegerOverflow(
                byteOffset: start
            )
        }
        return .uint64(value)
    }

    private mutating func consumeLiteral(_ literal: StaticString) throws {
        let literalBytes = Array(literal.description.utf8)
        guard index + literalBytes.count <= bytes.count else {
            throw RepositoryCanonicalJSONError.unexpectedEnd(byteOffset: index)
        }
        guard bytes[index..<(index + literalBytes.count)].elementsEqual(literalBytes) else {
            throw RepositoryCanonicalJSONError.invalidSyntax(byteOffset: index)
        }
        index += literalBytes.count
    }

    private mutating func consumeRequired(_ byte: UInt8) throws {
        guard index < bytes.count else {
            throw RepositoryCanonicalJSONError.unexpectedEnd(byteOffset: index)
        }
        guard bytes[index] == byte else {
            throw RepositoryCanonicalJSONError.invalidSyntax(byteOffset: index)
        }
        index += 1
    }

    private mutating func consumeIfPresent(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else {
            return false
        }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0a, 0x0d:
                index += 1
            default:
                return
            }
        }
    }

    private func appendRawStringSegment(
        from lowerBound: Int,
        to upperBound: Int,
        into result: inout String
    ) throws {
        guard lowerBound < upperBound else {
            return
        }
        guard let segment = String(
            bytes: bytes[lowerBound..<upperBound],
            encoding: .utf8
        ) else {
            throw RepositoryCanonicalJSONError.invalidUTF8
        }
        result.append(segment)
    }

    private func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39:
            return byte - 0x30
        case 0x61...0x66:
            return byte - 0x61 + 10
        case 0x41...0x46:
            return byte - 0x41 + 10
        default:
            return nil
        }
    }
}
