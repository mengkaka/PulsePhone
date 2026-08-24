import PulsePhoneHostPaths
import PulsePhoneSharedDefinitions

public enum LiveLauncherStage: String, Equatable, Sendable {
    case ack
    case connect
    case createWindow
    case reserve
    case write
}

public enum LiveLauncherError: Error, Equatable, Sendable {
    case guiHostUnavailable(stage: LiveLauncherStage)
    case guiIPCFailure(stage: LiveLauncherStage)
    case guiLaunchOutcomeUnknown(stage: LiveLauncherStage)
}

public struct LiveLauncherTimed<Value: Sendable>: Sendable {
    public let completedAtNanoseconds: UInt64
    public let value: Value

    public init(value: Value, completedAtNanoseconds: UInt64) {
        self.value = value
        self.completedAtNanoseconds = completedAtNanoseconds
    }
}

public protocol LiveLauncherTransport: Sendable {
    func connectOrLaunch(
        endpoint: GUIHostEndpoint
    ) throws -> LiveLauncherTimed<Void>
    func hello(
        _ hello: GUIHostHello
    ) throws -> LiveLauncherTimed<GUIHostHelloAck>
    func openLive(
        _ request: GUIHostOpenLiveRequest
    ) throws -> LiveLauncherTimed<GUIHostOpenLiveResult>
}

public struct LiveLauncher: Sendable {
    public static let deadlineNanoseconds: UInt64 = 5_000_000_000

    private let canonicalAppPath: CanonicalAppPath
    private let endpoint: GUIHostEndpoint
    private let launcherBuildID: String
    private let launcherInstanceID: CanonicalUUID
    private let transport: any LiveLauncherTransport

    public init(
        canonicalAppPath: CanonicalAppPath,
        hostPaths: HostPathLayoutV1,
        launcherBuildID: String,
        launcherInstanceID: CanonicalUUID,
        transport: any LiveLauncherTransport
    ) throws {
        self.canonicalAppPath = canonicalAppPath
        self.endpoint = try GUIHostEndpoint(
            canonicalAppPath: canonicalAppPath,
            hostPaths: hostPaths
        )
        self.launcherBuildID = launcherBuildID
        self.launcherInstanceID = launcherInstanceID
        self.transport = transport
    }

    public func openLive(
        canonicalUDID: CanonicalUDID,
        requestID: CanonicalUUID,
        sourceSelectionPolicy: GUIHostSourceSelectionPolicy = .automatic,
        startedAtNanoseconds: UInt64
    ) throws -> GUIHostOpenLiveResult {
        let deadline = try absoluteDeadline(startedAtNanoseconds)
        let connected: LiveLauncherTimed<Void>
        do {
            connected = try transport.connectOrLaunch(endpoint: endpoint)
        } catch {
            throw LiveLauncherError.guiHostUnavailable(stage: .connect)
        }
        guard connected.completedAtNanoseconds < deadline else {
            throw LiveLauncherError.guiHostUnavailable(stage: .connect)
        }
        let hello = GUIHostHello(
            canonicalAppPathHash: canonicalAppPath.guiHostHash,
            guiHostCompatibilityID: GUIHostProcess.compatibilityID,
            launcherBuildID: launcherBuildID,
            launcherInstanceID: launcherInstanceID,
            wireRange: GUIHostWireRange(minimum: 1, maximum: 1)
        )
        let acknowledged: LiveLauncherTimed<GUIHostHelloAck>
        do {
            acknowledged = try transport.hello(hello)
        } catch {
            throw LiveLauncherError.guiIPCFailure(stage: .ack)
        }
        guard acknowledged.completedAtNanoseconds < deadline,
              acknowledged.value.canonicalAppPathHash
                == endpoint.canonicalAppPathHash,
              acknowledged.value.guiHostCompatibilityID
                == GUIHostProcess.compatibilityID,
              acknowledged.value.selectedWireMajor == 1
        else {
            throw LiveLauncherError.guiIPCFailure(stage: .ack)
        }
        let request = GUIHostOpenLiveRequest(
            requestID: requestID,
            canonicalUDID: canonicalUDID,
            sourceSelectionPolicy: sourceSelectionPolicy
        )
        let result: LiveLauncherTimed<GUIHostOpenLiveResult>
        do {
            result = try transport.openLive(request)
        } catch {
            throw LiveLauncherError.guiLaunchOutcomeUnknown(stage: .write)
        }
        guard result.completedAtNanoseconds < deadline else {
            throw LiveLauncherError.guiLaunchOutcomeUnknown(
                stage: .createWindow
            )
        }
        guard result.value.requestID == requestID else {
            throw LiveLauncherError.guiIPCFailure(stage: .ack)
        }
        return result.value
    }

    private func absoluteDeadline(_ start: UInt64) throws -> UInt64 {
        let (deadline, overflow) = start.addingReportingOverflow(
            Self.deadlineNanoseconds
        )
        guard !overflow else {
            throw LiveLauncherError.guiHostUnavailable(stage: .connect)
        }
        return deadline
    }
}
