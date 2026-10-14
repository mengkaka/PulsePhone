/// Validation shared by CLI, planning and Runtime. Errors never carry user values.
public enum LaunchEnvironmentError: Error, Equatable, Sendable {
    case invalidEnvironment
}

public enum LaunchEnvironment {
    public static let maximumVariables = 64
    public static let maximumNameBytes = 128
    public static let maximumTotalBytes = 8_192
    public static let maximumEncodedBytes = 65_536

    public static func parse(_ assignments: [String]) throws -> [String: String] {
        var result = [String: String]()
        for assignment in assignments {
            let bytes = assignment.utf8
            guard let separator = bytes.firstIndex(of: 0x3d) else {
                throw LaunchEnvironmentError.invalidEnvironment
            }
            let name = String(decoding: bytes[..<separator], as: UTF8.self)
            let value = String(decoding: bytes[bytes.index(after: separator)...], as: UTF8.self)
            try validateEntry(name: name, value: value)
            result[name] = value
        }
        try validate(result)
        return result
    }

    public static func validate(_ environment: [String: String]) throws {
        guard environment.count <= maximumVariables else {
            throw LaunchEnvironmentError.invalidEnvironment
        }
        var total = 0
        for (name, value) in environment {
            try validateEntry(name: name, value: value)
            total += name.utf8.count + value.utf8.count
            guard total <= maximumTotalBytes else {
                throw LaunchEnvironmentError.invalidEnvironment
            }
        }
    }

    public static func encode(_ environment: [String: String]) throws -> String {
        try validate(environment)
        let object = try RepositoryJSONObject(members: environment.map {
            RepositoryJSONMember(key: $0.key, value: .string($0.value))
        })
        return String(decoding: RepositoryCanonicalJSON.encodeDocument(object), as: UTF8.self)
    }

    public static func decode(_ encoded: String) throws -> [String: String] {
        do {
            guard encoded.utf8.count <= maximumEncodedBytes else {
                throw LaunchEnvironmentError.invalidEnvironment
            }
            let object = try RepositoryCanonicalJSON.parseDocument(
                Array(encoded.utf8), maximumByteCount: maximumEncodedBytes
            )
            var result = [String: String]()
            for member in object.members {
                guard case .string(let value) = member.value else {
                    throw LaunchEnvironmentError.invalidEnvironment
                }
                result[member.key] = value
            }
            try validate(result)
            return result
        } catch {
            throw LaunchEnvironmentError.invalidEnvironment
        }
    }

    private static func validateEntry(name: String, value: String) throws {
        let bytes = Array(name.utf8)
        func letter(_ byte: UInt8) -> Bool {
            (65...90).contains(byte) || (97...122).contains(byte) || byte == 95
        }
        guard (1...maximumNameBytes).contains(bytes.count),
              letter(bytes[0]),
              bytes.allSatisfy({ letter($0) || (48...57).contains($0) }),
              !value.utf8.contains(0), value.utf8.count <= maximumTotalBytes else {
            throw LaunchEnvironmentError.invalidEnvironment
        }
    }
}
