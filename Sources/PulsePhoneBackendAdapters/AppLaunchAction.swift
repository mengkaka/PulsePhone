public enum AppLaunchRoute: String, Equatable, Sendable {
    case legacyDVT = "legacy.dvtLaunch"
    case modernCoreDevice = "coredevice.appLaunch"

    public var preparationGroupID: String {
        switch self {
        case .legacyDVT: return "prep.legacy.developer.v2"
        case .modernCoreDevice: return "prep.coredevice.v2"
        }
    }

    public static func resolve(osMajor: UInt64) throws -> AppLaunchRoute {
        switch osMajor {
        case 14..<17: return .legacyDVT
        case 17...: return .modernCoreDevice
        default: throw AppLaunchActionError.unsupportedOSMajor(osMajor)
        }
    }
}

public enum AppLaunchPreparationState: Equatable, Sendable {
    case failed(code: String)
    case ready
    case unavailable
}

public struct AppLaunchPreparation: Equatable, Sendable {
    public let preparationGroupID: String
    public let state: AppLaunchPreparationState

    public init(
        preparationGroupID: String,
        state: AppLaunchPreparationState
    ) {
        self.preparationGroupID = preparationGroupID
        self.state = state
    }
}

public enum AppLaunchActionError: Error, Equatable, Sendable {
    case unsupportedOSMajor(UInt64)
    case preparationGroupMismatch(expected: String, actual: String)
    case preparationNotReady(String)
    case developerSupportFailure(String)
    case backendDidNotComplete
    case transportFailure
}

public protocol AppLaunchTransport: Sendable {
    func launchCoreDevice(bundleID: String) throws
    func launchLegacyDVT(bundleID: String) throws
    func waitForLaunchComplete(
        route: AppLaunchRoute,
        timeoutMilliseconds: UInt64
    ) throws -> Bool
}

public struct AppLaunchExecution: Equatable, Sendable {
    public let result: AppOperationActionResult
    public let route: AppLaunchRoute
}

public struct AppLaunchAction: Sendable {
    public static let commandID = "app.launch"
    public static let deadlineMilliseconds: UInt64 = 60_000

    private let transport: any AppLaunchTransport

    public init(transport: any AppLaunchTransport) {
        self.transport = transport
    }

    public func execute(
        bundleID: String,
        osMajor: UInt64,
        preparation: AppLaunchPreparation
    ) throws -> AppLaunchExecution {
        let route = try AppLaunchRoute.resolve(osMajor: osMajor)
        guard preparation.preparationGroupID == route.preparationGroupID else {
            throw AppLaunchActionError.preparationGroupMismatch(
                expected: route.preparationGroupID,
                actual: preparation.preparationGroupID
            )
        }
        switch preparation.state {
        case .ready:
            break
        case .failed(let code):
            throw AppLaunchActionError.developerSupportFailure(code)
        case .unavailable:
            throw AppLaunchActionError.preparationNotReady(
                preparation.preparationGroupID
            )
        }

        do {
            switch route {
            case .modernCoreDevice:
                try transport.launchCoreDevice(bundleID: bundleID)
            case .legacyDVT:
                try transport.launchLegacyDVT(bundleID: bundleID)
            }
            guard try transport.waitForLaunchComplete(
                route: route,
                timeoutMilliseconds: Self.deadlineMilliseconds
            ) else {
                throw AppLaunchActionError.backendDidNotComplete
            }
        } catch let error as AppLaunchActionError {
            throw error
        } catch {
            throw AppLaunchActionError.transportFailure
        }

        return AppLaunchExecution(
            result: AppOperationActionResult(
                bundleID: bundleID,
                disposition: "launchRequested"
            ),
            route: route
        )
    }
}
