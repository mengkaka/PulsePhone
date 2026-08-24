import Foundation
import PulsePhoneClientCore
import PulsePhoneGUI
import PulsePhoneSharedDefinitions
import XCTest

final class LiveOwnerTests: XCTestCase {
    func testRuntimeRegistryIsFinalCrossWindowOwnerBoundary() throws {
        var registry = LiveOwnerRegistry()
        var first = LiveOwnerCoordinator()
        var second = LiveOwnerCoordinator()
        let firstAttachment = try attachment(owner: 1, subscription: 2)
        let secondAttachment = try attachment(owner: 3, subscription: 4)

        XCTAssertEqual(first.attach(
            attachment: firstAttachment,
            clientInstanceID: try uuid(10),
            windowID: "window-a",
            registry: &registry
        ), .attached)
        XCTAssertEqual(second.attach(
            attachment: secondAttachment,
            clientInstanceID: try uuid(11),
            windowID: "window-b",
            registry: &registry
        ), .conflict(existingLiveOwnerID: firstAttachment.liveOwnerID))
        XCTAssertTrue(first.runtimeBackedControlEnabled)
        XCTAssertFalse(second.runtimeBackedControlEnabled)
        XCTAssertEqual(registry.ownerCount, 1)
    }

    func testCloseWaitsForOwnedStreamCleanupBeforeDetach() throws {
        var registry = LiveOwnerRegistry()
        var owner = LiveOwnerCoordinator()
        let current = try attachment(owner: 20, subscription: 21)
        _ = owner.attach(
            attachment: current,
            clientInstanceID: try uuid(22),
            windowID: "window-a",
            registry: &registry
        )
        let pointer = try uuid(23)
        let keyboard = try uuid(24)
        try owner.registerOwnedStream(pointer)
        try owner.registerOwnedStream(keyboard)

        let started = try owner.beginClose(atNanoseconds: 0)
        XCTAssertTrue(started.mediaStopped)
        XCTAssertEqual(started.pendingOwnedStreamCount, 2)
        XCTAssertFalse(started.acceptedOneShotCancellationRequested)
        XCTAssertThrowsError(try owner.detachRequest(atNanoseconds: 1)) {
            error in
            XCTAssertEqual(error as? LiveOwnerCoordinatorError, .streamsNotClean)
        }

        _ = try owner.completeOwnedStreamCleanup(
            pointer,
            atNanoseconds: 2
        )
        let cleaned = try owner.completeOwnedStreamCleanup(
            keyboard,
            atNanoseconds: 3
        )
        XCTAssertTrue(cleaned.readyForDetach)
        XCTAssertEqual(
            try owner.detachRequest(atNanoseconds: 4),
            LiveDetachRequest(attachment: current)
        )
        let detached = try owner.completeDetach(
            LiveDetachResult(detached: true),
            registry: &registry,
            atNanoseconds: 5
        )
        XCTAssertEqual(detached.stage, .closeConnection)
        XCTAssertEqual(registry.ownerCount, 0)
        XCTAssertEqual(
            try owner.completeConnectionClose(atNanoseconds: 6).stage,
            .completed
        )
        XCTAssertEqual(owner.state, .closed)
    }

    func testCompletedInteractionStreamIsReleasedWhileOwnerStaysAttached() throws {
        var registry = LiveOwnerRegistry()
        var owner = LiveOwnerCoordinator()
        _ = owner.attach(
            attachment: try attachment(owner: 25, subscription: 26),
            clientInstanceID: try uuid(27),
            windowID: "window-a",
            registry: &registry
        )
        let pointer = try uuid(28)
        try owner.registerOwnedStream(pointer)
        XCTAssertEqual(owner.ownedStreamCount, 1)

        try owner.completeOwnedStream(pointer)

        XCTAssertEqual(owner.ownedStreamCount, 0)
        XCTAssertTrue(owner.runtimeBackedControlEnabled)
        XCTAssertEqual(registry.ownerCount, 1)
    }

    func testCloseDeadlineIsStrictAndDoesNotReleaseOwnerEarly() throws {
        var registry = LiveOwnerRegistry()
        var owner = LiveOwnerCoordinator()
        _ = owner.attach(
            attachment: try attachment(owner: 30, subscription: 31),
            clientInstanceID: try uuid(32),
            windowID: "window-a",
            registry: &registry
        )
        _ = try owner.beginClose(atNanoseconds: 0)
        XCTAssertThrowsError(try owner.detachRequest(
            atNanoseconds: LiveCloseDeadline.durationNanoseconds
        )) { error in
            XCTAssertEqual(
                error as? LiveCloseError,
                .deadlineExceeded(stage: .detachLive)
            )
        }
        XCTAssertEqual(registry.ownerCount, 1)
    }

    func testUnconfirmedDetachDoesNotReleaseOwner() throws {
        var registry = LiveOwnerRegistry()
        var owner = LiveOwnerCoordinator()
        _ = owner.attach(
            attachment: try attachment(owner: 35, subscription: 36),
            clientInstanceID: try uuid(37),
            windowID: "window-a",
            registry: &registry
        )
        _ = try owner.beginClose(atNanoseconds: 0)
        XCTAssertThrowsError(try owner.completeDetach(
            LiveDetachResult(detached: false),
            registry: &registry,
            atNanoseconds: 1
        )) { error in
            XCTAssertEqual(
                error as? LiveOwnerCoordinatorError,
                .detachNotConfirmed
            )
        }
        XCTAssertEqual(registry.ownerCount, 1)
    }

    func testDetachIsIdempotentButStaleIdentityFailsClosed() throws {
        var registry = LiveOwnerRegistry()
        let current = try attachment(owner: 40, subscription: 41)
        let lease = LiveOwnerLease(
            attachment: current,
            clientInstanceID: try uuid(42),
            windowID: "window-a"
        )
        XCTAssertEqual(registry.attach(lease), .attached)
        XCTAssertTrue(try registry.detach(current))
        XCTAssertFalse(try registry.detach(current))

        XCTAssertEqual(registry.attach(lease), .attached)
        XCTAssertThrowsError(try registry.detach(try attachment(
            owner: 43,
            subscription: 44
        ))) { error in
            XCTAssertEqual(error as? LiveOwnerRegistryError, .staleDetach)
        }
    }

    func testAttachRequestFreezesUniqueObservationTopics() throws {
        let request = try LiveAttachRequest(
            canonicalUDID: CanonicalUDID(canonicalString: "A"),
            observationTopics: [.preparationStatus, .pointerProjection]
        )
        XCTAssertEqual(
            request.observationTopics,
            [.pointerProjection, .preparationStatus]
        )
        XCTAssertThrowsError(try LiveAttachRequest(
            canonicalUDID: CanonicalUDID(canonicalString: "A"),
            observationTopics: [.pointerProjection, .pointerProjection]
        )) { error in
            XCTAssertEqual(error as? LiveAttachError, .duplicateObservationTopic)
        }
    }

    private func attachment(
        owner: Int,
        subscription: Int
    ) throws -> LiveAttachment {
        try LiveAttachment(
            canonicalUDID: CanonicalUDID(canonicalString: "A"),
            liveOwnerID: uuid(owner),
            subscriptionID: uuid(subscription),
            connectionEpoch: 7,
            stateRevision: 9
        )
    }

    private func uuid(_ value: Int) throws -> CanonicalUUID {
        try CanonicalUUID(String(
            format: "00000000-0000-0000-0000-%012x",
            value
        ))
    }
}
