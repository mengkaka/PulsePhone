import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneSharedDefinitions

public struct PreparationWaitCapacityDetails: Equatable, Sendable {
    public let capacityClass = "preparationWaitRegistry"
    public let limit = 64
    public let truncated = false

    public init() {}
}

public enum PreparationWaitRegistryError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidDemand
    case duplicateWaitID
    case livePrewarmAlreadyRegistered
    case capacityExceeded(PreparationWaitCapacityDetails)
    case unknownWaitID
    case noLivePrewarm
    case attemptNotActive
    case connectionEpochOverflow
}

public struct PreparationAttemptKey: Equatable, Hashable, Sendable {
    public let runtimeEpoch: UInt64
    public let connectionEpoch: UInt64
    public let preparationGroupID: String

    public init(
        runtimeEpoch: UInt64,
        connectionEpoch: UInt64,
        preparationGroupID: String
    ) throws {
        guard Self.validIdentifier(preparationGroupID) else {
            throw PreparationWaitRegistryError.invalidIdentifier
        }
        self.runtimeEpoch = runtimeEpoch
        self.connectionEpoch = connectionEpoch
        self.preparationGroupID = preparationGroupID
    }

    fileprivate var stableSortKey: [UInt8] {
        "\(runtimeEpoch)\u{0}\(connectionEpoch)\u{0}\(preparationGroupID)"
            .utf8.map { $0 }
    }

    fileprivate static func validIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...256).contains(bytes.count)
            && bytes.allSatisfy { (0x21...0x7e).contains($0) }
    }
}

public enum PreparationWaitKind: String, Equatable, Sendable {
    case commandWaiter
    case explicitObserver
    case livePrewarm
}

public struct PreparationWaitEntry: Equatable, Sendable {
    public let waitID: String
    public let ownerClientInstanceID: CanonicalUUID
    public let key: PreparationAttemptKey
    public let demand: PreparationDemandDescriptor
    public let kind: PreparationWaitKind
    public let capabilityWaiter: CapabilityGateWaiter?

    public init(
        waitID: String,
        ownerClientInstanceID: CanonicalUUID,
        key: PreparationAttemptKey,
        demand: PreparationDemandDescriptor,
        kind: PreparationWaitKind,
        capabilityWaiter: CapabilityGateWaiter? = nil
    ) throws {
        guard PreparationAttemptKey.validIdentifier(waitID) else {
            throw PreparationWaitRegistryError.invalidIdentifier
        }
        guard demand.preparationGroupID == key.preparationGroupID else {
            throw PreparationWaitRegistryError.invalidDemand
        }
        switch kind {
        case .commandWaiter:
            guard demand.origin == .finiteCommand,
                  demand.persistence == .epochBound,
                  capabilityWaiter != nil
            else {
                throw PreparationWaitRegistryError.invalidDemand
            }
        case .explicitObserver:
            guard demand.origin == .explicitPrepare,
                  demand.persistence == .epochBound,
                  capabilityWaiter == nil
            else {
                throw PreparationWaitRegistryError.invalidDemand
            }
        case .livePrewarm:
            guard demand.origin == .livePrewarm,
                  demand.persistence == .persistentAcrossReconnect,
                  capabilityWaiter == nil
            else {
                throw PreparationWaitRegistryError.invalidDemand
            }
        }
        self.waitID = waitID
        self.ownerClientInstanceID = ownerClientInstanceID
        self.key = key
        self.demand = demand
        self.kind = kind
        self.capabilityWaiter = capabilityWaiter
    }

    fileprivate var isExternal: Bool {
        kind != .livePrewarm
    }
}

public enum PreparationRegistrationDisposition: Equatable, Sendable {
    case startSharedAttempt(PreparationAttemptKey, referenceCount: Int)
    case joinedSharedAttempt(PreparationAttemptKey, referenceCount: Int)
}

public enum PreparationAttemptResolution: Equatable, Sendable {
    case ready
    case unavailable(reason: String)
    case deviceDisconnected
}

public enum PreparationWaitCompletion: Equatable, Sendable {
    case resumePlanning(
        waitID: String,
        waiter: CapabilityGateWaiter,
        resolution: PreparationAttemptResolution
    )
    case observerTerminal(
        waitID: String,
        resolution: PreparationAttemptResolution
    )
}

public struct PreparationAttemptCompletion: Equatable, Sendable {
    public let completions: [PreparationWaitCompletion]
    public let persistentReferenceCount: Int
}

public struct PreparationWaitRemoval: Equatable, Sendable {
    public let removed: PreparationWaitEntry
    public let sharedAttemptContinues: Bool
    public let remainingReferenceCount: Int
}

public struct PreparationWaitRegistrySnapshot: Equatable, Sendable {
    public let externalEntryCount: Int
    public let livePrewarmRegistered: Bool
    public let entries: [PreparationWaitEntry]
    public let activeAttemptKeys: [PreparationAttemptKey]
}

public struct PreparationWaitRegistry: Sendable {
    public static let maximumExternalEntryCount = 64

    private var entries = [String: PreparationWaitEntry]()
    private var activeAttemptKeys = Set<PreparationAttemptKey>()

    public init() {}

    public var snapshot: PreparationWaitRegistrySnapshot {
        PreparationWaitRegistrySnapshot(
            externalEntryCount: externalEntryCount,
            livePrewarmRegistered: entries.values.contains {
                $0.kind == .livePrewarm
            },
            entries: entries.values.sorted {
                $0.waitID.utf8.lexicographicallyPrecedes($1.waitID.utf8)
            },
            activeAttemptKeys: activeAttemptKeys.sorted {
                $0.stableSortKey.lexicographicallyPrecedes($1.stableSortKey)
            }
        )
    }

    public mutating func register(
        _ entry: PreparationWaitEntry
    ) throws -> PreparationRegistrationDisposition {
        guard entries[entry.waitID] == nil else {
            throw PreparationWaitRegistryError.duplicateWaitID
        }
        if entry.kind == .livePrewarm {
            guard !snapshot.livePrewarmRegistered else {
                throw PreparationWaitRegistryError.livePrewarmAlreadyRegistered
            }
        } else {
            guard externalEntryCount < Self.maximumExternalEntryCount else {
                throw PreparationWaitRegistryError.capacityExceeded(
                    PreparationWaitCapacityDetails()
                )
            }
        }
        entries[entry.waitID] = entry
        let count = referenceCount(for: entry.key)
        if activeAttemptKeys.contains(entry.key) {
            return .joinedSharedAttempt(entry.key, referenceCount: count)
        }
        activeAttemptKeys.insert(entry.key)
        return .startSharedAttempt(entry.key, referenceCount: count)
    }

    public mutating func registerDormantLivePrewarm(
        _ entry: PreparationWaitEntry
    ) throws {
        guard entry.kind == .livePrewarm else {
            throw PreparationWaitRegistryError.invalidDemand
        }
        guard entries[entry.waitID] == nil else {
            throw PreparationWaitRegistryError.duplicateWaitID
        }
        guard !snapshot.livePrewarmRegistered else {
            throw PreparationWaitRegistryError.livePrewarmAlreadyRegistered
        }
        entries[entry.waitID] = entry
    }

    public mutating func restartAttemptIfReferenced(
        key: PreparationAttemptKey
    ) -> PreparationRegistrationDisposition? {
        let count = referenceCount(for: key)
        guard count > 0 else { return nil }
        if activeAttemptKeys.contains(key) {
            return .joinedSharedAttempt(key, referenceCount: count)
        }
        activeAttemptKeys.insert(key)
        return .startSharedAttempt(key, referenceCount: count)
    }

    public mutating func cancelAttemptStart(
        key: PreparationAttemptKey
    ) throws {
        guard activeAttemptKeys.remove(key) != nil else {
            throw PreparationWaitRegistryError.attemptNotActive
        }
    }

    public mutating func remove(
        waitID: String
    ) throws -> PreparationWaitRemoval {
        guard let entry = entries.removeValue(forKey: waitID) else {
            throw PreparationWaitRegistryError.unknownWaitID
        }
        return PreparationWaitRemoval(
            removed: entry,
            sharedAttemptContinues: activeAttemptKeys.contains(entry.key),
            remainingReferenceCount: referenceCount(for: entry.key)
        )
    }

    public mutating func completeAttempt(
        key: PreparationAttemptKey,
        resolution: PreparationAttemptResolution
    ) throws -> PreparationAttemptCompletion {
        guard activeAttemptKeys.remove(key) != nil else {
            throw PreparationWaitRegistryError.attemptNotActive
        }
        let matching = entries.values
            .filter { $0.key == key && $0.isExternal }
            .sorted { $0.waitID.utf8.lexicographicallyPrecedes($1.waitID.utf8) }
        var completions = [PreparationWaitCompletion]()
        for entry in matching {
            entries.removeValue(forKey: entry.waitID)
            switch entry.kind {
            case .commandWaiter:
                completions.append(
                    .resumePlanning(
                        waitID: entry.waitID,
                        waiter: entry.capabilityWaiter!,
                        resolution: resolution
                    )
                )
            case .explicitObserver:
                completions.append(
                    .observerTerminal(
                        waitID: entry.waitID,
                        resolution: resolution
                    )
                )
            case .livePrewarm:
                preconditionFailure("live prewarm is not an external completion")
            }
        }
        return PreparationAttemptCompletion(
            completions: completions,
            persistentReferenceCount: referenceCount(for: key)
        )
    }

    public mutating func detach(
        runtimeEpoch: UInt64,
        connectionEpoch: UInt64
    ) -> [PreparationWaitCompletion] {
        let keys = activeAttemptKeys.filter {
            $0.runtimeEpoch == runtimeEpoch
                && $0.connectionEpoch == connectionEpoch
        }
        activeAttemptKeys.subtract(keys)
        let matching = entries.values
            .filter {
                $0.key.runtimeEpoch == runtimeEpoch
                    && $0.key.connectionEpoch == connectionEpoch
                    && $0.demand.persistence == .epochBound
            }
            .sorted { $0.waitID.utf8.lexicographicallyPrecedes($1.waitID.utf8) }
        return matching.compactMap { entry in
            entries.removeValue(forKey: entry.waitID)
            switch entry.kind {
            case .commandWaiter:
                return .resumePlanning(
                    waitID: entry.waitID,
                    waiter: entry.capabilityWaiter!,
                    resolution: .deviceDisconnected
                )
            case .explicitObserver:
                return .observerTerminal(
                    waitID: entry.waitID,
                    resolution: .deviceDisconnected
                )
            case .livePrewarm:
                return nil
            }
        }
    }

    public mutating func rebindLivePrewarm(
        connectionEpoch: UInt64
    ) throws -> PreparationRegistrationDisposition {
        guard let current = entries.values.first(where: {
            $0.kind == .livePrewarm
        }) else {
            throw PreparationWaitRegistryError.noLivePrewarm
        }
        let reboundKey = try PreparationAttemptKey(
            runtimeEpoch: current.key.runtimeEpoch,
            connectionEpoch: connectionEpoch,
            preparationGroupID: current.key.preparationGroupID
        )
        let rebound = try PreparationWaitEntry(
            waitID: current.waitID,
            ownerClientInstanceID: current.ownerClientInstanceID,
            key: reboundKey,
            demand: current.demand,
            kind: .livePrewarm
        )
        entries[current.waitID] = rebound
        if activeAttemptKeys.contains(reboundKey) {
            return .joinedSharedAttempt(
                reboundKey,
                referenceCount: referenceCount(for: reboundKey)
            )
        }
        activeAttemptKeys.insert(reboundKey)
        return .startSharedAttempt(
            reboundKey,
            referenceCount: referenceCount(for: reboundKey)
        )
    }

    private var externalEntryCount: Int {
        entries.values.reduce(into: 0) {
            if $1.isExternal { $0 += 1 }
        }
    }

    private func referenceCount(for key: PreparationAttemptKey) -> Int {
        entries.values.reduce(into: 0) {
            if $1.key == key { $0 += 1 }
        }
    }
}
