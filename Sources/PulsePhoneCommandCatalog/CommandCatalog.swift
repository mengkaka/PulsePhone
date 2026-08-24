import Darwin
import Foundation
import PulsePhoneSharedDefinitions

public enum CommandCatalogError: Error, Equatable, Sendable {
    case missing(String)
    case unsafeNode(String)
    case invalidField(String)
    case invalidValue(String)
    case duplicateID(String)
    case unsorted(String)
    case resultSchemaCoverage
}

public enum CommandCatalog {
    public static let matrixRevision = "command-matrix.v17-20260822"
    public static let registryRelativePath = "Registries/command-catalog.v1.json"
    public static let schemaRelativePath = "Schemas/command-catalog.v1.schema.json"
    public static let resultSchemaDirectory = "Schemas/result-schemas"

    public static func load(repositoryRoot: URL) throws -> CommandCatalogV1 {
        let root = try loadCanonicalObject(
            repositoryRoot.appendingPathComponent(registryRelativePath),
            relativePath: registryRelativePath
        )
        try requireExactKeys(
            root,
            required: [
                "cliArgumentDefinitions", "cliGlobalOptions", "cliHelpGroups",
                "features", "matrixRevision", "productActions",
                "retainedResultSchemaRefs", "schemaVersion", "supportingActions",
            ],
            optional: [
                "compatibilityRules", "executionProfiles", "loggingProfiles",
                "resourceClaimTemplates",
            ],
            context: "catalog"
        )
        guard try uint64(root, "schemaVersion") == 1 else {
            throw CommandCatalogError.invalidValue("schemaVersion")
        }
        guard try string(root, "matrixRevision") == matrixRevision else {
            throw CommandCatalogError.invalidValue("matrixRevision")
        }
        let profileKeys = [
            "compatibilityRules", "executionProfiles", "loggingProfiles",
            "resourceClaimTemplates",
        ]
        let presentProfileKeys = profileKeys.filter { root[$0] != nil }
        guard presentProfileKeys.isEmpty || presentProfileKeys.count == profileKeys.count else {
            throw CommandCatalogError.invalidValue("profile definition set")
        }
        for key in presentProfileKeys {
            _ = try array(root, key)
        }

        let argumentDefinitions = try array(root, "cliArgumentDefinitions").map(
            parseCLIArgumentDefinition
        )
        let globalOptions = try array(root, "cliGlobalOptions").map(parseCLIOption)
        let helpGroups = try array(root, "cliHelpGroups").map(parseCLIHelpGroup)
        let products = try array(root, "productActions").map(parseProduct)
        let supporting = try array(root, "supportingActions").map(parseSupporting)
        let features = try array(root, "features").map(parseFeature)
        let retainedResultSchemaRefs = try strings(root, "retainedResultSchemaRefs")
        guard argumentDefinitions.count == 18,
              globalOptions.count == 1,
              helpGroups.count == 11,
              products.count == 52,
              supporting.count == 21,
              features.count == 6
        else {
            throw CommandCatalogError.invalidValue("identity counts")
        }
        try requireSortedUnique(
            argumentDefinitions.map(\.argumentSchemaID),
            context: "cliArgumentDefinitions"
        )
        try requireSortedUnique(
            globalOptions.map(\.spelling),
            context: "cliGlobalOptions"
        )
        try requireSortedUnique(helpGroups.map(\.groupID), context: "cliHelpGroups")
        try requireUnique(helpGroups.map { String($0.order) }, context: "cliHelpGroup order")
        try requireSortedUnique(
            retainedResultSchemaRefs,
            context: "retainedResultSchemaRefs"
        )
        try requireSortedUnique(products.map(\.commandID), context: "productActions")
        try requireSortedUnique(
            supporting.map(\.supportingActionID),
            context: "supportingActions"
        )
        try requireSortedUnique(features.map(\.featureID), context: "features")

        let productIDs = Set(products.map(\.commandID))
        let argumentDefinitionIDs = Set(argumentDefinitions.map(\.argumentSchemaID))
        let helpGroupIDs = Set(helpGroups.map(\.groupID))
        let cliProducts = products.filter { $0.exposures.contains(.cli) }
        guard cliProducts.count == 44,
              Set(cliProducts.map(\.argumentSchemaID)) == argumentDefinitionIDs,
              globalOptions.count == 1,
              globalOptions[0].spelling == "--json",
              !globalOptions[0].required,
              !globalOptions[0].repeatable,
              globalOptions[0].valueName == nil,
              cliProducts.allSatisfy({
                  guard let help = $0.help else { return false }
                  return argumentDefinitionIDs.contains($0.argumentSchemaID)
                      && helpGroupIDs.contains(help.groupID)
              }),
              products.filter({ !$0.exposures.contains(.cli) }).allSatisfy({ $0.help == nil })
        else {
            throw CommandCatalogError.invalidValue("CLI help coverage")
        }
        for descriptor in supporting {
            guard Set(descriptor.parentCommandIDs).isSubset(of: productIDs) else {
                throw CommandCatalogError.invalidValue(
                    "supporting parent: \(descriptor.supportingActionID)"
                )
            }
        }
        try validateResultSchemas(
            repositoryRoot: repositoryRoot,
            references: products.map { ($0.resultSchemaRef, $0.resultSchemaID) }
                + supporting.map { ($0.resultSchemaRef, $0.resultSchemaID) }
                + retainedResultSchemaRefs.map { ($0, "retained") }
        )
        return CommandCatalogV1(
            cliArgumentDefinitions: argumentDefinitions,
            cliGlobalOptions: globalOptions,
            cliHelpGroups: helpGroups,
            matrixRevision: matrixRevision,
            productActions: products,
            retainedResultSchemaRefs: retainedResultSchemaRefs,
            supportingActions: supporting,
            features: features
        )
    }

    public static func asciiLessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func parseProduct(
        _ value: RepositoryJSONValue
    ) throws -> ProductCommandDescriptor {
        let object = try requiredObject(value, context: "product action")
        try requireExactKeys(
            object,
            required: [
                "argumentSchemaID", "category", "commandID",
                "executionProfileID", "exposures", "loggingProfileID",
                "releaseScope", "resultSchemaID", "resultSchemaRef",
            ],
            optional: [
                "cliVariant", "guiSurface", "help", "policyBindings",
            ],
            context: "product action"
        )
        let commandID = try identifier(object, "commandID")
        guard let category = CommandCategory(rawValue: try string(object, "category")),
              let releaseScope = ReleaseScope(rawValue: try string(object, "releaseScope"))
        else {
            throw CommandCatalogError.invalidValue(commandID)
        }
        let exposureStrings = try strings(object, "exposures")
        try requireSortedUnique(exposureStrings, context: "exposures: \(commandID)")
        let exposures = try exposureStrings.map { value in
            guard let exposure = CatalogExposure(rawValue: value) else {
                throw CommandCatalogError.invalidValue("exposure: \(commandID)")
            }
            return exposure
        }
        let cliVariant = object["cliVariant"]?.stringValue
        let guiSurface = try object["guiSurface"].map(parseGUISurface)
        let help = try object["help"].map(parseCLIHelpPresentation)
        guard exposures.contains(.cli) == (cliVariant != nil),
              exposures.contains(.gui) == (guiSurface != nil),
              exposures.contains(.cli) == (help != nil)
        else {
            throw CommandCatalogError.invalidValue("exposure projection: \(commandID)")
        }
        if let cliVariant {
            try requireBoundedASCII(cliVariant, maximumBytes: 128, context: "cliVariant")
        }
        return ProductCommandDescriptor(
            argumentSchemaID: try identifier(object, "argumentSchemaID"),
            category: category,
            cliVariant: cliVariant,
            commandID: commandID,
            executionProfileID: try identifier(object, "executionProfileID"),
            exposures: exposures,
            guiSurface: guiSurface,
            help: help,
            loggingProfileID: try identifier(object, "loggingProfileID"),
            policyBindings: try object["policyBindings"].map {
                try parsePolicyBindings($0, context: commandID)
            },
            releaseScope: releaseScope,
            resultSchemaID: try identifier(object, "resultSchemaID"),
            resultSchemaRef: try resultSchemaRef(object)
        )
    }

    private static func parseSupporting(
        _ value: RepositoryJSONValue
    ) throws -> SupportingActionDescriptor {
        let object = try requiredObject(value, context: "supporting action")
        try requireExactKeys(
            object,
            required: [
                "callerIDs", "parentCommandIDs", "releaseInheritance",
                "resultSchemaID", "resultSchemaRef", "shape",
                "supportingActionID",
            ],
            optional: ["policyBindings"],
            context: "supporting action"
        )
        let supportingActionID = try identifier(object, "supportingActionID")
        guard let shape = SupportingActionShape(rawValue: try string(object, "shape")),
              let releaseInheritance = ReleaseScope(
                rawValue: try string(object, "releaseInheritance")
              )
        else {
            throw CommandCatalogError.invalidValue(supportingActionID)
        }
        let callerIDs = try strings(object, "callerIDs")
        let parentCommandIDs = try strings(object, "parentCommandIDs")
        guard !callerIDs.isEmpty else {
            throw CommandCatalogError.invalidValue("callerIDs: \(supportingActionID)")
        }
        try requireSortedUnique(callerIDs, context: "callerIDs: \(supportingActionID)")
        try requireSortedUnique(
            parentCommandIDs,
            context: "parentCommandIDs: \(supportingActionID)"
        )
        return SupportingActionDescriptor(
            callerIDs: callerIDs,
            parentCommandIDs: parentCommandIDs,
            policyBindings: try object["policyBindings"].map {
                try parsePolicyBindings($0, context: supportingActionID)
            },
            releaseInheritance: releaseInheritance,
            resultSchemaID: try identifier(object, "resultSchemaID"),
            resultSchemaRef: try resultSchemaRef(object),
            shape: shape,
            supportingActionID: supportingActionID
        )
    }

    private static func parseFeature(
        _ value: RepositoryJSONValue
    ) throws -> NonCommandFeatureDescriptor {
        let object = try requiredObject(value, context: "feature")
        try requireExactKeys(
            object,
            required: ["exposures", "featureID", "releaseScope"],
            context: "feature"
        )
        let featureID = try identifier(object, "featureID")
        let exposureStrings = try strings(object, "exposures")
        try requireSortedUnique(exposureStrings, context: "feature exposures: \(featureID)")
        let exposures = try exposureStrings.map { value in
            guard let exposure = CatalogExposure(rawValue: value) else {
                throw CommandCatalogError.invalidValue("feature exposure: \(featureID)")
            }
            return exposure
        }
        guard let releaseScope = ReleaseScope(rawValue: try string(object, "releaseScope")) else {
            throw CommandCatalogError.invalidValue("feature scope: \(featureID)")
        }
        return NonCommandFeatureDescriptor(
            exposures: exposures,
            featureID: featureID,
            releaseScope: releaseScope
        )
    }

    private static func parseGUISurface(
        _ value: RepositoryJSONValue
    ) throws -> GUISurfaceDescriptor {
        let object = try requiredObject(value, context: "gui surface")
        try requireExactKeys(
            object,
            required: ["kind"],
            optional: ["order"],
            context: "gui surface"
        )
        guard let kind = GUISurfaceKind(rawValue: try string(object, "kind")) else {
            throw CommandCatalogError.invalidValue("gui surface kind")
        }
        let order: UInt64?
        if let number = object["order"]?.numberValue {
            order = try number.requireUInt64()
        } else {
            order = nil
        }
        guard (kind == .toolbar) == (order != nil) else {
            throw CommandCatalogError.invalidValue("gui surface order")
        }
        return GUISurfaceDescriptor(kind: kind, order: order)
    }

    private static func parseCLIHelpGroup(
        _ value: RepositoryJSONValue
    ) throws -> CLIHelpGroupDescriptor {
        let object = try requiredObject(value, context: "CLI help group")
        try requireExactKeys(
            object,
            required: ["groupID", "order", "title"],
            context: "CLI help group"
        )
        let groupID = try identifier(object, "groupID")
        let title = try string(object, "title")
        try requireBoundedASCII(title, maximumBytes: 64, context: "CLI help title")
        return CLIHelpGroupDescriptor(
            groupID: groupID,
            order: try uint64(object, "order"),
            title: title
        )
    }

    private static func parseCLIArgumentDefinition(
        _ value: RepositoryJSONValue
    ) throws -> CLIArgumentDefinition {
        let object = try requiredObject(value, context: "CLI argument definition")
        try requireExactKeys(
            object,
            required: ["argumentSchemaID", "options"],
            context: "CLI argument definition"
        )
        let schemaID = try identifier(object, "argumentSchemaID")
        let options = try array(object, "options").map(parseCLIOption)
        try requireSortedUnique(
            options.map(\.spelling),
            context: "CLI options: \(schemaID)"
        )
        return CLIArgumentDefinition(argumentSchemaID: schemaID, options: options)
    }

    private static func parseCLIOption(
        _ value: RepositoryJSONValue
    ) throws -> CLIOptionDefinition {
        let object = try requiredObject(value, context: "CLI option")
        try requireExactKeys(
            object,
            required: ["repeatable", "required", "spelling", "summary"],
            optional: ["constraint", "valueName"],
            context: "CLI option"
        )
        let spelling = try string(object, "spelling")
        let summary = try string(object, "summary")
        guard spelling.hasPrefix("--"),
              spelling.utf8.count <= 64,
              spelling.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e })
        else {
            throw CommandCatalogError.invalidValue("CLI option spelling")
        }
        try requireBoundedASCII(summary, maximumBytes: 256, context: "CLI option summary")
        let valueName = try optionalString(object["valueName"], context: "CLI value name")
        if let valueName {
            try requireBoundedASCII(valueName, maximumBytes: 64, context: "CLI value name")
        }
        let constraint = try optionalString(object["constraint"], context: "CLI constraint")
        if let constraint {
            try requireBoundedASCII(
                constraint,
                maximumBytes: 256,
                context: "CLI option constraint"
            )
        }
        guard case .bool(let required) = object["required"] else {
            throw CommandCatalogError.invalidField("CLI option required")
        }
        guard case .bool(let repeatable) = object["repeatable"],
              !repeatable || valueName != nil
        else {
            throw CommandCatalogError.invalidField("CLI option repeatable")
        }
        return CLIOptionDefinition(
            constraint: constraint,
            required: required,
            repeatable: repeatable,
            spelling: spelling,
            summary: summary,
            valueName: valueName
        )
    }

    private static func optionalString(
        _ value: RepositoryJSONValue?,
        context: String
    ) throws -> String? {
        guard let value else { return nil }
        guard case .string(let string) = value else {
            throw CommandCatalogError.invalidField(context)
        }
        return string
    }

    private static func parseCLIHelpPresentation(
        _ value: RepositoryJSONValue
    ) throws -> CLIHelpPresentation {
        let object = try requiredObject(value, context: "CLI help presentation")
        try requireExactKeys(
            object,
            required: ["commandPath", "examples", "groupID", "summary"],
            optional: ["selectorOption"],
            context: "CLI help presentation"
        )
        let commandPath = try string(object, "commandPath")
        let examples = try strings(object, "examples")
        let summary = try string(object, "summary")
        try requireBoundedASCII(commandPath, maximumBytes: 128, context: "commandPath")
        try requireBoundedASCII(summary, maximumBytes: 256, context: "help summary")
        guard !commandPath.split(separator: " ").isEmpty,
              !commandPath.split(separator: " ").contains(where: { $0.hasPrefix("--") }),
              examples.count <= 8,
              Set(examples).count == examples.count
        else {
            throw CommandCatalogError.invalidValue("CLI help presentation")
        }
        for example in examples {
            try requireBoundedASCII(example, maximumBytes: 256, context: "help example")
        }
        return CLIHelpPresentation(
            commandPath: commandPath,
            examples: examples,
            groupID: try identifier(object, "groupID"),
            selectorOption: try object["selectorOption"].map(parseCLIOption),
            summary: summary
        )
    }

    private static func parsePolicyBindings(
        _ value: RepositoryJSONValue,
        context: String
    ) throws -> CommandPolicyBindings {
        let object = try requiredObject(value, context: "policyBindings: \(context)")
        try requireExactKeys(
            object,
            required: [
                "allowedErrorCodes", "candidateOrderIDs", "cleanupPolicyID",
                "compatibilityRuleID", "deadlinePolicyID", "fallbackPolicyID",
                "ownerDisconnectPolicyID", "preparationGroupIDs",
                "queuePolicyID", "redactionPolicyID",
                "resourceClaimTemplateID", "runtimeActivationPolicyID",
            ],
            context: "policyBindings: \(context)"
        )
        let errors = try strings(object, "allowedErrorCodes")
        let candidates = try strings(object, "candidateOrderIDs")
        let groups = try strings(object, "preparationGroupIDs")
        try requireSortedUnique(errors, context: "allowedErrorCodes: \(context)")
        try requireUnique(candidates, context: "candidateOrderIDs: \(context)")
        try requireUnique(groups, context: "preparationGroupIDs: \(context)")
        return CommandPolicyBindings(
            allowedErrorCodes: errors,
            candidateOrderIDs: candidates,
            cleanupPolicyID: try identifier(object, "cleanupPolicyID"),
            compatibilityRuleID: try identifier(object, "compatibilityRuleID"),
            deadlinePolicyID: try identifier(object, "deadlinePolicyID"),
            fallbackPolicyID: try identifier(object, "fallbackPolicyID"),
            ownerDisconnectPolicyID: try identifier(object, "ownerDisconnectPolicyID"),
            preparationGroupIDs: groups,
            queuePolicyID: try identifier(object, "queuePolicyID"),
            redactionPolicyID: try identifier(object, "redactionPolicyID"),
            resourceClaimTemplateID: try identifier(object, "resourceClaimTemplateID"),
            runtimeActivationPolicyID: try identifier(object, "runtimeActivationPolicyID")
        )
    }

    private static func validateResultSchemas(
        repositoryRoot: URL,
        references: [(String, String)]
    ) throws {
        let pairs = Dictionary(grouping: references, by: { $0.0 })
        for (reference, values) in pairs {
            let ids = Set(values.map { $0.1 })
            guard ids.count == 1 else {
                throw CommandCatalogError.invalidValue("schema ID mismatch: \(reference)")
            }
            let schema = try loadCanonicalObject(
                repositoryRoot.appendingPathComponent(reference),
                relativePath: reference
            )
            guard ids == Set(["retained"])
                    || schema["$id"]?.stringValue == ids.first
            else {
                throw CommandCatalogError.invalidValue("schema $id: \(reference)")
            }
        }
        let directoryURL = repositoryRoot.appendingPathComponent(resultSchemaDirectory)
        let actual = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: []
        ).map { url -> String in
            let relative = "\(resultSchemaDirectory)/\(url.lastPathComponent)"
            _ = try loadCanonicalObject(url, relativePath: relative)
            return relative
        }
        let expected = Array(pairs.keys).sorted(by: asciiLessThan)
        guard actual.sorted(by: asciiLessThan) == expected else {
            throw CommandCatalogError.resultSchemaCoverage
        }
    }

    private static func resultSchemaRef(_ object: RepositoryJSONObject) throws -> String {
        let value = try string(object, "resultSchemaRef")
        guard value.hasPrefix("\(resultSchemaDirectory)/"),
              value.hasSuffix(".schema.json"),
              !value.contains("#"),
              !value.contains(".."),
              value.utf8.count <= 4096
        else {
            throw CommandCatalogError.invalidValue("resultSchemaRef")
        }
        return value
    }

    private static func loadCanonicalObject(
        _ url: URL,
        relativePath: String
    ) throws -> RepositoryJSONObject {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw CommandCatalogError.missing(relativePath)
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_nlink == 1
        else {
            throw CommandCatalogError.unsafeNode(relativePath)
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](data),
            maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
        ).root
    }

    private static func requireExactKeys(
        _ object: RepositoryJSONObject,
        required: Set<String>,
        optional: Set<String> = [],
        context: String
    ) throws {
        let actual = Set(object.members.map(\.key))
        guard required.isSubset(of: actual), actual.isSubset(of: required.union(optional)) else {
            throw CommandCatalogError.invalidField(context)
        }
    }

    private static func requiredObject(
        _ value: RepositoryJSONValue,
        context: String
    ) throws -> RepositoryJSONObject {
        guard let object = value.objectValue else {
            throw CommandCatalogError.invalidField(context)
        }
        return object
    }

    private static func string(_ object: RepositoryJSONObject, _ key: String) throws -> String {
        guard let value = object[key]?.stringValue else {
            throw CommandCatalogError.invalidField(key)
        }
        return value
    }

    private static func identifier(
        _ object: RepositoryJSONObject,
        _ key: String
    ) throws -> String {
        let value = try string(object, key)
        try requireBoundedASCII(value, maximumBytes: 256, context: key)
        guard !value.contains("/"), !value.contains("\\"), !value.contains("://") else {
            throw CommandCatalogError.invalidValue(key)
        }
        return value
    }

    private static func array(
        _ object: RepositoryJSONObject,
        _ key: String
    ) throws -> [RepositoryJSONValue] {
        guard let value = object[key]?.arrayValue else {
            throw CommandCatalogError.invalidField(key)
        }
        return value
    }

    private static func strings(
        _ object: RepositoryJSONObject,
        _ key: String
    ) throws -> [String] {
        try array(object, key).map { value in
            guard let string = value.stringValue else {
                throw CommandCatalogError.invalidField(key)
            }
            try requireBoundedASCII(string, maximumBytes: 256, context: key)
            return string
        }
    }

    private static func uint64(
        _ object: RepositoryJSONObject,
        _ key: String
    ) throws -> UInt64 {
        guard let number = object[key]?.numberValue else {
            throw CommandCatalogError.invalidField(key)
        }
        return try number.requireUInt64()
    }

    private static func requireBoundedASCII(
        _ value: String,
        maximumBytes: Int,
        context: String
    ) throws {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty,
              bytes.count <= maximumBytes,
              bytes.allSatisfy({ (0x20...0x7e).contains($0) })
        else {
            throw CommandCatalogError.invalidValue(context)
        }
    }

    private static func requireSortedUnique(
        _ values: [String],
        context: String
    ) throws {
        try requireUnique(values, context: context)
        guard values == values.sorted(by: asciiLessThan) else {
            throw CommandCatalogError.unsorted(context)
        }
    }

    private static func requireUnique(
        _ values: [String],
        context: String
    ) throws {
        guard Set(values).count == values.count else {
            throw CommandCatalogError.duplicateID(context)
        }
    }
}
