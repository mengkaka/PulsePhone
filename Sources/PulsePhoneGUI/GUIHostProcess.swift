import Foundation
import PulsePhoneHostPaths
import PulsePhoneSharedDefinitions

public struct GUIHostWireRange: Codable, Equatable, Sendable {
    public let maximum: UInt16
    public let minimum: UInt16

    public init(minimum: UInt16, maximum: UInt16) {
        self.minimum = minimum
        self.maximum = maximum
    }
}

public struct GUIHostHello: Codable, Equatable, Sendable {
    public let canonicalAppPathHash: String
    public let guiHostCompatibilityID: String
    public let launcherBuildID: String
    public let launcherInstanceID: CanonicalUUID
    public let schemaVersion: Int
    public let wireRange: GUIHostWireRange

    public init(
        canonicalAppPathHash: String,
        guiHostCompatibilityID: String,
        launcherBuildID: String,
        launcherInstanceID: CanonicalUUID,
        wireRange: GUIHostWireRange
    ) {
        self.canonicalAppPathHash = canonicalAppPathHash
        self.guiHostCompatibilityID = guiHostCompatibilityID
        self.launcherBuildID = launcherBuildID
        self.launcherInstanceID = launcherInstanceID
        self.schemaVersion = 1
        self.wireRange = wireRange
    }
}

public struct GUIHostHelloAck: Codable, Equatable, Sendable {
    public let canonicalAppPathHash: String
    public let guiBuildID: String
    public let guiHostCompatibilityID: String
    public let guiHostInstanceID: CanonicalUUID
    public let schemaVersion: Int
    public let selectedWireMajor: UInt16

    public init(
        canonicalAppPathHash: String,
        guiBuildID: String,
        guiHostCompatibilityID: String,
        guiHostInstanceID: CanonicalUUID,
        schemaVersion: Int = 1,
        selectedWireMajor: UInt16
    ) {
        self.canonicalAppPathHash = canonicalAppPathHash
        self.guiBuildID = guiBuildID
        self.guiHostCompatibilityID = guiHostCompatibilityID
        self.guiHostInstanceID = guiHostInstanceID
        self.schemaVersion = schemaVersion
        self.selectedWireMajor = selectedWireMajor
    }
}

public enum GUIHostHelloDisposition: Equatable, Sendable {
    case accepted(GUIHostHelloAck)
    case rejected
}

public enum GUIHostSourceSelectionPolicy: String, Equatable, Sendable {
    case automatic
    case forceChooser
}

public struct GUIHostOpenLiveRequest: Equatable, Sendable {
    public let canonicalUDID: CanonicalUDID
    public let requestID: CanonicalUUID
    public let sourceSelectionPolicy: GUIHostSourceSelectionPolicy

    public init(
        requestID: CanonicalUUID,
        canonicalUDID: CanonicalUDID,
        sourceSelectionPolicy: GUIHostSourceSelectionPolicy = .automatic
    ) {
        self.requestID = requestID
        self.canonicalUDID = canonicalUDID
        self.sourceSelectionPolicy = sourceSelectionPolicy
    }
}

public enum GUIHostOpenErrorCode: String, Equatable, Sendable {
    case guiHostBusy
    case liveAlreadyOpen
    case windowCreateFailed
}

public enum GUIHostOpenDisposition: String, Equatable, Sendable {
    case alreadyOpen
    case failed
    case opened
    case sourceSelectionOpened
}

public struct GUIHostOpenLiveResult: Equatable, Sendable {
    public let canonicalUDID: CanonicalUDID?
    public let disposition: GUIHostOpenDisposition
    public let errorCode: GUIHostOpenErrorCode?
    public let requestID: CanonicalUUID
    public let windowID: String?

    public init(
        requestID: CanonicalUUID,
        disposition: GUIHostOpenDisposition,
        canonicalUDID: CanonicalUDID?,
        windowID: String?,
        errorCode: GUIHostOpenErrorCode?
    ) {
        self.requestID = requestID
        self.disposition = disposition
        self.canonicalUDID = canonicalUDID
        self.windowID = windowID
        self.errorCode = errorCode
    }
}

public struct GUIHostOpenToken: Equatable, Sendable {
    public let canonicalUDID: CanonicalUDID
    public let connectionID: CanonicalUUID
    public let deadlineNanoseconds: UInt64
    public let requestID: CanonicalUUID
    public let sourceSelectionPolicy: GUIHostSourceSelectionPolicy
}

public enum GUIHostOpenStart: Equatable, Sendable {
    case pending(GUIHostOpenToken)
    case terminal(GUIHostOpenLiveResult)
}

public enum GUIHostProcessError: Error, Equatable, Sendable {
    case duplicateConnection
    case invalidConnectionState
    case invalidWindowID
    case requestNotFound
    case staleWindowClose
}

public struct GUIHostProcess: Sendable {
    public static let compatibilityID = "guihost.v2"
    public static let openLiveDeadlineNanoseconds: UInt64 = 5_000_000_000
    public static let pendingOpenLimit = 8
    public static let selectedWireMajor: UInt16 = 1

    private enum ConnectionState: Equatable, Sendable {
        case awaitingHello
        case normal
        case rejected
    }

    private let endpoint: GUIHostEndpoint
    private let guiBuildID: String
    private let guiHostInstanceID: CanonicalUUID
    private var connections = [CanonicalUUID: ConnectionState]()
    private var openWindows = [CanonicalUDID: String]()
    private var pending = [CanonicalUUID: GUIHostOpenToken]()
    private var reservedTargets = Set<CanonicalUDID>()

    public init(
        endpoint: GUIHostEndpoint,
        guiBuildID: String,
        guiHostInstanceID: CanonicalUUID
    ) {
        self.endpoint = endpoint
        self.guiBuildID = guiBuildID
        self.guiHostInstanceID = guiHostInstanceID
    }

    public var openWindowCount: Int { openWindows.count }
    public var pendingOpenCount: Int { pending.count }

    public mutating func acceptConnection(
        connectionID: CanonicalUUID
    ) throws {
        guard connections[connectionID] == nil else {
            throw GUIHostProcessError.duplicateConnection
        }
        connections[connectionID] = .awaitingHello
    }

    public mutating func receiveHello(
        connectionID: CanonicalUUID,
        hello: GUIHostHello
    ) throws -> GUIHostHelloDisposition {
        guard connections[connectionID] == .awaitingHello else {
            throw GUIHostProcessError.invalidConnectionState
        }
        guard hello.schemaVersion == 1,
              hello.canonicalAppPathHash == endpoint.canonicalAppPathHash,
              hello.guiHostCompatibilityID == Self.compatibilityID,
              hello.wireRange.minimum <= Self.selectedWireMajor,
              hello.wireRange.maximum >= Self.selectedWireMajor
        else {
            connections[connectionID] = .rejected
            return .rejected
        }
        connections[connectionID] = .normal
        return .accepted(GUIHostHelloAck(
            canonicalAppPathHash: endpoint.canonicalAppPathHash,
            guiBuildID: guiBuildID,
            guiHostCompatibilityID: Self.compatibilityID,
            guiHostInstanceID: guiHostInstanceID,
            schemaVersion: 1,
            selectedWireMajor: Self.selectedWireMajor
        ))
    }

    public mutating func beginOpenLive(
        connectionID: CanonicalUUID,
        request: GUIHostOpenLiveRequest,
        atMonotonicNanoseconds now: UInt64
    ) throws -> GUIHostOpenStart {
        guard connections[connectionID] == .normal else {
            throw GUIHostProcessError.invalidConnectionState
        }
        if pending.values.contains(where: { $0.connectionID == connectionID })
            || pending.count >= Self.pendingOpenLimit
        {
            return .terminal(failure(
                request: request,
                disposition: .failed,
                code: .guiHostBusy
            ))
        }
        if let windowID = openWindows[request.canonicalUDID] {
            return .terminal(GUIHostOpenLiveResult(
                requestID: request.requestID,
                disposition: request.sourceSelectionPolicy == .forceChooser
                    ? .sourceSelectionOpened
                    : .alreadyOpen,
                canonicalUDID: request.canonicalUDID,
                windowID: windowID,
                errorCode: nil
            ))
        }
        if reservedTargets.contains(request.canonicalUDID) {
            return .terminal(failure(
                request: request,
                disposition: .failed,
                code: .guiHostBusy
            ))
        }
        let (deadline, overflow) = now.addingReportingOverflow(
            Self.openLiveDeadlineNanoseconds
        )
        guard !overflow else {
            return .terminal(failure(
                request: request,
                disposition: .failed,
                code: .windowCreateFailed
            ))
        }
        let token = GUIHostOpenToken(
            canonicalUDID: request.canonicalUDID,
            connectionID: connectionID,
            deadlineNanoseconds: deadline,
            requestID: request.requestID,
            sourceSelectionPolicy: request.sourceSelectionPolicy
        )
        reservedTargets.insert(request.canonicalUDID)
        pending[request.requestID] = token
        return .pending(token)
    }

    public mutating func completeOpenLive(
        token: GUIHostOpenToken,
        windowID: String?,
        atMonotonicNanoseconds now: UInt64
    ) throws -> GUIHostOpenLiveResult {
        guard pending[token.requestID] == token else {
            throw GUIHostProcessError.requestNotFound
        }
        pending.removeValue(forKey: token.requestID)
        reservedTargets.remove(token.canonicalUDID)
        guard now < token.deadlineNanoseconds,
              let windowID,
              Self.validIdentifier(windowID)
        else {
            if let windowID, !Self.validIdentifier(windowID) {
                throw GUIHostProcessError.invalidWindowID
            }
            return GUIHostOpenLiveResult(
                requestID: token.requestID,
                disposition: .failed,
                canonicalUDID: nil,
                windowID: nil,
                errorCode: .windowCreateFailed
            )
        }
        openWindows[token.canonicalUDID] = windowID
        return GUIHostOpenLiveResult(
            requestID: token.requestID,
            disposition: token.sourceSelectionPolicy == .forceChooser
                ? .sourceSelectionOpened
                : .opened,
            canonicalUDID: token.canonicalUDID,
            windowID: windowID,
            errorCode: nil
        )
    }

    public mutating func closeConnection(connectionID: CanonicalUUID) {
        connections.removeValue(forKey: connectionID)
        let owned = pending.values.filter { $0.connectionID == connectionID }
        for token in owned {
            pending.removeValue(forKey: token.requestID)
            reservedTargets.remove(token.canonicalUDID)
        }
    }

    public mutating func closeWindow(
        canonicalUDID: CanonicalUDID,
        windowID: String
    ) throws {
        guard openWindows[canonicalUDID] == windowID else {
            throw GUIHostProcessError.staleWindowClose
        }
        openWindows.removeValue(forKey: canonicalUDID)
    }

    private func failure(
        request: GUIHostOpenLiveRequest,
        disposition: GUIHostOpenDisposition,
        code: GUIHostOpenErrorCode
    ) -> GUIHostOpenLiveResult {
        GUIHostOpenLiveResult(
            requestID: request.requestID,
            disposition: disposition,
            canonicalUDID: nil,
            windowID: nil,
            errorCode: code
        )
    }

    private static func validIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...128).contains(bytes.count)
            && bytes.allSatisfy { (0x21...0x7e).contains($0) }
    }
}

public enum GUIHostProcessEntrypoint {
    public static let roleArgument = "--gui-host"

    public static func handles(_ arguments: [String]) -> Bool {
        arguments.first == roleArgument
            || AudioPreviewHelperProcessEntrypoint.handles(arguments)
            || ProductionPerformanceCollectionEntrypoint.handles(arguments)
            || ProductionVideoSourceHandoffEntrypoint.handles(arguments)
    }

    public static func run(arguments: [String]) -> Int32 {
        if AudioPreviewHelperProcessEntrypoint.handles(arguments) {
            return AudioPreviewHelperProcessEntrypoint.run(arguments: arguments)
        }
        if ProductionPerformanceCollectionEntrypoint.handles(arguments) {
            return ProductionPerformanceCollectionEntrypoint.run(arguments: arguments)
        }
        if ProductionVideoSourceHandoffEntrypoint.handles(arguments) {
            return ProductionVideoSourceHandoffEntrypoint.run(arguments: arguments)
        }
        guard arguments == [roleArgument] else { return 64 }
        guard let appPath = try? CanonicalAppPath.resolveCurrentExecutable() else {
            return 0
        }
        guard Thread.isMainThread else { return 70 }
        return MainActor.assumeIsolated {
            do {
                let system = POSIXHostPathSystem()
                try ProductionGUIHostServer(
                    canonicalAppPath: appPath,
                    hostPaths: system.makeHostPathLayout()
                ).runAppKit()
                return 0
            } catch {
                return 70
            }
        }
    }
}
