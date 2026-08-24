import Foundation
import PulsePhoneSharedDefinitions
@testable import PulsePhoneWire
import XCTest

final class HelperWireTests: XCTestCase {
    func testCodecEnforcesDirectionShapeCapsAndJSONNumbers() throws {
        var fields = base(.progress, messageIndex: 1)
        fields["requestID"] = .string(uuid(20))
        fields["payload"] = .object(["fraction": .double(0.5)])
        let message = try decode(fields, direction: .helperToRuntime)
        XCTAssertEqual(message.payload?["fraction"], .double(0.5))

        XCTAssertThrowsError(
            try HelperWireCodec.decodeLine(
                HelperWireCodec.encodeLine(
                    fields: fields,
                    direction: .helperToRuntime
                ),
                direction: .runtimeToHelper
            )
        ) { error in
            XCTAssertEqual(error as? HelperWireCodecError, .wrongDirection)
        }

        fields["unknown"] = .bool(true)
        XCTAssertThrowsError(
            try HelperWireCodec.encodeLine(
                fields: fields,
                direction: .helperToRuntime
            )
        )
    }

    func testCodecRejectsDuplicateObjectKeysIncludingEscapedNestedKey() {
        let topLevelDuplicate = Array(
            #"{"executorGeneration":3,"helperBuildID":"build","helperKind":"direct","manifestHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","messageID":"00000000-0000-0000-0000-000000000001","processStartIdentity":"pid:1","runtimeEpoch":7,"schemaVersion":1,"type":"Hello","\u0074ype":"Hello"}"#.utf8
        ) + [0x0a]
        XCTAssertThrowsError(
            try HelperWireCodec.decodeLine(
                topLevelDuplicate,
                direction: .helperToRuntime
            )
        ) { error in
            XCTAssertEqual(error as? HelperWireCodecError, .invalidJSON)
        }

        let nestedDuplicate = Array(
            #"{"executorGeneration":3,"messageID":"00000000-0000-0000-0000-000000000002","payload":{"facets":[],"\u0066acets":[]},"runtimeEpoch":7,"schemaVersion":1,"type":"Ready"}"#.utf8
        ) + [0x0a]
        XCTAssertThrowsError(
            try HelperWireCodec.decodeLine(
                nestedDuplicate,
                direction: .helperToRuntime
            )
        ) { error in
            XCTAssertEqual(error as? HelperWireCodecError, .invalidJSON)
        }
    }

    func testCodecSharedFixtureMatchesGoAndLegacyPython() throws {
        let fixtureURL = repositoryRoot().appendingPathComponent(
            "Fixtures/helper-wire/codec-parity.v1.json"
        )
        let fixture = try JSONDecoder().decode(
            HelperWireCodecParityFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertFalse(fixture.cases.isEmpty)
        for item in fixture.cases {
            var line = item.line
            if let token = item.expandToken {
                let count = try XCTUnwrap(item.expandCount, item.name)
                XCTAssertGreaterThan(count, 0, item.name)
                XCTAssertEqual(
                    line.components(separatedBy: token).count,
                    2,
                    item.name
                )
                line = line.replacingOccurrences(
                    of: token,
                    with: String(repeating: "x", count: count)
                )
            } else {
                XCTAssertNil(item.expandCount, item.name)
            }
            let direction: HelperWireDirection
            switch item.direction {
            case "runtimeToHelper": direction = .runtimeToHelper
            case "helperToRuntime": direction = .helperToRuntime
            default:
                return XCTFail("Unknown fixture direction: \(item.direction)")
            }
            let accepted: Bool
            do {
                _ = try HelperWireCodec.decodeLine(
                    Array(line.utf8),
                    direction: direction
                )
                accepted = true
            } catch {
                accepted = false
            }
            XCTAssertEqual(
                accepted,
                item.expectation == "accept",
                item.name
            )
        }
    }

    func testOneShotOrderingCommittedResultAndDuplicateTerminal() throws {
        var machine = try readyMachine()
        let requestID = try CanonicalUUID(uuid(21))
        try machine.receive(
            try request(messageIndex: 4, requestID: requestID),
            direction: .runtimeToHelper
        )
        try machine.receive(
            try event(.accepted, messageIndex: 5, requestID: requestID),
            direction: .helperToRuntime
        )
        try machine.receive(
            try event(.started, messageIndex: 6, requestID: requestID),
            direction: .helperToRuntime
        )
        try machine.receive(
            try event(.committed, messageIndex: 7, requestID: requestID),
            direction: .helperToRuntime
        )

        XCTAssertThrowsError(
            try machine.receive(
                try result(
                    messageIndex: 8,
                    requestID: requestID,
                    commitState: "notCommitted"
                ),
                direction: .helperToRuntime
            )
        ) { error in
            XCTAssertEqual(
                error as? HelperWireProtocolViolation,
                HelperWireProtocolViolation(
                    reason: .committedResultMismatch,
                    scope: .fatalHelperFailure
                )
            )
        }

        try machine.receive(
            try result(
                messageIndex: 9,
                requestID: requestID,
                commitState: "committed"
            ),
            direction: .helperToRuntime
        )
        XCTAssertThrowsError(
            try machine.receive(
                try event(.started, messageIndex: 10, requestID: requestID),
                direction: .helperToRuntime
            )
        ) { error in
            XCTAssertEqual(
                (error as? HelperWireProtocolViolation)?.reason,
                .eventAfterResult
            )
        }
    }

    func testStreamFrameAckDeliveryAndCleanupBarrier() throws {
        var machine = try readyMachine()
        let sessionID = try CanonicalUUID(uuid(22))
        let delivery = "delivery-1"
        try machine.receive(
            try streamOpen(
                messageIndex: 4,
                sessionID: sessionID,
                deliveryAttemptID: delivery
            ),
            direction: .runtimeToHelper
        )
        try machine.receive(
            try frame(
                messageIndex: 5,
                sessionID: sessionID,
                deliveryAttemptID: delivery,
                sequence: 0
            ),
            direction: .runtimeToHelper
        )
        try machine.receive(
            try close(
                messageIndex: 6,
                sessionID: sessionID,
                deliveryAttemptID: delivery
            ),
            direction: .runtimeToHelper
        )
        XCTAssertThrowsError(
            try machine.completeStreamCleanup(
                sessionID: sessionID,
                deliveryAttemptID: delivery
            )
        ) { error in
            XCTAssertEqual(
                (error as? HelperWireProtocolViolation)?.reason,
                .cleanupBarrierIncomplete
            )
        }
        try machine.receive(
            try frameAccepted(
                messageIndex: 7,
                sessionID: sessionID,
                deliveryAttemptID: delivery,
                sequence: 0
            ),
            direction: .helperToRuntime
        )
        try machine.completeStreamCleanup(
            sessionID: sessionID,
            deliveryAttemptID: delivery
        )
        XCTAssertTrue(machine.snapshot.activeSessionIDs.isEmpty)
    }

    func testDeveloperSupportReferenceRejectsPathAndUnknownRole() throws {
        var validMachine = try readyMachine()
        try validMachine.receive(
            try request(
                messageIndex: 4,
                requestID: CanonicalUUID(uuid(23))
            ),
            direction: .runtimeToHelper
        )

        var pathMachine = try readyMachine()
        var withPath = developerSupportPayload()
        withPath["deviceContext"] = .object(["path": .string("/tmp/image")])
        XCTAssertThrowsError(
            try pathMachine.receive(
                try request(
                    messageIndex: 4,
                    requestID: CanonicalUUID(uuid(24)),
                    backendPayload: withPath
                ),
                direction: .runtimeToHelper
            )
        ) { error in
            XCTAssertEqual(
                (error as? HelperWireProtocolViolation)?.reason,
                .forbiddenPathMaterial
            )
        }

        var roleMachine = try readyMachine()
        var withRole = developerSupportPayload()
        withRole["fileRoles"] = .array([
            .string("classic.image"), .string("other.image"),
        ])
        XCTAssertThrowsError(
            try roleMachine.receive(
                try request(
                    messageIndex: 4,
                    requestID: CanonicalUUID(uuid(25)),
                    backendPayload: withRole
                ),
                direction: .runtimeToHelper
            )
        ) { error in
            XCTAssertEqual(
                (error as? HelperWireProtocolViolation)?.reason,
                .invalidDeveloperSupportReference
            )
        }
    }

    func testCatalogFDPathBoundaryFixture() throws {
        let root = repositoryRoot()
        let fixture = root.appendingPathComponent(
            "Fixtures/requirements/T-016/helper-wire-catalog-fd-path-boundary-l3"
        )
        let input = try JSONDecoder().decode(
            FixtureInput.self,
            from: Data(contentsOf: fixture.appendingPathComponent("input/input.v1.json"))
        )
        let expected = try JSONDecoder().decode(
            FixtureExpected.self,
            from: Data(contentsOf: fixture.appendingPathComponent("expected.v1.json"))
        )
        var observed = [String: String]()
        for item in input.cases {
            observed[item.name] = try runFixtureCase(item.name)
        }
        XCTAssertEqual(observed, expected.outcomes)
        XCTAssertEqual(expected.outcome, "passed")
    }

    private func runFixtureCase(_ name: String) throws -> String {
        switch name {
        case "validCatalogReference":
            var machine = try readyMachine()
            try machine.receive(
                try request(
                    messageIndex: 4,
                    requestID: CanonicalUUID(uuid(26))
                ),
                direction: .runtimeToHelper
            )
            return "accepted"
        case "absolutePath":
            var machine = try readyMachine()
            var payload = developerSupportPayload()
            payload["deviceContext"] = .object([
                "absolutePath": .string("/tmp/image"),
            ])
            return violationReason {
                try machine.receive(
                    try request(
                        messageIndex: 4,
                        requestID: CanonicalUUID(uuid(27)),
                        backendPayload: payload
                    ),
                    direction: .runtimeToHelper
                )
            }
        case "wrongGeneration":
            var machine = try readyMachine()
            var fields = requestFields(
                messageIndex: 4,
                requestID: try CanonicalUUID(uuid(28)),
                backendPayload: developerSupportPayload()
            )
            fields["executorGeneration"] = .unsignedInteger(4)
            return violationReason {
                try machine.receive(
                    try decode(fields, direction: .runtimeToHelper),
                    direction: .runtimeToHelper
                )
            }
        case "frameAckBeforeFrame":
            var machine = try readyMachine()
            let session = try CanonicalUUID(uuid(29))
            try machine.receive(
                try streamOpen(
                    messageIndex: 4,
                    sessionID: session,
                    deliveryAttemptID: "delivery-fixture"
                ),
                direction: .runtimeToHelper
            )
            return violationReason {
                try machine.receive(
                    try frameAccepted(
                        messageIndex: 5,
                        sessionID: session,
                        deliveryAttemptID: "delivery-fixture",
                        sequence: 0
                    ),
                    direction: .helperToRuntime
                )
            }
        case "duplicateResult":
            var machine = try readyMachine()
            let requestID = try CanonicalUUID(uuid(30))
            try machine.receive(
                try request(messageIndex: 4, requestID: requestID),
                direction: .runtimeToHelper
            )
            try machine.receive(
                try result(messageIndex: 5, requestID: requestID),
                direction: .helperToRuntime
            )
            return violationReason {
                try machine.receive(
                    try result(messageIndex: 6, requestID: requestID),
                    direction: .helperToRuntime
                )
            }
        default:
            XCTFail("Unknown fixture case: \(name)")
            return "unknown"
        }
    }

    private func violationReason(_ body: () throws -> Void) -> String {
        do {
            try body()
            return "accepted"
        } catch let error as HelperWireProtocolViolation {
            return error.reason.rawValue
        } catch {
            return "unexpected"
        }
    }

    private func readyMachine() throws -> HelperWireProtocolMachine {
        var machine = HelperWireProtocolMachine(
            runtimeEpoch: 7,
            executorGeneration: 3
        )
        try machine.receive(try hello(messageIndex: 1), direction: .helperToRuntime)
        try machine.receive(
            try helloAccepted(messageIndex: 2),
            direction: .runtimeToHelper
        )
        try machine.receive(try ready(messageIndex: 3), direction: .helperToRuntime)
        return machine
    }

    private func hello(messageIndex: Int) throws -> HelperWireMessage {
        var fields = base(.hello, messageIndex: messageIndex)
        fields["helperBuildID"] = .string("build")
        fields["helperKind"] = .string("direct")
        fields["manifestHash"] = .string(String(repeating: "a", count: 64))
        fields["processStartIdentity"] = .string("1.000002")
        return try decode(fields, direction: .helperToRuntime)
    }

    private func helloAccepted(messageIndex: Int) throws -> HelperWireMessage {
        var fields = base(.helloAccepted, messageIndex: messageIndex)
        fields["manifestHash"] = .string(String(repeating: "a", count: 64))
        return try decode(fields, direction: .runtimeToHelper)
    }

    private func ready(messageIndex: Int) throws -> HelperWireMessage {
        var fields = base(.ready, messageIndex: messageIndex)
        fields["payload"] = .object(["facets": .array([])])
        return try decode(fields, direction: .helperToRuntime)
    }

    private func request(
        messageIndex: Int,
        requestID: CanonicalUUID,
        backendPayload: [String: HelperWireJSONValue]? = nil
    ) throws -> HelperWireMessage {
        try decode(
            requestFields(
                messageIndex: messageIndex,
                requestID: requestID,
                backendPayload: backendPayload ?? developerSupportPayload()
            ),
            direction: .runtimeToHelper
        )
    }

    private func requestFields(
        messageIndex: Int,
        requestID: CanonicalUUID,
        backendPayload: [String: HelperWireJSONValue]
    ) -> [String: HelperWireJSONValue] {
        var fields = base(.request, messageIndex: messageIndex)
        fields["requestID"] = .string(requestID.canonicalString)
        fields["payload"] = .object([
            "actionID": .string(uuid(40)),
            "backendPayload": .object(backendPayload),
            "executorOperationID": .string("operation"),
        ])
        return fields
    }

    private func event(
        _ type: HelperWireMessageID,
        messageIndex: Int,
        requestID: CanonicalUUID
    ) throws -> HelperWireMessage {
        var fields = base(type, messageIndex: messageIndex)
        fields["requestID"] = .string(requestID.canonicalString)
        if type == .progress {
            fields["payload"] = .object(["phase": .string("working")])
        }
        return try decode(fields, direction: .helperToRuntime)
    }

    private func result(
        messageIndex: Int,
        requestID: CanonicalUUID,
        commitState: String? = nil
    ) throws -> HelperWireMessage {
        var fields = base(.result, messageIndex: messageIndex)
        fields["requestID"] = .string(requestID.canonicalString)
        var standard: [String: HelperWireJSONValue] = [
            "outcome": .string("succeeded"),
        ]
        if let commitState { standard["commitState"] = .string(commitState) }
        fields["payload"] = .object([
            "fallbackDisposition": .string("terminal"),
            "result": .object(standard),
        ])
        return try decode(fields, direction: .helperToRuntime)
    }

    private func streamOpen(
        messageIndex: Int,
        sessionID: CanonicalUUID,
        deliveryAttemptID: String
    ) throws -> HelperWireMessage {
        var fields = base(.streamOpen, messageIndex: messageIndex)
        fields["sessionID"] = .string(sessionID.canonicalString)
        fields["deliveryAttemptID"] = .string(deliveryAttemptID)
        fields["payload"] = .object([
            "actionID": .string(uuid(41)),
            "interactionID": .string(uuid(42)),
            "streamKind": .string("pointer"),
            "streamPayload": .object([:]),
        ])
        return try decode(fields, direction: .runtimeToHelper)
    }

    private func frame(
        messageIndex: Int,
        sessionID: CanonicalUUID,
        deliveryAttemptID: String,
        sequence: UInt64
    ) throws -> HelperWireMessage {
        var fields = base(.frame, messageIndex: messageIndex)
        fields["sessionID"] = .string(sessionID.canonicalString)
        fields["deliveryAttemptID"] = .string(deliveryAttemptID)
        fields["payload"] = .object([
            "framePayload": .object([:]),
            "interactionID": .string(uuid(42)),
            "seq": .unsignedInteger(sequence),
        ])
        return try decode(fields, direction: .runtimeToHelper)
    }

    private func frameAccepted(
        messageIndex: Int,
        sessionID: CanonicalUUID,
        deliveryAttemptID: String,
        sequence: UInt64
    ) throws -> HelperWireMessage {
        var fields = base(.frameAccepted, messageIndex: messageIndex)
        fields["sessionID"] = .string(sessionID.canonicalString)
        fields["deliveryAttemptID"] = .string(deliveryAttemptID)
        fields["payload"] = .object([
            "interactionID": .string(uuid(42)),
            "seq": .unsignedInteger(sequence),
        ])
        return try decode(fields, direction: .helperToRuntime)
    }

    private func close(
        messageIndex: Int,
        sessionID: CanonicalUUID,
        deliveryAttemptID: String
    ) throws -> HelperWireMessage {
        var fields = base(.close, messageIndex: messageIndex)
        fields["sessionID"] = .string(sessionID.canonicalString)
        fields["deliveryAttemptID"] = .string(deliveryAttemptID)
        fields["payload"] = .object([
            "interactionID": .string(uuid(42)),
            "reason": .string("done"),
        ])
        return try decode(fields, direction: .runtimeToHelper)
    }

    private func developerSupportPayload() -> [String: HelperWireJSONValue] {
        [
            "assetContentManifestSHA256": .string(
                "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
            ),
            "catalogCanonicalSHA256": .string(
                "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
            ),
            "catalogRevision": .string("catalog-r1"),
            "deviceContext": .object(["service": .string("lockdown")]),
            "fileRoles": .array([
                .string("classic.image"), .string("classic.signature"),
            ]),
            "operation": .string("mount"),
            "preparationAttemptID": .string("attempt-1"),
            "preparationGroupID": .string("prep.direct.lockdown.v1"),
        ]
    }

    private func decode(
        _ fields: [String: HelperWireJSONValue],
        direction: HelperWireDirection
    ) throws -> HelperWireMessage {
        try HelperWireCodec.decodeLine(
            HelperWireCodec.encodeLine(fields: fields, direction: direction),
            direction: direction
        )
    }

    private func base(
        _ type: HelperWireMessageID,
        messageIndex: Int
    ) -> [String: HelperWireJSONValue] {
        [
            "executorGeneration": .unsignedInteger(3),
            "messageID": .string(uuid(messageIndex)),
            "runtimeEpoch": .unsignedInteger(7),
            "schemaVersion": .unsignedInteger(1),
            "type": .string(type.rawValue),
        ]
    }

    private func uuid(_ index: Int) -> String {
        String(format: "00000000-0000-0000-0000-%012x", index)
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url
    }
}

private struct FixtureInput: Decodable {
    struct Case: Decodable { let name: String }
    let cases: [Case]
}

private struct FixtureExpected: Decodable {
    let outcome: String
    let outcomes: [String: String]
}

private struct HelperWireCodecParityFixture: Decodable {
    struct Case: Decodable {
        let direction: String
        let expectation: String
        let expandCount: Int?
        let expandToken: String?
        let line: String
        let name: String
    }

    let cases: [Case]
    let schemaVersion: Int
}
