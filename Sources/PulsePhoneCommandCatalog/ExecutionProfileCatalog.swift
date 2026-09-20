import Darwin
import Foundation
import PulsePhoneSharedDefinitions

public enum ExecutionProfileCatalog {
  public static let preparationRegistryRelativePath =
    "Registries/preparation-groups.v1.json"
  public static let preparationSchemaRelativePath =
    "Schemas/developer-support/preparation-group.v1.schema.json"
  public static let standardErrorRegistryRelativePath =
    "Registries/standard-errors.v1.json"

  public static func load(repositoryRoot: URL) throws -> ExecutionProfileCatalogV1 {
    let commandCatalog = try CommandCatalog.load(repositoryRoot: repositoryRoot)
    let root = try loadCanonicalObject(
      repositoryRoot.appendingPathComponent(CommandCatalog.registryRelativePath),
      relativePath: CommandCatalog.registryRelativePath
    )
    try requireExactKeys(
      root,
      required: [
        "cliArgumentDefinitions", "cliGlobalOptions", "cliHelpGroups",
        "compatibilityRules", "executionProfiles", "features", "loggingProfiles",
        "matrixRevision", "productActions", "resourceClaimTemplates",
        "retainedResultSchemaRefs", "schemaVersion", "supportingActions",
      ],
      context: "expanded command catalog"
    )

    let executionProfiles = try array(root, "executionProfiles").map(parseExecutionProfile)
    let loggingProfiles = try array(root, "loggingProfiles").map(parseLoggingProfile)
    let compatibilityRules = try array(root, "compatibilityRules").map(
      parseCompatibilityRule
    )
    let resourceClaimTemplates = try array(root, "resourceClaimTemplates").map(
      parseResourceClaimTemplate
    )
    try requireSortedUnique(
      executionProfiles.map(\.executionProfileID),
      context: "executionProfiles"
    )
    try requireSortedUnique(
      loggingProfiles.map(\.loggingProfileID),
      context: "loggingProfiles"
    )
    try requireSortedUnique(
      compatibilityRules.map(\.ruleID),
      context: "compatibilityRules"
    )
    try requireSortedUnique(
      resourceClaimTemplates.map(\.resourceClaimTemplateID),
      context: "resourceClaimTemplates"
    )
    guard executionProfiles.count == 7,
      loggingProfiles.count == 5,
      (1...128).contains(compatibilityRules.count),
      (1...64).contains(resourceClaimTemplates.count)
    else {
      throw CommandCatalogError.invalidValue("profile definition counts")
    }

    let preparationGroups = try loadPreparationGroups(repositoryRoot: repositoryRoot)
    let allowedErrorCodes = try loadStandardErrorCodes(repositoryRoot: repositoryRoot)
    let profilesByID = Dictionary(
      uniqueKeysWithValues: executionProfiles.map { ($0.executionProfileID, $0) }
    )
    let loggingByID = Dictionary(
      uniqueKeysWithValues: loggingProfiles.map { ($0.loggingProfileID, $0) }
    )
    let rulesByID = Dictionary(
      uniqueKeysWithValues: compatibilityRules.map { ($0.ruleID, $0) }
    )
    let claimsByID = Dictionary(
      uniqueKeysWithValues: resourceClaimTemplates.map {
        ($0.resourceClaimTemplateID, $0)
      }
    )
    let groupsByID = Dictionary(
      uniqueKeysWithValues: preparationGroups.map { ($0.preparationGroupID, $0) }
    )

    try validatePreparationReferences(
      preparationGroups,
      rulesByID: rulesByID,
      claimsByID: claimsByID
    )
    let expandedProducts = try commandCatalog.productActions.map { command in
      guard let bindings = command.policyBindings,
        let profile = profilesByID[command.executionProfileID],
        let logging = loggingByID[command.loggingProfileID],
        let rule = rulesByID[bindings.compatibilityRuleID],
        let claimTemplate = claimsByID[bindings.resourceClaimTemplateID]
      else {
        throw CommandCatalogError.invalidValue("product expansion: \(command.commandID)")
      }
      try validatePolicyBindings(
        bindings,
        context: command.commandID,
        allowedErrorCodes: allowedErrorCodes,
        groupsByID: groupsByID
      )
      guard profile.executionShape == command.category else {
        throw CommandCatalogError.invalidValue("profile shape: \(command.commandID)")
      }
      return ExpandedProductCommandDescriptor(
        command: command,
        compatibilityRule: rule,
        executionProfile: profile,
        loggingProfile: logging,
        policyBindings: bindings,
        preparationGroups: bindings.preparationGroupIDs.map { groupsByID[$0]! },
        resourceClaimTemplate: claimTemplate
      )
    }
    let expandedSupporting = try commandCatalog.supportingActions.map { action in
      guard let bindings = action.policyBindings,
        let rule = rulesByID[bindings.compatibilityRuleID],
        let claimTemplate = claimsByID[bindings.resourceClaimTemplateID]
      else {
        throw CommandCatalogError.invalidValue(
          "supporting expansion: \(action.supportingActionID)"
        )
      }
      try validatePolicyBindings(
        bindings,
        context: action.supportingActionID,
        allowedErrorCodes: allowedErrorCodes,
        groupsByID: groupsByID
      )
      return ExpandedSupportingActionDescriptor(
        action: action,
        compatibilityRule: rule,
        policyBindings: bindings,
        preparationGroups: bindings.preparationGroupIDs.map { groupsByID[$0]! },
        resourceClaimTemplate: claimTemplate
      )
    }
    let referencedRuleIDs = Set(
      expandedProducts.map { $0.policyBindings.compatibilityRuleID }
        + expandedSupporting.map { $0.policyBindings.compatibilityRuleID }
        + preparationGroups.map(\.compatibilityRuleID)
    )
    let referencedClaimTemplateIDs = Set(
      expandedProducts.map { $0.policyBindings.resourceClaimTemplateID }
        + expandedSupporting.map { $0.policyBindings.resourceClaimTemplateID }
        + preparationGroups.flatMap { group in
          group.phaseClaimBindings.map(\.resourceClaimTemplateID)
        }
    )
    let referencedGroupIDs = Set(
      expandedProducts.flatMap { $0.policyBindings.preparationGroupIDs }
        + expandedSupporting.flatMap { $0.policyBindings.preparationGroupIDs }
    )
    guard referencedRuleIDs == Set(rulesByID.keys),
      referencedClaimTemplateIDs == Set(claimsByID.keys),
      referencedGroupIDs == Set(groupsByID.keys),
      Set(commandCatalog.productActions.map(\.executionProfileID)) == Set(profilesByID.keys),
      Set(commandCatalog.productActions.map(\.loggingProfileID)) == Set(loggingByID.keys)
    else {
      throw CommandCatalogError.invalidValue("expanded definition coverage")
    }

    return ExecutionProfileCatalogV1(
      commandCatalog: commandCatalog,
      compatibilityRules: compatibilityRules,
      executionProfiles: executionProfiles,
      expandedProductActions: expandedProducts,
      expandedSupportingActions: expandedSupporting,
      loggingProfiles: loggingProfiles,
      preparationGroups: preparationGroups,
      resourceClaimTemplates: resourceClaimTemplates
    )
  }

  private static func parseExecutionProfile(
    _ value: RepositoryJSONValue
  ) throws -> ExecutionProfileDescriptor {
    let object = try requiredObject(value, context: "execution profile")
    try requireExactKeys(
      object,
      required: [
        "acceptedWorkPolicy", "automaticRetryPolicy", "executionProfileID",
        "executionShape", "planningAuthority", "preparationWaitPolicy",
        "resultOwner", "schedulerPolicy",
      ],
      context: "execution profile"
    )
    let profileID = try identifier(object, "executionProfileID")
    guard let accepted = AcceptedWorkPolicy(rawValue: try string(object, "acceptedWorkPolicy")),
      let retry = AutomaticRetryPolicy(
        rawValue: try string(object, "automaticRetryPolicy")
      ),
      let shape = CommandCategory(rawValue: try string(object, "executionShape")),
      let authority = PlanningAuthority(rawValue: try string(object, "planningAuthority")),
      let wait = PreparationWaitPolicy(
        rawValue: try string(object, "preparationWaitPolicy")
      ),
      let resultOwner = PlanningAuthority(rawValue: try string(object, "resultOwner")),
      let scheduler = SchedulerPolicy(rawValue: try string(object, "schedulerPolicy"))
    else {
      throw CommandCatalogError.invalidValue("execution profile: \(profileID)")
    }
    return ExecutionProfileDescriptor(
      acceptedWorkPolicy: accepted,
      automaticRetryPolicy: retry,
      executionProfileID: profileID,
      executionShape: shape,
      planningAuthority: authority,
      preparationWaitPolicy: wait,
      resultOwner: resultOwner,
      schedulerPolicy: scheduler
    )
  }

  private static func parseLoggingProfile(
    _ value: RepositoryJSONValue
  ) throws -> LoggingProfileDescriptor {
    let object = try requiredObject(value, context: "logging profile")
    try requireExactKeys(
      object,
      required: [
        "actionLogPolicy", "loggingProfileID", "redactionPolicyID",
        "replayTracePolicy",
      ],
      context: "logging profile"
    )
    let profileID = try identifier(object, "loggingProfileID")
    guard let actionLog = ActionLogPolicy(rawValue: try string(object, "actionLogPolicy")),
      let replay = ReplayTracePolicy(rawValue: try string(object, "replayTracePolicy"))
    else {
      throw CommandCatalogError.invalidValue("logging profile: \(profileID)")
    }
    return LoggingProfileDescriptor(
      actionLogPolicy: actionLog,
      loggingProfileID: profileID,
      redactionPolicyID: try identifier(object, "redactionPolicyID"),
      replayTracePolicy: replay
    )
  }

  private static func parseCompatibilityRule(
    _ value: RepositoryJSONValue
  ) throws -> CompatibilityRuleDescriptor {
    let object = try requiredObject(value, context: "compatibility rule")
    try requireExactKeys(
      object,
      required: ["parameters", "ruleID", "ruleVersion"],
      context: "compatibility rule"
    )
    let ruleID = try identifier(object, "ruleID")
    let parametersObject = try requiredObject(
      object["parameters"],
      context: "compatibility parameters: \(ruleID)"
    )
    guard parametersObject.members.count <= 32 else {
      throw CommandCatalogError.invalidValue("compatibility parameters: \(ruleID)")
    }
    var parameters: [String: CompatibilityParameterValue] = [:]
    for member in parametersObject.members {
      try requireBoundedASCII(
        member.key,
        maximumBytes: 256,
        context: "compatibility parameter key"
      )
      parameters[member.key] = try parseCompatibilityParameter(
        member.value,
        context: "\(ruleID).\(member.key)"
      )
    }
    return CompatibilityRuleDescriptor(
      parameters: parameters,
      ruleID: ruleID,
      ruleVersion: try uint64(object, "ruleVersion")
    )
  }

  private static func parseCompatibilityParameter(
    _ value: RepositoryJSONValue,
    context: String
  ) throws -> CompatibilityParameterValue {
    switch value {
    case .bool(let value):
      return .bool(value)
    case .number(let number):
      return .uint64(try number.requireUInt64())
    case .string(let value):
      try requireBoundedASCII(value, maximumBytes: 256, context: context)
      return .string(value)
    case .array(let values):
      guard values.count <= 64 else {
        throw CommandCatalogError.invalidValue(context)
      }
      let strings = try values.map { value in
        guard let string = value.stringValue else {
          throw CommandCatalogError.invalidField(context)
        }
        try requireBoundedASCII(string, maximumBytes: 256, context: context)
        return string
      }
      try requireSortedUnique(strings, context: context)
      return .strings(strings)
    default:
      throw CommandCatalogError.invalidField(context)
    }
  }

  private static func parseResourceClaimTemplate(
    _ value: RepositoryJSONValue
  ) throws -> ResourceClaimTemplateDescriptor {
    let object = try requiredObject(value, context: "resource claim template")
    try requireExactKeys(
      object,
      required: ["claims", "resourceClaimTemplateID"],
      context: "resource claim template"
    )
    let templateID = try identifier(object, "resourceClaimTemplateID")
    let claimValues = try array(object, "claims")
    guard claimValues.count <= 32 else {
      throw CommandCatalogError.invalidValue("resource claims: \(templateID)")
    }
    let claims = try claimValues.map { value in
      let claim = try requiredObject(value, context: "resource claim: \(templateID)")
      try requireExactKeys(
        claim,
        required: ["accessMode", "phase", "resourceIDTemplate"],
        context: "resource claim: \(templateID)"
      )
      guard let access = ResourceAccessMode(rawValue: try string(claim, "accessMode")),
        let phase = ResourceClaimPhase(rawValue: try string(claim, "phase"))
      else {
        throw CommandCatalogError.invalidValue("resource claim: \(templateID)")
      }
      return ResourceClaimDescriptor(
        accessMode: access,
        phase: phase,
        resourceIDTemplate: try identifier(claim, "resourceIDTemplate")
      )
    }
    let keys = claims.map {
      "\($0.phase.rawValue)|\($0.accessMode.rawValue)|\($0.resourceIDTemplate)"
    }
    try requireSortedUnique(keys, context: "resource claims: \(templateID)")
    return ResourceClaimTemplateDescriptor(
      claims: claims,
      resourceClaimTemplateID: templateID
    )
  }

  private static func loadPreparationGroups(
    repositoryRoot: URL
  ) throws -> [PreparationGroupDescriptor] {
    _ = try loadCanonicalObject(
      repositoryRoot.appendingPathComponent(preparationSchemaRelativePath),
      relativePath: preparationSchemaRelativePath
    )
    let root = try loadCanonicalObject(
      repositoryRoot.appendingPathComponent(preparationRegistryRelativePath),
      relativePath: preparationRegistryRelativePath
    )
    try requireExactKeys(
      root,
      required: ["matrixRevision", "preparationGroups", "schemaVersion"],
      context: "preparation group registry"
    )
    guard try uint64(root, "schemaVersion") == 1,
      try string(root, "matrixRevision") == CommandCatalog.matrixRevision
    else {
      throw CommandCatalogError.invalidValue("preparation group registry identity")
    }
    let groups = try array(root, "preparationGroups").map(parsePreparationGroup)
    try requireSortedUnique(groups.map(\.preparationGroupID), context: "preparationGroups")
    guard
      Set(groups.map(\.preparationGroupID)) == [
        "prep.coredevice.v2", "prep.direct.lockdown.v1", "prep.legacy.developer.v2",
      ]
    else {
      throw CommandCatalogError.invalidValue("preparation group identity")
    }
    let defaults = groups.flatMap { group in
      group.targetDefaultOSProfileIDs.map { ($0, group.preparationGroupID) }
    }
    guard defaults.count == 2,
      Set(defaults.map(\.0)).count == defaults.count
    else {
      throw CommandCatalogError.invalidValue("preparation group defaults")
    }
    let defaultsByProfile = Dictionary(uniqueKeysWithValues: defaults)
    guard defaultsByProfile[.legacyClassic] == "prep.legacy.developer.v2",
      defaultsByProfile[.modernRSD] == "prep.coredevice.v2"
    else {
      throw CommandCatalogError.invalidValue("preparation group defaults")
    }
    return groups
  }

  private static func parsePreparationGroup(
    _ value: RepositoryJSONValue
  ) throws -> PreparationGroupDescriptor {
    let object = try requiredObject(value, context: "preparation group")
    try requireExactKeys(
      object,
      required: [
        "compatibilityRuleID", "optionalCapabilityIDs", "phaseClaimBindings",
        "preparationGroupID", "releaseScope", "requiredCapabilityIDs", "route",
        "targetDefaultOSProfileIDs",
      ],
      context: "preparation group"
    )
    let groupID = try identifier(object, "preparationGroupID")
    let capabilities = try strings(object, "requiredCapabilityIDs")
    let optionalCapabilities = try strings(object, "optionalCapabilityIDs")
    guard (1...16).contains(capabilities.count) else {
      throw CommandCatalogError.invalidValue("required capabilities: \(groupID)")
    }
    try requireSortedUnique(capabilities, context: "required capabilities: \(groupID)")
    try requireSortedUnique(
      optionalCapabilities,
      context: "optional capabilities: \(groupID)"
    )
    guard Set(capabilities).isDisjoint(with: optionalCapabilities) else {
      throw CommandCatalogError.invalidValue("overlapping capabilities: \(groupID)")
    }
    let profileStrings = try strings(object, "targetDefaultOSProfileIDs")
    guard profileStrings.count <= 2 else {
      throw CommandCatalogError.invalidValue("target profiles: \(groupID)")
    }
    try requireSortedUnique(profileStrings, context: "target profiles: \(groupID)")
    let targetProfiles = try profileStrings.map { profile in
      guard let value = TargetOSProfileID(rawValue: profile) else {
        throw CommandCatalogError.invalidValue("target profile: \(groupID)")
      }
      return value
    }
    let phaseBindingValues = try array(object, "phaseClaimBindings")
    guard phaseBindingValues.count <= 3 else {
      throw CommandCatalogError.invalidValue("phase claims: \(groupID)")
    }
    let phaseBindings = try phaseBindingValues.map { value in
      let binding = try requiredObject(value, context: "phase claim: \(groupID)")
      try requireExactKeys(
        binding,
        required: ["phaseID", "resourceClaimTemplateID"],
        context: "phase claim: \(groupID)"
      )
      guard let phaseID = PreparationPhaseID(rawValue: try string(binding, "phaseID")) else {
        throw CommandCatalogError.invalidValue("phase claim: \(groupID)")
      }
      return PreparationPhaseClaimBinding(
        phaseID: phaseID,
        resourceClaimTemplateID: try identifier(binding, "resourceClaimTemplateID")
      )
    }
    try requireSortedUnique(
      phaseBindings.map(\.phaseID.rawValue),
      context: "phase claims: \(groupID)"
    )
    guard let releaseScope = ReleaseScope(rawValue: try string(object, "releaseScope")),
      let route = PreparationRoute(rawValue: try string(object, "route"))
    else {
      throw CommandCatalogError.invalidValue("preparation group: \(groupID)")
    }
    return PreparationGroupDescriptor(
      compatibilityRuleID: try identifier(object, "compatibilityRuleID"),
      phaseClaimBindings: phaseBindings,
      preparationGroupID: groupID,
      optionalCapabilityIDs: optionalCapabilities,
      releaseScope: releaseScope,
      requiredCapabilityIDs: capabilities,
      route: route,
      targetDefaultOSProfileIDs: targetProfiles
    )
  }

  private static func validatePreparationReferences(
    _ groups: [PreparationGroupDescriptor],
    rulesByID: [String: CompatibilityRuleDescriptor],
    claimsByID: [String: ResourceClaimTemplateDescriptor]
  ) throws {
    for group in groups {
      guard rulesByID[group.compatibilityRuleID] != nil else {
        throw CommandCatalogError.invalidValue(
          "preparation compatibility: \(group.preparationGroupID)"
        )
      }
      for binding in group.phaseClaimBindings {
        guard claimsByID[binding.resourceClaimTemplateID] != nil else {
          throw CommandCatalogError.invalidValue(
            "preparation claims: \(group.preparationGroupID)"
          )
        }
      }
    }
  }

  private static func validatePolicyBindings(
    _ bindings: CommandPolicyBindings,
    context: String,
    allowedErrorCodes: Set<String>,
    groupsByID: [String: PreparationGroupDescriptor]
  ) throws {
    guard Set(bindings.allowedErrorCodes).isSubset(of: allowedErrorCodes),
      bindings.preparationGroupIDs.allSatisfy({ groupsByID[$0] != nil })
    else {
      throw CommandCatalogError.invalidValue("policy references: \(context)")
    }
  }

  private static func loadStandardErrorCodes(repositoryRoot: URL) throws -> Set<String> {
    let root = try loadCanonicalObject(
      repositoryRoot.appendingPathComponent(standardErrorRegistryRelativePath),
      relativePath: standardErrorRegistryRelativePath
    )
    let codes = try array(root, "entries").map { value in
      let entry = try requiredObject(value, context: "standard error entry")
      return try identifier(entry, "code")
    }
    try requireSortedUnique(codes, context: "standard error codes")
    return Set(codes)
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
    context: String
  ) throws {
    guard Set(object.members.map(\.key)) == required else {
      throw CommandCatalogError.invalidField(context)
    }
  }

  private static func requiredObject(
    _ value: RepositoryJSONValue?,
    context: String
  ) throws -> RepositoryJSONObject {
    guard let object = value?.objectValue else {
      throw CommandCatalogError.invalidField(context)
    }
    return object
  }

  private static func requiredObject(
    _ value: RepositoryJSONValue,
    context: String
  ) throws -> RepositoryJSONObject {
    try requiredObject(Optional(value), context: context)
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
    guard let values = object[key]?.arrayValue else {
      throw CommandCatalogError.invalidField(key)
    }
    return values
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
    guard Set(values).count == values.count else {
      throw CommandCatalogError.duplicateID(context)
    }
    guard values == values.sorted(by: CommandCatalog.asciiLessThan) else {
      throw CommandCatalogError.unsorted(context)
    }
  }
}
