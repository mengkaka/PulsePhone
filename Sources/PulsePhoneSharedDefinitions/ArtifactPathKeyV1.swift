public enum ArtifactPathDomainV1: String, CaseIterable, Sendable {
    case broadOSCoverageSet
    case developmentCandidateInput
    case evidenceReleaseHold
    case evidenceRunPackage
    case evidenceRunValidation
    case evidenceSelectionSet
    case evidenceStoreRecord
    case formalAttemptLedgerWAL
    case negativeRemovalWriteGrant
    case performanceThresholdDecision
    case releaseCandidateAppTree
    case releaseCandidateInput
    case releaseFlow
    case releaseGateProfile
    case releaseHoldSet
    case releaseStagePackage
    case releaseStageValidation
    case stageGateOutcomeReport
}

public enum ArtifactPathKeyError: Error, Equatable, Sendable {
    case invalidOpaqueID
}

public struct ArtifactPathKeyV1: Equatable, Sendable {
    public static let domainID = "pulsephone.artifact-path-key.v1"

    public let schemaVersion: UInt64
    public let artifactDomain: ArtifactPathDomainV1
    public let opaqueID: String

    public init(artifactDomain: ArtifactPathDomainV1, opaqueID: String) throws {
        let bytes = Array(opaqueID.utf8)
        guard !bytes.isEmpty,
              bytes.count <= 128,
              bytes.allSatisfy({ (0x21...0x7e).contains($0) }),
              !opaqueID.contains("/"),
              !opaqueID.contains("\\"),
              !opaqueID.contains("://")
        else {
            throw ArtifactPathKeyError.invalidOpaqueID
        }
        self.schemaVersion = 1
        self.artifactDomain = artifactDomain
        self.opaqueID = opaqueID
    }

    public var pathKey: String {
        get throws {
            let object = RepositoryJSONObject(validatedMembers: [
                RepositoryJSONMember(
                    key: "artifactDomain",
                    value: .string(artifactDomain.rawValue)
                ),
                RepositoryJSONMember(key: "opaqueID", value: .string(opaqueID)),
                RepositoryJSONMember(
                    key: "schemaVersion",
                    value: .number(.uint64(schemaVersion))
                ),
            ])
            return try StableBytes.domainSeparatedSHA256Hex(
                domainID: Self.domainID,
                payload: RepositoryCanonicalJSON.encodeDocument(object)
            )
        }
    }
}
