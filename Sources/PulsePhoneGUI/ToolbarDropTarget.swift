public struct ToolbarDropCandidate: Equatable, Sendable {
    public let isRegularFile: Bool
    public let isDirectory: Bool
    public let path: String

    public init(path: String, isRegularFile: Bool, isDirectory: Bool = false) {
        self.path = path
        self.isRegularFile = isRegularFile
        self.isDirectory = isDirectory
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
        guard ToolbarPicker.matchesInstallType(candidate.path, isRegularFile: candidate.isRegularFile, isDirectory: candidate.isDirectory),
              ToolbarPicker.validIPAPath(candidate.path)
        else {
            throw ToolbarDropTargetError.invalidCandidate
        }
        return ToolbarInstallParameter(absoluteIPAPath: candidate.path)
    }
}
