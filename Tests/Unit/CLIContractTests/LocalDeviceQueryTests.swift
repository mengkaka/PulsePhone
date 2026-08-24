import Foundation
import PulsePhoneCLI
@testable import PulsePhoneClientCore
import PulsePhoneSharedDefinitions
import XCTest

final class LocalDeviceQueryTests: XCTestCase {
    func testDevicesAreSortedAndNeverTruncated() throws {
        let provider = RecordingFactsProvider(
            rawDevices: [
                raw(2, "BBBB"),
                raw(1, "AAAA"),
                raw(3, "CCCC", transport: .network),
            ],
            results: [
                1: facts(udid: "AAAA", name: "Alpha"),
                2: facts(udid: "BBBB", name: "Beta", osVersion: "26.5"),
            ]
        )
        let result = try LocalDeviceQueries(
            discovery: USBDeviceDiscovery(factsProvider: provider)
        ).devices()

        XCTAssertEqual(result.devices.map(\.canonicalUDID.rawValue), ["AAAA", "BBBB"])
        XCTAssertEqual(result.devices.map(\.name), ["Alpha", "Beta"])
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(provider.probedDeviceIDs, [2, 1])
    }

    func testDeviceInfoUsesExplicitTargetWithoutCompatibilityFallback() throws {
        let snapshot = try makeSnapshot([
            device("AAAA", deviceClass: "iPad"),
            device("BBBB", name: "Chosen"),
        ])
        let result = try LocalDeviceQueries(snapshot: snapshot).deviceInfo(
            canonicalUDID: CanonicalUDID(canonicalString: "BBBB")
        )

        XCTAssertEqual(result.canonicalUDID.rawValue, "BBBB")
        XCTAssertEqual(result.name, "Chosen")
        XCTAssertEqual(result.probeProvenance, .snapshot)
    }

    func testDeviceInfoDefaultUsesCanonicalFirstEligibleIPhone() throws {
        let snapshot = try makeSnapshot([
            device("AAAA", deviceClass: "iPad"),
            device("BBBB", name: "First iPhone"),
            device("CCCC", name: "Second iPhone"),
        ])
        let result = try LocalDeviceQueries(snapshot: snapshot).deviceInfo()
        XCTAssertEqual(result.canonicalUDID.rawValue, "BBBB")
    }

    func testDiscoveryBackedInfoReportsFactsProbeProvenance() throws {
        let provider = RecordingFactsProvider(
            rawDevices: [raw(1, "AAAA")],
            results: [1: facts(udid: "AAAA")]
        )
        let result = try LocalDeviceQueries(
            discovery: USBDeviceDiscovery(factsProvider: provider)
        ).deviceInfo()
        XCTAssertEqual(result.probeProvenance, .factsProbe)
    }

    func testStatusConditionProjectionDoesNotConsultRuntime() throws {
        let cases: [(LocalDeviceCondition, DeviceStatusCondition)] = [
            (.init(connected: false, locked: false, trusted: false), .disconnected),
            (.init(connected: true, locked: true, trusted: true), .locked),
            (.init(connected: true, locked: false, trusted: false), .unknown),
            (.init(connected: true, locked: false, trusted: true), .available),
        ]
        for (index, item) in cases.enumerated() {
            let snapshot = try makeSnapshot([
                device("AAAA", condition: item.0),
            ])
            let result = try LocalDeviceQueries(snapshot: snapshot).deviceStatus()
            XCTAssertEqual(result.condition, item.1, "case \(index)")
        }
    }

    func testMissingNameIsOmittedFromJSONAndShownAsUnknownToHumans() throws {
        let queries = LocalDeviceQueries(
            snapshot: try makeSnapshot([device("AAAA", name: "")])
        )
        let json = try DeviceInfoCommand(queries: queries).run(outputMode: .json)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertNil(object["name"])
        XCTAssertEqual(Set(object.keys), [
            "canonicalUDID", "deviceClass", "osBuild", "osVersion",
            "probeProvenance",
        ])

        let human = try DeviceInfoCommand(queries: queries).run(outputMode: .human)
        XCTAssertTrue(human.contains("Name: unknown"))
    }

    func testDevicesCommandRendersSchemaShapedJSONAndStableHumanRows() throws {
        let queries = LocalDeviceQueries(
            snapshot: try makeSnapshot([
                device("AAAA", name: "Alpha"),
                device("BBBB", name: ""),
            ])
        )
        let command = DevicesCommand(queries: queries)
        let json = try command.run(outputMode: .json)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["truncated"] as? Bool, false)
        XCTAssertEqual((object["devices"] as? [Any])?.count, 2)

        XCTAssertEqual(
            try command.run(outputMode: .human),
            "UDID\tNAME\tCLASS\tOS\tBUILD\n" +
                "AAAA\tAlpha\tiPhone\t17.0\t21A000\n" +
                "BBBB\tunknown\tiPhone\t17.0\t21A000"
        )
    }

    func testStatusCommandRendersOnlyConciseIdentityAndCondition() throws {
        let queries = LocalDeviceQueries(
            snapshot: try makeSnapshot([
                device(
                    "AAAA",
                    name: "Alpha",
                    condition: .init(connected: true, locked: true, trusted: true)
                ),
            ])
        )
        let json = try DeviceStatusCommand(queries: queries).run(outputMode: .json)
        XCTAssertEqual(
            json,
            #"{"canonicalUDID":"AAAA","condition":"locked","name":"Alpha"}"#
        )
        XCTAssertEqual(
            try DeviceStatusCommand(queries: queries).run(outputMode: .human),
            "UDID: AAAA\nName: Alpha\nCondition: locked"
        )
    }

    func testTargetErrorsRemainTyped() throws {
        let empty = LocalDeviceQueries(snapshot: try makeSnapshot([]))
        XCTAssertThrowsError(try empty.deviceInfo()) { error in
            XCTAssertEqual(error as? LocalDeviceQueryError, .noDeviceConnected)
        }

        let requested = try CanonicalUDID(canonicalString: "BBBB")
        let queries = LocalDeviceQueries(
            snapshot: try makeSnapshot([device("AAAA")])
        )
        XCTAssertThrowsError(
            try queries.deviceStatus(canonicalUDID: requested)
        ) { error in
            XCTAssertEqual(error as? LocalDeviceQueryError, .deviceNotFound(requested))
        }
    }

    func testOversizedRequiredFactFailsInsteadOfProducingInvalidSchema() throws {
        let queries = LocalDeviceQueries(
            snapshot: try makeSnapshot([
                device("AAAA", osBuild: String(repeating: "A", count: 65)),
            ])
        )
        XCTAssertThrowsError(try queries.devices()) { error in
            XCTAssertEqual(
                error as? LocalDeviceQueryError,
                .invalidProjection(field: "osBuild")
            )
        }
    }

    private func raw(
        _ id: UInt64,
        _ udid: String,
        transport: FactsProbeTransport = .usb
    ) -> RawDiscoveredDevice {
        RawDiscoveredDevice(
            deviceID: id,
            rawTransportUDID: udid,
            transport: transport
        )
    }

    private func facts(
        udid: String,
        name: String = "Phone",
        deviceClass: String = "iPhone",
        osVersion: String = "17.0",
        osBuild: String = "21A000",
        condition: LocalDeviceCondition = .init(
            connected: true,
            locked: false,
            trusted: true
        )
    ) -> LocalDeviceFactsResult {
        LocalDeviceFactsResult(
            facts: LocalDeviceFacts(
                buildVersion: osBuild,
                deviceClass: deviceClass,
                deviceName: name,
                productType: "iPhone15,2",
                productVersion: osVersion,
                uniqueDeviceID: udid
            ),
            condition: condition,
            provenance: FactsProbeProvenance(
                autopair: false,
                mode: "directHelperFacts",
                queriedKeys: []
            )
        )
    }

    private func device(
        _ udid: String,
        name: String = "Phone",
        deviceClass: String = "iPhone",
        osVersion: String = "17.0",
        osBuild: String = "21A000",
        condition: LocalDeviceCondition = .init(
            connected: true,
            locked: false,
            trusted: true
        )
    ) throws -> USBDiscoveredDevice {
        let result = facts(
            udid: udid,
            name: name,
            deviceClass: deviceClass,
            osVersion: osVersion,
            osBuild: osBuild,
            condition: condition
        )
        return USBDiscoveredDevice(
            deviceID: 1,
            rawTransportUDID: udid,
            canonicalUDID: try CanonicalUDID(rawTransportUDID: udid),
            facts: result.facts,
            condition: result.condition
        )
    }

    private func makeSnapshot(
        _ devices: [USBDiscoveredDevice]
    ) throws -> USBDiscoverySnapshot {
        USBDiscoverySnapshot(
            observedAtMonotonicNanoseconds: 1,
            devices: devices
        )
    }
}

private final class RecordingFactsProvider: LocalDeviceFactsProviding,
    @unchecked Sendable
{
    private let rawDevices: [RawDiscoveredDevice]
    private let results: [UInt64: LocalDeviceFactsResult]
    private(set) var probedDeviceIDs = [UInt64]()

    init(
        rawDevices: [RawDiscoveredDevice],
        results: [UInt64: LocalDeviceFactsResult]
    ) {
        self.rawDevices = rawDevices
        self.results = results
    }

    func enumerate() throws -> RawDiscoverySnapshot {
        RawDiscoverySnapshot(
            observedAtMonotonicNanoseconds: 1,
            devices: rawDevices
        )
    }

    func probe(
        deviceID: UInt64,
        rawTransportUDID: String
    ) throws -> LocalDeviceFactsResult {
        probedDeviceIDs.append(deviceID)
        return try XCTUnwrap(results[deviceID])
    }
}
