import Foundation
import XCTest
@testable import PulsePhoneClientCore
import PulsePhoneSharedDefinitions

final class DeviceTargetSelectionTests: XCTestCase {
    func testDeviceTargetModelFixture() throws {
        let model = try JSONDecoder().decode(
            DeviceTargetModelFixture.self,
            from: Data(
                contentsOf: FixtureCaseLoaderV1.repositoryRoot(containing: #filePath)
                    .appendingPathComponent("Fixtures/identity/device-target/model.v1.json")
            )
        )
        XCTAssertEqual(model.schemaVersion, 1)
        XCTAssertEqual(model.defaultTransport, FactsProbeTransport.usb.rawValue)
        XCTAssertEqual(model.defaultDeviceClass, "iPhone")
        XCTAssertEqual(model.ordering, "canonicalASCIIBytes")
        XCTAssertEqual(model.deviceLimit, LocalDeviceFactsProbe.deviceLimit)
        XCTAssertFalse(model.compatibilityFallbackAllowed)
    }

    func testMultiDeviceTargetSelectionFixture() throws {
        let fixture = try loadFixture("T-001/multi-device-target-selection-l4")
        let input = try fixture.decodeInput(SelectionInput.self)
        let expected = try fixture.decodeExpected(SelectionExpected.self)
        let snapshot = try materialize(input)

        let selected = try DeviceTargetSelector.select(from: snapshot)
        XCTAssertEqual(selected.device.canonicalUDID.rawValue, expected.defaultTarget)
        XCTAssertEqual(selected.source, .defaultCanonicalFirst)
        XCTAssertEqual(
            DeviceEligibility.defaultEligibleDevices(in: snapshot)
                .map(\.canonicalUDID.rawValue),
            expected.eligibleTargets
        )
        let explicitTarget = try XCTUnwrap(expected.explicitTarget)
        let explicit = try DeviceTargetSelector.select(
            explicit: CanonicalUDID(canonicalString: explicitTarget),
            from: snapshot
        )
        XCTAssertEqual(explicit.device.rawTransportUDID, expected.boundRawTransportUDID)
        XCTAssertEqual(explicit.device.deviceID, expected.boundDeviceID)
        XCTAssertEqual(expected.compatibilityFallbackAllowed, false)
    }

    func testDiscoveryDefaultTargetSelectionFixture() throws {
        let fixture = try loadFixture(
            "T-012/discovery-default-target-selection-l3"
        )
        let input = try fixture.decodeInput(SelectionInput.self)
        let expected = try fixture.decodeExpected(SelectionExpected.self)
        let snapshot = try materialize(input)

        XCTAssertEqual(
            snapshot.canonicalUDIDs.map(\.rawValue),
            expected.usbCanonicalTargets
        )
        XCTAssertEqual(
            DeviceEligibility.defaultEligibleDevices(in: snapshot)
                .map(\.canonicalUDID.rawValue),
            ["A", "B", "IPAD"]
        )
        XCTAssertEqual(
            try DeviceTargetSelector.select(from: snapshot)
                .device.canonicalUDID.rawValue,
            expected.defaultTarget
        )
        XCTAssertFalse(snapshot.devices.contains { $0.rawTransportUDID == "WIRELESS" })
    }

    func testTemporaryIPadOnlyDefaultSelection() throws {
        let snapshot = try USBDeviceDiscovery.materialize(
            RawDiscoverySnapshot(
                observedAtMonotonicNanoseconds: 1,
                devices: [raw(1, "IPAD", .usb)]
            )
        ) { device in
            facts(rawUDID: device.rawTransportUDID, deviceClass: "iPad")
        }
        XCTAssertEqual(
            try DeviceTargetSelector.select(from: snapshot).device.canonicalUDID.rawValue,
            "IPAD"
        )
    }

    func testTargetBindingFixture() throws {
        let fixture = try loadFixture("T-021/target-binding-l4")
        let input = try fixture.decodeInput(SelectionInput.self)
        let expected = try fixture.decodeExpected(SelectionExpected.self)
        let snapshot = try materialize(input)
        let explicit = try XCTUnwrap(expected.explicitTarget)
        let selected = try DeviceTargetSelector.select(
            explicit: CanonicalUDID(canonicalString: explicit),
            from: snapshot
        )
        XCTAssertEqual(selected.source, .explicit)
        XCTAssertEqual(selected.device.canonicalUDID.rawValue, explicit)
        XCTAssertEqual(selected.device.rawTransportUDID, expected.boundRawTransportUDID)
        XCTAssertEqual(selected.device.deviceID, expected.boundDeviceID)
    }

    func testZeroCollisionLimitAndNoSkipFailClosed() throws {
        let empty = USBDiscoverySnapshot(
            observedAtMonotonicNanoseconds: 1,
            devices: []
        )
        XCTAssertThrowsError(try DeviceTargetSelector.select(from: empty)) { error in
            XCTAssertEqual(
                error as? DeviceTargetSelectorError,
                .noDeviceConnected
            )
        }

        let collision = RawDiscoverySnapshot(
            observedAtMonotonicNanoseconds: 1,
            devices: [
                raw(1, " abc ", .usb),
                raw(2, "ABC", .usb),
            ]
        )
        XCTAssertThrowsError(
            try USBDeviceDiscovery.materialize(collision) { device in
                facts(rawUDID: device.rawTransportUDID, deviceClass: "iPhone")
            }
        )

        let oversized = RawDiscoverySnapshot(
            observedAtMonotonicNanoseconds: 1,
            devices: (0...256).map { raw(UInt64($0), "D\($0)", .usb) }
        )
        XCTAssertThrowsError(
            try USBDeviceDiscovery.materialize(oversized) { device in
                facts(rawUDID: device.rawTransportUDID, deviceClass: "iPhone")
            }
        ) { error in
            XCTAssertEqual(
                error as? USBDeviceDiscoveryError,
                .snapshotLimitExceeded(actual: 257, limit: 256)
            )
        }

        let provider = RecordingProvider(
            snapshot: RawDiscoverySnapshot(
                observedAtMonotonicNanoseconds: 1,
                devices: [raw(1, "A", .usb), raw(2, "B", .usb)]
            ),
            results: [
                "A": .failure(.probeFailed),
                "B": .success(facts(rawUDID: "B", deviceClass: "iPhone")),
            ]
        )
        XCTAssertThrowsError(try USBDeviceDiscovery(factsProvider: provider).discover())
        XCTAssertEqual(provider.probedRawUDIDs, ["A"])
    }

    private func materialize(_ input: SelectionInput) throws -> USBDiscoverySnapshot {
        let snapshot = RawDiscoverySnapshot(
            observedAtMonotonicNanoseconds: 42,
            devices: input.devices.map {
                raw($0.deviceID, $0.rawTransportUDID, FactsProbeTransport(rawValue: $0.transport)!)
            }
        )
        let factsByRaw = Dictionary(
            uniqueKeysWithValues: input.devices.map {
                ($0.rawTransportUDID, $0.deviceClass)
            }
        )
        return try USBDeviceDiscovery.materialize(snapshot) { device in
            facts(
                rawUDID: device.rawTransportUDID,
                deviceClass: factsByRaw[device.rawTransportUDID]!
            )
        }
    }

    private func raw(
        _ deviceID: UInt64,
        _ rawTransportUDID: String,
        _ transport: FactsProbeTransport
    ) -> RawDiscoveredDevice {
        RawDiscoveredDevice(
            deviceID: deviceID,
            rawTransportUDID: rawTransportUDID,
            transport: transport
        )
    }

    private func facts(
        rawUDID: String,
        deviceClass: String
    ) -> LocalDeviceFactsResult {
        LocalDeviceFactsResult(
            facts: LocalDeviceFacts(
                buildVersion: "23F79",
                deviceClass: deviceClass,
                deviceName: rawUDID,
                productType: deviceClass == "iPhone" ? "iPhone14,7" : "iPad14,1",
                productVersion: "26.5",
                uniqueDeviceID: rawUDID
            ),
            condition: LocalDeviceCondition(
                connected: true,
                locked: false,
                trusted: true
            ),
            provenance: FactsProbeProvenance(
                autopair: false,
                mode: "directHelperFacts",
                queriedKeys: []
            )
        )
    }

    private func loadFixture(_ requirementID: String) throws -> FixtureCaseBundleV1 {
        try FixtureCaseLoaderV1.load(
            requirementID: requirementID,
            repositoryRoot: FixtureCaseLoaderV1.repositoryRoot(containing: #filePath)
        )
    }
}

private struct SelectionInput: Decodable {
    struct Device: Decodable {
        let deviceID: UInt64
        let rawTransportUDID: String
        let transport: String
        let deviceClass: String
    }

    let devices: [Device]
}

private struct DeviceTargetModelFixture: Decodable {
    let compatibilityFallbackAllowed: Bool
    let defaultDeviceClass: String
    let defaultTransport: String
    let deviceLimit: Int
    let ordering: String
    let schemaVersion: Int
}

private struct SelectionExpected: Decodable {
    let usbCanonicalTargets: [String]
    let eligibleTargets: [String]
    let defaultTarget: String
    let explicitTarget: String?
    let boundRawTransportUDID: String?
    let boundDeviceID: UInt64?
    let compatibilityFallbackAllowed: Bool
}

private enum RecordingProbeError: Error {
    case probeFailed
}

private final class RecordingProvider: LocalDeviceFactsProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let snapshot: RawDiscoverySnapshot
    private let results: [String: Result<LocalDeviceFactsResult, RecordingProbeError>]
    private var probed = [String]()

    init(
        snapshot: RawDiscoverySnapshot,
        results: [String: Result<LocalDeviceFactsResult, RecordingProbeError>]
    ) {
        self.snapshot = snapshot
        self.results = results
    }

    var probedRawUDIDs: [String] {
        lock.withLock { probed }
    }

    func enumerate() throws -> RawDiscoverySnapshot {
        snapshot
    }

    func probe(
        deviceID: UInt64,
        rawTransportUDID: String
    ) throws -> LocalDeviceFactsResult {
        try lock.withLock {
            probed.append(rawTransportUDID)
            return try results[rawTransportUDID]!.get()
        }
    }
}
