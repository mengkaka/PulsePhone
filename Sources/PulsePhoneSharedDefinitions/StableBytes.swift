import CryptoKit
import Foundation

public enum ASCIIByteOrdering: Int, Equatable, Sendable {
    case ascending = -1
    case equal = 0
    case descending = 1
}

public enum StableBytes {
    public static func utf8(_ string: String) -> [UInt8] {
        Array(string.utf8)
    }

    public static func ascii(_ string: String) throws -> [UInt8] {
        let bytes = Array(string.utf8)
        guard bytes.allSatisfy({ $0 < 0x80 }) else {
            throw SharedPrimitiveError.invalidASCII
        }
        return bytes
    }

    public static func compareASCII(
        _ lhs: String,
        _ rhs: String
    ) throws -> ASCIIByteOrdering {
        let lhsBytes = try ascii(lhs)
        let rhsBytes = try ascii(rhs)
        if lhsBytes == rhsBytes {
            return .equal
        }
        return lhsBytes.lexicographicallyPrecedes(rhsBytes)
            ? .ascending
            : .descending
    }

    public static func lowercaseHex(_ bytes: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var result = [UInt8]()
        for byte in bytes {
            result.append(digits[Int(byte >> 4)])
            result.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: result, as: UTF8.self)
    }

    public static func decodeLowercaseHex(_ string: String) throws -> [UInt8] {
        let bytes = Array(string.utf8)
        guard bytes.count.isMultiple(of: 2) else {
            throw SharedPrimitiveError.invalidLowercaseHex
        }

        var result = [UInt8]()
        result.reserveCapacity(bytes.count / 2)
        var index = 0
        while index < bytes.count {
            guard let high = hexNibble(bytes[index]),
                  let low = hexNibble(bytes[index + 1])
            else {
                throw SharedPrimitiveError.invalidLowercaseHex
            }
            result.append((high << 4) | low)
            index += 2
        }
        return result
    }

    public static func sha256(_ bytes: some Sequence<UInt8>) -> [UInt8] {
        Array(SHA256.hash(data: Data(bytes)))
    }

    public static func sha256Hex(_ bytes: some Sequence<UInt8>) -> String {
        lowercaseHex(sha256(bytes))
    }

    public static func domainSeparatedBytes(
        domainID: String,
        payload: some Sequence<UInt8>
    ) throws -> [UInt8] {
        let domainBytes: [UInt8]
        do {
            domainBytes = try ascii(domainID)
        } catch {
            throw SharedPrimitiveError.invalidDomainID
        }
        guard !domainBytes.contains(0) else {
            throw SharedPrimitiveError.invalidDomainID
        }

        var bytes = domainBytes
        bytes.append(0)
        bytes.append(contentsOf: payload)
        return bytes
    }

    public static func domainSeparatedSHA256(
        domainID: String,
        payload: some Sequence<UInt8>
    ) throws -> [UInt8] {
        sha256(try domainSeparatedBytes(domainID: domainID, payload: payload))
    }

    public static func domainSeparatedSHA256Hex(
        domainID: String,
        payload: some Sequence<UInt8>
    ) throws -> String {
        lowercaseHex(try domainSeparatedSHA256(domainID: domainID, payload: payload))
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39:
            byte - 0x30
        case 0x61...0x66:
            byte - 0x61 + 10
        default:
            nil
        }
    }
}
