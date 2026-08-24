public struct SwipeAction: Sendable {
    public static let commandID = "touch.swipe"
    public static let routeID = LinearGestureActionRunner.routeID

    private let runner: LinearGestureActionRunner

    public init(transport: any LinearGestureTransport) {
        self.runner = LinearGestureActionRunner(transport: transport)
    }

    public func execute(
        _ request: LinearGestureExecutionRequest
    ) throws -> LinearGestureExecution {
        try runner.execute(request, expectedCommandID: Self.commandID)
    }
}
