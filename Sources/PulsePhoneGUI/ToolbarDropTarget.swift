public struct ToolbarDropCandidate: Equatable, Sendable {
    public let isRegularFile: Bool
    public let path: String

    public init(path: String, isRegularFile: Bool) {
        self.path = path
        self.isRegularFile = isRegularFile
    }
}

public enum ToolbarDropTargetError: Error, Equatable, Sendable {
    case invalidCandidate
    case multipleItems
}

public enum ToolbarDropTarget {
    public static func resolve(
        candidates: [ToolbarDropCandidate]
    ) throws -> ToolbarInstallParameter {
        guard candidates.count == 1 else {
            throw ToolbarDropTargetError.multipleItems
        }
        let candidate = candidates[0]
        guard candidate.isRegularFile,
              ToolbarPicker.validIPAPath(candidate.path)
        else {
            throw ToolbarDropTargetError.invalidCandidate
        }
        return ToolbarInstallParameter(absoluteIPAPath: candidate.path)
    }
}
