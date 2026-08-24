import PulsePhoneSharedDefinitions

public enum RuntimeLaunchArgumentError: Error, Equatable, Sendable {
  case duplicateOption(String)
  case invalidCanonicalUDID
  case missingOption(String)
  case unexpectedArgument(String)

  public var standardErrorCode: String {
    switch self {
    case .invalidCanonicalUDID:
      return "invalidArgument"
    case .duplicateOption, .missingOption, .unexpectedArgument:
      return "internalFailure"
    }
  }
}

public struct RuntimeLaunchArguments: Equatable, Sendable {
  public static let startupDeadlineNanoseconds: UInt64 = 5_000_000_000
  public static let helpText = """
    PulsePhoneRuntime

    Internal per-device Runtime process.

    Usage:
      PulsePhoneRuntime --canonical-udid <UDID>
      PulsePhoneRuntime --help
    """

  public let canonicalUDID: CanonicalUDID

  public init(canonicalUDID: CanonicalUDID) {
    self.canonicalUDID = canonicalUDID
  }

  public static func isHelpRequest(_ arguments: [String]) -> Bool {
    Array(arguments.dropFirst()) == ["--help"]
      || Array(arguments.dropFirst()) == ["help"]
  }

  public static func parse(_ arguments: [String]) throws -> RuntimeLaunchArguments {
    var canonicalUDID: CanonicalUDID?
    var index = 1
    while index < arguments.count {
      let option = arguments[index]
      guard option == "--canonical-udid" else {
        throw RuntimeLaunchArgumentError.unexpectedArgument(option)
      }
      guard canonicalUDID == nil else {
        throw RuntimeLaunchArgumentError.duplicateOption(option)
      }
      index += 1
      guard index < arguments.count else {
        throw RuntimeLaunchArgumentError.missingOption(option)
      }
      do {
        canonicalUDID = try CanonicalUDID(canonicalString: arguments[index])
      } catch {
        throw RuntimeLaunchArgumentError.invalidCanonicalUDID
      }
      index += 1
    }
    guard let canonicalUDID else {
      throw RuntimeLaunchArgumentError.missingOption("--canonical-udid")
    }
    return RuntimeLaunchArguments(canonicalUDID: canonicalUDID)
  }
}
