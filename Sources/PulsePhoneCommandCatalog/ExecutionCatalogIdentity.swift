import Darwin
import Foundation
import PulsePhoneSharedDefinitions

public enum ExecutionCatalogIdentityError: Error, Equatable, Sendable {
  case duplicatePlannerRule(String)
  case invalidContract(String)
  case invalidPlannerContractVersion
  case missingContract(String)
  case unsafeContract(String)
}

public enum PlannerRuleParameterValue: Equatable, Sendable {
  case bool(Bool)
  case string(String)
  case stringSet([String])
  case uint64(UInt64)
}

public struct PlannerRuleIdentity: Equatable, Sendable {
  public let parameters: [String: PlannerRuleParameterValue]
  public let ruleID: String
  public let ruleVersion: UInt64

  public init(
    parameters: [String: PlannerRuleParameterValue],
    ruleID: String,
    ruleVersion: UInt64
  ) {
    self.parameters = parameters
    self.ruleID = ruleID
    self.ruleVersion = ruleVersion
  }
}

public struct PlannerContractIdentity: Equatable, Sendable {
  public let plannerContractVersion: String
  public let rules: [PlannerRuleIdentity]

  public init(plannerContractVersion: String, rules: [PlannerRuleIdentity]) {
    self.plannerContractVersion = plannerContractVersion
    self.rules = rules
  }
}

public struct ExecutionCatalogIdentity: Sendable {
  public static let domainID = "pulsephone.execution-catalog.v1"
  public static let runtimeWireSchemaRelativePath =
    "Schemas/wire/runtime-wire.v1.schema.json"
  public static let detailsSchemaDirectory = "Schemas/details-schemas"

  public let canonicalProjectionBytes: [UInt8]
  public let executionCatalogHash: String
  public let plannerContractVersion: String
  public let projectionSHA256: String

  public static func load(
    repositoryRoot: URL,
    plannerContract: PlannerContractIdentity
  ) throws -> ExecutionCatalogIdentity {
    try make(
      catalog: ExecutionProfileCatalog.load(repositoryRoot: repositoryRoot),
      repositoryRoot: repositoryRoot,
      plannerContract: plannerContract
    )
  }

  public static func make(
    catalog: ExecutionProfileCatalogV1,
    repositoryRoot: URL,
    plannerContract: PlannerContractIdentity
  ) throws -> ExecutionCatalogIdentity {
    try validate(plannerContract: plannerContract)
    let projection = try object([
      ("plannerContract", plannerContractValue(plannerContract)),
      (
        "productActions",
        .array(
          try catalog.expandedProductActions
            .sorted { asciiLessThan($0.command.commandID, $1.command.commandID) }
            .map(productValue)
        )
      ),
      (
        "runtimeContracts",
        try runtimeContractsValue(repositoryRoot: repositoryRoot, catalog: catalog)
      ),
      ("schemaVersion", .number(.uint64(1))),
      (
        "supportingActions",
        .array(
          try catalog.expandedSupportingActions
            .sorted {
              asciiLessThan($0.action.supportingActionID, $1.action.supportingActionID)
            }
            .map(supportingValue)
        )
      ),
    ])
    let bytes = RepositoryCanonicalJSON.encodeDocument(projection)
    return ExecutionCatalogIdentity(
      canonicalProjectionBytes: bytes,
      executionCatalogHash: try StableBytes.domainSeparatedSHA256Hex(
        domainID: domainID,
        payload: bytes
      ),
      plannerContractVersion: plannerContract.plannerContractVersion,
      projectionSHA256: StableBytes.sha256Hex(bytes)
    )
  }

  private static func validate(plannerContract: PlannerContractIdentity) throws {
    let versionBytes = Array(plannerContract.plannerContractVersion.utf8)
    guard !versionBytes.isEmpty,
      versionBytes.count <= 256,
      versionBytes.allSatisfy({ (0x21...0x7e).contains($0) })
    else {
      throw ExecutionCatalogIdentityError.invalidPlannerContractVersion
    }
    var ruleIDs = Set<String>()
    for rule in plannerContract.rules {
      guard ruleIDs.insert(rule.ruleID).inserted else {
        throw ExecutionCatalogIdentityError.duplicatePlannerRule(rule.ruleID)
      }
    }
  }

  private static func productValue(
    _ row: ExpandedProductCommandDescriptor
  ) throws -> RepositoryJSONValue {
    try objectValue([
      (
        "argumentNormalizer",
        try objectValue([
          (
            "parameters",
            try objectValue([("schemaID", .string(row.command.argumentSchemaID))])
          ),
          ("ruleID", .string("argument-normalizer.\(row.command.argumentSchemaID)")),
          ("ruleVersion", .number(.uint64(1))),
        ])
      ),
      ("commandID", .string(row.command.commandID)),
      ("compatibilityRule", try compatibilityRuleValue(row.compatibilityRule)),
      ("executionProfile", try executionProfileValue(row.executionProfile)),
      ("executionShape", .string(row.command.category.rawValue)),
      ("loggingProfile", try loggingProfileValue(row.loggingProfile)),
      ("policyBindings", try policyBindingsValue(row.policyBindings)),
      (
        "preparationGroups",
        .array(try row.preparationGroups.map(preparationGroupValue))
      ),
      ("resourceClaimTemplate", try claimTemplateValue(row.resourceClaimTemplate)),
      ("resultSchemaID", .string(row.command.resultSchemaID)),
      ("resultSchemaRef", .string(row.command.resultSchemaRef)),
    ])
  }

  private static func supportingValue(
    _ row: ExpandedSupportingActionDescriptor
  ) throws -> RepositoryJSONValue {
    try objectValue([
      ("callerIDs", stringSetValue(row.action.callerIDs)),
      ("compatibilityRule", try compatibilityRuleValue(row.compatibilityRule)),
      ("parentCommandIDs", stringSetValue(row.action.parentCommandIDs)),
      ("policyBindings", try policyBindingsValue(row.policyBindings)),
      (
        "preparationGroups",
        .array(try row.preparationGroups.map(preparationGroupValue))
      ),
      ("resourceClaimTemplate", try claimTemplateValue(row.resourceClaimTemplate)),
      ("resultSchemaID", .string(row.action.resultSchemaID)),
      ("resultSchemaRef", .string(row.action.resultSchemaRef)),
      ("shape", .string(row.action.shape.rawValue)),
      ("supportingActionID", .string(row.action.supportingActionID)),
    ])
  }

  private static func compatibilityRuleValue(
    _ rule: CompatibilityRuleDescriptor
  ) throws -> RepositoryJSONValue {
    let parameters = rule.parameters.map { key, value in
      let projected: RepositoryJSONValue
      switch value {
      case .bool(let value):
        projected = .bool(value)
      case .string(let value):
        projected = .string(value)
      case .strings(let values):
        projected = stringSetValue(values)
      case .uint64(let value):
        projected = .number(.uint64(value))
      }
      return (key, projected)
    }
    return try objectValue([
      ("parameters", try objectValue(parameters)),
      ("ruleID", .string(rule.ruleID)),
      ("ruleVersion", .number(.uint64(rule.ruleVersion))),
    ])
  }

  private static func executionProfileValue(
    _ profile: ExecutionProfileDescriptor
  ) throws -> RepositoryJSONValue {
    try objectValue([
      ("acceptedWorkPolicy", .string(profile.acceptedWorkPolicy.rawValue)),
      ("automaticRetryPolicy", .string(profile.automaticRetryPolicy.rawValue)),
      ("executionProfileID", .string(profile.executionProfileID)),
      ("executionShape", .string(profile.executionShape.rawValue)),
      ("planningAuthority", .string(profile.planningAuthority.rawValue)),
      ("preparationWaitPolicy", .string(profile.preparationWaitPolicy.rawValue)),
      ("resultOwner", .string(profile.resultOwner.rawValue)),
      ("schedulerPolicy", .string(profile.schedulerPolicy.rawValue)),
    ])
  }

  private static func loggingProfileValue(
    _ profile: LoggingProfileDescriptor
  ) throws -> RepositoryJSONValue {
    try objectValue([
      ("actionLogPolicy", .string(profile.actionLogPolicy.rawValue)),
      ("loggingProfileID", .string(profile.loggingProfileID)),
      ("redactionPolicyID", .string(profile.redactionPolicyID)),
      ("replayTracePolicy", .string(profile.replayTracePolicy.rawValue)),
    ])
  }

  private static func policyBindingsValue(
    _ bindings: CommandPolicyBindings
  ) throws -> RepositoryJSONValue {
    try objectValue([
      ("allowedErrorCodes", stringSetValue(bindings.allowedErrorCodes)),
      ("candidateOrderIDs", stringsValue(bindings.candidateOrderIDs)),
      ("cleanupPolicyID", .string(bindings.cleanupPolicyID)),
      ("compatibilityRuleID", .string(bindings.compatibilityRuleID)),
      ("deadlinePolicyID", .string(bindings.deadlinePolicyID)),
      ("fallbackPolicyID", .string(bindings.fallbackPolicyID)),
      ("ownerDisconnectPolicyID", .string(bindings.ownerDisconnectPolicyID)),
      ("preparationGroupIDs", stringsValue(bindings.preparationGroupIDs)),
      ("queuePolicyID", .string(bindings.queuePolicyID)),
      ("redactionPolicyID", .string(bindings.redactionPolicyID)),
      ("resourceClaimTemplateID", .string(bindings.resourceClaimTemplateID)),
      ("runtimeActivationPolicyID", .string(bindings.runtimeActivationPolicyID)),
    ])
  }

  private static func claimTemplateValue(
    _ template: ResourceClaimTemplateDescriptor
  ) throws -> RepositoryJSONValue {
    let claims = template.claims.sorted {
      let lhs = "\($0.phase.rawValue)|\($0.accessMode.rawValue)|\($0.resourceIDTemplate)"
      let rhs = "\($1.phase.rawValue)|\($1.accessMode.rawValue)|\($1.resourceIDTemplate)"
      return asciiLessThan(lhs, rhs)
    }
    return try objectValue([
      (
        "claims",
        .array(
          try claims.map { claim in
            try objectValue([
              ("accessMode", .string(claim.accessMode.rawValue)),
              ("phase", .string(claim.phase.rawValue)),
              ("resourceIDTemplate", .string(claim.resourceIDTemplate)),
            ])
          }
        )
      ),
      ("resourceClaimTemplateID", .string(template.resourceClaimTemplateID)),
    ])
  }

  private static func preparationGroupValue(
    _ group: PreparationGroupDescriptor
  ) throws -> RepositoryJSONValue {
    let phaseBindings = group.phaseClaimBindings.sorted {
      asciiLessThan($0.phaseID.rawValue, $1.phaseID.rawValue)
    }
    return try objectValue([
      ("compatibilityRuleID", .string(group.compatibilityRuleID)),
      (
        "phaseClaimBindings",
        .array(
          try phaseBindings.map { binding in
            try objectValue([
              ("phaseID", .string(binding.phaseID.rawValue)),
              ("resourceClaimTemplateID", .string(binding.resourceClaimTemplateID)),
            ])
          }
        )
      ),
      ("preparationGroupID", .string(group.preparationGroupID)),
      ("requiredCapabilityIDs", stringSetValue(group.requiredCapabilityIDs)),
      ("route", .string(group.route.rawValue)),
      (
        "targetDefaultOSProfileIDs",
        stringSetValue(group.targetDefaultOSProfileIDs.map(\.rawValue))
      ),
    ])
  }

  private static func plannerContractValue(
    _ contract: PlannerContractIdentity
  ) throws -> RepositoryJSONValue {
    let rules = contract.rules.sorted { asciiLessThan($0.ruleID, $1.ruleID) }
    return try objectValue([
      ("plannerContractVersion", .string(contract.plannerContractVersion)),
      (
        "rules",
        .array(
          try rules.map { rule in
            let parameters = rule.parameters.map { key, value in
              let projected: RepositoryJSONValue
              switch value {
              case .bool(let value):
                projected = .bool(value)
              case .string(let value):
                projected = .string(value)
              case .stringSet(let values):
                projected = stringSetValue(values)
              case .uint64(let value):
                projected = .number(.uint64(value))
              }
              return (key, projected)
            }
            return try objectValue([
              ("parameters", try objectValue(parameters)),
              ("ruleID", .string(rule.ruleID)),
              ("ruleVersion", .number(.uint64(rule.ruleVersion))),
            ])
          }
        )
      ),
    ])
  }

  private static func runtimeContractsValue(
    repositoryRoot: URL,
    catalog: ExecutionProfileCatalogV1
  ) throws -> RepositoryJSONValue {
    let resultPaths = Set(
      catalog.expandedProductActions.map(\.command.resultSchemaRef)
        + catalog.expandedSupportingActions.map(\.action.resultSchemaRef)
    ).sorted(by: asciiLessThan)
    let resultSchemas = try resultPaths.map { relativePath in
      try documentValue(repositoryRoot: repositoryRoot, relativePath: relativePath)
    }
    let standardErrors = try standardErrorContractValue(repositoryRoot: repositoryRoot)
    let runtimeWire = try runtimeWireContractValue(repositoryRoot: repositoryRoot)
    return try objectValue([
      ("resultSchemas", .array(resultSchemas)),
      ("runtimeWire", runtimeWire),
      ("standardErrors", standardErrors),
    ])
  }

  private static func standardErrorContractValue(
    repositoryRoot: URL
  ) throws -> RepositoryJSONValue {
    let root = try loadCanonicalObject(
      repositoryRoot: repositoryRoot,
      relativePath: ExecutionProfileCatalog.standardErrorRegistryRelativePath
    )
    let expectedTopLevelKeys: Set<String> = [
      "capacityClasses", "clientContinuationProjectionPolicies", "commitStates",
      "entries", "lifecyclePhases", "outcomes", "revision", "schemaVersion",
      "setID", "visibilities",
    ]
    guard Set(root.members.map(\.key)) == expectedTopLevelKeys,
      let entries = root["entries"]?.arrayValue,
      let schemaVersion = root["schemaVersion"]
    else {
      throw ExecutionCatalogIdentityError.invalidContract("standard error registry")
    }
    let projectedEntries = try entries.map { value -> (String, RepositoryJSONValue) in
      guard let entry = value.objectValue else {
        throw ExecutionCatalogIdentityError.invalidContract("standard error entry")
      }
      let expectedKeys: Set<String> = [
        "allowedCommitStates", "allowedLifecyclePhases", "allowedOutcomes",
        "clientContinuationProjectionPolicy", "code", "defaultCLIExit",
        "defaultMessage", "detailsSchemaID", "family", "retryable", "visibility",
      ]
      guard Set(entry.members.map(\.key)) == expectedKeys,
        let code = entry["code"]?.stringValue
      else {
        throw ExecutionCatalogIdentityError.invalidContract("standard error entry")
      }
      return (
        code,
        try objectValue([
          ("allowedCommitStates", try sortedStringArray(entry, "allowedCommitStates")),
          (
            "allowedLifecyclePhases",
            try sortedStringArray(entry, "allowedLifecyclePhases")
          ),
          ("allowedOutcomes", try sortedStringArray(entry, "allowedOutcomes")),
          (
            "clientContinuationProjectionPolicy",
            try requiredValue(entry, "clientContinuationProjectionPolicy")
          ),
          ("code", .string(code)),
          ("detailsSchemaID", try requiredValue(entry, "detailsSchemaID")),
          ("family", try requiredValue(entry, "family")),
          ("retryable", try requiredValue(entry, "retryable")),
          ("visibility", try requiredValue(entry, "visibility")),
        ])
      )
    }.sorted { asciiLessThan($0.0, $1.0) }

    let detailDirectory = repositoryRoot.appendingPathComponent(detailsSchemaDirectory)
    let detailURLs = try regularJSONFiles(in: detailDirectory)
    let detailDocuments = try detailURLs.map { url -> (String, RepositoryJSONValue) in
      let relativePath = "\(detailsSchemaDirectory)/\(url.lastPathComponent)"
      let document = try loadCanonicalObject(
        repositoryRoot: repositoryRoot,
        relativePath: relativePath
      )
      guard let schemaID = document["$id"]?.stringValue else {
        throw ExecutionCatalogIdentityError.invalidContract(relativePath)
      }
      return (
        schemaID,
        try objectValue([
          ("document", .object(document)),
          ("relativePath", .string(relativePath)),
        ])
      )
    }.sorted { asciiLessThan($0.0, $1.0) }
    let referencedDetailIDs = Set(try projectedEntries.map { entry -> String in
      guard let object = entry.1.objectValue,
        let identifier = object["detailsSchemaID"]?.stringValue
      else {
        throw ExecutionCatalogIdentityError.invalidContract("details schema reference")
      }
      return identifier
    })
    guard Set(detailDocuments.map(\.0)).count == detailDocuments.count,
      referencedDetailIDs == Set(detailDocuments.map(\.0))
    else {
      throw ExecutionCatalogIdentityError.invalidContract("details schema coverage")
    }

    return try objectValue([
      ("capacityClasses", try sortedStringArray(root, "capacityClasses")),
      (
        "clientContinuationProjectionPolicies",
        try sortedStringArray(root, "clientContinuationProjectionPolicies")
      ),
      ("commitStates", try sortedStringArray(root, "commitStates")),
      ("detailsSchemas", .array(detailDocuments.map(\.1))),
      ("entries", .array(projectedEntries.map(\.1))),
      ("lifecyclePhases", try sortedStringArray(root, "lifecyclePhases")),
      ("outcomes", try sortedStringArray(root, "outcomes")),
      ("schemaVersion", schemaVersion),
    ])
  }

  private static func runtimeWireContractValue(
    repositoryRoot: URL
  ) throws -> RepositoryJSONValue {
    let root = try loadCanonicalObject(
      repositoryRoot: repositoryRoot,
      relativePath: runtimeWireSchemaRelativePath
    )
    guard let definitions = root["$defs"]?.objectValue else {
      throw ExecutionCatalogIdentityError.invalidContract(runtimeWireSchemaRelativePath)
    }
    let requiredDefinitionIDs = ["artifactFD", "standardError", "standardResult", "streamFrame"]
    return try objectValue(
      requiredDefinitionIDs.map { identifier in
        guard let value = definitions[identifier] else {
          throw ExecutionCatalogIdentityError.invalidContract(
            "\(runtimeWireSchemaRelativePath)#$defs/\(identifier)"
          )
        }
        return (identifier, value)
      }
    )
  }

  private static func documentValue(
    repositoryRoot: URL,
    relativePath: String
  ) throws -> RepositoryJSONValue {
    try objectValue([
      (
        "document",
        .object(
          try loadCanonicalObject(
            repositoryRoot: repositoryRoot,
            relativePath: relativePath
          )
        )
      ),
      ("relativePath", .string(relativePath)),
    ])
  }

  private static func loadCanonicalObject(
    repositoryRoot: URL,
    relativePath: String
  ) throws -> RepositoryJSONObject {
    let url = repositoryRoot.appendingPathComponent(relativePath)
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
      throw ExecutionCatalogIdentityError.missingContract(relativePath)
    }
    guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_nlink == 1 else {
      throw ExecutionCatalogIdentityError.unsafeContract(relativePath)
    }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    do {
      return try RepositoryCanonicalJSON.validateCanonicalDocument(
        [UInt8](data),
        maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
      ).root
    } catch {
      throw ExecutionCatalogIdentityError.invalidContract(relativePath)
    }
  }

  private static func regularJSONFiles(in directory: URL) throws -> [URL] {
    let urls = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }
    for url in urls {
      var metadata = stat()
      guard lstat(url.path, &metadata) == 0,
        metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
        metadata.st_nlink == 1
      else {
        throw ExecutionCatalogIdentityError.unsafeContract(url.path)
      }
    }
    return urls.sorted { asciiLessThan($0.lastPathComponent, $1.lastPathComponent) }
  }

  private static func sortedStringArray(
    _ object: RepositoryJSONObject,
    _ key: String
  ) throws -> RepositoryJSONValue {
    guard let values = object[key]?.arrayValue else {
      throw ExecutionCatalogIdentityError.invalidContract(key)
    }
    let strings = try values.map { value -> String in
      guard let string = value.stringValue else {
        throw ExecutionCatalogIdentityError.invalidContract(key)
      }
      return string
    }
    return stringSetValue(strings)
  }

  private static func requiredValue(
    _ object: RepositoryJSONObject,
    _ key: String
  ) throws -> RepositoryJSONValue {
    guard let value = object[key] else {
      throw ExecutionCatalogIdentityError.invalidContract(key)
    }
    return value
  }

  private static func stringsValue(_ values: [String]) -> RepositoryJSONValue {
    .array(values.map(RepositoryJSONValue.string))
  }

  private static func stringSetValue(_ values: [String]) -> RepositoryJSONValue {
    stringsValue(Array(Set(values)).sorted(by: asciiLessThan))
  }

  private static func objectValue(
    _ members: [(String, RepositoryJSONValue)]
  ) throws -> RepositoryJSONValue {
    .object(try object(members))
  }

  private static func object(
    _ members: [(String, RepositoryJSONValue)]
  ) throws -> RepositoryJSONObject {
    try RepositoryJSONObject(
      members: members.map { RepositoryJSONMember(key: $0.0, value: $0.1) }
    )
  }

  private static func asciiLessThan(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
  }
}
