public enum VolumeButtonDirection: String, CaseIterable, Sendable {
    case down
    case up
}

public struct VolumeButtonAction: Sendable {
    private let direction: VolumeButtonDirection
    private let runner: SystemButtonActionRunner

    public init(
        direction: VolumeButtonDirection,
        transport: any SystemButtonTransport
    ) {
        self.direction = direction
        self.runner = SystemButtonActionRunner(transport: transport)
    }

    public var descriptor: SystemButtonDescriptor {
        switch direction {
        case .up:
            return SystemButtonDescriptor.singlePress(
                commandID: "button.volumeUp",
                routeID: "coredevice.button.volumeUp",
                usage: 0xe9,
                holdMilliseconds: 50
            )
        case .down:
            return SystemButtonDescriptor.singlePress(
                commandID: "button.volumeDown",
                routeID: "coredevice.button.volumeDown",
                usage: 0xea,
                holdMilliseconds: 50
            )
        }
    }

    public func execute() throws -> SystemButtonExecution {
        try runner.execute(descriptor: descriptor)
    }
}
