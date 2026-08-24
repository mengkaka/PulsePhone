import Foundation
import XCTest
@testable import PulsePhoneRuntimeState
import PulsePhoneCommandCatalog
import PulsePhoneCommandPlanner
import PulsePhoneSharedDefinitions

final class SchedulerTests: XCTestCase {
    func testConflictingFIFOExclusiveFairnessAndDisjointBypass() throws {
        var scheduler = DeviceScheduler()
        let activeShared = try scheduler.submit(
            request("active.shared", .oneShot, [.shared("resource.r")])
        )
        guard case .running = activeShared else {
            return XCTFail("expected active shared lease")
        }
        XCTAssertPending(
            try scheduler.submit(
                request("earlier.exclusive", .oneShot, [.exclusive("resource.r")])
            )
        )
        XCTAssertPending(
            try scheduler.submit(
                request("later.shared", .oneShot, [.shared("resource.r")])
            )
        )
        guard case .running(let disjoint) = try scheduler.submit(
            request("later.disjoint", .oneShot, [.exclusive("resource.s")])
        ) else {
            return XCTFail("disjoint request must bypass")
        }
        XCTAssertEqual(disjoint.requestID, "later.disjoint")

        let first = try scheduler.release(requestID: "active.shared")
        XCTAssertEqual(first.newlyGranted.map(\.requestID), ["earlier.exclusive"])
        XCTAssertEqual(
            scheduler.snapshot.pendingRequests.map(\.requestID),
            ["later.shared"]
        )
        let second = try scheduler.release(requestID: "earlier.exclusive")
        XCTAssertEqual(second.newlyGranted.map(\.requestID), ["later.shared"])
    }

    func testAllOrNothingClaimsDoNotReservePartialLease() throws {
        var scheduler = DeviceScheduler()
        _ = try scheduler.submit(
            request("active.a", .oneShot, [.exclusive("resource.a")])
        )
        XCTAssertPending(
            try scheduler.submit(
                request(
                    "multi.a.b",
                    .oneShot,
                    [.exclusive("resource.a"), .exclusive("resource.b")]
                )
            )
        )
        XCTAssertTrue(
            scheduler.snapshot.activeLeases.allSatisfy {
                !$0.claims.contains(where: { $0.resourceID == "resource.b" })
            }
        )
        XCTAssertPending(
            try scheduler.submit(
                request("later.b", .oneShot, [.exclusive("resource.b")])
            )
        )
        guard case .running = try scheduler.submit(
            request("later.c", .oneShot, [.exclusive("resource.c")])
        ) else {
            return XCTFail("resource.c should bypass")
        }
    }

    func testSchedulerFairnessCapacityFixture() throws {
        try testConflictingFIFOExclusiveFairnessAndDisjointBypass()
        try testAllOrNothingClaimsDoNotReservePartialLease()
        let expected = try loadExpected(
            "T-015/scheduler-fairness-capacity-l1"
        )
        var scheduler = DeviceScheduler()
        _ = try scheduler.submit(
            request("active", .oneShot, [.exclusive("resource.cap")])
        )
        for index in 0..<64 {
            XCTAssertPending(
                try scheduler.submit(
                    request(
                        "pending.\(index)",
                        .oneShot,
                        [.exclusive("resource.cap")]
                    )
                )
            )
        }
        XCTAssertEqual(scheduler.snapshot.pendingOneShotCount, 64)
        XCTAssertEqual(
            try scheduler.submit(
                request("overflow", .oneShot, [.exclusive("resource.cap")])
            ),
            .queueFull(limit: 64)
        )
        XCTAssertEqual(uint(expected["pendingLimit"]), 64)
        XCTAssertEqual(uint(expected["queueFullOrdinal"]), 65)
        XCTAssertEqual(bool(expected["allOrNothing"]), true)
        XCTAssertEqual(
            bool(expected["exclusiveWaiterBlocksLaterShared"]),
            true
        )
        XCTAssertEqual(bool(expected["disjointBypass"]), true)
    }

    func testStreamFailsFastAndPreparationIsNotProductAccepted() throws {
        var scheduler = DeviceScheduler()
        _ = try scheduler.submit(
            request("active", .oneShot, [.exclusive("resource.input")])
        )
        XCTAssertEqual(
            try scheduler.submit(
                request("stream", .stream, [.exclusive("resource.input")])
            ),
            .resourceBusy(["resource.input"])
        )
        let preparation = try SchedulerRequest(
            requestID: "preparation",
            claimantKind: .preparation,
            phase: .devicePreparation,
            claims: [.exclusive("service.mobile-image-mounter")]
        )
        guard case .running(let lease) = try scheduler.submit(preparation) else {
            return XCTFail("preparation should run on disjoint resource")
        }
        XCTAssertFalse(lease.productAccepted)
        XCTAssertThrowsError(
            try SchedulerRequest(
                requestID: "download",
                claimantKind: .preparation,
                phase: .hostAcquisition,
                claims: []
            )
        ) { error in
            XCTAssertEqual(error as? ResourceClaimError, .hostAcquisitionForbidden)
        }
    }

    func testPreparationClaimsBypassFixture() throws {
        let expected = try loadExpected(
            "T-020/scheduler-claims-bypass-l3"
        )
        var scheduler = DeviceScheduler()
        let preparation = try SchedulerRequest(
            requestID: "prep.mount",
            claimantKind: .preparation,
            phase: .devicePreparation,
            claims: [
                .exclusive("service.mobile-image-mounter"),
                .shared("device.developer-environment"),
            ]
        )
        guard case .running(let prepLease) = try scheduler.submit(preparation) else {
            return XCTFail("preparation claim should run")
        }
        XCTAssertEqual(prepLease.claims.count, 2)
        let laterPreparation = try SchedulerRequest(
            requestID: "prep.mount.later",
            claimantKind: .preparation,
            phase: .devicePreparation,
            claims: [.exclusive("service.mobile-image-mounter")]
        )
        guard case .waiting = try scheduler.submit(laterPreparation) else {
            return XCTFail("second mount claimant must wait")
        }
        guard case .running(let disjoint) = try scheduler.submit(
            request(
                "device.info",
                .oneShot,
                [.shared("device.facts")]
            )
        ) else {
            return XCTFail("non-DDI command should bypass")
        }
        XCTAssertEqual(disjoint.requestID, "device.info")
        XCTAssertEqual(uint(expected["hostAcquisitionDeviceLeaseCount"]), 0)
        XCTAssertEqual(bool(expected["devicePreparationClaimsPhaseScoped"]), true)
        XCTAssertEqual(bool(expected["disjointCommandRuns"]), true)
        XCTAssertEqual(bool(expected["mountMutationOrdered"]), true)
        XCTAssertEqual(bool(expected["preparationClaimantProductAccepted"]), false)
    }

    private func request(
        _ id: String,
        _ kind: SchedulerClaimantKind,
        _ claims: [ResourceClaim]
    ) throws -> SchedulerRequest {
        try SchedulerRequest(
            requestID: id,
            claimantKind: kind,
            phase: kind == .stream ? .stream : .running,
            claims: claims
        )
    }

    private func XCTAssertPending(
        _ admission: SchedulerAdmission,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .pending = admission else {
            return XCTFail("expected pending admission", file: file, line: line)
        }
    }

    private func loadExpected(_ requirement: String) throws -> RepositoryJSONObject {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: root.appendingPathComponent(
                "Fixtures/requirements/\(requirement)/expected.v1.json"
            )
        )
        return try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](data),
            maximumByteCount: 16 * 1_024
        ).root
    }

    private func bool(_ value: RepositoryJSONValue?) -> Bool? {
        guard case .bool(let value)? = value else { return nil }
        return value
    }

    private func uint(_ value: RepositoryJSONValue?) -> UInt64? {
        guard let number = value?.numberValue else { return nil }
        return try? number.requireUInt64()
    }
}

private extension ResourceClaim {
    static func shared(_ resourceID: String) throws -> ResourceClaim {
        try ResourceClaim(accessMode: .shared, resourceID: resourceID)
    }

    static func exclusive(_ resourceID: String) throws -> ResourceClaim {
        try ResourceClaim(accessMode: .exclusive, resourceID: resourceID)
    }
}
