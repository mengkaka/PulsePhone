import PulsePhoneCommandPlanner
import PulsePhoneSharedDefinitions

public enum LinearGestureActionError: Error, Equatable, Sendable {
    case commandMismatch
    case transportFailure
    case cleanupAcknowledgementMissing
}

public protocol LinearGestureTransport: Sendable {
    func sendFrame(_ frame: LinearGestureFrame) throws
    func waitForCleanupAcknowledgement(
        timeoutMilliseconds: UInt64
    ) throws
}

public struct LinearGestureExecutionRequest: Equatable, Sendable {
    public let currentGeometry: DisplayGeometryDTO
    public let expectedGeometry: GeometryAssertionDTO
    public let plan: LinearGesturePlan

    public init(
        plan: LinearGesturePlan,
        expectedGeometry: GeometryAssertionDTO,
        currentGeometry: DisplayGeometryDTO
    ) {
        self.plan = plan
        self.expectedGeometry = expectedGeometry
        self.currentGeometry = currentGeometry
    }
}

public struct LinearGestureActionResult: Codable, Equatable, Sendable {
    public let disposition: String

    public init(disposition: String = "acknowledged") {
        self.disposition = disposition
    }
}

public struct LinearGestureSemanticLog: Equatable, Sendable {
    public let commandID: String
    public let durationMilliseconds: UInt64
    public let frameCount: Int
    public let inputReleased: Bool
    public let routeID: String
}

public struct LinearGestureExecution: Equatable, Sendable {
    public let result: LinearGestureActionResult
    public let semanticLog: LinearGestureSemanticLog
}

struct LinearGestureActionRunner: Sendable {
    static let cleanupAcknowledgementMilliseconds: UInt64 = 2_000
    static let routeID = "coredevice.normalTouch"

    let transport: any LinearGestureTransport

    func execute(
        _ request: LinearGestureExecutionRequest,
        expectedCommandID: String
    ) throws -> LinearGestureExecution {
        guard request.plan.commandID == expectedCommandID else {
            throw LinearGestureActionError.commandMismatch
        }
        try request.expectedGeometry.validate(request.currentGeometry)

        var began = false
        var ended = false
        do {
            for frame in request.plan.frames {
                try transport.sendFrame(frame)
                began = began || frame.kind == .begin
                ended = ended || frame.kind == .end
            }
        } catch {
            if began, !ended, let end = request.plan.frames.last {
                try? transport.sendFrame(end)
            }
            try cleanupAcknowledgement()
            throw LinearGestureActionError.transportFailure
        }
        try cleanupAcknowledgement()
        return LinearGestureExecution(
            result: LinearGestureActionResult(),
            semanticLog: LinearGestureSemanticLog(
                commandID: expectedCommandID,
                durationMilliseconds: request.plan.durationMilliseconds,
                frameCount: request.plan.frames.count,
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
            throw LinearGestureActionError.cleanupAcknowledgementMissing
        }
    }
}

public struct DragAction: Sendable {
    public static let commandID = "touch.drag"
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
