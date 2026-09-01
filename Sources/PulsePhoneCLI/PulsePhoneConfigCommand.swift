import Foundation
import PulsePhoneElement
import PulsePhoneHostPaths

public struct PulsePhoneConfigCommandResult: Codable, Equatable, Sendable {
    public let effectiveAt: String
    public let key: String
    public let state: String
    public let value: PulsePhoneConfigurationValue?

    public init(key: PulsePhoneConfigurationKey, value: PulsePhoneConfigurationValue?) {
        self.effectiveAt = "newRuntime"
        self.key = key.rawValue
        self.state = value == nil ? "unset" : "configured"
        self.value = value
    }
}

enum PulsePhoneConfigCommand {
    static func dispatch(
        arguments: [String],
        adapter: CLIOutputAdapter,
        store suppliedStore: PulsePhoneConfigurationStore? = nil
    ) throws -> CLITerminalOutput? {
        if arguments == ["help", "config"] || arguments == ["help", "config", "--json"] {
            return CLITerminalOutput(
                chunk: CLIOutputChunk(stdout: [help]),
                exitCode: 0
            )
        }
        guard arguments.first == "config" else { return nil }
        guard arguments.filter({ $0 == "--json" }).count <= 1 else {
            return try failure(adapter, message: "Duplicate --json option.")
        }
        let command = arguments.filter { $0 != "--json" }
        if command == ["config", "--help"] || command == ["config", "help"] {
            return CLITerminalOutput(
                chunk: CLIOutputChunk(stdout: [help]),
                exitCode: 0
            )
        }
        guard command.count >= 3,
              let key = PulsePhoneConfigurationRegistry.key(named: command[2])
        else {
            return try failure(adapter, message: help)
        }
        switch command[1] {
        case "get":
            guard command.count == 3 else { return try failure(adapter, message: help) }
            let result: PulsePhoneConfigCommandResult
            do {
                let store = try suppliedStore ?? PulsePhoneConfigurationStore.bundled()
                result = PulsePhoneConfigCommandResult(
                    key: key,
                    value: try store.load().values[key.rawValue]
                )
            } catch {
                return try storageFailure(adapter, commandID: "config.get")
            }
            return try adapter.success(
                commandID: "config.get",
                target: .global,
                result: result,
                human: humanGet(result)
            )
        case "set":
            guard command.count == 4 else { return try failure(adapter, message: help) }
            let value: PulsePhoneConfigurationValue
            do {
                value = try PulsePhoneConfigurationRegistry.validate(
                    key: key,
                    rawValue: command[3]
                )
            } catch {
                return try invalidValueFailure(adapter, commandID: "config.set", key: key)
            }
            do {
                let store = try suppliedStore ?? PulsePhoneConfigurationStore.bundled()
                var snapshot = try store.load()
                snapshot.values[key.rawValue] = value
                try store.save(snapshot)
            } catch {
                return try storageFailure(adapter, commandID: "config.set")
            }
            let result = PulsePhoneConfigCommandResult(key: key, value: value)
            return try adapter.success(
                commandID: "config.set",
                target: .global,
                result: result,
                human: "Configuration saved. It will be used by newly started device runtimes."
            )
        case "clear":
            guard command.count == 3 else { return try failure(adapter, message: help) }
            do {
                let store = try suppliedStore ?? PulsePhoneConfigurationStore.bundled()
                var snapshot = try store.load()
                snapshot.values.removeValue(forKey: key.rawValue)
                try store.save(snapshot)
            } catch {
                return try storageFailure(adapter, commandID: "config.clear")
            }
            let result = PulsePhoneConfigCommandResult(key: key, value: nil)
            return try adapter.success(
                commandID: "config.clear",
                target: .global,
                result: result,
                human: "Configuration cleared. Newly started device runtimes use the default behavior."
            )
        default:
            return try failure(adapter, message: help)
        }
    }

    static var help: String {
        let keys = PulsePhoneConfigurationKey.allCases.map {
            "  \($0.rawValue)  \($0.summary)"
        }.joined(separator: "\n")
        return """
        Usage: PulsePhone config <get|set|clear> KEY [VALUE] [--json]

        Available keys:
        \(keys)
        """
    }

    static let globalHelpSection = """
    Configuration:
      PulsePhone config --help
          List whitelisted local configuration keys.
      PulsePhone config get KEY [--json]
          Read a local configuration value.
      PulsePhone config set KEY VALUE [--json]
          Save a local configuration value.
      PulsePhone config clear KEY [--json]
          Remove a local configuration value.
    """

    private static func humanGet(_ result: PulsePhoneConfigCommandResult) -> String {
        guard let value = result.value else {
            return "\(result.key) is unset."
        }
        return "\(result.key): \(render(value))"
    }

    private static func render(_ value: PulsePhoneConfigurationValue) -> String {
        switch value {
        case .boolean(let value): String(value)
        case .string(let value): value
        case .uint64(let value): String(value)
        }
    }

    private static func failure(
        _ adapter: CLIOutputAdapter,
        message: String
    ) throws -> CLITerminalOutput {
        try adapter.failure(
            family: .argument,
            commandToken: "config",
            target: .global,
            error: CLIErrorPayload(code: "invalidArgument", message: message)
        )
    }

    private static func invalidValueFailure(
        _ adapter: CLIOutputAdapter,
        commandID: String,
        key: PulsePhoneConfigurationKey
    ) throws -> CLITerminalOutput {
        try adapter.failure(
            family: .argument,
            commandID: commandID,
            target: .global,
            error: CLIErrorPayload(
                code: "invalidArgument",
                details: ["key": key.rawValue],
                message: "Invalid value for \(key.rawValue)."
            )
        )
    }

    private static func storageFailure(
        _ adapter: CLIOutputAdapter,
        commandID: String
    ) throws -> CLITerminalOutput {
        try adapter.failure(
            family: .internal,
            commandID: commandID,
            target: .global,
            error: CLIErrorPayload(
                code: "internalFailure",
                message: "PulsePhone configuration could not be read or written."
            )
        )
    }
}
