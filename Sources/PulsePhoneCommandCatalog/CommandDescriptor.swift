public enum CommandCategory: String, Sendable {
    case local
    case control
    case oneShot
    case stream
    case hybrid
}

public enum CatalogExposure: String, Sendable {
    case cli
    case gui
}

public enum ReleaseScope: String, Sendable {
    case productGate
    case capability
}

public enum GUISurfaceKind: String, Sendable {
    case toolbar
    case window
    case ownerBoundInteraction
}

public enum SupportingActionShape: String, Sendable {
    case local
    case control
    case preparationControl
    case oneShot
    case bootstrapControl
    case oneWayControl
}

public struct GUISurfaceDescriptor: Equatable, Sendable {
    public let kind: GUISurfaceKind
    public let order: UInt64?

    public init(kind: GUISurfaceKind, order: UInt64?) {
        self.kind = kind
        self.order = order
    }
}

public struct CLIHelpGroupDescriptor: Equatable, Sendable {
    public let groupID: String
    public let order: UInt64
    public let title: String

    public init(groupID: String, order: UInt64, title: String) {
        self.groupID = groupID
        self.order = order
        self.title = title
    }
}

public struct CLIOptionDefinition: Equatable, Sendable {
    public let constraint: String?
    public let required: Bool
    public let repeatable: Bool
    public let spelling: String
    public let summary: String
    public let valueName: String?

    public init(
        constraint: String?,
        required: Bool,
        repeatable: Bool,
        spelling: String,
        summary: String,
        valueName: String?
    ) {
        self.constraint = constraint
        self.required = required
        self.repeatable = repeatable
        self.spelling = spelling
        self.summary = summary
        self.valueName = valueName
    }
}

public struct CLIArgumentDefinition: Equatable, Sendable {
    public let argumentSchemaID: String
    public let options: [CLIOptionDefinition]

    public init(
        argumentSchemaID: String,
        options: [CLIOptionDefinition]
    ) {
        self.argumentSchemaID = argumentSchemaID
        self.options = options
    }
}

public struct CLIHelpPresentation: Equatable, Sendable {
    public let commandPath: String
    public let examples: [String]
    public let groupID: String
    public let selectorOption: CLIOptionDefinition?
    public let summary: String

    public init(
        commandPath: String,
        examples: [String],
        groupID: String,
        selectorOption: CLIOptionDefinition?,
        summary: String
    ) {
        self.commandPath = commandPath
        self.examples = examples
        self.groupID = groupID
        self.selectorOption = selectorOption
        self.summary = summary
    }
}

public struct CommandPolicyBindings: Equatable, Sendable {
    public let allowedErrorCodes: [String]
    public let candidateOrderIDs: [String]
    public let cleanupPolicyID: String
    public let compatibilityRuleID: String
    public let deadlinePolicyID: String
    public let fallbackPolicyID: String
    public let ownerDisconnectPolicyID: String
    public let preparationGroupIDs: [String]
    public let queuePolicyID: String
    public let redactionPolicyID: String
    public let resourceClaimTemplateID: String
    public let runtimeActivationPolicyID: String

    public init(
        allowedErrorCodes: [String],
        candidateOrderIDs: [String],
        cleanupPolicyID: String,
        compatibilityRuleID: String,
        deadlinePolicyID: String,
        fallbackPolicyID: String,
        ownerDisconnectPolicyID: String,
        preparationGroupIDs: [String],
        queuePolicyID: String,
        redactionPolicyID: String,
        resourceClaimTemplateID: String,
        runtimeActivationPolicyID: String
    ) {
        self.allowedErrorCodes = allowedErrorCodes
        self.candidateOrderIDs = candidateOrderIDs
        self.cleanupPolicyID = cleanupPolicyID
        self.compatibilityRuleID = compatibilityRuleID
        self.deadlinePolicyID = deadlinePolicyID
        self.fallbackPolicyID = fallbackPolicyID
        self.ownerDisconnectPolicyID = ownerDisconnectPolicyID
        self.preparationGroupIDs = preparationGroupIDs
        self.queuePolicyID = queuePolicyID
        self.redactionPolicyID = redactionPolicyID
        self.resourceClaimTemplateID = resourceClaimTemplateID
        self.runtimeActivationPolicyID = runtimeActivationPolicyID
    }
}

public struct ProductCommandDescriptor: Equatable, Sendable {
    public let argumentSchemaID: String
    public let category: CommandCategory
    public let cliVariant: String?
    public let commandID: String
    public let executionProfileID: String
    public let exposures: [CatalogExposure]
    public let guiSurface: GUISurfaceDescriptor?
    public let help: CLIHelpPresentation?
    public let loggingProfileID: String
    public let policyBindings: CommandPolicyBindings?
    public let releaseScope: ReleaseScope
    public let resultSchemaID: String
    public let resultSchemaRef: String

    public init(
        argumentSchemaID: String,
        category: CommandCategory,
        cliVariant: String?,
        commandID: String,
        executionProfileID: String,
        exposures: [CatalogExposure],
        guiSurface: GUISurfaceDescriptor?,
        help: CLIHelpPresentation?,
        loggingProfileID: String,
        policyBindings: CommandPolicyBindings?,
        releaseScope: ReleaseScope,
        resultSchemaID: String,
        resultSchemaRef: String
    ) {
        self.argumentSchemaID = argumentSchemaID
        self.category = category
        self.cliVariant = cliVariant
        self.commandID = commandID
        self.executionProfileID = executionProfileID
        self.exposures = exposures
        self.guiSurface = guiSurface
        self.help = help
        self.loggingProfileID = loggingProfileID
        self.policyBindings = policyBindings
        self.releaseScope = releaseScope
        self.resultSchemaID = resultSchemaID
        self.resultSchemaRef = resultSchemaRef
    }
}

public struct SupportingActionDescriptor: Equatable, Sendable {
    public let callerIDs: [String]
    public let parentCommandIDs: [String]
    public let policyBindings: CommandPolicyBindings?
    public let releaseInheritance: ReleaseScope
    public let resultSchemaID: String
    public let resultSchemaRef: String
    public let shape: SupportingActionShape
    public let supportingActionID: String

    public init(
        callerIDs: [String],
        parentCommandIDs: [String],
        policyBindings: CommandPolicyBindings?,
        releaseInheritance: ReleaseScope,
        resultSchemaID: String,
        resultSchemaRef: String,
        shape: SupportingActionShape,
        supportingActionID: String
    ) {
        self.callerIDs = callerIDs
        self.parentCommandIDs = parentCommandIDs
        self.policyBindings = policyBindings
        self.releaseInheritance = releaseInheritance
        self.resultSchemaID = resultSchemaID
        self.resultSchemaRef = resultSchemaRef
        self.shape = shape
        self.supportingActionID = supportingActionID
    }
}

public struct NonCommandFeatureDescriptor: Equatable, Sendable {
    public let exposures: [CatalogExposure]
    public let featureID: String
    public let releaseScope: ReleaseScope

    public init(
        exposures: [CatalogExposure],
        featureID: String,
        releaseScope: ReleaseScope
    ) {
        self.exposures = exposures
        self.featureID = featureID
        self.releaseScope = releaseScope
    }
}

public struct CommandCatalogV1: Equatable, Sendable {
    public let cliArgumentDefinitions: [CLIArgumentDefinition]
    public let cliGlobalOptions: [CLIOptionDefinition]
    public let cliHelpGroups: [CLIHelpGroupDescriptor]
    public let schemaVersion: UInt64
    public let matrixRevision: String
    public let productActions: [ProductCommandDescriptor]
    public let retainedResultSchemaRefs: [String]
    public let supportingActions: [SupportingActionDescriptor]
    public let features: [NonCommandFeatureDescriptor]

    public init(
        cliArgumentDefinitions: [CLIArgumentDefinition],
        cliGlobalOptions: [CLIOptionDefinition],
        cliHelpGroups: [CLIHelpGroupDescriptor],
        matrixRevision: String,
        productActions: [ProductCommandDescriptor],
        retainedResultSchemaRefs: [String],
        supportingActions: [SupportingActionDescriptor],
        features: [NonCommandFeatureDescriptor]
    ) {
        self.schemaVersion = 1
        self.cliArgumentDefinitions = cliArgumentDefinitions
        self.cliGlobalOptions = cliGlobalOptions
        self.cliHelpGroups = cliHelpGroups
        self.matrixRevision = matrixRevision
        self.productActions = productActions
        self.retainedResultSchemaRefs = retainedResultSchemaRefs
        self.supportingActions = supportingActions
        self.features = features
    }
}
