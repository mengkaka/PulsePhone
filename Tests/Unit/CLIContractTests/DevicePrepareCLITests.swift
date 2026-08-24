import Foundation
import PulsePhoneCLI
@testable import PulsePhoneClientCore
import PulsePhoneSharedDefinitions
import XCTest

final class DevicePrepareCLITests: XCTestCase {
    func testPrepareStatusProgressProjectionFixture() throws {
        let input = try load(FixtureInput.self, "input/input.v1.json")
        let expected = try load(FixtureExpected.self, "expected.v1.json")
        let start = instant(seconds: 10)
        var human = try DevicePrepareCommand().begin(
            snapshot: try snapshot(input.canonicalUDID),
            requestID: uuid(1),
            actionID: uuid(2),
            startedAt: start,
            outputMode: .human
        )

        XCTAssertEqual(human.request.canonicalUDID.rawValue, input.canonicalUDID)
        XCTAssertEqual(human.targetSelectionSource, .defaultCanonicalFirst)
        let requestMirror = Mirror(reflecting: human.request)
        XCTAssertEqual(
            Set(requestMirror.children.compactMap(\.label)),
            Set(expected.requestFields)
        )
        let progress = try makeProgress(input)
        guard case .progress(let humanChunk) = try human.receiveProgress(
            progress,
            at: instant(seconds: 11)
        ) else {
            return XCTFail("expected progress")
        }
        XCTAssertEqual(humanChunk.stderr.count, 1)
        XCTAssertTrue(humanChunk.stderr[0].contains(input.progressPhase))
        guard case .terminal(let humanTerminal) = try human.receiveTerminal(
            .succeeded(try makeSuccess(input, disposition: "ready")),
            at: instant(seconds: 12)
        ) else {
            return XCTFail("expected terminal")
        }
        XCTAssertEqual(humanTerminal.exitCode, expected.readyExit)
        XCTAssertTrue(humanTerminal.chunk.stdout[0].contains("is ready"))

        var json = try DevicePrepareCommand().begin(
            snapshot: try snapshot(input.canonicalUDID),
            explicitTarget: try CanonicalUDID(
                canonicalString: input.canonicalUDID
            ),
            requestID: uuid(3),
            actionID: uuid(4),
            startedAt: start,
            outputMode: .json
        )
        XCTAssertEqual(json.targetSelectionSource, .explicit)
        guard case .progress(let jsonChunk) = try json.receiveProgress(
            progress,
            at: instant(seconds: 11)
        ) else {
            return XCTFail("expected progress")
        }
        XCTAssertTrue(jsonChunk.stdout.isEmpty)
        XCTAssertTrue(jsonChunk.stderr.isEmpty)
        guard case .terminal(let jsonTerminal) = try json.receiveTerminal(
            .succeeded(try makeSuccess(input, disposition: "ready")),
            at: instant(seconds: 12)
        ) else {
            return XCTFail("expected terminal")
        }
        let object = try jsonObject(jsonTerminal.chunk.stdout[0])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["commandID"] as? String, "device.prepare")
        XCTAssertNil(jsonTerminal.chunk.stdout[0].range(of: "sourceURL"))
        XCTAssertNil(jsonTerminal.chunk.stdout[0].range(of: "cachePath"))
        XCTAssertNil(jsonTerminal.chunk.stdout[0].range(of: "tss"))
    }

    func testAlreadyReadyKnownFailureAndIgnoredObserverTimeoutAndSIGINT() throws {
        let input = try load(FixtureInput.self, "input/input.v1.json")
        let expected = try load(FixtureExpected.self, "expected.v1.json")

        var ready = try session(input, suffix: 10)
        guard case .terminal(let readyOutput) = try ready.receiveTerminal(
            .succeeded(try makeSuccess(input, disposition: "alreadyReady")),
            at: instant(seconds: 11)
        ) else { return XCTFail("expected terminal") }
        XCTAssertEqual(readyOutput.exitCode, expected.alreadyReadyExit)

        var failure = try session(input, suffix: 20)
        guard case .terminal(let failedOutput) = try failure.receiveTerminal(
            .failed(try PrepareObserverFailureProjection(
                code: input.knownFailureCode,
                reason: "deviceLocked"
            )),
            at: instant(seconds: 11)
        ) else { return XCTFail("expected terminal") }
        XCTAssertEqual(failedOutput.exitCode, expected.knownFailureExit)

        var waiting = try session(input, suffix: 30)
        XCTAssertNil(try waiting.checkDeadline(
            at: instant(seconds: 10 + 20 * 60)
        ))
        XCTAssertNil(try waiting.receiveSIGINT(at: instant(seconds: 10 + 20 * 60 + 1)))
        guard case .terminal(let waitingOutput) = try waiting.receiveTerminal(
            .succeeded(try makeSuccess(input, disposition: "ready")),
            at: instant(seconds: 10 + 20 * 60 + 2)
        ) else { return XCTFail("expected Runtime terminal") }
        XCTAssertEqual(waitingOutput.exitCode, expected.readyExit)
    }

    func testProgressIdentityRegressionAndDuplicateTerminalFailClosed() throws {
        let input = try load(FixtureInput.self, "input/input.v1.json")
        var session = try self.session(input, suffix: 50)
        _ = try session.receiveProgress(
            makeProgress(input),
            at: instant(seconds: 11)
        )
        let regressed = try PrepareObserverProgressProjection(
            fraction: 0.1,
            phase: input.progressPhase,
            phaseSequence: 0,
            preparationAttemptID: uuid(99),
            preparationGroupID: input.preparationGroupID,
            stateRevision: 0
        )
        XCTAssertThrowsError(try session.receiveProgress(
            regressed,
            at: instant(seconds: 12)
        )) { error in
            XCTAssertEqual(
                error as? PrepareObserverClientError,
                .progressRegressed
            )
        }
        _ = try session.receiveTerminal(
            .succeeded(try makeSuccess(input, disposition: "ready")),
            at: instant(seconds: 13)
        )
        XCTAssertThrowsError(try session.receiveSIGINT(
            at: instant(seconds: 14)
        )) { error in
            XCTAssertEqual(
                error as? PrepareObserverClientError,
                .alreadyTerminal
            )
        }
    }

    func testObserverClockAndSIGINTDoNotCreateTerminal() throws {
        let request = PrepareObserverClientRequest(
            canonicalUDID: try CanonicalUDID(canonicalString: "AAAA"),
            requestID: uuid(60),
            actionID: uuid(61)
        )
        var client = try PrepareObserverClient(
            request: request,
            startedAt: instant(seconds: 10)
        )
        XCTAssertNil(try client.checkDeadline(
            at: instant(seconds: 1_210)
        ))
        XCTAssertNil(try client.interrupt(at: instant(seconds: 1_211)))
        XCTAssertFalse(client.isTerminal)
    }

    private func session(
        _ input: FixtureInput,
        suffix: Int
    ) throws -> DevicePrepareCommandSession {
        try DevicePrepareCommand().begin(
            snapshot: snapshot(input.canonicalUDID),
            requestID: uuid(suffix),
            actionID: uuid(suffix + 1),
            startedAt: instant(seconds: 10),
            outputMode: .json
        )
    }

    private func makeProgress(
        _ input: FixtureInput
    ) throws -> PrepareObserverProgressProjection {
        try PrepareObserverProgressProjection(
            completedBytes: 25,
            fraction: 0.25,
            phase: input.progressPhase,
            phaseSequence: 1,
            preparationAttemptID: uuid(99),
            preparationGroupID: input.preparationGroupID,
            stateRevision: 2,
            totalBytes: 100
        )
    }

    private func makeSuccess(
        _ input: FixtureInput,
        disposition: String
    ) throws -> PrepareObserverSuccessProjection {
        try PrepareObserverSuccessProjection(
            assetDisposition: disposition == "ready" ? "cacheHit" : "notRequired",
            capabilityIDs: input.capabilityIDs,
            disposition: disposition,
            mountDisposition: disposition == "ready" ? "mounted" : "alreadyMounted",
            preparationAttemptID: disposition == "ready" ? uuid(99) : nil,
            preparationGroupID: input.preparationGroupID,
            provenance: "approved",
            serviceDisposition: "ready"
        )
    }

    private func snapshot(_ canonicalUDID: String) throws -> USBDiscoverySnapshot {
        USBDiscoverySnapshot(
            observedAtMonotonicNanoseconds: 1,
            devices: [USBDiscoveredDevice(
                deviceID: 1,
                rawTransportUDID: canonicalUDID,
                canonicalUDID: try CanonicalUDID(
                    canonicalString: canonicalUDID
                ),
                facts: LocalDeviceFacts(
                    buildVersion: "22A000",
                    deviceClass: "iPhone",
                    deviceName: "Phone",
                    productType: "iPhone15,2",
                    productVersion: "18.0",
                    uniqueDeviceID: canonicalUDID
                ),
                condition: LocalDeviceCondition(
                    connected: true,
                    locked: false,
                    trusted: true
                )
            )]
        )
    }

    private func load<Value: Decodable>(
        _ type: Value.Type,
        _ relativePath: String
    ) throws -> Value {
        try JSONDecoder().decode(
            type,
            from: Data(contentsOf: fixtureURL(relativePath))
        )
    }

    private func fixtureURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/requirements/T-012")
            .appendingPathComponent("prepare-status-progress-projection-l3")
            .appendingPathComponent(relativePath)
    }

    private func jsonObject(_ value: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(value.utf8))
                as? [String: Any]
        )
    }

    private func uuid(_ suffix: Int) -> CanonicalUUID {
        try! CanonicalUUID(String(format: "00000000-0000-4000-8000-%012d", suffix))
    }

    private func instant(seconds: UInt64) -> MonotonicInstant {
        MonotonicInstant(nanoseconds: seconds * 1_000_000_000)
    }
}

private struct FixtureInput: Decodable {
    let canonicalUDID: String
    let capabilityIDs: [String]
    let knownFailureCode: String
    let preparationGroupID: String
    let progressPhase: String
}

private struct FixtureExpected: Decodable {
    let alreadyReadyExit: Int32
    let knownFailureExit: Int32
    let readyExit: Int32
    let requestFields: [String]
}
