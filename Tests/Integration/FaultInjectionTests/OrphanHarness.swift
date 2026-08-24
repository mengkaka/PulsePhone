import Darwin
@testable import PulsePhoneRuntimeKernel
import PulsePhoneSharedDefinitions

func faultRuntimeIdentity() -> RuntimeRecoveryIdentity {
    RuntimeRecoveryIdentity(
        executablePath: "/runtime",
        pid: 700,
        processStartIdentity: HelperProcessStartIdentity(
            seconds: 11,
            microseconds: 12
        )
    )
}

func faultHelperRecord(
    id: String,
    pid: pid_t
) -> HelperStateRecord {
    HelperStateRecord(
        helperID: id,
        role: "direct",
        executorID: "executor.direct",
        executorGeneration: 1,
        processIdentity: HelperProcessIdentity(
            pid: pid,
            processGroupID: pid,
            processStartIdentity: HelperProcessStartIdentity(
                seconds: UInt64(pid),
                microseconds: 1
            ),
            executablePath: "/helpers/\(id)"
        )
    )
}

func faultManifest(
    helpers: [HelperStateRecord]
) -> HelperStateManifest {
    HelperStateManifest(
        runtimeEpoch: 7,
        canonicalUDIDHash: String(repeating: "a", count: 64),
        ownerUID: 501,
        runtimePID: 700,
        runtimeProcessStartIdentity: HelperProcessStartIdentity(
            seconds: 11,
            microseconds: 12
        ),
        helpers: helpers
    )
}

func faultOrphanRecovery(
    system: ScriptedRuntimeRecoverySystem,
    maximumPollAttempts: Int = 4
) -> OrphanRecovery {
    let poller = DeterministicRecoveryPoller(
        maximumAttempts: maximumPollAttempts
    )
    return OrphanRecovery(
        processSystem: system,
        processRecovery: VerifiedProcessRecovery(
            processSystem: system,
            poller: poller,
            gracefulExitTimeout: MonotonicDuration(nanoseconds: 1),
            forcedExitTimeout: MonotonicDuration(nanoseconds: 1)
        ),
        poller: poller,
        controlledExitTimeout: MonotonicDuration(nanoseconds: 1),
        lockReleaseTimeout: MonotonicDuration(nanoseconds: 1)
    )
}
