import Foundation
import PulsePhoneCLI
import PulsePhoneClientCore
import PulsePhoneSharedDefinitions
import XCTest

final class RuntimeStatusAndStopTests: XCTestCase {
    func testFullLiteNotRunningBusyAndPreparationProjection() throws {
        let identity = compatibility("a")
        let probes = [
            RuntimeStatusProbe(
                canonicalUDID: try CanonicalUDID(canonicalString: "A"),
                kind: .full(RuntimeFullStatus(
                    compatibility: identity,
                    preparations: [],
                    runtimeEpoch: 1
                ))
            ),
            RuntimeStatusProbe(
                canonicalUDID: try CanonicalUDID(canonicalString: "B"),
                kind: .full(RuntimeFullStatus(
                    compatibility: identity,
                    preparations: [RuntimePreparationProjection(
                        preparationGroupID: "prep.coredevice.v2",
                        state: "mounting"
                    )],
                    runtimeEpoch: 2
                ))
            ),
            RuntimeStatusProbe(
                canonicalUDID: try CanonicalUDID(canonicalString: "C"),
                kind: .lite(RuntimeLiteStatus(
                    canonicalUDID: try CanonicalUDID(canonicalString: "C"),
                    compatibility: compatibility("b"),
                    runtimeEpoch: 3,
                    blockers: [],
                    socketBasenameMatchesTarget: true
                ))
            ),
            RuntimeStatusProbe(
                canonicalUDID: try CanonicalUDID(canonicalString: "D"),
                kind: .noSocket(.absent)
            ),
            RuntimeStatusProbe(
                canonicalUDID: try CanonicalUDID(canonicalString: "E"),
                kind: .noSocket(.exiting)
            ),
        ]
        let aggregate = try RuntimeStatusAggregator.aggregate(
            probes,
            expectedCompatibility: identity
        )
        XCTAssertEqual(aggregate.targets.map(\.state), [
            "full",
            "fullPreparing",
            "incompatible",
            "notRunning",
            "generationBusy:runtimeExiting",
        ])
    }

    func testLiteMustMatchTargetAndSocketIdentity() throws {
        let target = try CanonicalUDID(canonicalString: "A")
        let mismatch = RuntimeStatusProbe(
            canonicalUDID: target,
            kind: .lite(RuntimeLiteStatus(
                canonicalUDID: try CanonicalUDID(canonicalString: "B"),
                compatibility: compatibility("a"),
                runtimeEpoch: 1,
                blockers: [],
                socketBasenameMatchesTarget: true
            ))
        )
        XCTAssertThrowsError(try RuntimeStatusAggregator.aggregate(
            [mismatch],
            expectedCompatibility: compatibility("a")
        )) { error in
            XCTAssertEqual(
                error as? RuntimeStatusAggregationError,
                .liteTargetMismatch
            )
        }
    }

    func testGlobalTargetCapIsSortedAndTruncated() throws {
        let identity = compatibility("a")
        let probes = try (0..<260).map { index in
            RuntimeStatusProbe(
                canonicalUDID: try CanonicalUDID(canonicalString:
                    String(format: "T%03d", 259 - index)
                ),
                kind: .noSocket(.absent)
            )
        }
        let result = try RuntimeStatusAggregator.aggregate(
            probes,
            expectedCompatibility: identity
        )
        XCTAssertEqual(result.targets.count, 256)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.targets.first?.canonicalUDID, "T000")
        XCTAssertEqual(result.targets.last?.canonicalUDID, "T255")
        XCTAssertEqual(RuntimeStatusAggregator.maximumFanout, 8)
        XCTAssertEqual(RuntimeStatusAggregator.maximumItemBytes, 2 * 1_024)
        XCTAssertEqual(RuntimeStatusAggregator.maximumResultBytes, 1_024 * 1_024)
    }

    func testDuplicateTargetsAreRejected() throws {
        let target = try CanonicalUDID(canonicalString: "A")
        let probe = RuntimeStatusProbe(
            canonicalUDID: target,
            kind: .noSocket(.absent)
        )
        XCTAssertThrowsError(try RuntimeStatusAggregator.aggregate(
            [probe, probe],
            expectedCompatibility: compatibility("a")
        )) { error in
            XCTAssertEqual(
                error as? RuntimeStatusAggregationError,
                .duplicateTarget
            )
        }
    }

    func testAggregateExitPriorityIsInterruptedUnknownPartialSuccess() {
        let completed = AggregateTargetInput(
            canonicalUDID: "A",
            disposition: .completed
        )
        let partial = AggregateTargetInput(
            canonicalUDID: "B",
            disposition: .notSubmitted
        )
        let unknown = AggregateTargetInput(
            canonicalUDID: "C",
            disposition: .mutatingSubmittedOutcomeUnknown
        )
        let interrupted = AggregateTargetInput(
            canonicalUDID: "D",
            disposition: .interrupted
        )
        XCTAssertEqual(
            RuntimeStatusAggregator.projectDispositions([completed]).exitCode,
            0
        )
        XCTAssertEqual(
            RuntimeStatusAggregator.projectDispositions([completed, partial]).exitCode,
            6
        )
        XCTAssertEqual(
            RuntimeStatusAggregator.projectDispositions(
                [completed, partial, unknown]
            ).exitCode,
            7
        )
        XCTAssertEqual(
            RuntimeStatusAggregator.projectDispositions(
                [completed, partial, unknown, interrupted]
            ).exitCode,
            130
        )
    }

    func testAggregateTargetPartialOutcomeFixture() throws {
        let root = repositoryRoot()
        let fixture = root.appendingPathComponent(
            "Fixtures/requirements/T-012/aggregate-target-partial-outcome-l3"
        )
        let inputBytes = [UInt8](try Data(contentsOf:
            fixture.appendingPathComponent("input/input.v1.json")
        ))
        let expectedBytes = [UInt8](try Data(contentsOf:
            fixture.appendingPathComponent("expected.v1.json")
        ))
        _ = try RepositoryCanonicalJSON.parseDocument(
            inputBytes,
            maximumByteCount: 64 * 1_024
        )
        _ = try RepositoryCanonicalJSON.parseDocument(
            expectedBytes,
            maximumByteCount: 64 * 1_024
        )
        let input = try JSONDecoder().decode(
            AggregateFixtureInput.self,
            from: Data(inputBytes)
        )
        let expected = try JSONDecoder().decode(
            AggregateDispositionProjection.self,
            from: Data(expectedBytes)
        )
        XCTAssertEqual(
            RuntimeStatusAggregator.projectDispositions(input.targets),
            expected
        )
    }

    func testRuntimeStatusCommandRendersDeviceAndGlobal() throws {
        let identity = compatibility("a")
        let provider = StatusProvider(probes: [RuntimeStatusProbe(
            canonicalUDID: try CanonicalUDID(canonicalString: "A"),
            kind: .noSocket(.absent)
        )])
        let command = RuntimeStatusCommand(
            compatibility: identity,
            provider: provider
        )
        let global = try command.runGlobal(outputMode: .json)
        XCTAssertTrue(global.chunk.stdout[0].contains("notRunning"))
        let device = try command.runDevice(
            canonicalUDID: try CanonicalUDID(canonicalString: "A"),
            outputMode: .human
        )
        XCTAssertEqual(device.chunk.stdout, ["A: notRunning"])
    }

    func testStopWaitsForEOFAndRuntimeLockRelease() throws {
        let target = try CanonicalUDID(canonicalString: "A")
        let backend = RecordingStopBackend(states: [.compatible])
        let output = try RuntimeStopCommand(backend: backend).run(
            canonicalUDID: target,
            outputMode: .human
        )
        XCTAssertEqual(output.chunk.stdout, ["Stopped"])
        XCTAssertEqual(backend.events, [
            "bootstrapLock",
            "recheck:compatible",
            "request:stopIfIdle",
            "socketEOF",
            "runtimeLockReleased",
        ])
    }

    func testStopUsesLiteRetireAndBusyRecoveryWithoutSpawn() throws {
        let target = try CanonicalUDID(canonicalString: "A")
        let incompatible = RecordingStopBackend(states: [.incompatible])
        _ = try RuntimeStopCommand(backend: incompatible).run(
            canonicalUDID: target,
            outputMode: .json
        )
        XCTAssertTrue(incompatible.events.contains("request:retireIfIdle"))

        let recovering = RecordingStopBackend(states: [.orphanHelpers, .absent])
        let output = try RuntimeStopCommand(backend: recovering).run(
            canonicalUDID: target,
            outputMode: .human
        )
        XCTAssertEqual(output.chunk.stdout, ["Already stopped"])
        XCTAssertEqual(recovering.waitCount, 1)
    }

    func testStopIdentityUnknownFailsClosedWithoutRecovery() throws {
        let target = try CanonicalUDID(canonicalString: "A")
        let backend = RecordingStopBackend(states: [.identityUnknown])
        XCTAssertThrowsError(try RuntimeStopCommand(backend: backend).run(
            canonicalUDID: target,
            outputMode: .human
        )) { error in
            XCTAssertEqual(
                error as? RuntimeStopCommandError,
                .generationBusy(.identityUnknown)
            )
        }
        XCTAssertEqual(backend.events, [
            "bootstrapLock",
            "recheck:identityUnknown",
        ])
        XCTAssertEqual(backend.waitCount, 0)
    }

    func testStopRequiresSocketEOFBeforeRuntimeLockProbe() throws {
        let target = try CanonicalUDID(canonicalString: "A")
        let backend = RecordingStopBackend(
            states: [.compatible],
            socketEOF: false
        )
        XCTAssertThrowsError(try RuntimeStopCommand(backend: backend).run(
            canonicalUDID: target,
            outputMode: .human
        )) { error in
            XCTAssertEqual(
                error as? RuntimeStopCommandError,
                .socketDidNotClose
            )
        }
        XCTAssertEqual(backend.events, [
            "bootstrapLock",
            "recheck:compatible",
            "request:stopIfIdle",
            "socketEOF",
        ])
    }

    func testStopRequiresRuntimeLockReleaseBeforeStopped() throws {
        let target = try CanonicalUDID(canonicalString: "A")
        let backend = RecordingStopBackend(
            states: [.compatible],
            runtimeLockReleased: false
        )
        XCTAssertThrowsError(try RuntimeStopCommand(backend: backend).run(
            canonicalUDID: target,
            outputMode: .human
        )) { error in
            XCTAssertEqual(
                error as? RuntimeStopCommandError,
                .runtimeLockStillBusy
            )
        }
        XCTAssertEqual(backend.events.last, "runtimeLockReleased")
    }

    private func compatibility(_ value: Character) -> RuntimeStatusCompatibilityIdentity {
        RuntimeStatusCompatibilityIdentity(
            runtimeCompatibilityID: "runtime.v1.\(value)",
            executionCatalogHash: String(repeating: value, count: 64),
            developerImageCatalogRevision: "catalog.v1.\(value)",
            developerImageCatalogHash: String(repeating: value, count: 64)
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct AggregateFixtureInput: Decodable {
    let targets: [AggregateTargetInput]
}

private struct StatusProvider: RuntimeStatusProviding {
    let probes: [RuntimeStatusProbe]

    func globalProbes() throws -> [RuntimeStatusProbe] { probes }

    func deviceProbe(
        canonicalUDID: CanonicalUDID
    ) throws -> RuntimeStatusProbe {
        try XCTUnwrap(probes.first { $0.canonicalUDID == canonicalUDID })
    }
}

private final class RecordingStopBackend: RuntimeStopBackend, @unchecked Sendable {
    private var states: [RuntimeStopGenerationState]
    private let runtimeLockReleased: Bool
    private let socketEOF: Bool
    private(set) var events = [String]()
    private(set) var waitCount = 0

    init(
        states: [RuntimeStopGenerationState],
        socketEOF: Bool = true,
        runtimeLockReleased: Bool = true
    ) {
        self.states = states
        self.socketEOF = socketEOF
        self.runtimeLockReleased = runtimeLockReleased
    }

    func acquireBootstrapLock(canonicalUDID: CanonicalUDID) throws {
        events.append("bootstrapLock")
    }

    func releaseBootstrapLock() {}

    func recheck(
        canonicalUDID: CanonicalUDID
    ) throws -> RuntimeStopGenerationState {
        let state = states.removeFirst()
        events.append("recheck:\(state)")
        return state
    }

    func waitOrRecover(
        canonicalUDID: CanonicalUDID,
        state: RuntimeStopGenerationState
    ) throws -> Bool {
        waitCount += 1
        events.append("waitOrRecover:\(state)")
        return true
    }

    func requestStop(
        canonicalUDID: CanonicalUDID,
        kind: RuntimeStopRequestKind
    ) throws -> Bool {
        events.append("request:\(kind)")
        return true
    }

    func waitForSocketEOF(canonicalUDID: CanonicalUDID) throws -> Bool {
        events.append("socketEOF")
        return socketEOF
    }

    func probeRuntimeLockReleased(
        canonicalUDID: CanonicalUDID
    ) throws -> Bool {
        events.append("runtimeLockReleased")
        return runtimeLockReleased
    }
}
