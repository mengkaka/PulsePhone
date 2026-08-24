import Darwin
import Foundation
import PulsePhoneSharedDefinitions
import PulsePhoneWire

public enum RuntimeHandshakeConnectionState: String, Equatable, Sendable {
    case awaitingHello
    case bootstrapOnly
    case normal
    case closed
}

public enum RuntimeHandshakeCloseReason: Equatable, Sendable {
    case authenticationFailed
    case malformedHello
    case unexpectedState
}

public enum RuntimeHandshakeDecision: Equatable, Sendable {
    case respond(frameBytes: [UInt8], state: RuntimeHandshakeConnectionState)
    case close(RuntimeHandshakeCloseReason)
}

public struct RuntimeHandshakeContext: Sendable {
    public let expectedPeerUserID: uid_t
    public let runtimeBuildID: String
    public let compatibility: RuntimeCompatibilityIdentity
    public let canonicalUDID: CanonicalUDID
    public let runtimeEpoch: UInt64
    public let connectionEpoch: UInt64?
    public let quiescing: Bool
    public let connectionIDFactory: @Sendable () -> CanonicalUUID

    public init(
        expectedPeerUserID: uid_t,
        runtimeBuildID: String,
        compatibility: RuntimeCompatibilityIdentity,
        canonicalUDID: CanonicalUDID,
        runtimeEpoch: UInt64,
        connectionEpoch: UInt64? = nil,
        quiescing: Bool,
        connectionIDFactory: @escaping @Sendable () -> CanonicalUUID
    ) {
        self.expectedPeerUserID = expectedPeerUserID
        self.runtimeBuildID = runtimeBuildID
        self.compatibility = compatibility
        self.canonicalUDID = canonicalUDID
        self.runtimeEpoch = runtimeEpoch
        self.connectionEpoch = connectionEpoch
        self.quiescing = quiescing
        self.connectionIDFactory = connectionIDFactory
    }
}

public final class RuntimeHandshakeServer: @unchecked Sendable {
    private let context: RuntimeHandshakeContext
    private let stateLock = NSLock()
    private var state: RuntimeHandshakeConnectionState = .awaitingHello

    public init(context: RuntimeHandshakeContext) {
        self.context = context
    }

    public var connectionState: RuntimeHandshakeConnectionState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state
    }

    public func receiveHello(
        frameBytes: [UInt8],
        peerSocket: Int32
    ) -> RuntimeHandshakeDecision {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard state == .awaitingHello else {
            state = .closed
            return .close(.unexpectedState)
        }

        guard authenticatedPeerUserID(on: peerSocket) == context.expectedPeerUserID else {
            state = .closed
            return .close(.authenticationFailed)
        }
        let hello: RuntimeHello
        do {
            hello = try RuntimeHandshakeCodec.decodeHello(frameBytes)
        } catch {
            state = .closed
            return .close(.malformedHello)
        }

        let blockers = compatibilityBlockers(for: hello)
        do {
            if blockers.isEmpty {
                let ack = try RuntimeHelloAck(
                    runtimeBuildID: context.runtimeBuildID,
                    compatibility: context.compatibility,
                    connectionID: context.connectionIDFactory(),
                    canonicalUDID: context.canonicalUDID,
                    runtimeEpoch: context.runtimeEpoch,
                    connectionEpoch: context.connectionEpoch,
                    quiescing: context.quiescing
                )
                let frame = try RuntimeHandshakeCodec.encodeAck(ack)
                state = .normal
                return .respond(frameBytes: frame, state: .normal)
            }
            let reject = try RuntimeHelloReject(
                blockers: blockers,
                clientCompatibilityID: hello.compatibility.runtimeCompatibilityID,
                runtimeCompatibilityID: context.compatibility.runtimeCompatibilityID,
                executionCatalogHash: context.compatibility.executionCatalogHash
            )
            let frame = try RuntimeHandshakeCodec.encodeReject(reject)
            state = .bootstrapOnly
            return .respond(frameBytes: frame, state: .bootstrapOnly)
        } catch {
            state = .closed
            return .close(.malformedHello)
        }
    }

    private func compatibilityBlockers(for hello: RuntimeHello) -> [String] {
        var blockers = [String]()
        if !hello.wireRange.contains(RuntimeWireFrame.protocolMajor) {
            blockers.append("wireRange")
        }
        if hello.compatibility.runtimeCompatibilityID
            != context.compatibility.runtimeCompatibilityID
        {
            blockers.append("runtimeCompatibilityID")
        }
        if hello.compatibility.executionCatalogHash
            != context.compatibility.executionCatalogHash
        {
            blockers.append("executionCatalogHash")
        }
        return blockers.sorted()
    }

    private func authenticatedPeerUserID(on socket: Int32) -> uid_t? {
        var userID: uid_t = 0
        var groupID: gid_t = 0
        guard getpeereid(socket, &userID, &groupID) == 0 else {
            return nil
        }
        return userID
    }

}
