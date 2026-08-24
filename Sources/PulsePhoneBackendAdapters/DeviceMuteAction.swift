public struct DeviceMuteAction: Sendable {
    public static let descriptor = SystemButtonDescriptor.singlePress(
        commandID: "button.mute",
        routeID: "coredevice.button.mute",
        usage: 0xe2,
        holdMilliseconds: 50
    )

    private let runner: SystemButtonActionRunner

    public init(transport: any SystemButtonTransport) {
        self.runner = SystemButtonActionRunner(transport: transport)
    }

    public func execute() throws -> SystemButtonExecution {
        try runner.execute(descriptor: Self.descriptor)
    }
}
