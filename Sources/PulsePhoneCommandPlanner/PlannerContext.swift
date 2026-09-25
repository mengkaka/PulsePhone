import PulsePhoneCommandCatalog

public struct DeviceFactsSnapshot: Equatable, Sendable {
  public let deviceClass: String
  public let osMajor: UInt64
  public let transportIDs: Set<String>

  public init(deviceClass: String, osMajor: UInt64, transportIDs: Set<String>) {
    self.deviceClass = deviceClass
    self.osMajor = osMajor
    self.transportIDs = transportIDs
  }
}

public enum RuntimeConnectionState: String, Sendable {
  case absent
  case compatible
  case incompatible
}

public struct DeviceConditionSnapshot: Equatable, Sendable {
  public let connected: Bool
  public let liveAttached: Bool
  public let locked: Bool
  public let runtimeConnectionState: RuntimeConnectionState
  public let trusted: Bool

  public init(
    connected: Bool,
    liveAttached: Bool,
    locked: Bool,
    runtimeConnectionState: RuntimeConnectionState,
    trusted: Bool
  ) {
    self.connected = connected
    self.liveAttached = liveAttached
    self.locked = locked
    self.runtimeConnectionState = runtimeConnectionState
    self.trusted = trusted
  }
}

public struct DisplayGeometrySnapshot: Equatable, Sendable {
  public let geometryRevision: UInt64
  public let logicalHeight: UInt64
  public let logicalWidth: UInt64

  public init(geometryRevision: UInt64, logicalHeight: UInt64, logicalWidth: UInt64) {
    self.geometryRevision = geometryRevision
    self.logicalHeight = logicalHeight
    self.logicalWidth = logicalWidth
  }
}

public enum CapabilityAvailability: Equatable, Sendable {
  case available
  case preparing
  case unavailable(reason: String)
  case unknown
}

public struct PlanningRevisions: Equatable, Sendable {
  public let capability: UInt64
  public let condition: UInt64
  public let connection: UInt64
  public let geometry: UInt64
  public let preparation: UInt64
  public let quiescing: UInt64

  public init(
    capability: UInt64,
    condition: UInt64,
    connection: UInt64,
    geometry: UInt64,
    preparation: UInt64,
    quiescing: UInt64
  ) {
    self.capability = capability
    self.condition = condition
    self.connection = connection
    self.geometry = geometry
    self.preparation = preparation
    self.quiescing = quiescing
  }
}

public struct RuntimePlanningContext: Equatable, Sendable {
  public let capabilities: [String: CapabilityAvailability]
  public let condition: DeviceConditionSnapshot
  public let facts: DeviceFactsSnapshot?
  public let geometry: DisplayGeometrySnapshot?
  public let quiescing: Bool
  public let revisions: PlanningRevisions

  public init(
    capabilities: [String: CapabilityAvailability],
    condition: DeviceConditionSnapshot,
    facts: DeviceFactsSnapshot?,
    geometry: DisplayGeometrySnapshot?,
    quiescing: Bool,
    revisions: PlanningRevisions
  ) {
    self.capabilities = capabilities
    self.condition = condition
    self.facts = facts
    self.geometry = geometry
    self.quiescing = quiescing
    self.revisions = revisions
  }
}

public enum CompatibilityDisposition: Equatable, Sendable {
  case compatible
  case incompatible(reason: String)
  case unknown(reason: String)
}

public enum CommandCompatibility {
  public static func evaluate(
    rule: CompatibilityRuleDescriptor,
    facts: DeviceFactsSnapshot?
  ) -> CompatibilityDisposition {
    let deviceRequired = bool(rule.parameters["deviceRequired"]) ?? true
    guard deviceRequired else {
      return .compatible
    }
    guard let facts else {
      return .unknown(reason: "deviceFactsUnavailable")
    }
    guard facts.deviceClass == "iPhone" || facts.deviceClass == "iPad" else {
      return .incompatible(reason: "unsupportedDeviceClass")
    }
    if let minimum = uint64(rule.parameters["minimumOSMajor"]), facts.osMajor < minimum {
      return .incompatible(reason: "unsupportedOSVersion")
    }
    if let maximum = uint64(rule.parameters["maximumOSMajorExclusive"]),
      facts.osMajor >= maximum
    {
      return .incompatible(reason: "unsupportedOSVersion")
    }
    if let transports = strings(rule.parameters["transportIDs"]),
      facts.transportIDs.isDisjoint(with: transports)
    {
      return .incompatible(reason: "unsupportedTransport")
    }
    return .compatible
  }

  private static func bool(_ value: CompatibilityParameterValue?) -> Bool? {
    guard case .bool(let result)? = value else {
      return nil
    }
    return result
  }

  private static func uint64(_ value: CompatibilityParameterValue?) -> UInt64? {
    guard case .uint64(let result)? = value else {
      return nil
    }
    return result
  }

  private static func strings(_ value: CompatibilityParameterValue?) -> Set<String>? {
    guard case .strings(let result)? = value else {
      return nil
    }
    return Set(result)
  }
}
