public enum HomeButtonActionError: Error, Equatable, Sendable {
    case transportFailure
    case cleanupAcknowledgementMissing
}

public protocol HomeButtonTransport: Sendable {
    func sendButton(
        usagePage: UInt16,
        usage: UInt16,
        pressed: Bool
    ) throws
    func wait(milliseconds: UInt64) throws
    func waitForCleanupAcknowledgement(
        timeoutMilliseconds: UInt64
    ) throws
}

public struct HomeButtonActionResult: Codable, Equatable, Sendable {
    public let disposition: String

    public init(disposition: String = "acknowledged") {
        self.disposition = disposition
    }
}

public struct HomeButtonSemanticLog: Equatable, Sendable {
    public let commandID: String
    public let inputReleased: Bool
    public let routeID: String
}

public struct HomeButtonExecution: Equatable, Sendable {
    public let result: HomeButtonActionResult
    public let semanticLog: HomeButtonSemanticLog
}

public struct HomeButtonAction: Sendable {
    public static let commandID = "button.home"
    public static let routeID = "coredevice.button.home"
    public static let usagePage: UInt16 = 0x0c
    public static let usage: UInt16 = 0x40
    public static let holdMilliseconds: UInt64 = 50
    public static let cleanupAcknowledgementMilliseconds: UInt64 = 2_000

    private let transport: any HomeButtonTransport

    public init(transport: any HomeButtonTransport) {
        self.transport = transport
    }

    public func execute() throws -> HomeButtonExecution {
        var pressed = false
        do {
            try transport.sendButton(
                usagePage: Self.usagePage,
                usage: Self.usage,
                pressed: true
            )
            pressed = true
            try transport.wait(milliseconds: Self.holdMilliseconds)
            try transport.sendButton(
                usagePage: Self.usagePage,
                usage: Self.usage,
                pressed: false
            )
            pressed = false
        } catch {
            if pressed {
                try? transport.sendButton(
                    usagePage: Self.usagePage,
                    usage: Self.usage,
                    pressed: false
                )
            }
            try cleanupAcknowledgement()
            throw HomeButtonActionError.transportFailure
        }
        try cleanupAcknowledgement()
        return HomeButtonExecution(
            result: HomeButtonActionResult(),
            semanticLog: HomeButtonSemanticLog(
                commandID: Self.commandID,
                inputReleased: true,
                routeID: Self.routeID
            )
        )
    }

    private func cleanupAcknowledgement() throws {
        do {
            try transport.waitForCleanupAcknowledgement(
                timeoutMilliseconds: Self.cleanupAcknowledgementMilliseconds
            )
        } catch {
            throw HomeButtonActionError.cleanupAcknowledgementMissing
        }
    }
}
