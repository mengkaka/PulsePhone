import Foundation

public struct ToolbarInstallParameter: Equatable, Sendable {
    public let absoluteIPAPath: String

    public init(absoluteIPAPath: String) {
        self.absoluteIPAPath = absoluteIPAPath
    }
}

public enum ToolbarPickerResult: Equatable, Sendable {
    case accepted(ToolbarInstallParameter)
    case cancelled
}

public enum ToolbarPickerError: Error, Equatable, Sendable {
    case invalidIPAPath
}

public enum ToolbarPicker {
    public static func resolve(
        selectedPath: String?,
        isRegularFile: Bool = true
    ) throws -> ToolbarPickerResult {
        guard let selectedPath else { return .cancelled }
        guard isRegularFile, validIPAPath(selectedPath) else {
            throw ToolbarPickerError.invalidIPAPath
        }
        return .accepted(ToolbarInstallParameter(
            absoluteIPAPath: selectedPath
        ))
    }

    static func validIPAPath(_ path: String) -> Bool {
        path.hasPrefix("/")
            && !path.utf8.contains(0)
            && !path.contains("//")
            && !path.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).contains("..")
            && (path as NSString).standardizingPath == path
            && (path as NSString).pathExtension.lowercased() == "ipa"
    }
}
