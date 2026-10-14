import Foundation
import Darwin

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
        isRegularFile: Bool = true,
        isDirectory: Bool = false
    ) throws -> ToolbarPickerResult {
        guard let selectedPath else { return .cancelled }
        guard validIPAPath(selectedPath), matchesInstallType(selectedPath, isRegularFile: isRegularFile, isDirectory: isDirectory) else {
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
            && ["ipa", "app"].contains((path as NSString).pathExtension.lowercased())
    }

    static func matchesInstallType(_ path: String, isRegularFile: Bool, isDirectory: Bool) -> Bool {
        (path as NSString).pathExtension.lowercased() == "app" ? isDirectory : isRegularFile
    }

    static func nodeTypes(_ path: String) -> (isRegularFile: Bool, isDirectory: Bool) {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else { return (false, false) }
        let type = metadata.st_mode & mode_t(S_IFMT)
        return (type == mode_t(S_IFREG) && metadata.st_size > 0, type == mode_t(S_IFDIR))
    }
}
