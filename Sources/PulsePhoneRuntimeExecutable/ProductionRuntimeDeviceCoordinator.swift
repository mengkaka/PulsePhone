import Darwin
import Foundation
import PulsePhoneAvailability
import PulsePhoneClientCore
import PulsePhoneCommandCatalog
import PulsePhoneCommandPlanner
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneHostPaths
import PulsePhoneRuntimeKernel
import PulsePhoneSharedDefinitions

public enum ProductionRuntimeDeviceCoordinatorError: Error, Equatable, Sendable {
    case invalidBundledResources
    case invalidProductVersion
    case screenshotUnavailable(String)
    case stalePreparationState(
        groupID: String,
        expectedConnectionEpoch: UInt64,
        currentConnectionEpoch: UInt64
    )
    case unknownPreparationGroup(String)
}

public struct ProductionRuntimeDeviceFacts: Equatable, Sendable {
    public let buildVersion: String
    public let deviceClass: String
    public let deviceName: String
    public let productType: String
    public let productVersion: String
    public let uniqueDeviceID: String

    public init(
        buildVersion: String,
        deviceClass: String,
        deviceName: String,
        productType: String,
        productVersion: String,
        uniqueDeviceID: String
    ) {
        self.buildVersion = buildVersion
        self.deviceClass = deviceClass
        self.deviceName = deviceName
        self.productType = productType
        self.productVersion = productVersion
        self.uniqueDeviceID = uniqueDeviceID
    }
}

public struct ProductionRuntimeDeviceCondition: Equatable, Sendable {
    public let connected: Bool
    public let locked: Bool
    public let trusted: Bool

    public init(connected: Bool, locked: Bool, trusted: Bool) {
        self.connected = connected
        self.locked = locked
        self.trusted = trusted
    }
}

public struct ProductionRuntimeDeviceObservation: Equatable, Sendable {
    public let rawTransportUDID: String
    public let facts: ProductionRuntimeDeviceFacts
    public let condition: ProductionRuntimeDeviceCondition

    public init(
        rawTransportUDID: String,
        facts: ProductionRuntimeDeviceFacts,
        condition: ProductionRuntimeDeviceCondition
    ) {
        self.rawTransportUDID = rawTransportUDID
        self.facts = facts
        self.condition = condition
    }
}

public struct ProductionRuntimeDeviceSnapshot: Sendable {
    public let device: ProductionRuntimeDeviceObservation?
    public let connectionEpoch: UInt64
    public let factsRevision: UInt64
    public let conditionRevision: UInt64
    public let capabilityRevision: UInt64
    public let geometry: DisplayGeometryDTO?
    public let geometryRevision: UInt64
    public let stateRevision: UInt64
    public let planningContext: RuntimePlanningContext
}

public enum ProductionRuntimeConnectionTransitionKind: Equatable, Sendable {
    case attached
    case detached(previousConnectionEpoch: UInt64)
    case unchanged
}

public struct ProductionRuntimeConnectionTransition: Sendable {
    public let kind: ProductionRuntimeConnectionTransitionKind
    public let snapshot: ProductionRuntimeDeviceSnapshot
}

struct ProductionRuntimeElementSnapshotAuthority: Equatable, Sendable {
    let connectionEpoch: UInt64
    let geometry: DisplayGeometryDTO
    let rawTransportUDID: String
    let uniqueDeviceID: String

    init?(snapshot: ProductionRuntimeDeviceSnapshot) {
        guard let device = snapshot.device,
              let geometry = snapshot.geometry,
              geometry.connectionEpoch == snapshot.connectionEpoch
        else {
            return nil
        }
        self.connectionEpoch = snapshot.connectionEpoch
        self.geometry = geometry
        self.rawTransportUDID = device.rawTransportUDID
        self.uniqueDeviceID = device.facts.uniqueDeviceID
    }
}

struct ProductionScreenshotProviderPlan: Equatable, Sendable {
    let preferredProvider: String
    let attemptOrder: [String]

    static let compatibilityDefault = ProductionScreenshotProviderPlan(
        preferredProvider: "dvt",
        attemptOrder: ["dvt", "coreDevice", "axAudit"]
    )!

    init?(preferredProvider: String, attemptOrder: [String]) {
        switch (preferredProvider, attemptOrder) {
        case ("dvt", ["dvt", "coreDevice", "axAudit"]),
             ("coreDevice", ["coreDevice", "axAudit"]),
             ("axAudit", ["axAudit"]),
             ("unavailable", []):
            self.preferredProvider = preferredProvider
            self.attemptOrder = attemptOrder
        default:
            return nil
        }
    }

    var identifier: String {
        attemptOrder.isEmpty ? "unavailable" : attemptOrder.joined(separator: "->")
    }
}

public final class ProductionRuntimeDeviceCoordinator: @unchecked Sendable {
    public typealias Discovery = @Sendable () throws
        -> ProductionRuntimeDeviceObservation?

    private struct State {
        var device: ProductionRuntimeDeviceObservation?
        var connectionEpoch: UInt64 = 0
        var readyPreparationGroupIDs = Set<String>()
        var optionalCapabilityAvailability = [String: CapabilityAvailability]()
        var factsRevision: UInt64 = 0
        var conditionRevision: UInt64 = 0
        var capabilityRevision: UInt64 = 0
        var geometryRevision: UInt64 = 0
        var geometryLogicalWidth: UInt64?
        var geometryLogicalHeight: UInt64?
        var geometryOrientation: DisplayOrientationDTO?
        var screenshotProviderPlan: ProductionScreenshotProviderPlan?
        var stateRevision: UInt64 = 0
        var liveAttached = false
    }

    private struct ElementAuthorityObserver {
        let authority: ProductionRuntimeElementSnapshotAuthority
        let invalidated: @Sendable () -> Void
    }

    private let canonicalUDID: CanonicalUDID
    private let catalog: ExecutionProfileCatalogV1
    private let planner: CommandPlanner
    private let discovery: Discovery
    private let lock = NSLock()
    private var elementAuthorityObservers = [UUID: ElementAuthorityObserver]()
    private var state = State()

    public init(
        canonicalUDID: CanonicalUDID,
        catalog: ExecutionProfileCatalogV1,
        discovery: @escaping Discovery
    ) {
        self.canonicalUDID = canonicalUDID
        self.catalog = catalog
        self.planner = CommandPlanner(catalog: catalog)
        self.discovery = discovery
    }

    public static func bundled(
        canonicalUDID: CanonicalUDID
    ) throws -> ProductionRuntimeDeviceCoordinator {
        let root = try bundledContractRoot()
        let helper = BundledHelperExecutableSet(
            resourcesURL: root
        ).directExecutableURL
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw ProductionRuntimeDeviceCoordinatorError.invalidBundledResources
        }
        let catalog = try ExecutionProfileCatalog.load(repositoryRoot: root)
        let deviceDiscovery = USBDeviceDiscovery(
            factsProvider: LocalDeviceFactsProbe(executablePath: helper.path)
        )
        return ProductionRuntimeDeviceCoordinator(
            canonicalUDID: canonicalUDID,
            catalog: catalog,
            discovery: {
                guard let device = try deviceDiscovery.discover(
                    canonicalUDID: canonicalUDID
                ) else {
                    return nil
                }
                return ProductionRuntimeDeviceObservation(
                    rawTransportUDID: device.rawTransportUDID,
                    facts: ProductionRuntimeDeviceFacts(
                        buildVersion: device.facts.buildVersion,
                        deviceClass: device.facts.deviceClass,
                        deviceName: device.facts.deviceName,
                        productType: device.facts.productType,
                        productVersion: device.facts.productVersion,
                        uniqueDeviceID: device.facts.uniqueDeviceID
                    ),
                    condition: ProductionRuntimeDeviceCondition(
                        connected: device.condition.connected,
                        locked: device.condition.locked,
                        trusted: device.condition.trusted
                    )
                )
            }
        )
    }

    public func refresh() throws -> ProductionRuntimeDeviceSnapshot {
        lock.lock()
        if state.liveAttached {
            defer { lock.unlock() }
            return try snapshotLocked()
        }
        lock.unlock()

        let discovered = try discovery()
        lock.lock()
        guard !state.liveAttached else {
            do {
                let snapshot = try snapshotLocked()
                lock.unlock()
                return snapshot
            } catch {
                lock.unlock()
                throw error
            }
        }
        do {
            let transition = try applyLocked(discovered: discovered)
            let invalidations = drainInvalidElementAuthoritiesLocked()
            lock.unlock()
            invalidations.forEach { $0() }
            return transition.snapshot
        } catch {
            lock.unlock()
            throw error
        }
    }

    public func refreshConnectionTransition(
        allowDetachment: Bool
    ) throws
        -> ProductionRuntimeConnectionTransition
    {
        let discovered = try discovery()
        lock.lock()
        if discovered == nil, !allowDetachment, state.device != nil {
            do {
                let transition = ProductionRuntimeConnectionTransition(
                    kind: .unchanged,
                    snapshot: try snapshotLocked()
                )
                lock.unlock()
                return transition
            } catch {
                lock.unlock()
                throw error
            }
        }
        do {
            let transition = try applyLocked(discovered: discovered)
            let invalidations = drainInvalidElementAuthoritiesLocked()
            lock.unlock()
            invalidations.forEach { $0() }
            return transition
        } catch {
            lock.unlock()
            throw error
        }
    }

    public func probeConnectionPresence() throws -> Bool {
        try discovery() != nil
    }

    public var hasConnectedDevice: Bool {
        lock.withLock { state.device != nil }
    }

    public func refreshConnectionTransition() throws
        -> ProductionRuntimeConnectionTransition
    {
        try refreshConnectionTransition(allowDetachment: true)
    }

    public func confirmDisconnected() throws
        -> ProductionRuntimeConnectionTransition
    {
        try apply(discovered: nil)
    }

    public var hasPersistentLiveDemand: Bool {
        lock.withLock { state.liveAttached }
    }

    private func apply(
        discovered: ProductionRuntimeDeviceObservation?
    ) throws -> ProductionRuntimeConnectionTransition {
        lock.lock()
        do {
            let transition = try applyLocked(discovered: discovered)
            let invalidations = drainInvalidElementAuthoritiesLocked()
            lock.unlock()
            invalidations.forEach { $0() }
            return transition
        } catch {
            lock.unlock()
            throw error
        }
    }

    private func applyLocked(
        discovered: ProductionRuntimeDeviceObservation?
    ) throws -> ProductionRuntimeConnectionTransition {

        let prior = state.device
        let previousConnectionEpoch = state.connectionEpoch
        if prior?.rawTransportUDID != discovered?.rawTransportUDID {
            if discovered != nil { state.connectionEpoch = increment(state.connectionEpoch) }
            state.readyPreparationGroupIDs.removeAll()
            state.optionalCapabilityAvailability.removeAll()
            state.geometryRevision = 0
            state.geometryLogicalWidth = nil
            state.geometryLogicalHeight = nil
            state.geometryOrientation = nil
            state.screenshotProviderPlan = nil
        }
        if prior?.facts != discovered?.facts {
            state.factsRevision = increment(state.factsRevision)
        }
        if prior?.condition != discovered?.condition {
            state.conditionRevision = increment(state.conditionRevision)
        }
        if prior?.condition != discovered?.condition || prior?.facts != discovered?.facts {
            state.capabilityRevision = increment(state.capabilityRevision)
        }
        if prior != discovered {
            state.stateRevision = increment(state.stateRevision)
        }
        state.device = discovered
        let kind: ProductionRuntimeConnectionTransitionKind
        if prior != nil, discovered == nil {
            kind = .detached(previousConnectionEpoch: previousConnectionEpoch)
        } else if prior == nil, discovered != nil {
            kind = .attached
        } else {
            kind = .unchanged
        }
        return ProductionRuntimeConnectionTransition(
            kind: kind,
            snapshot: try snapshotLocked()
        )
    }

    public func commandAdmissionSnapshot() throws
        -> ProductionRuntimeDeviceSnapshot
    {
        lock.lock()
        if state.liveAttached {
            defer { lock.unlock() }
            return try snapshotLocked()
        }
        lock.unlock()
        return try refresh()
    }

    public func setLiveAttached(_ attached: Bool) throws -> ProductionRuntimeDeviceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        if state.liveAttached != attached {
            state.liveAttached = attached
            state.conditionRevision = increment(state.conditionRevision)
            state.stateRevision = increment(state.stateRevision)
        }
        return try snapshotLocked()
    }

    public func updateGeometry(
        connectionEpoch: UInt64,
        geometryRevision: UInt64,
        logicalWidth: UInt64,
        logicalHeight: UInt64,
        orientation: DisplayOrientationDTO
    ) throws -> ProductionRuntimeDeviceSnapshot {
        lock.lock()
        do {
            if connectionEpoch == state.connectionEpoch,
               geometryRevision > 0,
               logicalWidth > 0,
               logicalHeight > 0,
               geometryRevision >= state.geometryRevision,
               geometryRevision != state.geometryRevision
                || (logicalWidth == state.geometryLogicalWidth
                    && logicalHeight == state.geometryLogicalHeight
                    && orientation == state.geometryOrientation)
            {
                if geometryRevision != state.geometryRevision
                    || logicalWidth != state.geometryLogicalWidth
                    || logicalHeight != state.geometryLogicalHeight
                    || orientation != state.geometryOrientation
                {
                    state.geometryRevision = geometryRevision
                    state.geometryLogicalWidth = logicalWidth
                    state.geometryLogicalHeight = logicalHeight
                    state.geometryOrientation = orientation
                    state.stateRevision = increment(state.stateRevision)
                }
            }
            let snapshot = try snapshotLocked()
            let invalidations = drainInvalidElementAuthoritiesLocked()
            lock.unlock()
            invalidations.forEach { $0() }
            return snapshot
        } catch {
            lock.unlock()
            throw error
        }
    }

    public func invalidateGeometry(
        connectionEpoch: UInt64,
        geometryRevision: UInt64
    ) throws -> ProductionRuntimeDeviceSnapshot {
        lock.lock()
        do {
            if connectionEpoch == state.connectionEpoch,
               geometryRevision == state.geometryRevision,
               state.geometryLogicalWidth != nil,
               state.geometryLogicalHeight != nil,
               state.geometryOrientation != nil
            {
                state.geometryLogicalWidth = nil
                state.geometryLogicalHeight = nil
                state.geometryOrientation = nil
                state.stateRevision = increment(state.stateRevision)
            }
            let snapshot = try snapshotLocked()
            let invalidations = drainInvalidElementAuthoritiesLocked()
            lock.unlock()
            invalidations.forEach { $0() }
            return snapshot
        } catch {
            lock.unlock()
            throw error
        }
    }

    public func synchronizeGeometry(
        connectionEpoch: UInt64,
        logicalWidth: UInt64,
        logicalHeight: UInt64,
        orientation: DisplayOrientationDTO
    ) throws -> ProductionRuntimeDeviceSnapshot {
        lock.lock()
        do {
            if connectionEpoch == state.connectionEpoch,
               logicalWidth > 0,
               logicalHeight > 0,
               !(logicalWidth == state.geometryLogicalWidth
                    && logicalHeight == state.geometryLogicalHeight
                    && orientation == state.geometryOrientation
                    && state.geometryRevision > 0),
               state.geometryRevision < UInt64.max
            {
                state.geometryRevision = increment(state.geometryRevision)
                state.geometryLogicalWidth = logicalWidth
                state.geometryLogicalHeight = logicalHeight
                state.geometryOrientation = orientation
                state.stateRevision = increment(state.stateRevision)
            }
            let snapshot = try snapshotLocked()
            let invalidations = drainInvalidElementAuthoritiesLocked()
            lock.unlock()
            invalidations.forEach { $0() }
            return snapshot
        } catch {
            lock.unlock()
            throw error
        }
    }

    func observeElementSnapshotAuthority(
        _ authority: ProductionRuntimeElementSnapshotAuthority,
        invalidated: @escaping @Sendable () -> Void
    ) -> UUID {
        let id = UUID()
        lock.lock()
        let invoke = !matchesElementAuthorityLocked(authority)
        if !invoke {
            elementAuthorityObservers[id] = ElementAuthorityObserver(
                authority: authority,
                invalidated: invalidated
            )
        }
        lock.unlock()
        if invoke { invalidated() }
        return id
    }

    func removeElementSnapshotAuthorityObserver(_ id: UUID) {
        _ = lock.withLock {
            elementAuthorityObservers.removeValue(forKey: id)
        }
    }

    private func drainInvalidElementAuthoritiesLocked() -> [@Sendable () -> Void] {
        var invalidations = [@Sendable () -> Void]()
        elementAuthorityObservers = elementAuthorityObservers.filter { _, observer in
            if matchesElementAuthorityLocked(observer.authority) { return true }
            invalidations.append(observer.invalidated)
            return false
        }
        return invalidations
    }

    private func matchesElementAuthorityLocked(
        _ authority: ProductionRuntimeElementSnapshotAuthority
    ) -> Bool {
        guard let device = state.device,
              state.connectionEpoch == authority.connectionEpoch,
              device.rawTransportUDID == authority.rawTransportUDID,
              device.facts.uniqueDeviceID == authority.uniqueDeviceID,
              let geometry = try? currentGeometryLocked()
        else {
            return false
        }
        return geometry == authority.geometry
    }

    private func currentGeometryLocked() throws -> DisplayGeometryDTO? {
        guard state.geometryRevision > 0,
              let logicalWidth = state.geometryLogicalWidth,
              let logicalHeight = state.geometryLogicalHeight,
              let orientation = state.geometryOrientation
        else {
            return nil
        }
        return try DisplayGeometryDTO(
            connectionEpoch: state.connectionEpoch,
            geometryRevision: state.geometryRevision,
            logicalHeight: logicalHeight,
            logicalWidth: logicalWidth,
            orientation: orientation
        )
    }

    public func plan(
        commandID: String,
        rawArguments: [String: String]
    ) throws -> (ProductionRuntimeDeviceSnapshot, PlanningResult) {
        let snapshot = try refresh()
        return (
            snapshot,
            try plan(
                commandID: commandID,
                rawArguments: rawArguments,
                snapshot: snapshot
            )
        )
    }

    func plan(
        commandID: String,
        rawArguments: [String: String],
        snapshot: ProductionRuntimeDeviceSnapshot
    ) throws -> PlanningResult {
        try planner.plan(
            commandID: commandID,
            rawArguments: rawArguments,
            context: snapshot.planningContext
        )
    }

    public func planScreenshot(
        commandID: String,
        rawArguments: [String: String]
    ) throws -> (ProductionRuntimeDeviceSnapshot, String) {
        let snapshot = try refresh()
        switch try planner.plan(
            commandID: commandID,
            rawArguments: rawArguments,
            context: snapshot.planningContext
        ) {
        case .notRuntimePlannable(.hybrid):
            break
        case .awaitingPreparation:
            throw ProductionRuntimeDeviceCoordinatorError.screenshotUnavailable(
                "capabilityPreparing"
            )
        case .unavailable(let reason), .unknown(let reason):
            throw ProductionRuntimeDeviceCoordinatorError.screenshotUnavailable(reason)
        case .notRuntimePlannable, .planned:
            throw ProductionRuntimeDeviceCoordinatorError.screenshotUnavailable(
                "invalidArgument"
            )
        }
        guard let device = snapshot.device,
              device.condition.connected
        else {
            throw ProductionRuntimeDeviceCoordinatorError.screenshotUnavailable(
                "deviceDisconnected"
            )
        }
        guard device.condition.trusted else {
            throw ProductionRuntimeDeviceCoordinatorError.screenshotUnavailable(
                "deviceNotTrusted"
            )
        }
        guard !device.condition.locked else {
            throw ProductionRuntimeDeviceCoordinatorError.screenshotUnavailable(
                "deviceLocked"
            )
        }
        guard let osMajor = UInt64(
            device.facts.productVersion.split(separator: ".").first ?? ""
        ) else {
            throw ProductionRuntimeDeviceCoordinatorError.invalidProductVersion
        }
        do {
            return (snapshot, try ScreenshotRoute.resolve(osMajor: osMajor).rawValue)
        } catch {
            throw ProductionRuntimeDeviceCoordinatorError.screenshotUnavailable(
                "unsupportedOSVersion"
            )
        }
    }

    public func availabilityValue() throws -> RepositoryJSONObject {
        let snapshot = try refresh()
        let effective = try EffectiveCommandAvailability(
            catalog: catalog,
            planner: planner,
            context: snapshot.planningContext
        )
        let revisions = try revisionsValue(snapshot)
        let commands = try effective.entries.map { entry -> RepositoryJSONValue in
            var members: [(String, RepositoryJSONValue)] = [
                ("commandID", .string(entry.commandID)),
                ("sourceRevisions", .object(revisions)),
            ]
            switch entry.state {
            case .available:
                members.append(("state", .string("enabled")))
            case .preparable:
                members.append(("state", .string("loading")))
                members.append(("reasonCode", .string("capabilityPreparing")))
            case .unavailable(let reason):
                members.append(("state", .string("disabled")))
                members.append(("reasonCode", .string(reason)))
            case .unknown(let reason):
                members.append(("state", .string("disabled")))
                members.append(("reasonCode", .string(reason)))
            }
            return .object(try object(members))
        }
        return try object([
            ("canonicalUDID", .string(canonicalUDID.rawValue)),
            ("capabilityRevision", .number(.uint64(snapshot.capabilityRevision))),
            ("commands", .array(commands)),
            ("conditionRevision", .number(.uint64(snapshot.conditionRevision))),
            ("connectionEpoch", .number(.uint64(snapshot.connectionEpoch))),
            ("factsRevision", .number(.uint64(snapshot.factsRevision))),
            ("geometryRevision", .number(.uint64(snapshot.geometryRevision))),
            ("inhibitorRevision", .number(.uint64(0))),
            ("omittedCommandCount", .number(.uint64(0))),
            ("quiescing", .bool(false)),
            ("stateRevision", .number(.uint64(snapshot.stateRevision))),
            ("truncated", .bool(false)),
        ])
    }

    func preparationCapabilityIDs(groupID: String) -> [String]? {
        catalog.preparationGroups.first {
            $0.preparationGroupID == groupID
        }?.requiredCapabilityIDs
    }

    func optionalCapabilityIDs(groupID: String) -> [String]? {
        catalog.preparationGroups.first {
            $0.preparationGroupID == groupID
        }?.optionalCapabilityIDs
    }

    func recordOptionalCapabilityAvailability(
        _ values: [String: CapabilityAvailability],
        connectionEpoch: UInt64
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard connectionEpoch == state.connectionEpoch else {
            throw ProductionRuntimeDeviceCoordinatorError.stalePreparationState(
                groupID: "optional-capabilities",
                expectedConnectionEpoch: connectionEpoch,
                currentConnectionEpoch: state.connectionEpoch
            )
        }
        guard values.keys.allSatisfy({ capabilityID in
            catalog.preparationGroups.contains {
                $0.optionalCapabilityIDs.contains(capabilityID)
            }
        }) else {
            return
        }
        guard state.optionalCapabilityAvailability != values else { return }
        state.optionalCapabilityAvailability = values
        state.capabilityRevision = increment(state.capabilityRevision)
        state.stateRevision = increment(state.stateRevision)
    }

    func validateDeveloperImageCatalog(
        _ developerImageCatalog: DeveloperImageCatalogV1
    ) throws {
        try DeveloperImageCatalog.validateCompatibilityRules(
            catalog: developerImageCatalog,
            executionCatalog: catalog
        )
    }

    /// The Runtime keeps Developer Support readiness only for its current
    /// connection epoch. Callers that bypass normal command planning (for
    /// example screenshot and Live stream setup) use this to decide whether
    /// they must run the same preparation operation first.
    func isPreparationReady(
        groupID: String,
        snapshot: ProductionRuntimeDeviceSnapshot
    ) -> Bool {
        guard let capabilityIDs = preparationCapabilityIDs(groupID: groupID),
              !capabilityIDs.isEmpty
        else {
            return false
        }
        return capabilityIDs.allSatisfy { capabilityID in
            if case .available? = snapshot.planningContext.capabilities[
                capabilityID
            ] {
                return true
            }
            return false
        }
    }

    /// Records a successful device-side Developer Support preparation for the
    /// current USB connection. A reconnect always invalidates this observation.
    func markPreparationReady(
        groupID: String,
        connectionEpoch: UInt64
    ) throws -> ProductionRuntimeDeviceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard catalog.preparationGroups.contains(where: {
            $0.preparationGroupID == groupID
        }) else {
            throw ProductionRuntimeDeviceCoordinatorError
                .unknownPreparationGroup(groupID)
        }
        guard connectionEpoch == state.connectionEpoch else {
            throw ProductionRuntimeDeviceCoordinatorError.stalePreparationState(
                groupID: groupID,
                expectedConnectionEpoch: connectionEpoch,
                currentConnectionEpoch: state.connectionEpoch
            )
        }
        if state.readyPreparationGroupIDs.insert(groupID).inserted {
            state.capabilityRevision = increment(state.capabilityRevision)
            state.stateRevision = increment(state.stateRevision)
        }
        return try snapshotLocked()
    }

    func recordScreenshotProviderPlan(
        _ plan: ProductionScreenshotProviderPlan,
        connectionEpoch: UInt64
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard connectionEpoch == state.connectionEpoch else {
            throw ProductionRuntimeDeviceCoordinatorError.stalePreparationState(
                groupID: "prep.coredevice.v2",
                expectedConnectionEpoch: connectionEpoch,
                currentConnectionEpoch: state.connectionEpoch
            )
        }
        state.screenshotProviderPlan = plan
    }

    func screenshotProviderPlan(
        connectionEpoch: UInt64
    ) -> ProductionScreenshotProviderPlan? {
        lock.withLock {
            guard connectionEpoch == state.connectionEpoch else { return nil }
            return state.screenshotProviderPlan
        }
    }

    func developerSupportRoute(osMajor: UInt64) throws -> DeveloperSupportOSRoute {
        try DeveloperSupportOSRouting.resolve(
            osMajor: osMajor,
            executionCatalog: catalog
        )
    }

    func targetFailureDetails(
        commandID: String,
        code: String,
        snapshot: ProductionRuntimeDeviceSnapshot
    ) throws -> RepositoryJSONObject? {
        guard code == "unsupportedOSVersion",
              let device = snapshot.device,
              let command = catalog.expandedProductActions.first(where: {
                  $0.command.commandID == commandID
              })
        else {
            return nil
        }
        let parameters = command.compatibilityRule.parameters
        let minimum = uint64(parameters["minimumOSMajor"])
        let maximum = uint64(parameters["maximumOSMajorExclusive"])
        guard let requirement = osRequirement(minimum: minimum, maximum: maximum)
        else {
            return nil
        }
        let label = command.command.help?.commandPath
            ?? command.command.cliVariant
            ?? command.command.commandID
        let reason = "\(label) requires \(requirement); target device is running iOS "
            + "\(device.facts.productVersion)."
        return try object([
            ("deviceClass", .string(device.facts.deviceClass)),
            ("osVersion", .string(device.facts.productVersion)),
            ("reason", .string(reason)),
        ])
    }

    private func snapshotLocked() throws -> ProductionRuntimeDeviceSnapshot {
        let facts: DeviceFactsSnapshot?
        if let device = state.device {
            guard let major = UInt64(
                device.facts.productVersion.split(separator: ".").first ?? ""
            ) else {
                throw ProductionRuntimeDeviceCoordinatorError.invalidProductVersion
            }
            facts = DeviceFactsSnapshot(
                deviceClass: device.facts.deviceClass,
                osMajor: major,
                transportIDs: ["usb"]
            )
        } else {
            facts = nil
        }
        let connected = state.device?.condition.connected == true
        let capabilities = Dictionary(uniqueKeysWithValues:
            catalog.preparationGroups.flatMap { group in
                (group.requiredCapabilityIDs + group.optionalCapabilityIDs).map { capabilityID in
                    (
                        capabilityID,
                        capabilityState(
                            capabilityID: capabilityID,
                            connected: connected
                        )
                    )
                }
            }
        )
        let geometry = try state.geometryLogicalWidth.flatMap { width in
            try state.geometryLogicalHeight.flatMap { height in
                try state.geometryOrientation.map { orientation in
                    try DisplayGeometryDTO(
                        connectionEpoch: state.connectionEpoch,
                        geometryRevision: state.geometryRevision,
                        logicalHeight: height,
                        logicalWidth: width,
                        orientation: orientation
                    )
                }
            }
        }
        let context = RuntimePlanningContext(
            capabilities: capabilities,
            condition: DeviceConditionSnapshot(
                connected: connected,
                liveAttached: state.liveAttached,
                locked: state.device?.condition.locked ?? false,
                runtimeConnectionState: .compatible,
                trusted: state.device?.condition.trusted ?? false
            ),
            facts: facts,
            geometry: geometry.map {
                DisplayGeometrySnapshot(
                    geometryRevision: $0.geometryRevision,
                    logicalHeight: $0.logicalHeight,
                    logicalWidth: $0.logicalWidth
                )
            },
            quiescing: false,
            revisions: PlanningRevisions(
                capability: state.capabilityRevision,
                condition: state.conditionRevision,
                connection: state.connectionEpoch,
                geometry: state.geometryRevision,
                preparation: state.capabilityRevision,
                quiescing: 0
            )
        )
        return ProductionRuntimeDeviceSnapshot(
            device: state.device,
            connectionEpoch: state.connectionEpoch,
            factsRevision: state.factsRevision,
            conditionRevision: state.conditionRevision,
            capabilityRevision: state.capabilityRevision,
            geometry: geometry,
            geometryRevision: state.geometryRevision,
            stateRevision: state.stateRevision,
            planningContext: context
        )
    }

    private func capabilityState(
        capabilityID: String,
        connected: Bool
    ) -> CapabilityAvailability {
        guard connected else { return .unknown }
        guard state.device?.condition.trusted == true else {
            return .unavailable(reason: "deviceNotTrusted")
        }
        guard state.device?.condition.locked == false else {
            return .unavailable(reason: "deviceLocked")
        }
        guard let group = catalog.preparationGroups.first(where: {
            $0.requiredCapabilityIDs.contains(capabilityID)
                || $0.optionalCapabilityIDs.contains(capabilityID)
        }) else {
            return .unknown
        }
        if group.optionalCapabilityIDs.contains(capabilityID),
           let optional = state.optionalCapabilityAvailability[capabilityID]
        {
            return optional
        }
        if group.route == .none
            || state.readyPreparationGroupIDs.contains(group.preparationGroupID)
        {
            return .available
        }
        return .preparing
    }

    private func revisionsValue(
        _ snapshot: ProductionRuntimeDeviceSnapshot
    ) throws -> RepositoryJSONObject {
        try object([
            ("capability", .number(.uint64(snapshot.capabilityRevision))),
            ("condition", .number(.uint64(snapshot.conditionRevision))),
            ("facts", .number(.uint64(snapshot.factsRevision))),
            ("geometry", .number(.uint64(snapshot.geometryRevision))),
            ("inhibitor", .number(.uint64(0))),
            ("state", .number(.uint64(snapshot.stateRevision))),
        ])
    }

    private func uint64(_ value: CompatibilityParameterValue?) -> UInt64? {
        guard case .uint64(let result)? = value else { return nil }
        return result
    }

    private func osRequirement(minimum: UInt64?, maximum: UInt64?) -> String? {
        switch (minimum, maximum) {
        case let (.some(minimum), .some(maximum)) where maximum > minimum:
            return maximum == minimum + 1
                ? "iOS \(minimum)"
                : "iOS \(minimum) through \(maximum - 1)"
        case let (.some(minimum), .none):
            return "iOS \(minimum) or later"
        case let (.none, .some(maximum)):
            return "an iOS version earlier than \(maximum)"
        default:
            return nil
        }
    }

    static func bundledContractRoot() throws -> URL {
        if Bundle.main.bundleURL.pathExtension == "app",
           let resources = Bundle.main.resourceURL
        {
            return resources
        }
        if let executable = canonicalExecutableURL() {
            let resources = executable
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources", isDirectory: true)
            if FileManager.default.fileExists(
                atPath: resources.appendingPathComponent("Registries").path
            ) {
                return resources
            }
        }
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard FileManager.default.fileExists(
            atPath: current.appendingPathComponent("Registries").path
        ) else {
            throw ProductionRuntimeDeviceCoordinatorError.invalidBundledResources
        }
        return current
    }

    private static func canonicalExecutableURL() -> URL? {
        var capacity: UInt32 = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(capacity))
        guard _NSGetExecutablePath(&buffer, &capacity) == 0,
              let resolved = realpath(buffer, nil)
        else {
            return nil
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private func increment(_ value: UInt64) -> UInt64 {
        value == UInt64.max ? value : value + 1
    }

    private func object(
        _ members: [(String, RepositoryJSONValue)]
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: members.map {
            RepositoryJSONMember(key: $0.0, value: $0.1)
        })
    }
}
