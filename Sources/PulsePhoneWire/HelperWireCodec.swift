import Foundation
import PulsePhoneSharedDefinitions

public enum HelperWireDirection: Equatable, Sendable {
    case runtimeToHelper
    case helperToRuntime
}

public indirect enum HelperWireJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case string(String)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case double(Double)
    case array([HelperWireJSONValue])
    case object([String: HelperWireJSONValue])

    public var objectValue: [String: HelperWireJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var uintValue: UInt64? {
        switch self {
        case let .unsignedInteger(value):
            return value
        case let .integer(value) where value >= 0:
            return UInt64(value)
        default:
            return nil
        }
    }

    fileprivate init(any value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
                return
            }
            let token = value.stringValue
            if token.contains(".") || token.contains("e") || token.contains("E") {
                let double = value.doubleValue
                guard double.isFinite else { throw HelperWireCodecError.invalidJSON }
                self = .double(double)
            } else if token.hasPrefix("-") {
                guard let integer = Int64(token) else {
                    throw HelperWireCodecError.invalidJSON
                }
                self = .integer(integer)
            } else if let integer = UInt64(token) {
                self = .unsignedInteger(integer)
            } else {
                throw HelperWireCodecError.invalidJSON
            }
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(try value.map(Self.init(any:)))
        case let value as [String: Any]:
            self = .object(
                try value.mapValues(Self.init(any:))
            )
        default:
            throw HelperWireCodecError.invalidJSON
        }
    }

    fileprivate var foundationValue: Any {
        switch self {
        case .null:
            return NSNull()
        case let .bool(value):
            return value
        case let .string(value):
            return value
        case let .integer(value):
            return NSNumber(value: value)
        case let .unsignedInteger(value):
            return NSNumber(value: value)
        case let .double(value):
            return NSNumber(value: value)
        case let .array(values):
            return values.map(\.foundationValue)
        case let .object(values):
            return values.mapValues(\.foundationValue)
        }
    }
}

public struct HelperWireMessage: Equatable, Sendable {
    public let type: HelperWireMessageID
    public let runtimeEpoch: UInt64
    public let executorGeneration: UInt64
    public let messageID: CanonicalUUID
    public let requestID: CanonicalUUID?
    public let sessionID: CanonicalUUID?
    public let deliveryAttemptID: String?
    public let payload: [String: HelperWireJSONValue]?
    public let fields: [String: HelperWireJSONValue]
}

public enum HelperWireCodecError: Error, Equatable, Sendable {
    case invalidLine
    case lineTooLarge
    case invalidJSON
    case unsupportedMessage
    case wrongDirection
    case invalidShape
    case invalidIdentity
}

public enum HelperWireCodec {
    public static let maximumLineBytes = 512 * 1_024

    public static func decodeLine(
        _ bytes: [UInt8],
        direction: HelperWireDirection
    ) throws -> HelperWireMessage {
        guard bytes.last == 0x0a,
              bytes.count > 1,
              !bytes.dropLast().contains(0x0a),
              !bytes.dropLast().contains(0x0d)
        else {
            throw HelperWireCodecError.invalidLine
        }
        let document = Array(bytes.dropLast())
        guard document.count <= maximumLineBytes else {
            throw HelperWireCodecError.lineTooLarge
        }
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: Data(document))
            try JSONDuplicateKeyValidator.validate(document)
        } catch {
            throw HelperWireCodecError.invalidJSON
        }
        guard let object = raw as? [String: Any],
              let typeValue = object["type"] as? String,
              let type = GeneratedWireRegistryDecoder.helperMessage(
                rawValue: typeValue
              ),
              let entry = GeneratedWireRegistryValidator.entry(
                registryID: .helperWire,
                id: type.rawValue
              )
        else {
            throw HelperWireCodecError.unsupportedMessage
        }
        try validate(direction, for: entry)
        guard let schemaID = schemaID(for: entry, direction: direction),
              let descriptor = GeneratedWireRegistryValidator.schemaDescriptor(
                schemaID
              ),
              document.count <= Int(descriptor.maxEncodedBytes ?? 0),
              Set(object.keys) == Set(descriptor.requiredPropertyNames)
        else {
            throw HelperWireCodecError.invalidShape
        }
        let fields = try object.mapValues(HelperWireJSONValue.init(any:))
        guard fields["schemaVersion"]?.uintValue == 1,
              let runtimeEpoch = fields["runtimeEpoch"]?.uintValue,
              let executorGeneration = fields["executorGeneration"]?.uintValue,
              let messageIDValue = fields["messageID"]?.stringValue,
              let messageID = try? CanonicalUUID(messageIDValue)
        else {
            throw HelperWireCodecError.invalidIdentity
        }
        let requestID = try optionalUUID(fields, key: "requestID")
        let sessionID = try optionalUUID(fields, key: "sessionID")
        let deliveryAttemptID = try optionalBoundedASCII(
            fields,
            key: "deliveryAttemptID",
            maximumBytes: 128
        )
        let payload: [String: HelperWireJSONValue]?
        if let value = fields["payload"] {
            guard let object = value.objectValue else {
                throw HelperWireCodecError.invalidShape
            }
            payload = object
        } else {
            payload = nil
        }
        return HelperWireMessage(
            type: type,
            runtimeEpoch: runtimeEpoch,
            executorGeneration: executorGeneration,
            messageID: messageID,
            requestID: requestID,
            sessionID: sessionID,
            deliveryAttemptID: deliveryAttemptID,
            payload: payload,
            fields: fields
        )
    }

    public static func encodeLine(
        fields: [String: HelperWireJSONValue],
        direction: HelperWireDirection
    ) throws -> [UInt8] {
        guard case let .string(typeValue)? = fields["type"],
              GeneratedWireRegistryDecoder.helperMessage(rawValue: typeValue) != nil
        else {
            throw HelperWireCodecError.unsupportedMessage
        }
        let object = fields.mapValues(\.foundationValue)
        guard JSONSerialization.isValidJSONObject(object) else {
            throw HelperWireCodecError.invalidJSON
        }
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0a)
        _ = try decodeLine([UInt8](data), direction: direction)
        return [UInt8](data)
    }

    private static func validate(
        _ direction: HelperWireDirection,
        for entry: GeneratedWireEntry
    ) throws {
        switch (direction, entry.direction) {
        case (.runtimeToHelper, .runtimeToHelper),
             (.helperToRuntime, .helperToRuntime),
             (_, .either):
            return
        default:
            throw HelperWireCodecError.wrongDirection
        }
    }

    private static func schemaID(
        for entry: GeneratedWireEntry,
        direction: HelperWireDirection
    ) -> WireSchemaID? {
        switch direction {
        case .runtimeToHelper:
            return entry.requestSchemaID ?? entry.responseSchemaID
        case .helperToRuntime:
            return entry.responseSchemaID ?? entry.requestSchemaID
        }
    }

    private static func optionalUUID(
        _ fields: [String: HelperWireJSONValue],
        key: String
    ) throws -> CanonicalUUID? {
        guard let value = fields[key] else { return nil }
        guard let string = value.stringValue,
              let identifier = try? CanonicalUUID(string)
        else {
            throw HelperWireCodecError.invalidIdentity
        }
        return identifier
    }

    private static func optionalBoundedASCII(
        _ fields: [String: HelperWireJSONValue],
        key: String,
        maximumBytes: Int
    ) throws -> String? {
        guard let value = fields[key] else { return nil }
        guard let string = value.stringValue,
              isBoundedASCII(string, maximumBytes: maximumBytes)
        else {
            throw HelperWireCodecError.invalidIdentity
        }
        return string
    }

    static func isBoundedASCII(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        let bytes = Array(value.utf8)
        return (1...maximumBytes).contains(bytes.count)
            && bytes.allSatisfy { (0x20...0x7e).contains($0) }
    }
}

// JSONSerialization accepts duplicate object keys and retains only the last
// value. HelperWire must reject those ambiguous inputs before shape validation.
private enum JSONDuplicateKeyValidator {
    static func validate(_ bytes: [UInt8]) throws {
        var parser = Parser(bytes: bytes)
        try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == bytes.count else {
            throw HelperWireCodecError.invalidJSON
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func parseValue() throws {
            skipWhitespace()
            guard index < bytes.count else {
                throw HelperWireCodecError.invalidJSON
            }
            switch bytes[index] {
            case 0x7b:
                try parseObject()
            case 0x5b:
                try parseArray()
            case 0x22:
                _ = try parseString()
            case 0x74:
                try consumeLiteral("true")
            case 0x66:
                try consumeLiteral("false")
            case 0x6e:
                try consumeLiteral("null")
            case 0x2d, 0x30...0x39:
                try parseNumber()
            default:
                throw HelperWireCodecError.invalidJSON
            }
        }

        mutating func parseObject() throws {
            index += 1
            skipWhitespace()
            if consume(0x7d) {
                return
            }
            var keys = Set<String>()
            while true {
                skipWhitespace()
                let key = try parseString()
                guard keys.insert(key).inserted else {
                    throw HelperWireCodecError.invalidJSON
                }
                skipWhitespace()
                try require(0x3a)
                try parseValue()
                skipWhitespace()
                if consume(0x7d) {
                    return
                }
                try require(0x2c)
            }
        }

        mutating func parseArray() throws {
            index += 1
            skipWhitespace()
            if consume(0x5d) {
                return
            }
            while true {
                try parseValue()
                skipWhitespace()
                if consume(0x5d) {
                    return
                }
                try require(0x2c)
            }
        }

        mutating func parseString() throws -> String {
            let start = index
            try require(0x22)
            while index < bytes.count {
                switch bytes[index] {
                case 0x22:
                    index += 1
                    let fragment = Data(bytes[start..<index])
                    guard let value = try? JSONSerialization.jsonObject(
                        with: fragment,
                        options: [.fragmentsAllowed]
                    ) as? String else {
                        throw HelperWireCodecError.invalidJSON
                    }
                    return value
                case 0x5c:
                    index += 1
                    guard index < bytes.count else {
                        throw HelperWireCodecError.invalidJSON
                    }
                    index += 1
                default:
                    index += 1
                }
            }
            throw HelperWireCodecError.invalidJSON
        }

        mutating func parseNumber() throws {
            let start = index
            while index < bytes.count {
                switch bytes[index] {
                case 0x2b, 0x2d, 0x2e, 0x45, 0x65, 0x30...0x39:
                    index += 1
                default:
                    guard index > start else {
                        throw HelperWireCodecError.invalidJSON
                    }
                    return
                }
            }
            guard index > start else {
                throw HelperWireCodecError.invalidJSON
            }
        }

        mutating func consumeLiteral(_ literal: String) throws {
            let expected = Array(literal.utf8)
            guard bytes[index...].starts(with: expected) else {
                throw HelperWireCodecError.invalidJSON
            }
            index += expected.count
        }

        mutating func require(_ byte: UInt8) throws {
            guard consume(byte) else {
                throw HelperWireCodecError.invalidJSON
            }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else {
                return false
            }
            index += 1
            return true
        }

        mutating func skipWhitespace() {
            while index < bytes.count,
                  bytes[index] == 0x20 || bytes[index] == 0x09 ||
                  bytes[index] == 0x0a || bytes[index] == 0x0d
            {
                index += 1
            }
        }
    }
}
