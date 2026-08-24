public struct FenceToken: Equatable, Sendable {
    public let runtimeEpoch: UInt64
    public let connectionEpoch: UInt64
    public let executorGeneration: UInt64
    public let preparationAttemptID: String?
    public let operationID: String?
    public let attemptID: String?

    public init(
        runtimeEpoch: UInt64,
        connectionEpoch: UInt64,
        executorGeneration: UInt64,
        preparationAttemptID: String? = nil,
        operationID: String? = nil,
        attemptID: String? = nil
    ) throws {
        guard executorGeneration > 0,
              Self.validIdentifier(preparationAttemptID),
              Self.validIdentifier(operationID),
              Self.validIdentifier(attemptID),
              (operationID == nil) == (attemptID == nil)
        else {
            throw FenceTokenError.invalidIdentity
        }
        self.runtimeEpoch = runtimeEpoch
        self.connectionEpoch = connectionEpoch
        self.executorGeneration = executorGeneration
        self.preparationAttemptID = preparationAttemptID
        self.operationID = operationID
        self.attemptID = attemptID
    }

    private static func validIdentifier(_ value: String?) -> Bool {
        guard let value else {
            return true
        }
        let bytes = Array(value.utf8)
        return (1...256).contains(bytes.count)
            && bytes.allSatisfy { (0x21...0x7e).contains($0) }
    }
}

public enum FenceTokenError: Error, Equatable, Sendable {
    case invalidIdentity
}
