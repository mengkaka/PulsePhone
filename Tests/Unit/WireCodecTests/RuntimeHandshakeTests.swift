import Darwin
import Dispatch
import XCTest
@testable import PulsePhoneRuntimeKernel
@testable import PulsePhoneWire
import PulsePhoneSharedDefinitions

final class RuntimeHandshakeTests: XCTestCase {
    func testRuntimeWireHeaderIsBigEndianAndStrict() throws {
        let payload = Array("{}".utf8)
        let bytes = try RuntimeWireFrameCodec.encode(
            RuntimeWireFrame(messageType: .hello, payload: payload)
        )
        XCTAssertEqual(Array(bytes[0..<4]), Array("PPRW".utf8))
        XCTAssertEqual(Array(bytes[4..<8]), [0, 1, 0, 1])
        XCTAssertEqual(Array(bytes[8..<16]), [0, 0, 0, 0, 0, 0, 0, 2])
        XCTAssertEqual(try RuntimeWireFrameCodec.decode(bytes).payload, payload)

        var reserved = bytes
        reserved[10] = 1
        XCTAssertThrowsError(try RuntimeWireFrameCodec.decode(reserved))
        XCTAssertThrowsError(try RuntimeWireFrameCodec.decode(Array(bytes.dropLast())))
        XCTAssertThrowsError(try RuntimeWireFrameCodec.decode(bytes + [0]))
    }

    func testCompatibleHelloAuthenticatesPeerAndEntersNormal() throws {
        let sockets = try makeSocketPair()
        defer { sockets.forEach { _ = Darwin.close($0) } }
        let server = try makeServer(expectedPeerUserID: geteuid())
        let decision = server.receiveHello(
            frameBytes: try RuntimeHandshakeCodec.encodeHello(makeHello()),
            peerSocket: sockets[0]
        )
        guard case .respond(let frame, let state) = decision else {
            return XCTFail("expected response")
        }
        XCTAssertEqual(state, .normal)
        XCTAssertEqual(server.connectionState, .normal)
        let ack = try RuntimeHandshakeCodec.decodeAck(frame)
        XCTAssertEqual(ack.selectedWireMajor, 1)
        XCTAssertEqual(ack.canonicalUDID.rawValue, "00008030-001C2D")
        XCTAssertEqual(ack.runtimeEpoch, 7)
        XCTAssertNil(ack.connectionEpoch)
        XCTAssertFalse(ack.quiescing)
    }

    func testEveryCompatibilityMismatchEntersBootstrapOnly() throws {
        let sockets = try makeSocketPair()
        defer { sockets.forEach { _ = Darwin.close($0) } }
        let mismatches: [RuntimeHello] = [
            try makeHello(wireRange: RuntimeWireRange(minimum: 2, maximum: 2)),
            try makeHello(runtimeCompatibilityID: "runtime.compat.other"),
            try makeHello(executionCatalogHash: String(repeating: "c", count: 64)),
        ]
        for hello in mismatches {
            let server = try makeServer(expectedPeerUserID: geteuid())
            let decision = server.receiveHello(
                frameBytes: try RuntimeHandshakeCodec.encodeHello(hello),
                peerSocket: sockets[0]
            )
            guard case .respond(let frame, let state) = decision else {
                return XCTFail("expected reject")
            }
            XCTAssertEqual(state, .bootstrapOnly)
            let reject = try RuntimeHandshakeCodec.decodeReject(frame)
            XCTAssertEqual(reject.code, "incompatibleRuntime")
            XCTAssertFalse(reject.blockers.isEmpty)
            XCTAssertEqual(server.connectionState, .bootstrapOnly)
        }
    }

    func testHandshakeDecodersAcceptRFC8259EncodingAndRejectTypedOptionals() throws {
        let encodedHello = try RuntimeHandshakeCodec.encodeHello(makeHello())
        let helloFrame = try RuntimeWireFrameCodec.decode(encodedHello)
        let nonCanonicalHello = try RuntimeWireFrameCodec.encode(
            RuntimeWireFrame(
                messageType: .hello,
                payload: [0x20, 0x0a] + helloFrame.payload + [0x0a]
            )
        )
        XCTAssertEqual(
            try RuntimeHandshakeCodec.decodeHello(nonCanonicalHello),
            try makeHello()
        )

        let reject = try RuntimeHelloReject(
            blockers: ["executionCatalogHash"],
            clientCompatibilityID: "runtime.compat.other",
            runtimeCompatibilityID: "runtime.compat.v1",
            executionCatalogHash: String(repeating: "a", count: 64)
        )
        XCTAssertEqual(
            try RuntimeHandshakeCodec.decodeReject(
                RuntimeHandshakeCodec.encodeReject(reject)
            ),
            reject
        )

        let invalidOptional = Array(
            "{\"code\":\"incompatibleRuntime\",\"details\":{\"blockers\":[\"executionCatalogHash\"],\"clientCompatibilityID\":\"runtime.compat.other\",\"executionCatalogHash\":1,\"runtimeCompatibilityID\":\"runtime.compat.v1\"},\"schemaVersion\":1}".utf8
        )
        XCTAssertThrowsError(
            try RuntimeHandshakeCodec.decodeReject(
                RuntimeWireFrameCodec.encode(
                    RuntimeWireFrame(
                        messageType: .helloReject,
                        payload: invalidOptional
                    )
                )
            )
        )
    }

    func testPeerUIDMismatchAndMalformedHelloCloseWithoutReject() throws {
        let sockets = try makeSocketPair()
        defer { sockets.forEach { _ = Darwin.close($0) } }
        let authServer = try makeServer(expectedPeerUserID: geteuid() &+ 1)
        XCTAssertEqual(
            authServer.receiveHello(
                frameBytes: try RuntimeHandshakeCodec.encodeHello(makeHello()),
                peerSocket: sockets[0]
            ),
            .close(.authenticationFailed)
        )

        let malformedServer = try makeServer(expectedPeerUserID: geteuid())
        XCTAssertEqual(
            malformedServer.receiveHello(
                frameBytes: [0, 1, 2],
                peerSocket: sockets[0]
            ),
            .close(.malformedHello)
        )
        XCTAssertEqual(malformedServer.connectionState, .closed)
    }

    func testHelloIsExactlyOncePerConnection() throws {
        let sockets = try makeSocketPair()
        defer { sockets.forEach { _ = Darwin.close($0) } }
        let server = try makeServer(expectedPeerUserID: geteuid())
        let hello = try RuntimeHandshakeCodec.encodeHello(makeHello())
        _ = server.receiveHello(frameBytes: hello, peerSocket: sockets[0])
        XCTAssertEqual(
            server.receiveHello(frameBytes: hello, peerSocket: sockets[0]),
            .close(.unexpectedState)
        )
        XCTAssertEqual(server.connectionState, .closed)
    }

    func testConcurrentHelloHasExactlyOneResponse() throws {
        let sockets = try makeSocketPair()
        defer { sockets.forEach { _ = Darwin.close($0) } }
        let server = try makeServer(expectedPeerUserID: geteuid())
        let hello = try RuntimeHandshakeCodec.encodeHello(makeHello())
        let decisionStore = LockedDecisionStore()

        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            decisionStore.append(
                server.receiveHello(
                    frameBytes: hello,
                    peerSocket: sockets[0]
                )
            )
        }
        let decisions = decisionStore.snapshot

        XCTAssertEqual(
            decisions.filter {
                guard case .respond = $0 else { return false }
                return true
            }.count,
            1
        )
        XCTAssertEqual(
            decisions.filter { $0 == .close(.unexpectedState) }.count,
            7
        )
        XCTAssertEqual(server.connectionState, .closed)
    }

    func testBootstrapControlIsExactlyOneBoundedRequest() throws {
        let request = BootstrapRequest(
            requestID: try CanonicalUUID("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            operation: .probeRuntimeLite
        )
        let bytes = try BootstrapControlCodec.encodeRequest(request)
        let session = try BootstrapControlSession(
            startedAt: MonotonicInstant(nanoseconds: 10)
        )
        XCTAssertEqual(
            try session.accept(bytes, now: MonotonicInstant(nanoseconds: 20)),
            request
        )
        XCTAssertThrowsError(
            try session.accept(bytes, now: MonotonicInstant(nanoseconds: 21))
        ) { error in
            XCTAssertEqual(error as? BootstrapControlSessionError, .alreadyConsumed)
        }

        let expired = try BootstrapControlSession(
            startedAt: MonotonicInstant(nanoseconds: 0)
        )
        XCTAssertThrowsError(
            try expired.accept(
                bytes,
                now: MonotonicInstant(
                    nanoseconds: BootstrapControlSession.absoluteLifetimeNanoseconds + 1
                )
            )
        ) { error in
            XCTAssertEqual(error as? BootstrapControlSessionError, .expired)
        }
    }

    func testBootstrapResponsePresenceAndErrorSubsetAreClosed() throws {
        let requestID = try CanonicalUUID(
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        let result = try RepositoryJSONObject(members: [])
        let success = BootstrapResponse(
            requestID: requestID,
            operation: .retireIfIdle,
            result: result
        )
        XCTAssertEqual(
            try BootstrapControlCodec.decodeResponse(
                BootstrapControlCodec.encodeResponse(success)
            ),
            success
        )
        let failure = BootstrapResponse(
            requestID: requestID,
            operation: .probeRuntimeLite,
            error: try BootstrapErrorPayload(
                code: "incompatibleRuntimeBusy",
                details: try RepositoryJSONObject(members: [])
            )
        )
        XCTAssertEqual(
            try BootstrapControlCodec.decodeResponse(
                BootstrapControlCodec.encodeResponse(failure)
            ),
            failure
        )
        XCTAssertThrowsError(
            try BootstrapErrorPayload(
                code: "invalidArgument",
                details: try RepositoryJSONObject(members: [])
            )
        )
    }

    private func makeHello(
        wireRange: RuntimeWireRange = try! RuntimeWireRange(minimum: 1, maximum: 1),
        runtimeCompatibilityID: String = "runtime.compat.v1",
        executionCatalogHash: String = String(repeating: "a", count: 64)
    ) throws -> RuntimeHello {
        try RuntimeHello(
            wireRange: wireRange,
            clientBuildID: "client.test",
            compatibility: RuntimeCompatibilityIdentity(
                runtimeCompatibilityID: runtimeCompatibilityID,
                executionCatalogHash: executionCatalogHash
            ),
            clientInstanceID: try CanonicalUUID(
                "11111111-2222-3333-4444-555555555555"
            ),
            role: .cli
        )
    }

    private func makeServer(
        expectedPeerUserID: uid_t
    ) throws -> RuntimeHandshakeServer {
        RuntimeHandshakeServer(
            context: RuntimeHandshakeContext(
                expectedPeerUserID: expectedPeerUserID,
                runtimeBuildID: "runtime.test",
                compatibility: try RuntimeCompatibilityIdentity(
                    runtimeCompatibilityID: "runtime.compat.v1",
                    executionCatalogHash: String(repeating: "a", count: 64)
                ),
                canonicalUDID: try CanonicalUDID(
                    canonicalString: "00008030-001C2D"
                ),
                runtimeEpoch: 7,
                connectionEpoch: nil,
                quiescing: false,
                connectionIDFactory: {
                    try! CanonicalUUID("99999999-8888-7777-6666-555555555555")
                }
            )
        )
    }

    private func makeSocketPair() throws -> [Int32] {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.EIO)
        }
        return descriptors
    }
}

private final class LockedDecisionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var decisions = [RuntimeHandshakeDecision]()

    func append(_ decision: RuntimeHandshakeDecision) {
        lock.lock()
        decisions.append(decision)
        lock.unlock()
    }

    var snapshot: [RuntimeHandshakeDecision] {
        lock.lock()
        defer { lock.unlock() }
        return decisions
    }
}
