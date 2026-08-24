public struct LockButtonAction: Sendable {
    public static let descriptor = SystemButtonDescriptor.singlePress(
        commandID: "button.lock",
        routeID: "coredevice.button.lock",
        usage: 0x30,
        holdMilliseconds: 500
    )

    private let runner: SystemButtonActionRunner

    public init(transport: any SystemButtonTransport) {
        self.runner = SystemButtonActionRunner(transport: transport)
    }

    public func execute() throws -> SystemButtonExecution {
        try runner.execute(descriptor: Self.descriptor)
    }
}
