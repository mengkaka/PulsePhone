public enum EvidenceContractHardCaps {
    public static let normalizedRelativePathBytes = 1024
    public static let implementationGateDefinitionCount = 6
    public static let sourcePoliciesPerGate = 2
    public static let identityFieldsPerGatePolicy = 8
    public static let inputSlotsPerGatePolicy = 32
    public static let checksPerGatePolicy = 256
    public static let allowedPathRulesPerGatePolicy = 256
    public static let sourceSnapshotEntries = 65_536
    public static let artifactsPerGateInputSlot = 65_536
    public static let reasonCodesPerGateResult = 32
    public static let appBundleEntries = 65_536
    public static let releaseGateRequirements = 65_536
    public static let evidenceSelectionScenarios = 131_072
    public static let lineageSelectedEvidenceRuns = 65_536
    public static let releaseStageManifestHolds = 3
    public static let releaseHoldSetEntries = 65_539
    public static let appBundleContentManifestBytes = 32 * 1024 * 1024
    public static let otherCanonicalDocumentBytes = 64 * 1024 * 1024

    public static func accepts(count: Int, maximum: Int) -> Bool {
        count >= 0 && count <= maximum
    }

    public static func acceptsExact(count: Int, expected: Int) -> Bool {
        count == expected
    }
}

public extension StableBytes {
    static func isLowercaseHex(_ value: String, byteCount: Int) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == byteCount * 2
            && bytes.allSatisfy {
                (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
            }
    }
}

public struct EvidencePolicyIdentityV1: Equatable, Sendable {
    public let policyID: String
    public let hash: String

    public init(policyID: String, hash: String) throws {
        guard !policyID.isEmpty,
              policyID.utf8.count <= 128,
              StableBytes.isLowercaseHex(hash, byteCount: 32)
        else {
            throw ArtifactPathKeyError.invalidOpaqueID
        }
        self.policyID = policyID
        self.hash = hash
    }
}

public enum EvidenceOutcomeV1: String, CaseIterable, Sendable {
    case failed
    case passed
    case unknown

    public static func aggregate<S: Sequence>(_ outcomes: S) -> Self
    where S.Element == Self {
        if outcomes.contains(.failed) {
            return .failed
        }
        if outcomes.contains(.unknown) {
            return .unknown
        }
        return .passed
    }
}

public enum RepositoryWorktreeStateV1: String, Sendable {
    case clean
    case taskOwnedDirty
}

public struct RepositorySourceSnapshotShapeV1: Equatable, Sendable {
    public let worktreeState: RepositoryWorktreeStateV1
    public let entryCount: Int

    public init(
        worktreeState: RepositoryWorktreeStateV1,
        entryCount: Int
    ) throws {
        guard EvidenceContractHardCaps.accepts(
            count: entryCount,
            maximum: EvidenceContractHardCaps.sourceSnapshotEntries
        ), (worktreeState == .clean) == (entryCount == 0)
        else {
            throw RepositoryContractArtifactSetError.invalidIdentifier
        }
        self.worktreeState = worktreeState
        self.entryCount = entryCount
    }
}
