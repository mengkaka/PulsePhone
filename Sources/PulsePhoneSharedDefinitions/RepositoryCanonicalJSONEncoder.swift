extension RepositoryCanonicalJSON {
    public static func encodeDocument(_ object: RepositoryJSONObject) -> [UInt8] {
        var bytes = [UInt8]()
        encode(.object(object), into: &bytes)
        return bytes
    }

    private static func encode(
        _ value: RepositoryJSONValue,
        into bytes: inout [UInt8]
    ) {
        switch value {
        case .null:
            bytes.append(contentsOf: "null".utf8)
        case .bool(let value):
            bytes.append(contentsOf: (value ? "true" : "false").utf8)
        case .string(let value):
            encodeString(value, into: &bytes)
        case .number(let number):
            switch number {
            case .decimal(let value):
                bytes.append(contentsOf: value.canonicalString.utf8)
            case .int64(let value):
                bytes.append(contentsOf: String(value).utf8)
            case .uint64(let value):
                bytes.append(contentsOf: String(value).utf8)
            }
        case .array(let values):
            bytes.append(0x5b)
            for (index, value) in values.enumerated() {
                if index > 0 {
                    bytes.append(0x2c)
                }
                encode(value, into: &bytes)
            }
            bytes.append(0x5d)
        case .object(let object):
            bytes.append(0x7b)
            let members = object.members.sorted { lhs, rhs in
                lhs.key.utf8.lexicographicallyPrecedes(rhs.key.utf8)
            }
            for (index, member) in members.enumerated() {
                if index > 0 {
                    bytes.append(0x2c)
                }
                encodeString(member.key, into: &bytes)
                bytes.append(0x3a)
                encode(member.value, into: &bytes)
            }
            bytes.append(0x7d)
        }
    }

    private static func encodeString(_ string: String, into bytes: inout [UInt8]) {
        bytes.append(0x22)
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22:
                bytes.append(contentsOf: [0x5c, 0x22])
            case 0x5c:
                bytes.append(contentsOf: [0x5c, 0x5c])
            case 0x08:
                bytes.append(contentsOf: [0x5c, 0x62])
            case 0x09:
                bytes.append(contentsOf: [0x5c, 0x74])
            case 0x0a:
                bytes.append(contentsOf: [0x5c, 0x6e])
            case 0x0c:
                bytes.append(contentsOf: [0x5c, 0x66])
            case 0x0d:
                bytes.append(contentsOf: [0x5c, 0x72])
            case 0x00...0x1f:
                bytes.append(contentsOf: [0x5c, 0x75, 0x30, 0x30])
                bytes.append(lowercaseHexDigit(UInt8(scalar.value >> 4)))
                bytes.append(lowercaseHexDigit(UInt8(scalar.value & 0x0f)))
            default:
                bytes.append(contentsOf: String(scalar).utf8)
            }
        }
        bytes.append(0x22)
    }

    private static func lowercaseHexDigit(_ nibble: UInt8) -> UInt8 {
        nibble < 10 ? 0x30 + nibble : 0x61 + nibble - 10
    }
}
