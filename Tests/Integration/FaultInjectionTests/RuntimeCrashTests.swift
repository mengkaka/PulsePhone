import Darwin
@testable import PulsePhoneRuntimeKernel
import XCTest

final class RuntimeCrashTests: XCTestCase {
    func testRuntimeSingletonOrphanPIDReuseFixture() throws {
        let fixture = try faultFixture(
            "T-007/runtime-singleton-orphan-pid-reuse-l3"
        )
        let input = try fixture.decodeInput(RuntimeRecoveryFixtureInput.self)
        let expected = try fixture.decodeExpected(
            RuntimeRecoveryFixtureExpected.self
        )
        XCTAssertEqual(input.scenarios, [
            "expectedRemoval",
            "foreignNode",
            "orphanHelpers",
            "otherTargetEvent",
            "pidReuseIdentityMismatch",
            "socketDelete",
            "socketReplace",
            "watcherInvalidation",
        ])

        let mismatchSystem = ScriptedRuntimeRecoverySystem()
        mismatchSystem.helperObservations[501] = [.identityMismatch]
        let mismatchRecovery = VerifiedProcessRecovery(
            processSystem: mismatchSystem,
            poller: DeterministicRecoveryPoller(maximumAttempts: 1)
        )
        XCTAssertThrowsError(try mismatchRecovery.recover(helpers: [
            faultHelperRecord(id: "pid-reused", pid: 501),
        ])) { error in
            XCTAssertEqual(
                error as? VerifiedProcessRecoveryError,
                .identityMismatch
            )
        }
        XCTAssertTrue(mismatchSystem.signals.isEmpty)

        let recoverySystem = ScriptedRuntimeRecoverySystem()
        recoverySystem.runtimeObservations = [.gone]
        recoverySystem.helperObservations[601] = [.verified, .gone]
        var lockStates = [false, true, true, true, true]
        let result = try faultOrphanRecovery(system: recoverySystem).recover(
            runtimeIdentity: faultRuntimeIdentity(),
            manifest: faultManifest(helpers: [
                faultHelperRecord(id: "verified", pid: 601),
            ]),
            runtimeLockIsFree: {
                lockStates.removeFirst()
            }
        )
        XCTAssertEqual(
            result,
            .recoveredHelpers(VerifiedProcessRecoveryResult(
                killedCount: 0,
                terminatedCount: 1,
                verifiedCount: 1
            ))
        )
        XCTAssertEqual(recoverySystem.signals, [
            RecoverySignal(pid: 601, signal: SIGTERM),
        ])
        XCTAssertTrue(lockStates.count < 5)

        XCTAssertFalse(expected.foreignNodeMutationAllowed)
        XCTAssertFalse(expected.identityUnknownSignalAllowed)
        XCTAssertFalse(expected.otherTargetEventFails)
        XCTAssertFalse(expected.pidReuseSignalAllowed)
        XCTAssertTrue(expected.socketReplacementTriggersFailStop)
        XCTAssertFalse(expected.stableLockNodeRemoved)
        XCTAssertTrue(expected.verifiedOrphanRecoveryRequired)
        XCTAssertEqual(expected.expectedRemovalFailureCount, 0)
    }

    func testVerifiedSetIsClosedBeforeFirstSignal() throws {
        let system = ScriptedRuntimeRecoverySystem()
        system.helperObservations[701] = [.verified]
        system.helperObservations[702] = [.identityMismatch]
        let recovery = VerifiedProcessRecovery(
            processSystem: system,
            poller: DeterministicRecoveryPoller(maximumAttempts: 1)
        )
        XCTAssertThrowsError(try recovery.recover(helpers: [
            faultHelperRecord(id: "a", pid: 701),
            faultHelperRecord(id: "b", pid: 702),
        ]))
        XCTAssertTrue(system.signals.isEmpty)
    }

    func testReplacementWaitsForRuntimeLockReleaseBarrier() throws {
        let system = ScriptedRuntimeRecoverySystem()
        system.runtimeObservations = [.gone]
        var replacementStartCount = 0
        XCTAssertThrowsError(try faultOrphanRecovery(
            system: system,
            maximumPollAttempts: 2
        ).recover(
            runtimeIdentity: faultRuntimeIdentity(),
            manifest: faultManifest(helpers: []),
            runtimeLockIsFree: { false }
        )) { error in
            XCTAssertEqual(
                error as? OrphanRecoveryError,
                .orphanHelperGenerationBusy
            )
        }
        XCTAssertEqual(replacementStartCount, 0)

        system.runtimeObservations = [.gone]
        _ = try faultOrphanRecovery(system: system).recover(
            runtimeIdentity: faultRuntimeIdentity(),
            manifest: faultManifest(helpers: []),
            runtimeLockIsFree: { true }
        )
        replacementStartCount += 1
        XCTAssertEqual(replacementStartCount, 1)
    }
}

private struct RuntimeRecoveryFixtureInput: Decodable {
    let scenarios: [String]
}

private struct RuntimeRecoveryFixtureExpected: Decodable {
    let expectedRemovalFailureCount: Int
    let foreignNodeMutationAllowed: Bool
    let identityUnknownSignalAllowed: Bool
    let otherTargetEventFails: Bool
    let pidReuseSignalAllowed: Bool
    let socketReplacementTriggersFailStop: Bool
    let stableLockNodeRemoved: Bool
    let verifiedOrphanRecoveryRequired: Bool
}
