import Foundation
import XCTest
@testable import PulsePhoneClientCore
import PulsePhoneSharedDefinitions

final class FactsProbeProcessTests: XCTestCase {
    func testNormalResponseWaitsForChildExitAndDecodesEnumeration() throws {
        let marker = temporaryPath("normal-exit")
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let probe = try makeProbe(scenario: "valid-waitpid", marker: marker)
        let result = try probe.enumerate()
        XCTAssertEqual(result.observedAtMonotonicNanoseconds, 123_456)
        XCTAssertEqual(
            result.devices,
            [
                RawDiscoveredDevice(
                    deviceID: 17,
                    rawTransportUDID: "00008030-001C2D",
                    transport: .usb
                ),
            ]
        )
        XCTAssertEqual(
            try String(contentsOfFile: marker, encoding: .utf8),
            "exited"
        )
    }

    func testProbeResponseIsStrictlyTyped() throws {
        let probe = try makeProbe(scenario: "valid-probe")
        let result = try probe.probe(
            deviceID: 17,
            rawTransportUDID: "00008030-001C2D"
        )
        XCTAssertEqual(result.facts.productType, "iPhone14,7")
        XCTAssertEqual(result.facts.productVersion, "26.5")
        XCTAssertEqual(result.facts.buildVersion, "23F79")
        XCTAssertTrue(result.condition.connected)
        XCTAssertTrue(result.condition.trusted)
        XCTAssertFalse(result.condition.locked)
        XCTAssertFalse(result.provenance.autopair)
        XCTAssertEqual(result.provenance.mode, "directHelperFacts")
        XCTAssertEqual(result.provenance.queriedKeys.count, 6)
    }

    func testMalformedSecondLineMismatchAndNonzeroFailClosed() throws {
        try assertFailure("malformed", expected: .invalidResponse)
        try assertFailure("second-line", expected: .invalidResponse)
        try assertFailure("request-mismatch", expected: .responseMismatch)

        let nonzero = try makeProbe(scenario: "nonzero")
        XCTAssertThrowsError(try nonzero.enumerate()) { error in
            guard case .childExitedNonzero = error as? LocalDeviceFactsProbeError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testTimeoutKillsAndReapsEntireProcessGroup() throws {
        let marker = temporaryPath("group-child")
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let probe = try makeProbe(
            scenario: "timeout-group",
            marker: marker,
            workTimeoutNanoseconds: 100_000_000
        )
        let startedAt = Date()
        XCTAssertThrowsError(try probe.enumerate()) { error in
            XCTAssertEqual(error as? LocalDeviceFactsProbeError, .workTimeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.0)
        usleep(500_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testInvalidExecutableAndInputFailBeforeSpawn() throws {
        let invalid = LocalDeviceFactsProbe(executablePath: "/does/not/exist")
        XCTAssertThrowsError(try invalid.enumerate()) { error in
            XCTAssertEqual(error as? LocalDeviceFactsProbeError, .invalidExecutable)
        }
        let probe = try makeProbe(scenario: "valid-probe")
        XCTAssertThrowsError(
            try probe.probe(
                deviceID: 17,
                rawTransportUDID: String(repeating: "x", count: 257)
            )
        ) { error in
            XCTAssertEqual(error as? LocalDeviceFactsProbeError, .invalidRequest)
        }
    }

    private func assertFailure(
        _ scenario: String,
        expected: LocalDeviceFactsProbeError
    ) throws {
        let probe = try makeProbe(scenario: scenario)
        XCTAssertThrowsError(try probe.enumerate()) { error in
            XCTAssertEqual(error as? LocalDeviceFactsProbeError, expected)
        }
    }

    private func makeProbe(
        scenario: String,
        marker: String? = nil,
        workTimeoutNanoseconds: UInt64 = 1_000_000_000
    ) throws -> LocalDeviceFactsProbe {
        var arguments = [scenario]
        if let marker { arguments.append(marker) }
        return LocalDeviceFactsProbe(
            executablePath: fixtureChildPath(),
            arguments: arguments,
            requestIDFactory: {
                try! CanonicalUUID(
                    "00000000-0000-0000-0000-000000000001"
                )
            },
            workTimeout: MonotonicDuration(
                nanoseconds: workTimeoutNanoseconds
            ),
            terminationTimeout: MonotonicDuration(
                nanoseconds: 500_000_000
            )
        )
    }

    private func fixtureChildPath() -> String {
        repositoryRoot()
            .appendingPathComponent("Fixtures/facts-probe/process_child.py")
            .path
    }

    private func temporaryPath(_ label: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsephone-facts-\(label)-\(UUID().uuidString)")
            .path
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
