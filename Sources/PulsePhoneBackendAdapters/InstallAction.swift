public enum AppInstallationActionError: Error, Equatable, Sendable {
    case backendDidNotComplete
    case transportFailure
}

public protocol InstallTransport: AFCUploadTransport {
    func finishAFCUpload() throws
    func waitForInstallComplete(
        timeoutMilliseconds: UInt64
    ) throws -> String?
}

public struct AppOperationActionResult: Codable, Equatable, Sendable {
    public let bundleID: String
    public let disposition: String

    public init(bundleID: String, disposition: String) {
        self.bundleID = bundleID
        self.disposition = disposition
    }
}

public struct InstallExecution: Equatable, Sendable {
    public let result: AppOperationActionResult
    public let upload: AFCUploadResult
}

public struct InstallAction: Sendable {
    public static let commandID = "app.install"
    public static let deadlineMilliseconds: UInt64 = 30 * 60 * 1_000
    public static let routeID = "direct.installationProxy.install"

    private let transport: any InstallTransport

    public init(transport: any InstallTransport) {
        self.transport = transport
    }

    public func execute() throws -> InstallExecution {
        let upload = try AFCUploadAction(transport: transport).execute()
        do {
            try transport.finishAFCUpload()
            guard let bundleID = try transport.waitForInstallComplete(
                timeoutMilliseconds: Self.deadlineMilliseconds
            ) else {
                throw AppInstallationActionError.backendDidNotComplete
            }
            return InstallExecution(
                result: AppOperationActionResult(
                    bundleID: bundleID,
                    disposition: "installed"
                ),
                upload: upload
            )
        } catch let error as AppInstallationActionError {
            throw error
        } catch {
            throw AppInstallationActionError.transportFailure
        }
    }
}
