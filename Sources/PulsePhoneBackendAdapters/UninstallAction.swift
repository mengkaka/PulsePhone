public protocol UninstallTransport: Sendable {
    func requestUninstall(bundleID: String) throws
    func waitForUninstallComplete(
        bundleID: String,
        timeoutMilliseconds: UInt64
    ) throws -> Bool
}

public struct UninstallAction: Sendable {
    public static let commandID = "app.uninstall"
    public static let deadlineMilliseconds: UInt64 = 5 * 60 * 1_000
    public static let routeID = "direct.installationProxy.uninstall"

    private let transport: any UninstallTransport

    public init(transport: any UninstallTransport) {
        self.transport = transport
    }

    public func execute(bundleID: String) throws -> AppOperationActionResult {
        do {
            try transport.requestUninstall(bundleID: bundleID)
            guard try transport.waitForUninstallComplete(
                bundleID: bundleID,
                timeoutMilliseconds: Self.deadlineMilliseconds
            ) else {
                throw AppInstallationActionError.backendDidNotComplete
            }
            return AppOperationActionResult(
                bundleID: bundleID,
                disposition: "uninstalled"
            )
        } catch let error as AppInstallationActionError {
            throw error
        } catch {
            throw AppInstallationActionError.transportFailure
        }
    }
}
