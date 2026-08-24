import Foundation
import PulsePhoneSharedDefinitions

public enum CLIOutputAdapterError: Error, Equatable, Sendable {
    case invalidEnvelope
}

public enum CLIOutputTarget: Equatable, Sendable, Encodable {
    case global
    case device(CanonicalUDID)
    case unresolved(requestedUDID: String?)

    private enum CodingKeys: String, CodingKey {
        case requestedUDID
        case scope
        case udid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .global:
            try container.encode("global", forKey: .scope)
        case .device(let canonicalUDID):
            try container.encode("device", forKey: .scope)
            try container.encode(canonicalUDID.rawValue, forKey: .udid)
        case .unresolved(let requestedUDID):
            try container.encode("unresolved", forKey: .scope)
            try container.encodeIfPresent(requestedUDID, forKey: .requestedUDID)
        }
    }
}

public struct CLIErrorPayload: Codable, Equatable, Sendable {
    public let code: String
    public let details: [String: String]?
    public let message: String?
    public let reason: String?

    public init(
        code: String,
        details: [String: String]? = nil,
        message: String? = nil,
        reason: String? = nil
    ) {
        self.code = code
        self.details = details
        self.message = message
        self.reason = reason
    }
}

public struct CLIOutputMetadata: Codable, Equatable, Sendable {
    public let runtimeMayContinue: Bool?

    public init(runtimeMayContinue: Bool? = nil) {
        self.runtimeMayContinue = runtimeMayContinue
    }
}

public struct CLIOutputChunk: Equatable, Sendable {
    public let stdout: [String]
    public let stderr: [String]

    public init(stdout: [String] = [], stderr: [String] = []) {
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct CLITerminalOutput: Equatable, Sendable {
    public let chunk: CLIOutputChunk
    public let exitCode: Int32

    public init(chunk: CLIOutputChunk, exitCode: Int32) {
        self.chunk = chunk
        self.exitCode = exitCode
    }
}

public struct CLIOutputAdapter: Sendable {
    private struct SuccessEnvelope<Result: Encodable>: Encodable {
        let schemaVersion = 1
        let ok = true
        let commandID: String
        let target: CLIOutputTarget
        let result: Result
        let metadata: CLIOutputMetadata?
    }

    private struct FailureEnvelope: Encodable {
        let schemaVersion = 1
        let ok = false
        let commandID: String?
        let commandToken: String?
        let target: CLIOutputTarget
        let error: CLIErrorPayload
        let metadata: CLIOutputMetadata?
    }

    public let mode: CLIOutputMode

    public init(mode: CLIOutputMode) {
        self.mode = mode
    }

    public func progress(_ message: String) -> CLIOutputChunk {
        switch mode {
        case .human:
            return CLIOutputChunk(stderr: [message])
        case .json:
            return CLIOutputChunk()
        }
    }

    public func success<Result: Encodable>(
        commandID: String,
        target: CLIOutputTarget,
        result: Result,
        human: String,
        metadata: CLIOutputMetadata? = nil
    ) throws -> CLITerminalOutput {
        switch mode {
        case .human:
            return CLITerminalOutput(
                chunk: CLIOutputChunk(stdout: [human]),
                exitCode: 0
            )
        case .json:
            return CLITerminalOutput(
                chunk: CLIOutputChunk(
                    stdout: [try encode(SuccessEnvelope(
                        commandID: commandID,
                        target: target,
                        result: result,
                        metadata: metadata
                    ))]
                ),
                exitCode: 0
            )
        }
    }

    public func failure(
        family: ErrorFamily,
        commandID: String? = nil,
        commandToken: String? = nil,
        target: CLIOutputTarget,
        error: CLIErrorPayload,
        metadata: CLIOutputMetadata? = nil
    ) throws -> CLITerminalOutput {
        switch mode {
        case .human:
            let explanation = error.reason
                ?? error.details?["reason"]
                ?? error.message
            let message = explanation.map { "\(error.code): \($0)" }
                ?? error.code
            return CLITerminalOutput(
                chunk: CLIOutputChunk(stderr: [message]),
                exitCode: family.exitCode
            )
        case .json:
            return CLITerminalOutput(
                chunk: CLIOutputChunk(
                    stdout: [try encode(FailureEnvelope(
                        commandID: commandID,
                        commandToken: commandID == nil ? commandToken : nil,
                        target: target,
                        error: error,
                        metadata: metadata
                    ))]
                ),
                exitCode: family.exitCode
            )
        }
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CLIOutputAdapterError.invalidEnvelope
        }
        return string
    }
}
