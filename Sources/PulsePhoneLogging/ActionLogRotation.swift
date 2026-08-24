public enum ActionLogRotationDecision: Equatable, Sendable {
    case appendCurrent
    case recordTooLarge
    case rotateThenAppend
}

public enum ActionLogRotation {
    public static let maximumFileBytes = 10 * 1_024 * 1_024

    public static func decide(
        currentByteCount: Int,
        currentRecordCount: Int,
        nextRecordByteCount: Int,
        maximumFileBytes: Int = maximumFileBytes
    ) -> ActionLogRotationDecision {
        guard maximumFileBytes > 0,
              nextRecordByteCount <= maximumFileBytes
        else { return .recordTooLarge }
        guard currentRecordCount > 0 else { return .appendCurrent }
        let (projected, overflow) = currentByteCount.addingReportingOverflow(
            nextRecordByteCount
        )
        guard !overflow, projected <= maximumFileBytes else {
            return .rotateThenAppend
        }
        return .appendCurrent
    }
}
