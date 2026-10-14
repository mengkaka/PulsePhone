import Foundation
import XCTest
import PulsePhoneCommandCatalog
import PulsePhoneSharedDefinitions
import PulsePhoneWire
@testable import PulsePhoneRuntimeExecutable

final class LaunchEnvironmentRuntimeTests: XCTestCase {
    func testProductionPayloadPreservesEnvironmentForBothOSFamilies() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let environment = ["APP_ENV": "testing", "EMPTY": "", "MESSAGE": "你好 hello=a=b"]
        for version in ["16.0", "17.0", "26.0"] {
            let target = try CanonicalUDID(canonicalString: "AAAA")
            let coordinator = ProductionRuntimeDeviceCoordinator(
                canonicalUDID: target,
                catalog: try ExecutionProfileCatalog.load(repositoryRoot: root),
                discovery: {
                    ProductionRuntimeDeviceObservation(
                        rawTransportUDID: target.rawValue,
                        facts: ProductionRuntimeDeviceFacts(
                            buildVersion: "test", deviceClass: "iPhone", deviceName: "Test iPhone",
                            productType: "iPhone14,7", productVersion: version, uniqueDeviceID: target.rawValue
                        ),
                        condition: ProductionRuntimeDeviceCondition(connected: true, locked: false, trusted: true)
                    )
                }
            )
            let snapshot = try coordinator.commandAdmissionSnapshot()
            let original = try XCTUnwrap(ProductionRuntimeOperationBackend.helperBackendPayload(
                commandID: "app.launch", arguments: ["bundleID": "com.example.App"], snapshot: snapshot
            ))
            XCTAssertEqual(Set(original.keys), ["bundleID", "commandID", "operation"])
            let payload = try XCTUnwrap(ProductionRuntimeOperationBackend.helperBackendPayload(
                commandID: "app.launch",
                arguments: ["bundleID": "com.example.App", "environment": try LaunchEnvironment.encode(environment)],
                snapshot: snapshot
            ))
            XCTAssertEqual(payload["environment"], .object(environment.mapValues { .string($0) }))
            XCTAssertThrowsError(try ProductionRuntimeOperationBackend.helperBackendPayload(
                commandID: "app.launch",
                arguments: ["bundleID": "com.example.App", "environment": "{\"BAD-NAME\":\"private-test-value\"}"],
                snapshot: snapshot
            ))
        }
    }
}
