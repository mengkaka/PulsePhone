public enum ErrorFamily: String, CaseIterable, Sendable {
    case `internal`
    case argument
    case targetCompatibility
    case runtimeProtocol
    case admissionBusy
    case knownCommandFailure
    case unknownOutcome
    case interrupted

    public var exitCode: Int32 {
        switch self {
        case .internal:
            1
        case .argument:
            2
        case .targetCompatibility:
            3
        case .runtimeProtocol:
            4
        case .admissionBusy:
            5
        case .knownCommandFailure:
            6
        case .unknownOutcome:
            7
        case .interrupted:
            130
        }
    }
}
