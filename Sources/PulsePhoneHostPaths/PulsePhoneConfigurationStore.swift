import Foundation

public enum PulsePhoneConfigurationStoreError: Error, Equatable, Sendable {
    case invalidDocument
    case unsafePath
    case writeFailed
}

public enum PulsePhoneConfigurationValue: Codable, Equatable, Sendable {
    case boolean(Bool)
    case string(String)
    case uint64(UInt64)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .uint64(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .boolean(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .uint64(let value): try container.encode(value)
        }
    }
}

public struct PulsePhoneConfigurationSnapshot: Codable, Equatable, Sendable {
    public static let schemaVersion: UInt64 = 1

    public let schemaVersion: UInt64
    public var values: [String: PulsePhoneConfigurationValue]

    public init(values: [String: PulsePhoneConfigurationValue] = [:]) {
        self.schemaVersion = Self.schemaVersion
        self.values = values
    }
}

public final class PulsePhoneConfigurationStore: @unchecked Sendable {
    public static let fileName = "configuration.v1.json"
    public static let maximumDocumentBytes = 16_384

    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public static func bundled() throws -> Self {
        let layout = try POSIXHostPathSystem().makeHostPathLayout()
        return Self(rootURL: URL(fileURLWithPath: layout.configurationDirectory))
    }

    public func load() throws -> PulsePhoneConfigurationSnapshot {
        let url = configurationURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PulsePhoneConfigurationSnapshot()
        }
        try requireRegularFile(url)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= Self.maximumDocumentBytes,
              let snapshot = try? JSONDecoder().decode(
                PulsePhoneConfigurationSnapshot.self,
                from: data
              ),
              snapshot.schemaVersion == PulsePhoneConfigurationSnapshot.schemaVersion
        else {
            throw PulsePhoneConfigurationStoreError.invalidDocument
        }
        return snapshot
    }

    public func save(_ snapshot: PulsePhoneConfigurationSnapshot) throws {
        guard snapshot.schemaVersion == PulsePhoneConfigurationSnapshot.schemaVersion else {
            throw PulsePhoneConfigurationStoreError.invalidDocument
        }
        try requireSafeRoot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(snapshot)
        } catch {
            throw PulsePhoneConfigurationStoreError.invalidDocument
        }
        guard data.count <= Self.maximumDocumentBytes else {
            throw PulsePhoneConfigurationStoreError.invalidDocument
        }
        do {
            try data.write(to: configurationURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configurationURL.path
            )
        } catch {
            throw PulsePhoneConfigurationStoreError.writeFailed
        }
    }

    private var configurationURL: URL {
        rootURL.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    private func requireSafeRoot() throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                  try rootURL.resourceValues(forKeys: [.isSymbolicLinkKey])
                    .isSymbolicLink != true
            else {
                throw PulsePhoneConfigurationStoreError.unsafePath
            }
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw PulsePhoneConfigurationStoreError.writeFailed
        }
    }

    private func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw PulsePhoneConfigurationStoreError.unsafePath
        }
    }
}
