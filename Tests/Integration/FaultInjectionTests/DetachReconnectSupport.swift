import Foundation
import PulsePhoneBackendAdapters
import PulsePhoneCommandCatalog
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneMedia
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions

func faultRepositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

func faultFixture(_ requirementID: String) throws -> FixtureCaseBundleV1 {
    try FixtureCaseLoaderV1.load(
        requirementID: requirementID,
        repositoryRoot: faultRepositoryRoot()
    )
}

func faultCatalog() throws -> ExecutionProfileCatalogV1 {
    try ExecutionProfileCatalog.load(repositoryRoot: faultRepositoryRoot())
}

func faultUUID(_ value: Int) throws -> CanonicalUUID {
    try CanonicalUUID(
        String(format: "00000000-0000-0000-0000-%012x", value)
    )
}

func faultSeed(_ value: Int) throws -> PreparationAttemptSeed {
    PreparationAttemptSeed(
        preparationAttemptID: try faultUUID(value),
        inhibitorTokenID: try faultUUID(value + 10_000)
    )
}

func faultObserverContext(_ value: Int) throws -> PrepareObserverContext {
    PrepareObserverContext(
        requestID: try faultUUID(value + 20_000),
        actionID: try faultUUID(value + 30_000)
    )
}

func faultExplicitSpec(
    catalog: ExecutionProfileCatalogV1,
    value: Int
) throws -> DemandSpec {
    try DemandSpec.explicitPrepare(
        observerID: faultUUID(value),
        ownerClientInstanceID: faultUUID(value + 1_000),
        osMajor: 26,
        executionCatalog: catalog
    )
}

func faultLiveSpec(
    catalog: ExecutionProfileCatalogV1,
    value: Int
) throws -> DemandSpec {
    try DemandSpec.livePrewarm(
        demandID: faultUUID(value),
        ownerClientInstanceID: faultUUID(value + 1_000),
        osMajor: 26,
        executionCatalog: catalog
    )
}

func faultInstant(_ nanoseconds: UInt64) -> MonotonicInstant {
    MonotonicInstant(nanoseconds: nanoseconds)
}

func faultCoreDemand(
    _ origin: PreparationDemandOrigin
) -> PreparationDemandDescriptor {
    PreparationDemandDescriptor(
        origin: origin,
        persistence: origin == .livePrewarm
            ? .persistentAcrossReconnect
            : .epochBound,
        preparationGroupID: CoreDeviceGenerationCoordinator
            .preparationGroupID
    )
}

func faultCoreServiceSet(_ revision: String) throws -> CoreDeviceServiceSet {
    try CoreDeviceServiceSet(
        surfaceRevision: revision,
        facets: CoreDeviceGenerationFacet.allCases
    )
}

func faultVideoResolution(
    target: CanonicalUDID,
    sourceID: String,
    sourceEpoch: UInt64
) throws -> VideoSourceResolution {
    .mapped(VideoResolvedSource(
        canonicalUDID: target,
        descriptor: try VideoSourceDescriptor(
            sourceID: sourceID,
            sourceEpoch: sourceEpoch,
            activeFormatWidth: 1_920,
            activeFormatHeight: 1_080
        ),
        mappingProofID: "fault-fixture-proof"
    ))
}
