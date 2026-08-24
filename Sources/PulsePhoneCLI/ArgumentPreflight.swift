import Foundation

public enum CLIOutputMode: Equatable, Sendable {
    case human
    case json
}

public enum CLIArgumentPreflightError: Error, Equatable, Sendable {
    case duplicateJSONFlag
    case invalidInternalAnalyzers
    case verboseUnsupported
    case missingCommand
    case unknownCommand(String)
}

public struct CLIInvocation: Equatable, Sendable {
    public let commandID: String
    public let outputMode: CLIOutputMode
    public let commandToken: String
    public let arguments: [String]
    public let options: [CLICommandOption]
}

public enum CLIArgumentPreflight {
    public static func outputMode(in arguments: [String]) -> CLIOutputMode {
        arguments.contains("--json") ? .json : .human
    }

    public static func helpRequest(
        _ rawArguments: [String],
        surface: CLIStaticSurface
    ) throws -> CLIHelpRequest? {
        let arguments = try normalizedArguments(rawArguments)
        if arguments == ["--help"] || arguments == ["help"] {
            return .topLevel
        }
        guard arguments.last == "--help" else { return nil }
        let commandArguments = Array(arguments.dropLast())
        guard let path = surface.matchingCommandPath(in: commandArguments),
              path.split(separator: " ").map(String.init) == commandArguments
        else {
            throw CLIArgumentPreflightError.unknownCommand(
                commandArguments.joined(separator: " ")
            )
        }
        return .commandPath(path)
    }

    public static func parse(
        _ rawArguments: [String],
        surface: CLIStaticSurface
    ) throws -> CLIInvocation {
        let outputMode = outputMode(in: rawArguments)
        let arguments = try normalizedArguments(rawArguments)
        guard let first = arguments.first else {
            throw CLIArgumentPreflightError.missingCommand
        }
        guard let path = surface.matchingCommandPath(in: arguments) else {
            throw CLIArgumentPreflightError.unknownCommand(first)
        }
        let wordCount = path.split(separator: " ").count
        let remaining = Array(arguments.dropFirst(wordCount))
        let variant = try surface.resolveVariant(
            commandPath: path,
            arguments: remaining
        )
        return CLIInvocation(
            commandID: variant.commandID,
            outputMode: outputMode,
            commandToken: path,
            arguments: remaining,
            options: variant.options
        )
    }

    private static func normalizedArguments(_ rawArguments: [String]) throws -> [String] {
        let jsonCount = rawArguments.filter { $0 == "--json" }.count
        guard jsonCount <= 1 else {
            throw CLIArgumentPreflightError.duplicateJSONFlag
        }
        guard !rawArguments.contains("--verbose") else {
            throw CLIArgumentPreflightError.verboseUnsupported
        }
        return rawArguments.filter { $0 != "--json" }
    }
}
