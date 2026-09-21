import Dispatch
import XCTest
@testable import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions

final class RuntimeLifecycleControllerTests: XCTestCase {
    func testLastBlockerReleaseStartsFreshGracePeriod() throws {
        let schedule = ScheduledWorkStore()
        let clock = IdleTestClock()
        let fired = LockedInt()
        let controller = RuntimeLifecycleController(
            clock: clock, idleGraceNanoseconds: 600,
            schedule: { _, item in schedule.append(item) },
            automaticIdle: { fired.increment() }
        )
        controller.runtimeReady()
        XCTAssertEqual(schedule.count, 1)
        let live = try controller.attachLive(
            liveOwnerID: try uuid(1),
            subscriptionID: try uuid(2)
        )
        XCTAssertEqual(schedule.count, 1)
        clock.set(3_600)
        try controller.release(live)
        XCTAssertEqual(schedule.count, 2)
        XCTAssertEqual(controller.idleDeadline?.nanoseconds, 4_200)
        clock.set(4_199)
        schedule.last?.perform()
        XCTAssertEqual(fired.value, 0)
        clock.set(4_200)
        schedule.last?.perform()
        XCTAssertEqual(fired.value, 1)
    }

    func testActivityRestartsGraceAndBlockersSuppressTimer() throws {
        let schedule = ScheduledWorkStore()
        let clock = IdleTestClock()
        let fired = LockedInt()
        let controller = RuntimeLifecycleController(
            clock: clock, idleGraceNanoseconds: 600,
            schedule: { _, item in schedule.append(item) },
            automaticIdle: { fired.increment() }
        )
        controller.runtimeReady()
        clock.set(200)
        controller.recordActivity(.validatedCLICommandIntent)
        XCTAssertEqual(schedule.count, 2)
        XCTAssertEqual(controller.idleDeadline?.nanoseconds, 800)
        let stream = try controller.openStream(
            sessionID: try uuid(3),
            interactionID: try uuid(4),
            commandID: "gui.pointer.interaction"
        )
        XCTAssertEqual(schedule.count, 2)
        clock.set(900)
        schedule.items[1].perform()
        XCTAssertEqual(fired.value, 0)
        try controller.release(stream)
        XCTAssertEqual(schedule.count, 3)
        XCTAssertEqual(controller.idleDeadline?.nanoseconds, 1_500)
    }

    func testQuiescingRejectsNewBlockersAndStopsOnlyOnce() throws {
        let schedule = ScheduledWorkStore()
        let fired = LockedInt()
        let controller = RuntimeLifecycleController(
            idleGraceNanoseconds: 10,
            schedule: { _, item in schedule.append(item) },
            automaticIdle: { fired.increment() }
        )
        controller.runtimeReady()
        XCTAssertTrue(controller.attemptStop())
        XCTAssertFalse(controller.attemptStop())
        XCTAssertThrowsError(
            try controller.attachLive(
                liveOwnerID: try uuid(5),
                subscriptionID: try uuid(6)
            )
        )
        schedule.last?.perform()
        XCTAssertEqual(fired.value, 0)
    }

    private func uuid(_ value: Int) throws -> CanonicalUUID {
        try CanonicalUUID(String(format: "00000000-0000-0000-0000-%012x", value))
    }

    func testEveryBlockerAndNestedReleaseSuppressesIdleAndManualStop() throws {
        for kind in ShutdownInhibitorKind.allCases {
            let schedule = ScheduledWorkStore()
            let clock = IdleTestClock()
            let fired = LockedInt()
            let controller = RuntimeLifecycleController(
                clock: clock, idleGraceNanoseconds: 600,
                schedule: { _, item in schedule.append(item) },
                automaticIdle: { fired.increment() }
            )
            controller.runtimeReady()
            let first = try controller.acquire(kind: kind)
            let second = try controller.acquire(kind: .cleanup)
            XCTAssertNil(controller.idleDeadline)
            XCTAssertFalse(controller.attemptStop())
            clock.set(3_600)
            schedule.last?.perform()
            try controller.release(first)
            XCTAssertNil(controller.idleDeadline)
            XCTAssertThrowsError(try controller.release(first))
            try controller.release(second)
            XCTAssertEqual(controller.idleDeadline?.nanoseconds, 4_200)
            clock.set(4_200)
            schedule.last?.perform()
            XCTAssertEqual(fired.value, 1, kind.rawValue)
            XCTAssertThrowsError(try controller.acquire(kind: kind))
        }
    }

    func testFailedAcquireDoesNotLosePendingTimerAndShutdownCancelsIt() throws {
        let schedule = ScheduledWorkStore()
        let clock = IdleTestClock()
        let fired = LockedInt()
        let controller = RuntimeLifecycleController(
            clock: clock, idleGraceNanoseconds: 600,
            schedule: { _, item in schedule.append(item) },
            automaticIdle: { fired.increment() }
        )
        controller.runtimeReady()
        XCTAssertThrowsError(try controller.acquire(kind: .runningJob, jobID: "/invalid"))
        XCTAssertEqual(controller.idleDeadline?.nanoseconds, 600)
        controller.shutdown()
        clock.set(1_000)
        schedule.last?.perform()
        XCTAssertEqual(fired.value, 0)
    }
}

private final class ScheduledWorkStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [DispatchWorkItem]()
    var items: [DispatchWorkItem] { lock.withLock { storage } }

    var count: Int { items.count }
    var last: DispatchWorkItem? { items.last }

    func append(_ item: DispatchWorkItem) {
        lock.withLock { storage.append(item) }
    }
}

private final class IdleTestClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: UInt64 = 0
    func now() -> MonotonicInstant { lock.withLock { MonotonicInstant(nanoseconds: instant) } }
    func set(_ value: UInt64) { lock.withLock { instant = value } }
}

private final class LockedInt: @unchecked Sendable {
    private var valueStorage = 0
    private let lock = NSLock()

    var value: Int { lock.withLock { valueStorage } }

    func increment() {
        lock.withLock { valueStorage += 1 }
    }
}
