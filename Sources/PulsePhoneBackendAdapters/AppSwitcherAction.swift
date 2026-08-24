public enum SystemButtonActionError: Error, Equatable, Sendable {
    case transportFailure
    case cleanupAcknowledgementMissing
}

public protocol SystemButtonTransport: Sendable {
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

public enum SystemButtonStep: Equatable, Sendable {
    case button(pressed: Bool)
    case wait(milliseconds: UInt64)
}

public struct SystemButtonDescriptor: Equatable, Sendable {
    public let commandID: String
    public let deadlineMilliseconds: UInt64
    public let routeID: String
    public let steps: [SystemButtonStep]
    public let usage: UInt16
    public let usagePage: UInt16

    public init(
        commandID: String,
        routeID: String,
        usagePage: UInt16,
        usage: UInt16,
        deadlineMilliseconds: UInt64,
        steps: [SystemButtonStep]
    ) {
        self.commandID = commandID
        self.routeID = routeID
        self.usagePage = usagePage
        self.usage = usage
        self.deadlineMilliseconds = deadlineMilliseconds
        self.steps = steps
    }

    public static func singlePress(
        commandID: String,
        routeID: String,
        usage: UInt16,
        holdMilliseconds: UInt64
    ) -> SystemButtonDescriptor {
        SystemButtonDescriptor(
            commandID: commandID,
            routeID: routeID,
            usagePage: 0x0c,
            usage: usage,
            deadlineMilliseconds: 5_000,
            steps: [
                .button(pressed: true),
                .wait(milliseconds: holdMilliseconds),
                .button(pressed: false),
            ]
        )
    }
}

public struct SystemButtonActionResult: Codable, Equatable, Sendable {
    public let disposition: String

    public init(disposition: String = "acknowledged") {
        self.disposition = disposition
    }
}

public struct SystemButtonSemanticLog: Equatable, Sendable {
    public let commandID: String
    public let inputReleased: Bool
    public let routeID: String
}

public struct SystemButtonExecution: Equatable, Sendable {
    public let result: SystemButtonActionResult
    public let semanticLog: SystemButtonSemanticLog
}

struct SystemButtonActionRunner: Sendable {
    static let cleanupAcknowledgementMilliseconds: UInt64 = 2_000

    let transport: any SystemButtonTransport

    func execute(
        descriptor: SystemButtonDescriptor
    ) throws -> SystemButtonExecution {
        var pressed = false
        do {
            for step in descriptor.steps {
                switch step {
                case .button(let nextPressed):
                    try transport.sendButton(
                        usagePage: descriptor.usagePage,
                        usage: descriptor.usage,
                        pressed: nextPressed
                    )
                    pressed = nextPressed
                case .wait(let milliseconds):
                    try transport.wait(milliseconds: milliseconds)
                }
            }
        } catch {
            if pressed {
                try? transport.sendButton(
                    usagePage: descriptor.usagePage,
                    usage: descriptor.usage,
                    pressed: false
                )
            }
            try cleanupAcknowledgement()
            throw SystemButtonActionError.transportFailure
        }
        if pressed {
            try? transport.sendButton(
                usagePage: descriptor.usagePage,
                usage: descriptor.usage,
                pressed: false
            )
            try cleanupAcknowledgement()
            throw SystemButtonActionError.transportFailure
        }
        try cleanupAcknowledgement()
        return SystemButtonExecution(
            result: SystemButtonActionResult(),
            semanticLog: SystemButtonSemanticLog(
                commandID: descriptor.commandID,
                inputReleased: true,
                routeID: descriptor.routeID
            )
        )
    }

    private func cleanupAcknowledgement() throws {
        do {
            try transport.waitForCleanupAcknowledgement(
                timeoutMilliseconds: Self.cleanupAcknowledgementMilliseconds
            )
        } catch {
            throw SystemButtonActionError.cleanupAcknowledgementMissing
        }
    }
}

public struct AppSwitcherAction: Sendable {
    public static let descriptor = SystemButtonDescriptor(
        commandID: "button.appSwitcher",
        routeID: "coredevice.button.doubleHome",
        usagePage: 0x0c,
        usage: 0x40,
        deadlineMilliseconds: 10_000,
        steps: [
            .button(pressed: true),
            .wait(milliseconds: 35),
            .button(pressed: false),
            .wait(milliseconds: 120),
            .button(pressed: true),
            .wait(milliseconds: 35),
            .button(pressed: false),
        ]
    )

    private let runner: SystemButtonActionRunner

    public init(transport: any SystemButtonTransport) {
        self.runner = SystemButtonActionRunner(transport: transport)
    }

    public func execute() throws -> SystemButtonExecution {
        try runner.execute(descriptor: Self.descriptor)
    }
}
