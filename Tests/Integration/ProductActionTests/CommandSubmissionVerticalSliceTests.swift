import Foundation
import PulsePhoneClientCore
import PulsePhoneCommandCatalog
import PulsePhoneCommandPlanner
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions
import XCTest

final class CommandSubmissionVerticalSliceTests: XCTestCase {
    func testClientPreparationReplanSchedulerHelperTerminalIsRepeatable() throws {
        let catalog = try loadCatalog()
        let runtime = VerticalSliceRuntime(catalog: catalog)
        let submitter = CommandSubmitter(runtime: runtime)

        let first = try submitter.submit(intent(1))
        let second = try submitter.submit(intent(2))

        XCTAssertEqual(stableShape(first.events), stableShape(second.events))
        XCTAssertNotEqual(
            preparationAttemptID(first.events),
            preparationAttemptID(second.events)
        )
        XCTAssertEqual(first.terminal.outcome, .succeeded)
        XCTAssertEqual(first.terminal.commitState, .committed)
        XCTAssertEqual(first.terminal.routeID, "coredevice.normalTouch")
        XCTAssertEqual(runtime.executionCount, 2)
        XCTAssertEqual(runtime.activeLeaseCount, 0)
    }

    func testStaleReplanAndDuplicateTerminalAreRejected() throws {
        var lifecycle = PreparationAwareSubmission()
        try lifecycle.consume(.accepted)
        try lifecycle.consume(.awaitingPreparation(
            preparationGroupIDs: ["prep.coredevice.v2"],
            sourceRevision: 1
        ))
        try lifecycle.consume(.preparationReady(
            preparationAttemptID: uuid(40),
            preparationGroupID: "prep.coredevice.v2"
        ))
        XCTAssertThrowsError(
            try lifecycle.consume(.authoritativePlan(
                routeID: "coredevice.normalTouch",
                sourceRevision: 1,
                resumedAfterPreparation: true
            ))
        ) { error in
            XCTAssertEqual(
                error as? PreparationAwareSubmissionError,
                .staleReplan
            )
        }

        let terminal = try CommandSubmissionTerminal(
            outcome: .succeeded,
            commitState: .committed,
            routeID: "coredevice.normalTouch"
        )
        let runtime = StaticRuntime(events: [
            .accepted,
            .authoritativePlan(
                routeID: "coredevice.normalTouch",
                sourceRevision: 1,
                resumedAfterPreparation: false
            ),
            .queued,
            .started(routeID: "coredevice.normalTouch"),
            .terminal(terminal),
            .terminal(terminal),
        ])
        XCTAssertThrowsError(try CommandSubmitter(runtime: runtime).submit(intent(3))) {
            XCTAssertEqual(
                $0 as? CommandSubmissionValidationError,
                .eventAfterTerminal
            )
        }
    }

    private func intent(_ value: Int) throws -> CommandSubmissionIntent {
        try CommandSubmissionIntent(
            requestID: uuid(100 + value),
            actionID: uuid(200 + value),
            canonicalUDID: CanonicalUDID(canonicalString: "AAAA"),
            commandID: "touch.tap",
            rawArguments: ["point": "0.5,0.25"]
        )
    }

    private func stableShape(
        _ events: [CommandSubmissionEvent]
    ) -> [String] {
        events.map { event in
            switch event {
            case .accepted:
                "accepted"
            case .awaitingPreparation(let groups, let revision):
                "awaiting:\(groups.joined(separator: ",")):\(revision)"
            case .preparationReady(_, let groupID):
                "ready:\(groupID)"
            case .authoritativePlan(let routeID, let revision, let resumed):
                "plan:\(routeID):\(revision):\(resumed)"
            case .queued:
                "queued"
            case .started(let routeID):
                "started:\(routeID)"
            case .terminal(let terminal):
                "terminal:\(terminal.outcome.rawValue):\(terminal.routeID ?? "")"
            }
        }
    }

    private func preparationAttemptID(
        _ events: [CommandSubmissionEvent]
    ) -> CanonicalUUID? {
        for event in events {
            if case .preparationReady(let identifier, _) = event {
                return identifier
            }
        }
        return nil
    }

    private func loadCatalog() throws -> ExecutionProfileCatalogV1 {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try ExecutionProfileCatalog.load(repositoryRoot: root)
    }

    private func uuid(_ value: Int) throws -> CanonicalUUID {
        try CanonicalUUID(
            String(format: "00000000-0000-0000-0000-%012x", value)
        )
    }
}

private final class VerticalSliceRuntime: CommandSubmissionRuntime,
    @unchecked Sendable
{
    private let catalog: ExecutionProfileCatalogV1
    private let lock = NSLock()
    private var nextAttempt = 1
    private var executions = 0
    private var activeLeases = 0

    init(catalog: ExecutionProfileCatalogV1) {
        self.catalog = catalog
    }

    var executionCount: Int {
        lock.withLock { executions }
    }

    var activeLeaseCount: Int {
        lock.withLock { activeLeases }
    }

    func submit(
        _ intent: CommandSubmissionIntent
    ) throws -> [CommandSubmissionEvent] {
        try lock.withLock {
            let planner = CommandPlanner(catalog: catalog)
            let initialContext = context(capabilitiesReady: false, revision: 1)
            guard case .awaitingPreparation(let waiting) = try planner.plan(
                commandID: intent.commandID,
                rawArguments: intent.rawArguments,
                context: initialContext
            ) else {
                throw HarnessError.expectedPreparation
            }
            let waiter = CapabilityGateWaiter(
                commandID: intent.commandID,
                rawArguments: intent.rawArguments,
                sourceRevisions: waiting.sourceRevisions
            )
            let demand = try DemandSpec.finiteCommand(
                waiterID: intent.requestID,
                ownerClientInstanceID: intent.actionID,
                candidatePreparationGroupID: waiting.preparationGroupIDs[0],
                capabilityWaiter: waiter,
                executionCatalog: catalog
            )
            let attemptValue = nextAttempt
            nextAttempt += 1
            var coordinator = PreparationCoordinator(
                runtimeEpoch: 9,
                connectionEpoch: 1,
                executionCatalog: catalog
            )
            guard case .started(let identity, _) = try coordinator.register(
                demand,
                at: instant(0),
                newAttempt: PreparationAttemptSeed(
                    preparationAttemptID: uuid(1_000 + attemptValue),
                    inhibitorTokenID: uuid(2_000 + attemptValue)
                )
            ) else {
                throw HarnessError.expectedAttempt
            }
            try coordinator.transitionAttempt(
                identity.key,
                to: .queryingMountedImage,
                at: instant(1)
            )
            let completion = try coordinator.completeAttempt(
                identity.key,
                resolution: .ready,
                at: instant(2)
            )
            guard case .resumePlanning(_, let resumedWaiter, .ready) =
                    completion.waitCompletions.first
            else {
                throw HarnessError.expectedWaiter
            }
            guard case .planned(let plan) = try CapabilityGate.resumePlanning(
                waiter: resumedWaiter,
                planner: planner,
                refreshedContext: context(
                    capabilitiesReady: true,
                    revision: 2
                )
            ), let candidate = plan.candidates.first
            else {
                throw HarnessError.expectedPlan
            }

            var scheduler = DeviceScheduler()
            let request = try SchedulerRequest(
                requestID: intent.requestID.description,
                claimantKind: .oneShot,
                phase: .running,
                materializedClaims: plan.commonClaims + candidate.candidateClaims
            )
            guard case .running(let lease) = try scheduler.submit(request) else {
                throw HarnessError.expectedLease
            }
            activeLeases += 1
            let terminal = try executeHelper(routeID: candidate.routeID)
            _ = try scheduler.release(requestID: lease.requestID)
            activeLeases -= 1

            return [
                .accepted,
                .awaitingPreparation(
                    preparationGroupIDs: waiting.preparationGroupIDs,
                    sourceRevision: waiting.sourceRevisions.capability
                ),
                .preparationReady(
                    preparationAttemptID: identity.preparationAttemptID,
                    preparationGroupID: identity.preparationGroupID
                ),
                .authoritativePlan(
                    routeID: candidate.routeID,
                    sourceRevision: plan.sourceRevisions.capability,
                    resumedAfterPreparation: true
                ),
                .queued,
                .started(routeID: candidate.routeID),
                .terminal(terminal),
            ]
        }
    }

    private func executeHelper(
        routeID: String
    ) throws -> CommandSubmissionTerminal {
        executions += 1
        return try CommandSubmissionTerminal(
            outcome: .succeeded,
            commitState: .committed,
            routeID: routeID
        )
    }

    private func context(
        capabilitiesReady: Bool,
        revision: UInt64
    ) -> RuntimePlanningContext {
        let group = catalog.preparationGroups.first {
            $0.preparationGroupID == "prep.coredevice.v2"
        }!
        return RuntimePlanningContext(
            capabilities: Dictionary(uniqueKeysWithValues:
                group.requiredCapabilityIDs.map {
                    ($0, capabilitiesReady ? .available : .unknown)
                }
            ),
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
            revisions: PlanningRevisions(
                capability: revision,
                condition: revision,
                connection: revision,
                geometry: revision,
                preparation: revision,
                quiescing: revision
            )
        )
    }

    private func instant(_ value: UInt64) -> MonotonicInstant {
        MonotonicInstant(nanoseconds: value * 1_000_000_000)
    }

    private func uuid(_ value: Int) throws -> CanonicalUUID {
        try CanonicalUUID(
            String(format: "00000000-0000-0000-0000-%012x", value)
        )
    }
}

private struct StaticRuntime: CommandSubmissionRuntime {
    let events: [CommandSubmissionEvent]

    func submit(
        _ intent: CommandSubmissionIntent
    ) throws -> [CommandSubmissionEvent] {
        _ = intent
        return events
    }
}

private enum HarnessError: Error {
    case expectedPreparation
    case expectedAttempt
    case expectedWaiter
    case expectedPlan
    case expectedLease
}
