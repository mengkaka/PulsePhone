public enum ActionLogPolicy: String, Sendable {
  case clientHybridAppendOnce
  case existingRuntimeBestEffort
  case none
  case runtimeAppendOnce
}

public enum ReplayTracePolicy: String, Sendable {
  case none
  case semantic
}

public struct LoggingProfileDescriptor: Equatable, Sendable {
  public let actionLogPolicy: ActionLogPolicy
  public let loggingProfileID: String
  public let redactionPolicyID: String
  public let replayTracePolicy: ReplayTracePolicy

  public init(
    actionLogPolicy: ActionLogPolicy,
    loggingProfileID: String,
    redactionPolicyID: String,
    replayTracePolicy: ReplayTracePolicy
  ) {
    self.actionLogPolicy = actionLogPolicy
    self.loggingProfileID = loggingProfileID
    self.redactionPolicyID = redactionPolicyID
    self.replayTracePolicy = replayTracePolicy
  }
}
