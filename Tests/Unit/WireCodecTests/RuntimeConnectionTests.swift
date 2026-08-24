import Darwin
import Foundation
import XCTest
@testable import PulsePhoneRuntimeKernel
@testable import PulsePhoneWire
import PulsePhoneSharedDefinitions

final class RuntimeConnectionTests: XCTestCase {
    func testDemultiplexerHandlesPartialAndMultipleFramesWithAbsoluteDeadline() throws {
        let first = try encodedFrame(type: .protocolError, payload: "{}")
        let second = try encodedFrame(type: .streamFrame, payload: "{}")
        let demultiplexer = ConnectionDemultiplexer()
        XCTAssertTrue(
            try demultiplexer.consume(
                Array(first.prefix(7)),
                now: MonotonicInstant(nanoseconds: 10)
            ).isEmpty
        )
        let frames = try demultiplexer.consume(
            Array(first.dropFirst(7)) + second,
            now: MonotonicInstant(nanoseconds: 20)
        )
        XCTAssertEqual(frames.map(\.messageType), [.protocolError, .streamFrame])

        let trickle = ConnectionDemultiplexer()
        _ = try trickle.consume(
            [first[0]],
            now: MonotonicInstant(nanoseconds: 100)
        )
        _ = try trickle.consume(
            [first[1]],
            now: MonotonicInstant(
                nanoseconds: 100
                    + ConnectionDemultiplexer.assemblyTimeoutNanoseconds - 1
            )
        )
        XCTAssertThrowsError(
            try trickle.consume(
                [first[2]],
                now: MonotonicInstant(
                    nanoseconds: 101
                        + ConnectionDemultiplexer.assemblyTimeoutNanoseconds
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ConnectionDemultiplexerError,
                .frameAssemblyTimedOut
            )
        }
    }

    func testSerializedWriterPreservesSequenceAndFinalReserve() throws {
        let writer = SerializedWriter()
        let regular = RuntimeWireFrame(
            messageType: .runtimeEvent,
            payload: Array("{}".utf8)
        )
        let terminal = RuntimeWireFrame(
            messageType: .response,
            payload: Array("{}".utf8)
        )
        for _ in 0..<SerializedWriter.regularFrameCap {
            XCTAssertEqual(
                try writer.enqueue(regular, lane: .regularReliable),
                .enqueued
            )
        }
        XCTAssertEqual(
            try writer.enqueue(regular, lane: .regularReliable),
            .regularQueueSaturated
        )
        for _ in 0..<SerializedWriter.finalControlFrameCap {
            XCTAssertEqual(
                try writer.enqueue(terminal, lane: .finalControl),
                .enqueued
            )
        }
        XCTAssertEqual(
            try writer.enqueue(terminal, lane: .finalControl),
            .disconnectRequired
        )

        var bytes = [UInt8]()
        while writer.queuedFrameCount > 0 {
            _ = try writer.drainNext(
                now: MonotonicInstant(nanoseconds: 1)
            ) { remaining in
                let count = min(5, remaining.count)
                bytes.append(contentsOf: remaining.prefix(count))
                return count
            }
        }
        let frames = try ConnectionDemultiplexer().consume(
            bytes,
            now: MonotonicInstant(nanoseconds: 1)
        )
        XCTAssertEqual(
            frames.map(\.messageType),
            Array(repeating: .runtimeEvent, count: 128)
                + Array(repeating: .response, count: 4)
        )

        let byteBounded = SerializedWriter()
        let large = RuntimeWireFrame(
            messageType: .runtimeEvent,
            payload: Array(repeating: 0x20, count: 256 * 1_024)
        )
        for _ in 0..<7 {
            XCTAssertEqual(
                try byteBounded.enqueue(large, lane: .regularReliable),
                .enqueued
            )
        }
        XCTAssertEqual(
            try byteBounded.enqueue(large, lane: .regularReliable),
            .regularQueueSaturated
        )
    }

    func testSlowWriterPartialProgressDoesNotRefreshDeadline() throws {
        let writer = SerializedWriter()
        XCTAssertEqual(
            try writer.enqueue(
                RuntimeWireFrame(
                    messageType: .response,
                    payload: Array("{}".utf8)
                ),
                lane: .finalControl
            ),
            .enqueued
        )
        XCTAssertEqual(
            try writer.drainNext(now: MonotonicInstant(nanoseconds: 50)) { _ in 0 },
            .wouldBlock
        )
        XCTAssertEqual(
            try writer.drainNext(
                now: MonotonicInstant(
                    nanoseconds: 50
                        + SerializedWriter.writeTimeoutNanoseconds - 1
                )
            ) { _ in 1 },
            .partial
        )
        XCTAssertThrowsError(
            try writer.drainNext(
                now: MonotonicInstant(
                    nanoseconds: 51
                        + SerializedWriter.writeTimeoutNanoseconds
                )
            ) { _ in 1 }
        ) { error in
            XCTAssertEqual(error as? SerializedWriterError, .writeTimedOut)
        }
    }

    func testOutstandingDuplicateTombstoneAndCaps() throws {
        let runtimeRegistry = RuntimeOutstandingRegistry()
        let requests = RuntimeConnectionRequests(runtimeRegistry: runtimeRegistry)
        let requestID = try uuid(1)
        try requests.accept(
            requestID: requestID,
            operation: .runtimeHealth,
            now: MonotonicInstant(nanoseconds: 0)
        )
        XCTAssertThrowsError(
            try requests.accept(
                requestID: requestID,
                operation: .runtimeHealth,
                now: MonotonicInstant(nanoseconds: 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeRequestTrackingError,
                .duplicateRequestID
            )
        }
        try requests.complete(
            requestID: requestID,
            operation: .runtimeHealth,
            now: MonotonicInstant(nanoseconds: 2)
        )
        XCTAssertThrowsError(
            try requests.accept(
                requestID: requestID,
                operation: .runtimeHealth,
                now: MonotonicInstant(nanoseconds: 3)
            )
        )
        try requests.accept(
            requestID: requestID,
            operation: .runtimeHealth,
            now: MonotonicInstant(
                nanoseconds: 2
                    + RuntimeConnectionRequests.tombstoneLifetimeNanoseconds
            )
        )
        requests.disconnect()

        for index in 0..<64 {
            try requests.accept(
                requestID: try uuid(index + 100),
                operation: .runtimeRecordLocalAction,
                now: MonotonicInstant(nanoseconds: 0)
            )
        }
        XCTAssertEqual(requests.activeCount, 0)
        XCTAssertEqual(runtimeRegistry.outstandingCount, 0)

        var connections = [RuntimeConnectionRequests]()
        for connectionIndex in 0..<8 {
            let connection = RuntimeConnectionRequests(
                runtimeRegistry: runtimeRegistry
            )
            connections.append(connection)
            for requestIndex in 0..<16 {
                try connection.accept(
                    requestID: try uuid(
                        1_000 + connectionIndex * 16 + requestIndex
                    ),
                    operation: .runtimeHealth,
                    now: MonotonicInstant(nanoseconds: 0)
                )
            }
        }
        XCTAssertEqual(runtimeRegistry.outstandingCount, 128)
        let overflow = RuntimeConnectionRequests(runtimeRegistry: runtimeRegistry)
        XCTAssertThrowsError(
            try overflow.accept(
                requestID: try uuid(9_999),
                operation: .runtimeHealth,
                now: MonotonicInstant(nanoseconds: 0)
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeRequestTrackingError,
                .runtimeCapacityExceeded
            )
        }
        connections.forEach { $0.disconnect() }
        XCTAssertEqual(runtimeRegistry.outstandingCount, 0)
    }

    func testDispatcherClosesOnDuplicateWrongDirectionAndTargetMismatch() throws {
        let registry = RuntimeOutstandingRegistry()
        let requests = RuntimeConnectionRequests(runtimeRegistry: registry)
        let dispatcher = try ControlDispatcher(
            state: .normal,
            canonicalUDID: target,
            requests: requests
        )
        let frame = try requestFrame(
            requestID: uuid(20),
            operation: .runtimeHealth,
            canonicalUDID: target.rawValue
        )
        guard case .request(let request) = try dispatcher.dispatch(
            frame,
            now: MonotonicInstant(nanoseconds: 0)
        ) else {
            return XCTFail("expected request")
        }
        XCTAssertEqual(request.operation, .runtimeHealth)
        XCTAssertThrowsError(
            try dispatcher.dispatch(
                frame,
                now: MonotonicInstant(nanoseconds: 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? ControlDispatcherError,
                .requestTracking(.duplicateRequestID)
            )
        }
        XCTAssertEqual(dispatcher.connectionState, .closed)

        let wrongTarget = try ControlDispatcher(
            state: .normal,
            canonicalUDID: target,
            requests: RuntimeConnectionRequests(runtimeRegistry: registry)
        )
        XCTAssertThrowsError(
            try wrongTarget.dispatch(
                requestFrame(
                    requestID: uuid(21),
                    operation: .runtimeHealth,
                    canonicalUDID: "00008030-OTHER"
                ),
                now: MonotonicInstant(nanoseconds: 0)
            )
        ) { error in
            XCTAssertEqual(error as? ControlDispatcherError, .targetMismatch)
        }
        XCTAssertEqual(wrongTarget.connectionState, .closed)

        let wrongDirection = try ControlDispatcher(
            state: .normal,
            canonicalUDID: target,
            requests: RuntimeConnectionRequests(runtimeRegistry: registry)
        )
        XCTAssertThrowsError(
            try wrongDirection.dispatch(
                RuntimeWireFrame(
                    messageType: .aggregateResponse,
                    payload: []
                ),
                now: MonotonicInstant(nanoseconds: 0)
            )
        ) { error in
            XCTAssertEqual(error as? ControlDispatcherError, .protocolViolation)
        }
        XCTAssertEqual(wrongDirection.connectionState, .closed)
    }

    func testTerminalOrderingAndPostTerminalAssociation() throws {
        let runtime = RuntimeOutstandingRegistry()
        let connection = RuntimeConnection(runtimeRegistry: runtime)
        let requestID = try uuid(30)
        try connection.requests.accept(
            requestID: requestID,
            operation: .commandSubmit,
            now: MonotonicInstant(nanoseconds: 0)
        )
        XCTAssertEqual(
            try connection.enqueueAssociated(
                RuntimeWireFrame(
                    messageType: .runtimeEvent,
                    payload: Array("{}".utf8)
                ),
                requestID: requestID,
                kind: .event,
                now: MonotonicInstant(nanoseconds: 1)
            ),
            .enqueued
        )
        XCTAssertThrowsError(
            try connection.enqueueTerminalResponse(
                responseFrame(
                    requestID: requestID,
                    operation: .runtimeHealth
                ),
                now: MonotonicInstant(nanoseconds: 2)
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeRequestTrackingError,
                .operationMismatch
            )
        }
        XCTAssertEqual(
            try connection.enqueueTerminalResponse(
                responseFrame(
                    requestID: requestID,
                    operation: .commandSubmit
                ),
                now: MonotonicInstant(nanoseconds: 2)
            ),
            .enqueued
        )
        XCTAssertThrowsError(
            try connection.enqueueAssociated(
                RuntimeWireFrame(
                    messageType: .progress,
                    payload: Array("{}".utf8)
                ),
                requestID: requestID,
                kind: .progress,
                now: MonotonicInstant(nanoseconds: 3)
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeRequestTrackingError,
                .associatedMessageAfterTerminal
            )
        }

        var bytes = [UInt8]()
        while connection.writer.queuedFrameCount > 0 {
            _ = try connection.writer.drainNext(
                now: MonotonicInstant(nanoseconds: 4)
            ) { remaining in
                bytes.append(contentsOf: remaining)
                return remaining.count
            }
        }
        XCTAssertEqual(
            try ConnectionDemultiplexer().consume(
                bytes,
                now: MonotonicInstant(nanoseconds: 4)
            ).map(\.messageType),
            [.runtimeEvent, .response]
        )
    }

    func testAcceptedConnectionComposesDemuxAndControlDispatch() throws {
        let connection = try RuntimeConnection.accepted(
            state: .normal,
            canonicalUDID: target,
            runtimeRegistry: RuntimeOutstandingRegistry()
        )
        let requestBytes = try RuntimeWireFrameCodec.encode(
            requestFrame(
                requestID: uuid(35),
                operation: .runtimeHealth,
                canonicalUDID: target.rawValue
            )
        )
        XCTAssertTrue(
            try connection.receive(
                Array(requestBytes.prefix(5)),
                now: MonotonicInstant(nanoseconds: 0)
            ).isEmpty
        )
        let messages = try connection.receive(
            Array(requestBytes.dropFirst(5)),
            now: MonotonicInstant(nanoseconds: 1)
        )
        guard case .request(let request)? = messages.first else {
            return XCTFail("expected composed request dispatch")
        }
        XCTAssertEqual(request.requestID, try uuid(35))
        XCTAssertEqual(request.operation, .runtimeHealth)
    }

    func testCompatibilityBootstrapFixture() throws {
        let expected = try loadFixtureObject("expected.v1.json")
        let sockets = try makeSocketPair()
        defer { sockets.forEach { _ = Darwin.close($0) } }
        let handshake = RuntimeHandshakeServer(
            context: RuntimeHandshakeContext(
                expectedPeerUserID: geteuid(),
                runtimeBuildID: "runtime.test",
                compatibility: try compatibility(),
                canonicalUDID: target,
                runtimeEpoch: 1,
                quiescing: false,
                connectionIDFactory: {
                    try! CanonicalUUID(
                        "00000000-0000-0000-0000-000000000028"
                    )
                }
            )
        )
        let mismatch = try RuntimeHello(
            wireRange: RuntimeWireRange(minimum: 1, maximum: 1),
            clientBuildID: "client.test",
            compatibility: RuntimeCompatibilityIdentity(
                runtimeCompatibilityID: "runtime.compat.other",
                executionCatalogHash: String(repeating: "a", count: 64)
            ),
            clientInstanceID: uuid(41),
            role: .cli
        )
        guard case .respond(_, let state) = handshake.receiveHello(
            frameBytes: try RuntimeHandshakeCodec.encodeHello(mismatch),
            peerSocket: sockets[0]
        ) else {
            return XCTFail("expected compatibility reject")
        }
        XCTAssertEqual(state.rawValue, expected["mismatchState"]?.stringValue)

        let dispatcher = try ControlDispatcher(
            state: state,
            canonicalUDID: target,
            requests: RuntimeConnectionRequests(
                runtimeRegistry: RuntimeOutstandingRegistry()
            ),
            bootstrapStartedAt: MonotonicInstant(nanoseconds: 0)
        )
        let request = BootstrapRequest(
            requestID: try uuid(42),
            operation: .probeRuntimeLite
        )
        let requestFrame = try RuntimeWireFrameCodec.decode(
            BootstrapControlCodec.encodeRequest(request)
        )
        guard case .bootstrap(let accepted) = try dispatcher.dispatch(
            requestFrame,
            now: MonotonicInstant(nanoseconds: 1)
        ) else {
            return XCTFail("expected bootstrap request")
        }
        XCTAssertEqual(accepted, request)
        XCTAssertThrowsError(
            try dispatcher.dispatch(
                requestFrame,
                now: MonotonicInstant(nanoseconds: 2)
            )
        )
        XCTAssertEqual(
            expected["oneBootstrapRequest"]?.boolValue,
            true
        )

        let completion = try ControlDispatcher(
            state: .bootstrapOnly,
            canonicalUDID: target,
            requests: RuntimeConnectionRequests(
                runtimeRegistry: RuntimeOutstandingRegistry()
            ),
            bootstrapStartedAt: MonotonicInstant(nanoseconds: 0)
        )
        _ = try completion.dispatch(
            requestFrame,
            now: MonotonicInstant(nanoseconds: 1)
        )
        try completion.completeBootstrapResponse(
            BootstrapResponse(
                requestID: request.requestID,
                operation: request.operation,
                result: try object([])
            )
        )
        XCTAssertEqual(completion.connectionState, .closed)
    }

    private var target: CanonicalUDID {
        try! CanonicalUDID(canonicalString: "00008030-001C2D")
    }

    private func encodedFrame(
        type: RuntimeWireMessageType,
        payload: String
    ) throws -> [UInt8] {
        try RuntimeWireFrameCodec.encode(
            RuntimeWireFrame(
                messageType: type,
                payload: Array(payload.utf8)
            )
        )
    }

    private func requestFrame(
        requestID: CanonicalUUID,
        operation: RuntimeOperationID,
        canonicalUDID: String
    ) throws -> RuntimeWireFrame {
        let body = try object([
            ("canonicalUDID", .string(canonicalUDID)),
        ])
        let payload = try object([
            ("body", .object(body)),
            ("operation", .string(operation.rawValue)),
        ])
        let envelope = try object([
            ("payload", .object(payload)),
            ("requestID", .string(requestID.canonicalString)),
            ("schemaVersion", .number(.uint64(1))),
        ])
        return RuntimeWireFrame(
            messageType: .request,
            payload: RepositoryCanonicalJSON.encodeDocument(envelope)
        )
    }

    private func responseFrame(
        requestID: CanonicalUUID,
        operation: RuntimeOperationID
    ) throws -> RuntimeWireFrame {
        let result = try object([
            ("outcome", .string("succeeded")),
        ])
        let payload = try object([
            ("operation", .string(operation.rawValue)),
            ("result", .object(result)),
        ])
        let envelope = try object([
            ("payload", .object(payload)),
            ("requestID", .string(requestID.canonicalString)),
            ("schemaVersion", .number(.uint64(1))),
        ])
        return RuntimeWireFrame(
            messageType: .response,
            payload: RepositoryCanonicalJSON.encodeDocument(envelope)
        )
    }

    private func object(
        _ members: [(String, RepositoryJSONValue)]
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(
            members: members.map {
                RepositoryJSONMember(key: $0.0, value: $0.1)
            }
        )
    }

    private func uuid(_ value: Int) throws -> CanonicalUUID {
        try CanonicalUUID(
            String(format: "00000000-0000-0000-0000-%012x", value)
        )
    }

    private func compatibility() throws -> RuntimeCompatibilityIdentity {
        try RuntimeCompatibilityIdentity(
            runtimeCompatibilityID: "runtime.compat.v1",
            executionCatalogHash: String(repeating: "a", count: 64)
        )
    }

    private func makeSocketPair() throws -> [Int32] {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.EIO)
        }
        return descriptors
    }

    private func loadFixtureObject(
        _ relativePath: String
    ) throws -> RepositoryJSONObject {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: root.appendingPathComponent(
                "Fixtures/requirements/T-016/runtime-wire-compatibility-bootstrap-l3/"
                    + relativePath
            )
        )
        return try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](data),
            maximumByteCount: 16 * 1_024
        ).root
    }
}

private extension RepositoryJSONValue {
    var boolValue: Bool? {
        guard case .bool(let value) = self else {
            return nil
        }
        return value
    }
}
