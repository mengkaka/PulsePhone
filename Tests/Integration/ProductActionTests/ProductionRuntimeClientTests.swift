import Foundation
import PulsePhoneClientCore
import PulsePhoneHostPaths
import PulsePhoneSharedDefinitions
import XCTest

final class ProductionRuntimeClientTests: XCTestCase {
    func testCaptureReadyTransitionParsesCompleteActualGeometry() throws {
        let value = try Self.object([
            ("captureProvenance", .string("postCapture")),
            ("connectionEpoch", .number(.uint64(7))),
            ("disposition", .string("ready")),
            ("geometryRevision", .number(.uint64(9))),
            ("logicalHeight", .number(.uint64(1_170))),
            ("logicalWidth", .number(.uint64(2_532))),
            ("orientation", .string("landscapeLeft")),
        ])
        let transition = try ProductionRuntimeCaptureReadyTransition(
            value: value,
            expectedConnectionEpoch: 7
        )
        XCTAssertEqual(transition.geometry?.connectionEpoch, 7)
        XCTAssertEqual(transition.geometry?.geometryRevision, 9)
        XCTAssertEqual(transition.geometry?.logicalWidth, 2_532)
        XCTAssertEqual(transition.geometry?.logicalHeight, 1_170)
        XCTAssertEqual(transition.geometry?.orientation, .landscapeLeft)
    }

    func testCaptureReadyTransitionRejectsPartialGeometry() throws {
        let value = try Self.object([
            ("connectionEpoch", .number(.uint64(7))),
            ("geometryRevision", .number(.uint64(9))),
        ])
        XCTAssertThrowsError(try ProductionRuntimeCaptureReadyTransition(
            value: value,
            expectedConnectionEpoch: 7
        )) {
            XCTAssertEqual($0 as? RuntimeClientError, .invalidResponse)
        }
    }

    func testCaptureReadyTransitionRejectsInvalidOrientation() throws {
        let value = try Self.object([
            ("connectionEpoch", .number(.uint64(7))),
            ("geometryRevision", .number(.uint64(9))),
            ("logicalHeight", .number(.uint64(1_170))),
            ("logicalWidth", .number(.uint64(2_532))),
            ("orientation", .string("landscape")),
        ])
        XCTAssertThrowsError(try ProductionRuntimeCaptureReadyTransition(
            value: value,
            expectedConnectionEpoch: 7
        )) {
            XCTAssertEqual($0 as? RuntimeClientError, .invalidResponse)
        }
    }

    func testCaptureReadyTransitionRejectsForeignConnectionEpoch() throws {
        let value = try Self.object([
            ("connectionEpoch", .number(.uint64(8))),
        ])
        XCTAssertThrowsError(try ProductionRuntimeCaptureReadyTransition(
            value: value,
            expectedConnectionEpoch: 7
        )) {
            XCTAssertEqual($0 as? RuntimeClientError, .invalidResponse)
        }
    }

    func testTargetMismatchFailsBeforeTransport() throws {
        let expected = try CanonicalUDID(canonicalString: "M2031-A")
        let client = try RuntimeClient.testing(
            canonicalAppPath: CanonicalAppPath(
                canonicalBundlePath: "/Applications/PulsePhone.app"
            ),
            developerImageCatalogRevision: "catalog.test",
            developerImageCatalogHash: String(repeating: "b", count: 64)
        )
        let runtime = ProductionCommandSubmissionRuntime(
            client: client,
            canonicalUDID: expected
        )
        XCTAssertThrowsError(try runtime.submit(CommandSubmissionIntent(
            requestID: CanonicalUUID(value: UUID()),
            actionID: CanonicalUUID(value: UUID()),
            canonicalUDID: CanonicalUDID(canonicalString: "M2031-B"),
            commandID: "touch.tap",
            rawArguments: [:]
        ))) { error in
            XCTAssertEqual(error as? RuntimeClientError, .targetMismatch)
        }
    }

    private static func object(
        _ members: [(String, RepositoryJSONValue)]
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: members.map {
            RepositoryJSONMember(key: $0.0, value: $0.1)
        })
    }
}
