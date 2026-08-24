import Foundation
import PulsePhoneCommandCatalog
@testable import PulsePhoneRuntimeExecutable
import PulsePhoneSharedDefinitions
import XCTest

final class AppListRuntimeTests: XCTestCase {
    func testBrowseUsesDirectHelperExactPayloadAndThirtySecondDeadline() throws {
        let snapshot = try deviceSnapshot()
        let payload = try XCTUnwrap(
            ProductionRuntimeOperationBackend.helperBackendPayload(
                commandID: "app.list",
                arguments: [:],
                snapshot: snapshot
            )
        )
        XCTAssertEqual(payload, ["operation": .string("browse")])
        XCTAssertNil(try ProductionRuntimeOperationBackend.helperBackendPayload(
            commandID: "app.list",
            arguments: ["filter": "User"],
            snapshot: snapshot
        ))
        XCTAssertTrue(ProductionRuntimeOperationBackend.usesDirectHelper(
            routeID: "direct.installationProxy.browse"
        ))
        XCTAssertEqual(
            ProductionCoreDeviceHelperExecutor.oneShotDeadlineNanoseconds(
                routeID: "direct.installationProxy.browse",
                startedAt: 10
            ),
            10 + UInt64(30 * 1_000) * 1_000_000
        )
    }

    func testAppListProjectionRebuildsStrictSortedResult() throws {
        let helper = try object([
            ("commitState", .string("notCommitted")),
            ("outcome", .string("succeeded")),
            ("value", .object(try object([
                ("apps", .array([
                    .object(try app(
                        bundleID: "CtClient",
                        applicationType: "system"
                    )),
                    .object(try app(
                        bundleID: "com.example.zeta",
                        applicationType: "user",
                        displayName: "Zeta",
                        version: "1.0"
                    )),
                ])),
                ("truncated", .bool(false)),
            ]))),
        ])
        let projected = try ProductionRuntimeOperationBackend.projectAppListResult(
            helper
        )
        XCTAssertEqual(projected["outcome"]?.stringValue, "succeeded")
        XCTAssertEqual(projected["commitState"]?.stringValue, "notCommitted")
        let apps = try XCTUnwrap(
            projected["value"]?.objectValue?["apps"]?.arrayValue
        )
        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(
            apps[0].objectValue?["bundleID"]?.stringValue,
            "CtClient"
        )
        XCTAssertNil(apps[0].objectValue?["displayName"])
        XCTAssertEqual(
            apps[1].objectValue?["displayName"]?.stringValue,
            "Zeta"
        )
    }

    func testAppListProjectionRejectsMalformedUnknownAndOversizedResults() throws {
        let malformedValues: [RepositoryJSONObject] = [
            try object([
                ("apps", .array([
                    .object(try app(
                        bundleID: "com.example.same",
                        applicationType: "user"
                    )),
                    .object(try app(
                        bundleID: "com.example.same",
                        applicationType: "user"
                    )),
                ])),
                ("truncated", .bool(false)),
            ]),
            try object([
                ("apps", .array([
                    .object(try object([
                        ("applicationType", .string("user")),
                        ("bundleID", .string("com.example.extra")),
                        ("privatePath", .string("/private/app")),
                    ])),
                ])),
                ("truncated", .bool(false)),
            ]),
            try object([
                ("apps", .array([
                    .object(try app(
                        bundleID: "com.example.oversized",
                        applicationType: "user",
                        displayName: String(repeating: "x", count: 256 * 1_024)
                    )),
                ])),
                ("truncated", .bool(false)),
            ]),
        ]
        for value in malformedValues {
            let projected = try ProductionRuntimeOperationBackend
                .projectAppListResult(try object([
                    ("commitState", .string("notCommitted")),
                    ("outcome", .string("succeeded")),
                    ("value", .object(value)),
                ]))
            assertNormalizedFailure(
                projected,
                code: "backendFailed",
                stage: "resultNormalize"
            )
        }

        let unknown = try ProductionRuntimeOperationBackend.projectAppListResult(
            try object([
                ("commitState", .string("unknown")),
                ("outcome", .string("outcomeUnknown")),
            ])
        )
        assertNormalizedFailure(
            unknown,
            code: "backendFailed",
            stage: "resultNormalize"
        )
    }

    func testAppListProjectionPreservesOnlyKnownFailureFields() throws {
        let projected = try ProductionRuntimeOperationBackend.projectAppListResult(
            try object([
                ("commitState", .string("notCommitted")),
                ("error", .object(try object([
                    ("code", .string("transportFailure")),
                    ("details", .object(try object([
                        ("commitState", .string("notCommitted")),
                        ("privateMetadata", .string("must-not-pass")),
                        ("stage", .string("browseReceive")),
                    ]))),
                ]))),
                ("outcome", .string("failed")),
            ])
        )
        assertNormalizedFailure(
            projected,
            code: "transportFailure",
            stage: "browseReceive"
        )
        XCTAssertNil(
            projected["error"]?.objectValue?["details"]?
                .objectValue?["privateMetadata"]
        )
    }

    private func assertNormalizedFailure(
        _ result: RepositoryJSONObject,
        code: String,
        stage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            result["commitState"]?.stringValue,
            "notCommitted",
            file: file,
            line: line
        )
        XCTAssertEqual(
            result["outcome"]?.stringValue,
            "failed",
            file: file,
            line: line
        )
        XCTAssertEqual(
            result["error"]?.objectValue?["code"]?.stringValue,
            code,
            file: file,
            line: line
        )
        XCTAssertEqual(
            result["error"]?.objectValue?["details"]?
                .objectValue?["stage"]?.stringValue,
            stage,
            file: file,
            line: line
        )
    }

    private func deviceSnapshot() throws -> ProductionRuntimeDeviceSnapshot {
        let target = try CanonicalUDID(canonicalString: "APP-LIST-RUNTIME")
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(
                repositoryRoot: repositoryRoot()
            ),
            discovery: {
                ProductionRuntimeDeviceObservation(
                    rawTransportUDID: target.rawValue,
                    facts: ProductionRuntimeDeviceFacts(
                        buildVersion: "23F84",
                        deviceClass: "iPhone",
                        deviceName: "Test iPhone",
                        productType: "iPhone14,7",
                        productVersion: "26.5.2",
                        uniqueDeviceID: target.rawValue
                    ),
                    condition: ProductionRuntimeDeviceCondition(
                        connected: true,
                        locked: false,
                        trusted: true
                    )
                )
            }
        )
        return try coordinator.refresh()
    }

    private func app(
        bundleID: String,
        applicationType: String,
        displayName: String? = nil,
        version: String? = nil
    ) throws -> RepositoryJSONObject {
        var members: [(String, RepositoryJSONValue)] = [
            ("applicationType", .string(applicationType)),
            ("bundleID", .string(bundleID)),
        ]
        if let displayName {
            members.append(("displayName", .string(displayName)))
        }
        if let version {
            members.append(("version", .string(version)))
        }
        return try object(members)
    }

    private func object(
        _ members: [(String, RepositoryJSONValue)]
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: members.map {
            RepositoryJSONMember(key: $0.0, value: $0.1)
        })
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
