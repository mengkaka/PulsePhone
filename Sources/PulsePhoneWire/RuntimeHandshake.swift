import PulsePhoneSharedDefinitions

public enum RuntimeWireCodecError: Error, Equatable, Sendable {
    case invalidHeader
    case unsupportedProtocolMajor
    case unsupportedMessageType
    case invalidFlags
    case payloadTooLarge
    case truncatedFrame
    case trailingBytes
    case invalidPayload
}

public struct RuntimeWireFrame: Equatable, Sendable {
    public static let headerByteCount = 16
    public static let protocolMajor: UInt16 = 1
    public static let handshakePayloadCap = 16 * 1_024

    public let messageType: RuntimeWireMessageType
    public let flags: UInt16
    public let payload: [UInt8]

    public init(
        messageType: RuntimeWireMessageType,
        flags: UInt16 = 0,
        payload: [UInt8]
    ) {
        self.messageType = messageType
        self.flags = flags
        self.payload = payload
    }
}

public enum RuntimeWireFrameCodec {
    private static let magic: [UInt8] = [0x50, 0x50, 0x52, 0x57]

    public static func encode(_ frame: RuntimeWireFrame) throws -> [UInt8] {
        guard frame.flags & ~UInt16(1) == 0 else {
            throw RuntimeWireCodecError.invalidFlags
        }
        guard frame.payload.count <= payloadCap(for: frame.messageType),
              frame.payload.count <= Int(UInt32.max)
        else {
            throw RuntimeWireCodecError.payloadTooLarge
        }
        var bytes = magic
        append(RuntimeWireFrame.protocolMajor, to: &bytes)
        append(frame.messageType.rawValue, to: &bytes)
        append(frame.flags, to: &bytes)
        append(UInt16(0), to: &bytes)
        append(UInt32(frame.payload.count), to: &bytes)
        bytes.append(contentsOf: frame.payload)
        return bytes
    }

    public static func decode(_ bytes: [UInt8]) throws -> RuntimeWireFrame {
        guard bytes.count >= RuntimeWireFrame.headerByteCount,
              Array(bytes[0..<4]) == magic
        else {
            throw RuntimeWireCodecError.invalidHeader
        }
        let major = readUInt16(bytes, offset: 4)
        guard major == RuntimeWireFrame.protocolMajor else {
            throw RuntimeWireCodecError.unsupportedProtocolMajor
        }
        guard let messageType = RuntimeWireMessageType(
            rawValue: readUInt16(bytes, offset: 6)
        ) else {
            throw RuntimeWireCodecError.unsupportedMessageType
        }
        let flags = readUInt16(bytes, offset: 8)
        guard flags & ~UInt16(1) == 0 else {
            throw RuntimeWireCodecError.invalidFlags
        }
        guard readUInt16(bytes, offset: 10) == 0 else {
            throw RuntimeWireCodecError.invalidHeader
        }
        let payloadLength = Int(readUInt32(bytes, offset: 12))
        guard payloadLength <= payloadCap(for: messageType) else {
            throw RuntimeWireCodecError.payloadTooLarge
        }
        let expectedCount = RuntimeWireFrame.headerByteCount + payloadLength
        guard bytes.count >= expectedCount else {
            throw RuntimeWireCodecError.truncatedFrame
        }
        guard bytes.count == expectedCount else {
            throw RuntimeWireCodecError.trailingBytes
        }
        return RuntimeWireFrame(
            messageType: messageType,
            flags: flags,
            payload: Array(bytes[RuntimeWireFrame.headerByteCount..<expectedCount])
        )
    }

    private static func payloadCap(for type: RuntimeWireMessageType) -> Int {
        switch type {
        case .hello, .helloAck, .helloReject,
             .bootstrapRequestV1, .bootstrapResponseV1, .protocolError:
            return RuntimeWireFrame.handshakePayloadCap
        case .streamFrame:
            return 8 * 1_024
        case .progress:
            return 16 * 1_024
        case .runtimeObservation:
            return 8 * 1_024
        case .response, .runtimeEvent, .observationStreamReset, .artifactFD:
            return 256 * 1_024
        case .request:
            return 1 * 1_024 * 1_024
        case .aggregateResponse:
            return 0
        }
    }

    private static func append(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xff))
    }

    private static func append(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value >> 24))
        bytes.append(UInt8((value >> 16) & 0xff))
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8(value & 0xff))
    }

    private static func readUInt16(_ bytes: [UInt8], offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func readUInt32(_ bytes: [UInt8], offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }
}

public struct RuntimeWireRange: Equatable, Sendable {
    public let minimum: UInt16
    public let maximum: UInt16

    public init(minimum: UInt16, maximum: UInt16) throws {
        guard minimum >= 1, minimum <= maximum else {
            throw RuntimeWireCodecError.invalidPayload
        }
        self.minimum = minimum
        self.maximum = maximum
    }

    public func contains(_ value: UInt16) -> Bool {
        minimum <= value && value <= maximum
    }
}

public enum RuntimeClientRole: String, Equatable, Sendable {
    case cli
    case gui
}

public struct RuntimeCompatibilityIdentity: Equatable, Sendable {
    public let runtimeCompatibilityID: String
    public let executionCatalogHash: String

    public init(
        runtimeCompatibilityID: String,
        executionCatalogHash: String
    ) throws {
        guard RuntimeHandshakeCodec.isBoundedASCII(
            runtimeCompatibilityID,
            maximumBytes: 256
        ),
        StableBytes.isLowercaseHex(executionCatalogHash, byteCount: 32)
        else {
            throw RuntimeWireCodecError.invalidPayload
        }
        self.runtimeCompatibilityID = runtimeCompatibilityID
        self.executionCatalogHash = executionCatalogHash
    }

    /// Pre-release fixture compatibility. Dynamic catalog identity is not part
    /// of the Runtime handshake, so these values are deliberately ignored.
    public init(
        runtimeCompatibilityID: String,
        executionCatalogHash: String,
        developerImageCatalogRevision _: String,
        developerImageCatalogHash _: String
    ) throws {
        try self.init(
            runtimeCompatibilityID: runtimeCompatibilityID,
            executionCatalogHash: executionCatalogHash
        )
    }
}

public struct RuntimeHello: Equatable, Sendable {
    public let wireRange: RuntimeWireRange
    public let clientBuildID: String
    public let compatibility: RuntimeCompatibilityIdentity
    public let clientInstanceID: CanonicalUUID
    public let role: RuntimeClientRole

    public init(
        wireRange: RuntimeWireRange,
        clientBuildID: String,
        compatibility: RuntimeCompatibilityIdentity,
        clientInstanceID: CanonicalUUID,
        role: RuntimeClientRole
    ) throws {
        guard RuntimeHandshakeCodec.isBoundedASCII(
            clientBuildID,
            maximumBytes: 256
        ) else {
            throw RuntimeWireCodecError.invalidPayload
        }
        self.wireRange = wireRange
        self.clientBuildID = clientBuildID
        self.compatibility = compatibility
        self.clientInstanceID = clientInstanceID
        self.role = role
    }
}

public struct RuntimeHelloAck: Equatable, Sendable {
    public let selectedWireMajor: UInt16
    public let runtimeBuildID: String
    public let compatibility: RuntimeCompatibilityIdentity
    public let connectionID: CanonicalUUID
    public let canonicalUDID: CanonicalUDID
    public let runtimeEpoch: UInt64
    public let connectionEpoch: UInt64?
    public let quiescing: Bool

    public init(
        runtimeBuildID: String,
        compatibility: RuntimeCompatibilityIdentity,
        connectionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID,
        runtimeEpoch: UInt64,
        connectionEpoch: UInt64? = nil,
        quiescing: Bool
    ) throws {
        guard RuntimeHandshakeCodec.isBoundedASCII(
            runtimeBuildID,
            maximumBytes: 256
        ) else {
            throw RuntimeWireCodecError.invalidPayload
        }
        self.selectedWireMajor = RuntimeWireFrame.protocolMajor
        self.runtimeBuildID = runtimeBuildID
        self.compatibility = compatibility
        self.connectionID = connectionID
        self.canonicalUDID = canonicalUDID
        self.runtimeEpoch = runtimeEpoch
        self.connectionEpoch = connectionEpoch
        self.quiescing = quiescing
    }
}

public struct RuntimeHelloReject: Equatable, Sendable {
    public let code = "incompatibleRuntime"
    public let blockers: [String]
    public let clientCompatibilityID: String
    public let runtimeCompatibilityID: String
    public let executionCatalogHash: String?

    public init(
        blockers: [String],
        clientCompatibilityID: String,
        runtimeCompatibilityID: String,
        executionCatalogHash: String? = nil
    ) throws {
        guard !blockers.isEmpty,
              blockers.count <= 64,
              blockers == blockers.sorted(),
              Set(blockers).count == blockers.count,
              blockers.allSatisfy({
                  RuntimeHandshakeCodec.isBoundedASCII($0, maximumBytes: 256)
              }),
              RuntimeHandshakeCodec.isBoundedASCII(
                  clientCompatibilityID,
                  maximumBytes: 256
              ),
              RuntimeHandshakeCodec.isBoundedASCII(
                  runtimeCompatibilityID,
                  maximumBytes: 256
              ),
              (executionCatalogHash.map {
                  StableBytes.isLowercaseHex($0, byteCount: 32)
              } ?? true)
        else {
            throw RuntimeWireCodecError.invalidPayload
        }
        self.blockers = blockers
        self.clientCompatibilityID = clientCompatibilityID
        self.runtimeCompatibilityID = runtimeCompatibilityID
        self.executionCatalogHash = executionCatalogHash
    }
}

public enum RuntimeHandshakeCodec {
    public static func encodeHello(_ value: RuntimeHello) throws -> [UInt8] {
        try encodeFrame(
            type: .hello,
            object: object([
                ("clientBuildID", .string(value.clientBuildID)),
                ("clientInstanceID", .string(value.clientInstanceID.canonicalString)),
                (
                    "executionCatalogHash",
                    .string(value.compatibility.executionCatalogHash)
                ),
                ("role", .string(value.role.rawValue)),
                (
                    "runtimeCompatibilityID",
                    .string(value.compatibility.runtimeCompatibilityID)
                ),
                ("schemaVersion", .number(.uint64(1))),
                (
                    "wireRange",
                    .object(
                        try object([
                            ("maximum", .number(.uint64(UInt64(value.wireRange.maximum)))),
                            ("minimum", .number(.uint64(UInt64(value.wireRange.minimum)))),
                        ])
                    )
                ),
            ])
        )
    }

    public static func decodeHello(_ bytes: [UInt8]) throws -> RuntimeHello {
        let frame = try RuntimeWireFrameCodec.decode(bytes)
        guard frame.messageType == .hello, frame.flags == 0 else {
            throw RuntimeWireCodecError.invalidPayload
        }
        let object = try canonicalObject(frame.payload)
        guard exactKeys(object) == [
            "clientBuildID", "clientInstanceID", "executionCatalogHash", "role",
            "runtimeCompatibilityID", "schemaVersion", "wireRange",
        ],
        try uint(object, "schemaVersion") == 1,
        let rangeObject = object["wireRange"]?.objectValue,
        exactKeys(rangeObject) == ["maximum", "minimum"],
        let clientBuildID = object["clientBuildID"]?.stringValue,
        let clientInstance = object["clientInstanceID"]?.stringValue,
        let clientInstanceID = try? CanonicalUUID(clientInstance),
        let roleValue = object["role"]?.stringValue,
        let role = RuntimeClientRole(rawValue: roleValue),
        let runtimeCompatibilityID = object["runtimeCompatibilityID"]?.stringValue,
        let executionCatalogHash = object["executionCatalogHash"]?.stringValue
        else {
            throw RuntimeWireCodecError.invalidPayload
        }
        let minimum = try checkedUInt16(try uint(rangeObject, "minimum"))
        let maximum = try checkedUInt16(try uint(rangeObject, "maximum"))
        return try RuntimeHello(
            wireRange: RuntimeWireRange(minimum: minimum, maximum: maximum),
            clientBuildID: clientBuildID,
            compatibility: RuntimeCompatibilityIdentity(
                runtimeCompatibilityID: runtimeCompatibilityID,
                executionCatalogHash: executionCatalogHash
            ),
            clientInstanceID: clientInstanceID,
            role: role
        )
    }

    public static func encodeAck(_ value: RuntimeHelloAck) throws -> [UInt8] {
        var members: [(String, RepositoryJSONValue)] = [
            ("canonicalUDID", .string(value.canonicalUDID.rawValue)),
            ("connectionID", .string(value.connectionID.canonicalString)),
            ("executionCatalogHash", .string(value.compatibility.executionCatalogHash)),
            ("quiescing", .bool(value.quiescing)),
            ("runtimeBuildID", .string(value.runtimeBuildID)),
            (
                "runtimeCompatibilityID",
                .string(value.compatibility.runtimeCompatibilityID)
            ),
            ("runtimeEpoch", .number(.uint64(value.runtimeEpoch))),
            ("schemaVersion", .number(.uint64(1))),
            ("selectedWireMajor", .number(.uint64(UInt64(value.selectedWireMajor)))),
        ]
        if let connectionEpoch = value.connectionEpoch {
            members.append(("connectionEpoch", .number(.uint64(connectionEpoch))))
        }
        return try encodeFrame(type: .helloAck, object: object(members))
    }

    public static func decodeAck(_ bytes: [UInt8]) throws -> RuntimeHelloAck {
        let object = try decodePayloadObject(bytes, expectedType: .helloAck)
        let keys = exactKeys(object)
        let required = [
            "canonicalUDID", "connectionID", "executionCatalogHash", "quiescing",
            "runtimeBuildID", "runtimeCompatibilityID", "runtimeEpoch",
            "schemaVersion", "selectedWireMajor",
        ]
        guard keys == required || keys == (required + ["connectionEpoch"]).sorted(),
              try uint(object, "schemaVersion") == 1,
              try uint(object, "selectedWireMajor")
                == UInt64(RuntimeWireFrame.protocolMajor),
              let runtimeBuildID = object["runtimeBuildID"]?.stringValue,
              let runtimeCompatibilityID = object["runtimeCompatibilityID"]?.stringValue,
              let executionCatalogHash = object["executionCatalogHash"]?.stringValue,
              let connectionValue = object["connectionID"]?.stringValue,
              let connectionID = try? CanonicalUUID(connectionValue),
              let targetValue = object["canonicalUDID"]?.stringValue,
              let canonicalUDID = try? CanonicalUDID(canonicalString: targetValue),
              case .bool(let quiescing)? = object["quiescing"]
        else {
            throw RuntimeWireCodecError.invalidPayload
        }
        let connectionEpoch: UInt64?
        if object["connectionEpoch"] != nil {
            connectionEpoch = try uint(object, "connectionEpoch")
        } else {
            connectionEpoch = nil
        }
        return try RuntimeHelloAck(
            runtimeBuildID: runtimeBuildID,
            compatibility: RuntimeCompatibilityIdentity(
                runtimeCompatibilityID: runtimeCompatibilityID,
                executionCatalogHash: executionCatalogHash
            ),
            connectionID: connectionID,
            canonicalUDID: canonicalUDID,
            runtimeEpoch: try uint(object, "runtimeEpoch"),
            connectionEpoch: connectionEpoch,
            quiescing: quiescing
        )
    }

    public static func encodeReject(_ value: RuntimeHelloReject) throws -> [UInt8] {
        var details: [(String, RepositoryJSONValue)] = [
            ("blockers", .array(value.blockers.map(RepositoryJSONValue.string))),
            ("clientCompatibilityID", .string(value.clientCompatibilityID)),
            ("runtimeCompatibilityID", .string(value.runtimeCompatibilityID)),
        ]
        if let hash = value.executionCatalogHash {
            details.append(("executionCatalogHash", .string(hash)))
        }
        return try encodeFrame(
            type: .helloReject,
            object: object([
                ("code", .string(value.code)),
                ("details", .object(try object(details))),
                ("schemaVersion", .number(.uint64(1))),
            ])
        )
    }

    public static func decodeReject(_ bytes: [UInt8]) throws -> RuntimeHelloReject {
        let object = try decodePayloadObject(bytes, expectedType: .helloReject)
        guard exactKeys(object) == ["code", "details", "schemaVersion"],
              try uint(object, "schemaVersion") == 1,
              object["code"]?.stringValue == "incompatibleRuntime",
              let details = object["details"]?.objectValue,
              let blockersValues = details["blockers"]?.arrayValue,
              let blockers = stringArray(blockersValues),
              let clientCompatibilityID = details["clientCompatibilityID"]?.stringValue,
              let runtimeCompatibilityID = details["runtimeCompatibilityID"]?.stringValue
        else {
            throw RuntimeWireCodecError.invalidPayload
        }
        let allowedDetailKeys = Set([
            "blockers", "clientCompatibilityID", "executionCatalogHash",
            "runtimeCompatibilityID",
        ])
        guard Set(details.members.map(\.key)).isSubset(of: allowedDetailKeys) else {
            throw RuntimeWireCodecError.invalidPayload
        }
        let executionCatalogHash = try optionalString(
            details,
            "executionCatalogHash"
        )
        return try RuntimeHelloReject(
            blockers: blockers,
            clientCompatibilityID: clientCompatibilityID,
            runtimeCompatibilityID: runtimeCompatibilityID,
            executionCatalogHash: executionCatalogHash
        )
    }

    public static func decodePayloadObject(
        _ frameBytes: [UInt8],
        expectedType: RuntimeWireMessageType
    ) throws -> RepositoryJSONObject {
        let frame = try RuntimeWireFrameCodec.decode(frameBytes)
        guard frame.messageType == expectedType, frame.flags == 0 else {
            throw RuntimeWireCodecError.invalidPayload
        }
        return try canonicalObject(frame.payload)
    }

    static func isBoundedASCII(_ value: String, maximumBytes: Int) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count <= maximumBytes
            && bytes.allSatisfy { (0x20...0x7e).contains($0) }
    }

    static func exactKeys(_ object: RepositoryJSONObject) -> [String] {
        object.members.map(\.key).sorted { lhs, rhs in
            lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
        }
    }

    static func canonicalObject(_ payload: [UInt8]) throws -> RepositoryJSONObject {
        do {
            return try RepositoryCanonicalJSON.parseDocument(
                payload,
                maximumByteCount: RuntimeWireFrame.handshakePayloadCap
            )
        } catch {
            throw RuntimeWireCodecError.invalidPayload
        }
    }

    static func uint(_ object: RepositoryJSONObject, _ key: String) throws -> UInt64 {
        guard let number = object[key]?.numberValue,
              let value = try? number.requireUInt64()
        else {
            throw RuntimeWireCodecError.invalidPayload
        }
        return value
    }

    static func checkedUInt16(_ value: UInt64) throws -> UInt16 {
        guard value <= UInt64(UInt16.max) else {
            throw RuntimeWireCodecError.invalidPayload
        }
        return UInt16(value)
    }

    private static func optionalString(
        _ object: RepositoryJSONObject,
        _ key: String
    ) throws -> String? {
        guard let value = object[key] else {
            return nil
        }
        guard let string = value.stringValue else {
            throw RuntimeWireCodecError.invalidPayload
        }
        return string
    }

    private static func stringArray(
        _ values: [RepositoryJSONValue]
    ) -> [String]? {
        var result = [String]()
        for value in values {
            guard let string = value.stringValue else {
                return nil
            }
            result.append(string)
        }
        return result
    }

    static func object(
        _ members: [(String, RepositoryJSONValue)]
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(
            members: members.map { RepositoryJSONMember(key: $0.0, value: $0.1) }
        )
    }

    private static func encodeFrame(
        type: RuntimeWireMessageType,
        object: RepositoryJSONObject
    ) throws -> [UInt8] {
        try RuntimeWireFrameCodec.encode(
            RuntimeWireFrame(
                messageType: type,
                payload: RepositoryCanonicalJSON.encodeDocument(object)
            )
        )
    }
}
