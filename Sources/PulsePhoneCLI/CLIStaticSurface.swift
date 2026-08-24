import Foundation
import PulsePhoneCommandCatalog
import PulsePhoneHostPaths

public enum CLIStaticSurfaceError: Error, Equatable, Sendable {
    case ambiguousCommandPath(String)
    case invalidCompatibility(String)
    case invalidSelector(String)
    case missingArgumentDefinition(String)
    case missingBundledResources
}

public struct CLICompatibilitySupportVariant: Codable, Equatable, Sendable {
    public let maximumOSMajorExclusive: UInt64?
    public let minimumOSMajor: UInt64?
    public let preparationGroupID: String
    public let route: String?
    public let transportIDs: [String]
}

public struct CLICompatibilityPresentation: Codable, Equatable, Sendable {
    public let deviceRequired: Bool
    public let maximumOSMajorExclusive: UInt64?
    public let minimumOSMajor: UInt64?
    public let supportVariants: [CLICompatibilitySupportVariant]
    public let transportIDs: [String]
}

public struct CLICommandOption: Codable, Equatable, Sendable {
    public let constraint: String?
    public let required: Bool
    public let repeatable: Bool
    public let spelling: String
    public let summary: String
    public let valueName: String?

    init(_ definition: CLIOptionDefinition) {
        constraint = definition.constraint
        required = definition.required
        repeatable = definition.repeatable
        spelling = definition.spelling
        summary = definition.summary
        valueName = definition.valueName
    }
}

public struct CLICommandVariant: Codable, Equatable, Sendable {
    public let argumentSchemaID: String
    public let cliVariant: String
    public let commandID: String
    public let commandPath: String
    public let compatibility: CLICompatibilityPresentation
    public let examples: [String]
    public let groupID: String
    public let options: [CLICommandOption]
    public let selectorOption: String?
    public let summary: String
}

public struct CLICommandListResultV2: Codable, Equatable, Sendable {
    public let catalogSchemaVersion: UInt64
    public let commands: [CLICommandVariant]
    public let matrixRevision: String

    public init(surface: CLIStaticSurface) {
        catalogSchemaVersion = surface.catalogSchemaVersion
        commands = surface.variants
        matrixRevision = surface.matrixRevision
    }
}

public struct CLIStaticSurface: Equatable, Sendable {
    public let catalogSchemaVersion: UInt64
    public let globalOptions: [CLICommandOption]
    public let groups: [CLIHelpGroupDescriptor]
    public let matrixRevision: String
    public let variants: [CLICommandVariant]

    public static func bundled() throws -> Self {
        let appPath = try CanonicalAppPath.resolveCurrentExecutable()
        return try loading(repositoryRoot: appPath.resourcesURL)
    }

    public static func loading(repositoryRoot: URL) throws -> Self {
        try Self(catalog: ExecutionProfileCatalog.load(repositoryRoot: repositoryRoot))
    }

    public init(catalog: ExecutionProfileCatalogV1) throws {
        let definitions = Dictionary(
            uniqueKeysWithValues: catalog.commandCatalog.cliArgumentDefinitions.map {
                ($0.argumentSchemaID, $0)
            }
        )
        let cliProducts = catalog.expandedProductActions.filter {
            $0.command.exposures.contains(.cli)
        }
        var built = [CLICommandVariant]()
        for expanded in cliProducts {
            let command = expanded.command
            guard let cliVariant = command.cliVariant,
                  let help = command.help,
                  let definition = definitions[command.argumentSchemaID]
            else {
                throw CLIStaticSurfaceError.missingArgumentDefinition(command.commandID)
            }
            var options = definition.options.map(CLICommandOption.init)
            if let selector = help.selectorOption,
               !options.contains(where: { $0.spelling == selector.spelling }) {
                options.append(CLICommandOption(selector))
                options.sort { $0.spelling.utf8.lexicographicallyPrecedes($1.spelling.utf8) }
            }
            built.append(CLICommandVariant(
                argumentSchemaID: command.argumentSchemaID,
                cliVariant: cliVariant,
                commandID: command.commandID,
                commandPath: help.commandPath,
                compatibility: try Self.compatibility(expanded, catalog: catalog),
                examples: help.examples,
                groupID: help.groupID,
                options: options,
                selectorOption: nil,
                summary: help.summary
            ))
        }
        built.sort { $0.commandID.utf8.lexicographicallyPrecedes($1.commandID.utf8) }
        built = try Self.assignSelectors(built)
        guard built.count == 44 else {
            throw CLIStaticSurfaceError.ambiguousCommandPath("public CLI count")
        }
        catalogSchemaVersion = catalog.commandCatalog.schemaVersion
        globalOptions = catalog.commandCatalog.cliGlobalOptions.map(CLICommandOption.init)
        groups = catalog.commandCatalog.cliHelpGroups.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.groupID.utf8.lexicographicallyPrecedes($1.groupID.utf8)
        }
        matrixRevision = catalog.commandCatalog.matrixRevision
        variants = built
    }

    public func variants(commandPath: String) -> [CLICommandVariant] {
        variants.filter { $0.commandPath == commandPath }
    }

    public func matchingCommandPath(in arguments: [String]) -> String? {
        let candidates = Set(variants.map(\.commandPath)).filter { path in
            let words = path.split(separator: " ").map(String.init)
            return arguments.count >= words.count
                && Array(arguments.prefix(words.count)) == words
        }
        return candidates.max { lhs, rhs in
            lhs.split(separator: " ").count < rhs.split(separator: " ").count
        }
    }

    public func resolveVariant(
        commandPath: String,
        arguments: [String]
    ) throws -> CLICommandVariant {
        let candidates = variants(commandPath: commandPath)
        guard !candidates.isEmpty else {
            throw CLIStaticSurfaceError.ambiguousCommandPath(commandPath)
        }
        let selected = candidates.filter { variant in
            guard let selector = variant.selectorOption else { return false }
            return arguments.contains(selector)
        }
        if selected.count == 1 { return selected[0] }
        if selected.count > 1 {
            throw CLIStaticSurfaceError.ambiguousCommandPath(commandPath)
        }
        let defaults = candidates.filter { $0.selectorOption == nil }
        guard defaults.count == 1 else {
            throw CLIStaticSurfaceError.ambiguousCommandPath(commandPath)
        }
        return defaults[0]
    }

    private static func assignSelectors(
        _ variants: [CLICommandVariant]
    ) throws -> [CLICommandVariant] {
        let grouped = Dictionary(grouping: variants, by: \.commandPath)
        var output = [CLICommandVariant]()
        for variant in variants {
            let siblings = grouped[variant.commandPath] ?? []
            let selector: String?
            if siblings.count == 1 {
                selector = nil
            } else {
                let pathWords = variant.commandPath.split(separator: " ").map(String.init)
                let variantWords = variant.cliVariant.split(separator: " ").map(String.init)
                if variantWords == pathWords {
                    selector = nil
                } else if variantWords.count == pathWords.count + 1,
                          Array(variantWords.prefix(pathWords.count)) == pathWords,
                          let candidate = variantWords.last,
                          candidate.hasPrefix("--"),
                          variant.options.contains(where: { $0.spelling == candidate }) {
                    selector = candidate
                } else {
                    throw CLIStaticSurfaceError.invalidSelector(variant.commandID)
                }
            }
            output.append(CLICommandVariant(
                argumentSchemaID: variant.argumentSchemaID,
                cliVariant: variant.cliVariant,
                commandID: variant.commandID,
                commandPath: variant.commandPath,
                compatibility: variant.compatibility,
                examples: variant.examples,
                groupID: variant.groupID,
                options: variant.options,
                selectorOption: selector,
                summary: variant.summary
            ))
        }
        for (path, siblings) in Dictionary(grouping: output, by: \.commandPath) {
            guard siblings.filter({ $0.selectorOption == nil }).count == 1,
                  Set(siblings.compactMap(\.selectorOption)).count == siblings.count - 1
            else {
                throw CLIStaticSurfaceError.ambiguousCommandPath(path)
            }
        }
        return output
    }

    private static func compatibility(
        _ expanded: ExpandedProductCommandDescriptor,
        catalog: ExecutionProfileCatalogV1
    ) throws -> CLICompatibilityPresentation {
        let parameters = expanded.compatibilityRule.parameters
        let deviceRequired = try bool(parameters["deviceRequired"], default: false)
        let minimum = try uint64(parameters["minimumOSMajor"])
        let maximum = try uint64(parameters["maximumOSMajorExclusive"])
        let transports = try strings(parameters["transportIDs"])
        let rules = Dictionary(uniqueKeysWithValues: catalog.compatibilityRules.map {
            ($0.ruleID, $0)
        })
        let variants = try expanded.preparationGroups.map { group in
            guard let rule = rules[group.compatibilityRuleID] else {
                throw CLIStaticSurfaceError.invalidCompatibility(group.preparationGroupID)
            }
            return CLICompatibilitySupportVariant(
                maximumOSMajorExclusive: try uint64(
                    rule.parameters["maximumOSMajorExclusive"]
                ),
                minimumOSMajor: try uint64(rule.parameters["minimumOSMajor"]),
                preparationGroupID: group.preparationGroupID,
                route: try string(rule.parameters["route"]),
                transportIDs: try strings(rule.parameters["transportIDs"])
            )
        }
        return CLICompatibilityPresentation(
            deviceRequired: deviceRequired,
            maximumOSMajorExclusive: maximum,
            minimumOSMajor: minimum,
            supportVariants: variants,
            transportIDs: transports
        )
    }

    private static func bool(
        _ value: CompatibilityParameterValue?,
        default defaultValue: Bool
    ) throws -> Bool {
        guard let value else { return defaultValue }
        guard case .bool(let result) = value else {
            throw CLIStaticSurfaceError.invalidCompatibility("boolean")
        }
        return result
    }

    private static func string(
        _ value: CompatibilityParameterValue?
    ) throws -> String? {
        guard let value else { return nil }
        guard case .string(let result) = value else {
            throw CLIStaticSurfaceError.invalidCompatibility("string")
        }
        return result
    }

    private static func strings(
        _ value: CompatibilityParameterValue?
    ) throws -> [String] {
        guard let value else { return [] }
        guard case .strings(let result) = value else {
            throw CLIStaticSurfaceError.invalidCompatibility("strings")
        }
        return result
    }

    private static func uint64(
        _ value: CompatibilityParameterValue?
    ) throws -> UInt64? {
        guard let value else { return nil }
        guard case .uint64(let result) = value else {
            throw CLIStaticSurfaceError.invalidCompatibility("uint64")
        }
        return result
    }
}
