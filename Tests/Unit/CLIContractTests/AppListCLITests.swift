import Foundation
import PulsePhoneCLI
@testable import PulsePhoneClientCore
import PulsePhoneLogging
import PulsePhoneSharedDefinitions
import XCTest

final class AppListCLITests: XCTestCase {
    func testHumanOutputUsesStableColumnsFallbacksAndEscapes() throws {
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            runtimeRequest: { _, _, _, _, _ in
                try Self.appListSuccess()
            }
        )
        let output = process.run(arguments: [
            "apps", "--udid", "AAAA",
        ])
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertTrue(output.chunk.stderr.isEmpty)
        XCTAssertEqual(output.chunk.stdout, [
            "NAME\tBUNDLE ID\tVERSION\tTYPE\n"
                + "A\\\\B\\tC\\nD\\rE\\u001B\tCtClient\t1.0\tuser\n"
                + "unknown\tcom.example.beta\tunknown\tsystem",
        ])
    }

    func testJSONOutputOmitsMissingOptionalFields() throws {
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            runtimeRequest: { _, _, _, _, _ in
                try Self.appListSuccess()
            }
        )
        let output = process.run(arguments: [
            "apps", "--udid", "AAAA", "--json",
        ])
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.chunk.stdout.count, 1)
        XCTAssertTrue(output.chunk.stderr.isEmpty)
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(output.chunk.stdout[0].utf8)
            ) as? [String: Any]
        )
        XCTAssertEqual(envelope["commandID"] as? String, "app.list")
        let target = try XCTUnwrap(envelope["target"] as? [String: Any])
        XCTAssertEqual(target["udid"] as? String, "AAAA")
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["truncated"] as? Bool, false)
        let apps = try XCTUnwrap(result["apps"] as? [[String: Any]])
        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(apps[1]["bundleID"] as? String, "com.example.beta")
        XCTAssertNil(apps[1]["displayName"])
        XCTAssertNil(apps[1]["version"])
    }

    func testMalformedRuntimeSuccessFailsClosed() throws {
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            runtimeRequest: { _, _, _, _, _ in
                try Self.object([
                    ("commitState", .string("notCommitted")),
                    ("outcome", .string("succeeded")),
                    ("value", .object(try Self.object([
                        ("apps", .string("invalid")),
                        ("truncated", .bool(false)),
                    ]))),
                ])
            }
        )
        let output = process.run(arguments: [
            "apps", "--udid", "AAAA", "--json",
        ])
        XCTAssertNotEqual(output.exitCode, 0)
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(output.chunk.stdout[0].utf8)
            ) as? [String: Any]
        )
        XCTAssertEqual(
            (envelope["error"] as? [String: Any])?["code"] as? String,
            "backendFailed"
        )
    }

    private static func appListSuccess() throws -> RepositoryJSONObject {
        try object([
            ("commitState", .string("notCommitted")),
            ("outcome", .string("succeeded")),
            ("value", .object(try object([
                ("apps", .array([
                    .object(try object([
                        ("applicationType", .string("user")),
                        ("bundleID", .string("CtClient")),
                        ("displayName", .string("A\\B\tC\nD\rE\u{001B}")),
                        ("version", .string("1.0")),
                    ])),
                    .object(try object([
                        ("applicationType", .string("system")),
                        ("bundleID", .string("com.example.beta")),
                    ])),
                ])),
                ("truncated", .bool(false)),
            ]))),
        ])
    }

    private static func snapshot() throws -> USBDiscoverySnapshot {
        USBDiscoverySnapshot(
            observedAtMonotonicNanoseconds: 1,
            devices: [USBDiscoveredDevice(
                deviceID: 1,
                rawTransportUDID: "AAAA",
                canonicalUDID: try CanonicalUDID(canonicalString: "AAAA"),
                facts: LocalDeviceFacts(
                    buildVersion: "21A000",
                    deviceClass: "iPhone",
                    deviceName: "Test Phone",
                    productType: "iPhone15,2",
                    productVersion: "17.0",
                    uniqueDeviceID: "AAAA"
                ),
                condition: LocalDeviceCondition(
                    connected: true,
                    locked: false,
                    trusted: true
                )
            )]
        )
    }

    private static func staticSurface() throws -> CLIStaticSurface {
        try CLIStaticSurface.loading(
            repositoryRoot: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        )
    }

    private static func missingActionLogMaintenance() -> ProductionActionLogMaintenance {
        ProductionActionLogMaintenance(
            rootPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("pulsephone-missing-actionlogs")
                .appendingPathComponent(UUID().uuidString)
                .path
        )
    }

    private static func object(
        _ members: [(String, RepositoryJSONValue)]
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: members.map {
            RepositoryJSONMember(key: $0.0, value: $0.1)
        })
    }
}
