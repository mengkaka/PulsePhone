import Foundation
import PulsePhoneCommandCatalog
import PulsePhoneCommandPlanner
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions

func coordinatorRepositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

func loadCoordinatorCatalog() throws -> ExecutionProfileCatalogV1 {
    try ExecutionProfileCatalog.load(repositoryRoot: coordinatorRepositoryRoot())
}

func loadCoordinatorExpected(
    _ requirementID: String
) throws -> RepositoryJSONObject {
    let url = coordinatorRepositoryRoot()
        .appendingPathComponent("Fixtures/requirements")
        .appendingPathComponent(requirementID)
        .appendingPathComponent("expected.v1.json")
    return try RepositoryCanonicalJSON.validateCanonicalDocument(
        [UInt8](Data(contentsOf: url)),
        maximumByteCount: 16 * 1_024
    ).root
}

func coordinatorUUID(_ value: Int) throws -> CanonicalUUID {
    try CanonicalUUID(
        String(format: "00000000-0000-0000-0000-%012x", value)
    )
}

func coordinatorSeed(_ value: Int) throws -> PreparationAttemptSeed {
    PreparationAttemptSeed(
        preparationAttemptID: try coordinatorUUID(value),
        inhibitorTokenID: try coordinatorUUID(value + 10_000)
    )
}

func coordinatorRevisions(_ value: UInt64) -> PlanningRevisions {
    PlanningRevisions(
        capability: value,
        condition: value,
        connection: value,
        geometry: value,
        preparation: value,
        quiescing: value
    )
}

func coordinatorWaiter(revision: UInt64 = 1) -> CapabilityGateWaiter {
    CapabilityGateWaiter(
        commandID: "touch.tap",
        rawArguments: ["point": "0.5,0.25"],
        sourceRevisions: coordinatorRevisions(revision)
    )
}

func coordinatorContext(
    catalog: ExecutionProfileCatalogV1,
    readyGroupID: String?,
    revision: UInt64
) -> RuntimePlanningContext {
    let groups = Dictionary(
        uniqueKeysWithValues: catalog.preparationGroups.map {
            ($0.preparationGroupID, $0)
        }
    )
    var capabilities = [String: CapabilityAvailability]()
    if let readyGroupID {
        for capabilityID in groups[readyGroupID]?.requiredCapabilityIDs ?? [] {
            capabilities[capabilityID] = .available
        }
    }
    return RuntimePlanningContext(
        capabilities: capabilities,
        condition: DeviceConditionSnapshot(
            connected: true,
            liveAttached: false,
            locked: false,
            runtimeConnectionState: .compatible,
            trusted: true
        ),
        facts: DeviceFactsSnapshot(
            deviceClass: "iPhone",
            osMajor: 26,
            transportIDs: ["rsd", "usb"]
        ),
        geometry: DisplayGeometrySnapshot(
            geometryRevision: revision,
            logicalHeight: 2_532,
            logicalWidth: 1_170
        ),
        quiescing: false,
        revisions: coordinatorRevisions(revision)
    )
}

func expectedBool(
    _ object: RepositoryJSONObject,
    _ key: String
) -> Bool? {
    guard case .bool(let value)? = object[key] else { return nil }
    return value
}

func expectedString(
    _ object: RepositoryJSONObject,
    _ key: String
) -> String? {
    guard case .string(let value)? = object[key] else { return nil }
    return value
}

func expectedUInt(
    _ object: RepositoryJSONObject,
    _ key: String
) -> UInt64? {
    guard let number = object[key]?.numberValue else { return nil }
    return try? number.requireUInt64()
}

func expectedObject(
    _ object: RepositoryJSONObject,
    _ key: String
) -> RepositoryJSONObject? {
    object[key]?.objectValue
}
